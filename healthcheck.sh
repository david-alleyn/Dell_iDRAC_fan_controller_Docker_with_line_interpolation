#!/bin/bash

# `set -e` is intentionally omitted (see Dell_iDRAC_fan_controller.sh).
# `-u` catches unset variables, `-o pipefail` propagates pipe failures.

source functions.sh

set -uo pipefail

set_iDRAC_login_args

# Use the controller's sensor list cache if it has built one (never build it
# here: only the controller writes it).
use_existing_sdr_cache

ipmitool "${IPMITOOL_ARGS[@]}" "${SDR_CACHE_ARGS[@]}" sdr type temperature
