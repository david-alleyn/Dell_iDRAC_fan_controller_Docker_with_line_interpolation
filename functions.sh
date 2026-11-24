# shellcheck shell=bash
# Define global functions

# These variables are set inside functions and read by the sourcing script.
# shellcheck disable=SC2034
declare CURRENT_FAN_CONTROL_PROFILE INLET_TEMPERATURE EXHAUST_TEMPERATURE

# Last fan state successfully written to the iDRAC, so commands are only sent
# when the target actually changes:
#   ""      unknown (startup, or the last write failed) -> next apply always sends
#   "dell"  Dell default dynamic fan control profile
#   <n>     manual fan control at <n>% (decimal)
APPLIED_FAN_STATE=""

# This function applies Dell's default dynamic fan control profile
function apply_Dell_fan_control_profile () {
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
  if [ "$APPLIED_FAN_STATE" = "dell" ]; then
    return 0
  fi
  # Use ipmitool to send the raw command to set fan control to Dell default
  if ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0x30 0x01 0x01 > /dev/null; then
    APPLIED_FAN_STATE="dell"
  else
    APPLIED_FAN_STATE=""
    return 1
  fi
}

# Apply a manual (user-controlled) fan control profile at the given speed.
# Only talks to the iDRAC when the speed differs from the last one applied, and
# only re-enables manual mode when coming from Dell default (or unknown) state.
# Usage: apply_manual_fan_control_profile <profile_label> <decimal_speed> <hex_speed>
function apply_manual_fan_control_profile () {
  local PROFILE_LABEL=$1
  local DECIMAL_SPEED=$2
  local HEX_SPEED=$3
  CURRENT_FAN_CONTROL_PROFILE="$PROFILE_LABEL ($DECIMAL_SPEED%)"

  if [ "$APPLIED_FAN_STATE" = "$DECIMAL_SPEED" ]; then
    return 0
  fi

  # Switch to manual fan control unless we're already in it.
  if [ -z "$APPLIED_FAN_STATE" ] || [ "$APPLIED_FAN_STATE" = "dell" ]; then
    if ! ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0x30 0x01 0x00 > /dev/null; then
      APPLIED_FAN_STATE=""
      return 1
    fi
  fi
  # Set the fan speed.
  if ipmitool "${IPMITOOL_ARGS[@]}" raw 0x30 0x30 0x02 0xff "$HEX_SPEED" > /dev/null; then
    APPLIED_FAN_STATE="$DECIMAL_SPEED"
  else
    APPLIED_FAN_STATE=""
    return 1
  fi
}

# Returns 0 if the argument is a non-negative integer.
function is_integer () {
  [[ $1 =~ ^[0-9]+$ ]]
}

# Returns 0 if every temperature the controller expects was read as a number.
# Usage : temperatures_are_valid $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
function temperatures_are_valid () {
  local IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=$1
  local IS_CPU2_TEMPERATURE_SENSOR_PRESENT=$2
  is_integer "$INLET_TEMPERATURE" || return 1
  is_integer "$CPU1_TEMPERATURE" || return 1
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
    is_integer "$CPU2_TEMPERATURE" || return 1
  fi
  if $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT; then
    is_integer "$EXHAUST_TEMPERATURE" || return 1
  fi
  return 0
}

function apply_user_fan_control_profile () {
  apply_manual_fan_control_profile "User static fan control profile" "$DECIMAL_FAN_SPEED" "$HEXADECIMAL_FAN_SPEED"
}

function apply_fan_speed_interpolation_fan_control_profile () {
  apply_manual_fan_control_profile "Interpolated fan control profile" "$DECIMAL_CURRENT_FAN_SPEED" "$HEXADECIMAL_CURRENT_FAN_SPEED"
}

