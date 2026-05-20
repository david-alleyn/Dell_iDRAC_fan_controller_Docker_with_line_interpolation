# shellcheck shell=bash
# Define global functions

# These variables are set inside functions and read by the sourcing script.
# shellcheck disable=SC2034
declare CURRENT_FAN_CONTROL_PROFILE INLET_TEMPERATURE EXHAUST_TEMPERATURE

# This function applies Dell's default dynamic fan control profile
function apply_Dell_fan_control_profile () {
  # Use ipmitool to send the raw command to set fan control to Dell default
  ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0x30 0x01 0x01 > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

# This function applies a user-specified static fan control profile
function apply_user_fan_control_profile () {
  # Use ipmitool to send the raw command to set fan control to user-specified value
  ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0x30 0x01 0x00 > /dev/null
  ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0x30 0x02 0xff "$HEXADECIMAL_FAN_SPEED" > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"
}

# This function applies a user-specified interpolated fan control profile
function apply_fan_speed_interpolation_fan_control_profile () {
  ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0x30 0x01 0x00 > /dev/null
  ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0x30 0x02 0xff "$HEXADECIMAL_CURRENT_FAN_SPEED" > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="Interpolated fan control profile ($DECIMAL_CURRENT_FAN_SPEED%)"
}

# Convert DECIMAL_NUMBER to hexadecimal
# Usage : convert_decimal_value_to_hexadecimal $DECIMAL_NUMBER
# Returns : hexadecimal value of DECIMAL_NUMBER
function convert_decimal_value_to_hexadecimal () {
  local DECIMAL_NUMBER=$1
  local HEXADECIMAL_NUMBER
  HEXADECIMAL_NUMBER=$(printf '0x%02x' "$DECIMAL_NUMBER")
  echo "$HEXADECIMAL_NUMBER"
}

# Retrieve temperature sensors data using ipmitool
# Usage : retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
function retrieve_temperatures () {
  if (( $# != 2 ))
  then
    printf "Illegal number of parameters.\nUsage: retrieve_temperatures \$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT \$IS_CPU2_TEMPERATURE_SENSOR_PRESENT" >&2
    return 1
  fi
  local IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=$1
  local IS_CPU2_TEMPERATURE_SENSOR_PRESENT=$2

  local DATA
  DATA=$(ipmitool "${IPMITOOL_ARGS[@]}" sdr type temperature | grep degrees)

  # Parse CPU data. grep -Po outputs one match per line; previously the code
  # relied on bash word-splitting to flatten the lines, which awk would then
  # column-index. Use explicit line selection so quoting is safe.
  local CPU_DATA
  CPU_DATA=$(echo "$DATA" | grep "3\." | grep -Po '\d{2}')
  CPU1_TEMPERATURE=$(echo "$CPU_DATA" | sed -n 1p)
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
  then
    CPU2_TEMPERATURE=$(echo "$CPU_DATA" | sed -n 2p)
  else
    CPU2_TEMPERATURE="-"
  fi

  # Parse inlet temperature data
  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | grep -Po '\d{2}' | tail -1)

  # If exhaust temperature sensor is present, parse its temperature data
  if $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
  then
    EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | grep -Po '\d{2}' | tail -1)
  else
    EXHAUST_TEMPERATURE="-"
  fi
}

function enable_third_party_PCIe_card_Dell_default_cooling_response () {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00 > /dev/null
}

function disable_third_party_PCIe_card_Dell_default_cooling_response () {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 > /dev/null
}

# Returns :
# - 0 if third-party PCIe card Dell default cooling response is currently DISABLED
# - 1 if third-party PCIe card Dell default cooling response is currently ENABLED
# - 2 if the current status returned by ipmitool command output is unexpected
# function is_third_party_PCIe_card_Dell_default_cooling_response_disabled() {
#   THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE=$(ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00)

#   if [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 01 00 00" ]; then
#     return 0
#   elif [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 00 00 00" ]; then
#     return 1
#   else
#     echo "Unexpected output: $THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" >&2
#     return 2
#   fi
# }

# Prepare traps in case of container exit
function graceful_exit () {
  echo "Gracefully exit"
  apply_Dell_fan_control_profile

  # Reset third-party PCIe card cooling response to Dell default depending on the user's choice at startup
  if ! $KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT
  then
    enable_third_party_PCIe_card_Dell_default_cooling_response
  fi

  echo "/!\ WARNING /!\ Container stopped, Dell default dynamic fan control profile applied for safety."
  exit 0
}

# Helps debugging when people are posting their output
function get_Dell_server_model () {
  # FRU stands for "Field Replaceable Unit"
  if ! IPMI_FRU_content=$(ipmitool "${IPMITOOL_ARGS[@]}" fru 2>/dev/null); then
    echo "Failed to retrieve iDRAC data, please check IP and credentials." >&2
    return
  fi

  SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | grep "Product Manufacturer" | awk -F ': ' '{print $2}')
  SERVER_MODEL=$(echo "$IPMI_FRU_content" | grep "Product Name" | awk -F ': ' '{print $2}')

  # Check if SERVER_MANUFACTURER is empty, if yes, assign value based on "Board Mfg"
  if [ -z "$SERVER_MANUFACTURER" ]; then
    SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Mfg :" | awk -F ': ' '{print $2}')
  fi

  # Check if SERVER_MODEL is empty, if yes, assign value based on "Board Product"
  if [ -z "$SERVER_MODEL" ]; then
    SERVER_MODEL=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Product :" | awk -F ': ' '{print $2}')
  fi
}

# Define functions to check if CPU 1 and CPU 2 temperatures are above the threshold
function CPU1_OVERHEAT() { [ "$CPU1_TEMPERATURE" -gt "$CPU_TEMPERATURE_THRESHOLD" ]; }
function CPU2_OVERHEAT() { [ "$CPU2_TEMPERATURE" -gt "$CPU_TEMPERATURE_THRESHOLD" ]; }
