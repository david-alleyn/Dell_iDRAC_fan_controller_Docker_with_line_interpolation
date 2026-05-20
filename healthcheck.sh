#!/bin/bash

# `set -e` is intentionally omitted (see Dell_iDRAC_fan_controller.sh).
# `-u` catches unset variables, `-o pipefail` propagates pipe failures.

source functions.sh

set -uo pipefail

set_iDRAC_login_args

ipmitool "${IPMITOOL_ARGS[@]}" sdr type temperature