# Calculate interpolated fan speed for a given CPU temperature.
# Linearly interpolates between LOWER_FAN at LOWER_TEMP and HIGHER_FAN at UPPER_TEMP,
# clamping outside that range. Multiplication is performed before division to
# preserve integer precision (unlike the broken upstream variant).
# Usage : calculate_interpolated_fan_speed CPU_TEMP LOWER_TEMP UPPER_TEMP LOWER_FAN HIGHER_FAN
# Echoes the resulting fan speed (decimal).
function calculate_interpolated_fan_speed () {
  local CPU_TEMP=$1
  local LOWER_TEMP=$2
  local UPPER_TEMP=$3
  local LOWER_FAN=$4
  local HIGHER_FAN=$5

  # Degenerate or below-floor range: hold at the lower fan speed.
  if [ "$CPU_TEMP" -le "$LOWER_TEMP" ] || [ "$UPPER_TEMP" -le "$LOWER_TEMP" ]; then
    echo "$LOWER_FAN"
    return
  fi
  # At or above the ceiling: clamp to higher fan speed.
  if [ "$CPU_TEMP" -ge "$UPPER_TEMP" ]; then
    echo "$HIGHER_FAN"
    return
  fi
  echo $((LOWER_FAN + (HIGHER_FAN - LOWER_FAN) * (CPU_TEMP - LOWER_TEMP) / (UPPER_TEMP - LOWER_TEMP)))
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
  DATA=$(ipmitool "${IPMITOOL_ARGS[@]}" "${SDR_CACHE_ARGS[@]}" sdr type temperature | grep degrees)

  # Extract the digits immediately before " degrees C". This avoids the
  # earlier `\d{2}` regex which would have parsed 100°C as "10".
  local CPU_DATA
  CPU_DATA=$(echo "$DATA" | grep "3\." | grep -Po '\d+(?= degrees C)')
  CPU1_TEMPERATURE=$(echo "$CPU_DATA" | sed -n 1p)
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
  then
    CPU2_TEMPERATURE=$(echo "$CPU_DATA" | sed -n 2p)
  else
    CPU2_TEMPERATURE="-"
  fi

  # Parse inlet temperature data
  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | grep -Po '\d+(?= degrees C)' | tail -1)

  # If exhaust temperature sensor is present, parse its temperature data
  if $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
  then
    EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | grep -Po '\d+(?= degrees C)' | tail -1)
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

# Run a command until it succeeds, up to MAX_ATTEMPTS times, waiting
# DELAY_SECONDS between attempts. Returns the last attempt's exit status.
# Usage : retry MAX_ATTEMPTS DELAY_SECONDS command [args...]
function retry () {
  local -r MAX_ATTEMPTS=$1
  local -r DELAY_SECONDS=$2
  shift 2
  local ATTEMPT=1
  local STATUS
  while true
  do
    "$@"
    STATUS=$?
    if [ "$STATUS" -eq 0 ] || [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]
    then
      return "$STATUS"
    fi
    echo "Attempt $ATTEMPT/$MAX_ATTEMPTS of '$1' failed, retrying in ${DELAY_SECONDS}s..." >&2
    ATTEMPT=$((ATTEMPT + 1))
    sleep "$DELAY_SECONDS"
  done
}

# Number of attempts and delay for each restore command on exit. The iDRAC
# regularly drops IPMI sessions, and a restore that silently fails would leave
# the fans at a fixed manual speed with nothing controlling them.
EXIT_RESTORE_ATTEMPTS=5
EXIT_RESTORE_RETRY_DELAY=2

