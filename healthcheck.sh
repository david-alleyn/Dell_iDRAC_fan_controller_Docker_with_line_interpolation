#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh

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
  #echo "iDRAC/IPMI password: $IDRAC_PASSWORD"
  IPMITOOL_ARGS=(-I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USERNAME" -P "$IDRAC_PASSWORD")
fi

ipmitool "${IPMITOOL_ARGS[@]}" sdr type temperature