# Prepare traps in case of container exit
function graceful_exit () {
  echo "Gracefully exit"
  local RESTORE_FAILED=false

  # Always send on exit, regardless of what we think was last applied.
  APPLIED_FAN_STATE=""
  if ! retry "$EXIT_RESTORE_ATTEMPTS" "$EXIT_RESTORE_RETRY_DELAY" apply_Dell_fan_control_profile
  then
    echo "/!\ ERROR /!\ Could not restore the Dell default dynamic fan control profile after $EXIT_RESTORE_ATTEMPTS attempts. The fans may be stuck at a fixed manual speed: check the iDRAC and restore automatic fan control manually." >&2
    RESTORE_FAILED=true
  fi

  # Reset third-party PCIe card cooling response to Dell default depending on the user's choice at startup
  if ! $KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT
  then
    if ! retry "$EXIT_RESTORE_ATTEMPTS" "$EXIT_RESTORE_RETRY_DELAY" enable_third_party_PCIe_card_Dell_default_cooling_response
    then
      echo "/!\ ERROR /!\ Could not re-enable the third-party PCIe card Dell default cooling response after $EXIT_RESTORE_ATTEMPTS attempts." >&2
      RESTORE_FAILED=true
    fi
  fi

  if $RESTORE_FAILED
  then
    exit 1
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

# ---- SDR (sensor list) cache -------------------------------------------------
# Without a cache, every "sdr type temperature" over lanplus re-downloads the
# iDRAC's whole sensor list before reading any values: ~14-21s per read on an
# R630. With the list cached locally (ipmitool -S), only the live readings are
# fetched: ~0.1s. The list only changes with hardware/firmware changes, so it
# is dumped once at startup and rebuilt if reads keep failing.
SDR_CACHE_FILE=${SDR_CACHE_FILE:-/tmp/idrac_sdr.cache}
# Extra ipmitool arguments for sdr reads: (-S file) when the cache is in use.
SDR_CACHE_ARGS=()
# Rebuild the cache after this many invalid reads in a row while it's in use.
SDR_CACHE_REBUILD_AFTER_INVALID_READS=3
CONSECUTIVE_INVALID_READS=0

# Dump the iDRAC sensor list to SDR_CACHE_FILE and start using it. Writes to a
# temporary file first and moves it into place only if the dump succeeded and
# isn't empty, so readers (e.g. the healthcheck) never see a partial file.
# Returns non-zero, and deletes/stops using any cache, if the dump fails.
function build_sdr_cache () {
  local -r TEMPORARY_FILE="$SDR_CACHE_FILE.tmp.$$"
  if ipmitool "${IPMITOOL_ARGS[@]}" sdr dump "$TEMPORARY_FILE" > /dev/null &&
     [ -s "$TEMPORARY_FILE" ] &&
     mv -f "$TEMPORARY_FILE" "$SDR_CACHE_FILE"
  then
    SDR_CACHE_ARGS=(-S "$SDR_CACHE_FILE")
    return 0
  fi
  # Also remove any older cache, so the healthcheck stops using it too.
  rm -f "$TEMPORARY_FILE" "$SDR_CACHE_FILE"
  SDR_CACHE_ARGS=()
  return 1
}

# Use an existing cache file without building one (for the healthcheck,
# which must never write the cache itself).
function use_existing_sdr_cache () {
  if [ -s "$SDR_CACHE_FILE" ]
  then
    SDR_CACHE_ARGS=(-S "$SDR_CACHE_FILE")
  else
    SDR_CACHE_ARGS=()
  fi
}

# Record the result of a temperature read. After
# SDR_CACHE_REBUILD_AFTER_INVALID_READS invalid reads in a row while the cache
# is in use, assume it may be stale (hardware/firmware change) and rebuild it,
# falling back to uncached reads if the rebuild fails.
# Usage : record_temperature_read_result valid|invalid
function record_temperature_read_result () {
  if [ "$1" = "valid" ]
  then
    CONSECUTIVE_INVALID_READS=0
    return 0
  fi
  CONSECUTIVE_INVALID_READS=$((CONSECUTIVE_INVALID_READS + 1))
  if [ "${#SDR_CACHE_ARGS[@]}" -gt 0 ] && [ "$CONSECUTIVE_INVALID_READS" -ge "$SDR_CACHE_REBUILD_AFTER_INVALID_READS" ]
  then
    echo "$CONSECUTIVE_INVALID_READS invalid temperature reads in a row, rebuilding the iDRAC sensor list cache in case it is stale..." >&2
    CONSECUTIVE_INVALID_READS=0
    if build_sdr_cache
    then
      echo "Sensor list cache rebuilt." >&2
    else
      echo "/!\ Could not rebuild the sensor list cache, continuing without it (slower reads)." >&2
    fi
  fi
}

# Populate the global IPMITOOL_ARGS array based on IDRAC_HOST. Used by both
# the main controller and the healthcheck so the LAN/local setup stays
# consistent across entry points.
function set_iDRAC_login_args () {
  if [[ $IDRAC_HOST == "local" ]]
  then
    # Check that the Docker host IPMI device (the iDRAC) has been exposed to the Docker container
    if [ ! -e "/dev/ipmi0" ] && [ ! -e "/dev/ipmi/0" ] && [ ! -e "/dev/ipmidev/0" ]; then
      echo "/!\ Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0, check that you added the device to your Docker container or stop using local mode. Exiting." >&2
      exit 1
    fi
    IPMITOOL_ARGS=(-I open)
  else
    echo "iDRAC/IPMI username: $IDRAC_USERNAME"
    IPMITOOL_ARGS=(-I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USERNAME" -P "$IDRAC_PASSWORD")
  fi
}
