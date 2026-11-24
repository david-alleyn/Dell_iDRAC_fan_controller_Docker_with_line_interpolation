#!/bin/bash
# Pure-bash test runner. Run from repo root:
#   tests/run.sh
#
# Tests pure functions from functions.sh. ipmitool is never invoked.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

source ./functions.sh

PASS=0
FAIL=0
declare -a FAILURES=()

assert_eq () {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    printf '  \033[32mok\033[0m  %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: expected '$expected', got '$actual'")
    printf '  \033[31mFAIL\033[0m %s (expected %q, got %q)\n' "$name" "$expected" "$actual"
  fi
}

section () { printf '\n\033[1m%s\033[0m\n' "$1"; }

section "convert_decimal_value_to_hexadecimal"
assert_eq "0 → 0x00"    "0x00" "$(convert_decimal_value_to_hexadecimal 0)"
assert_eq "5 → 0x05"    "0x05" "$(convert_decimal_value_to_hexadecimal 5)"
assert_eq "12 → 0x0c"   "0x0c" "$(convert_decimal_value_to_hexadecimal 12)"
assert_eq "16 → 0x10"   "0x10" "$(convert_decimal_value_to_hexadecimal 16)"
assert_eq "60 → 0x3c"   "0x3c" "$(convert_decimal_value_to_hexadecimal 60)"
assert_eq "100 → 0x64"  "0x64" "$(convert_decimal_value_to_hexadecimal 100)"

section "calculate_interpolated_fan_speed (F1=12, F2=60, T1=38, T2=79)"
# Below or at lower threshold clamps to F1.
assert_eq "T=20 → 12"   "12" "$(calculate_interpolated_fan_speed 20 38 79 12 60)"
assert_eq "T=38 → 12"   "12" "$(calculate_interpolated_fan_speed 38 38 79 12 60)"
# Interpolated values verified against the upstream formula
# F1 + (F2-F1) * (T-T1) / (T2-T1), with multiplication BEFORE division.
assert_eq "T=41 → 15"   "15" "$(calculate_interpolated_fan_speed 41 38 79 12 60)"
assert_eq "T=42 → 16"   "16" "$(calculate_interpolated_fan_speed 42 38 79 12 60)"
assert_eq "T=50 → 26"   "26" "$(calculate_interpolated_fan_speed 50 38 79 12 60)"
assert_eq "T=70 → 49"   "49" "$(calculate_interpolated_fan_speed 70 38 79 12 60)"
# At or above upper threshold clamps to F2.
assert_eq "T=79 → 60"   "60" "$(calculate_interpolated_fan_speed 79 38 79 12 60)"
assert_eq "T=99 → 60"   "60" "$(calculate_interpolated_fan_speed 99 38 79 12 60)"
# 3-digit (100°C+) temperature handled correctly — the earlier `\d{2}` regex bug
# would parse 100°C as "10". The function itself doesn't parse; covered by
# retrieve_temperatures, but we verify the math still clamps sensibly here.
assert_eq "T=100 → 60"  "60" "$(calculate_interpolated_fan_speed 100 38 79 12 60)"
# Degenerate ranges should not panic.
assert_eq "T1==T2 → F1" "10" "$(calculate_interpolated_fan_speed 50 50 50 10 40)"
assert_eq "T1>T2 → F1"  "10" "$(calculate_interpolated_fan_speed 50 80 50 10 40)"

section "is_integer"
assert_eq "55 valid"        "0" "$(is_integer 55; echo $?)"
assert_eq "100 valid"       "0" "$(is_integer 100; echo $?)"
assert_eq "empty invalid"   "1" "$(is_integer ""; echo $?)"
assert_eq "'-' invalid"     "1" "$(is_integer "-"; echo $?)"
assert_eq "'4 5' invalid"   "1" "$(is_integer "4 5"; echo $?)"
assert_eq "'-5' invalid"    "1" "$(is_integer "-5"; echo $?)"

section "temperatures_are_valid"
INLET_TEMPERATURE=22 CPU1_TEMPERATURE=55 CPU2_TEMPERATURE=50 EXHAUST_TEMPERATURE=35
assert_eq "all valid"                 "0" "$(temperatures_are_valid true true; echo $?)"
CPU1_TEMPERATURE=""
assert_eq "empty CPU1"                "1" "$(temperatures_are_valid true true; echo $?)"
CPU1_TEMPERATURE=55 CPU2_TEMPERATURE=""
assert_eq "empty CPU2 (present)"      "1" "$(temperatures_are_valid true true; echo $?)"
CPU2_TEMPERATURE="-"
assert_eq "CPU2 '-' (absent)"         "0" "$(temperatures_are_valid true false; echo $?)"
EXHAUST_TEMPERATURE=""
assert_eq "empty exhaust (present)"   "1" "$(temperatures_are_valid true false; echo $?)"
EXHAUST_TEMPERATURE="-"
assert_eq "exhaust '-' (absent)"      "0" "$(temperatures_are_valid false false; echo $?)"
INLET_TEMPERATURE=""
assert_eq "empty inlet"               "1" "$(temperatures_are_valid false false; echo $?)"

section "fan commands only sent on change"
# Stub ipmitool: record the raw bytes of each call; fail when IPMITOOL_FAIL=1.
IPMITOOL_ARGS=(-I stub)
IPMITOOL_CALLS=()
IPMITOOL_FAIL=0
ipmitool () { shift 2; IPMITOOL_CALLS+=("$*"); [ "$IPMITOOL_FAIL" -eq 0 ]; }
calls () { local IFS='|'; echo "${IPMITOOL_CALLS[*]}"; }

APPLIED_FAN_STATE=""
apply_manual_fan_control_profile "P" 31 0x1f
assert_eq "unknown -> manual: enable + speed" "raw 0x30 0x30 0x01 0x00|raw 0x30 0x30 0x02 0xff 0x1f" "$(calls)"; IPMITOOL_CALLS=()
apply_manual_fan_control_profile "P" 31 0x1f
assert_eq "same speed: nothing sent"          "" "$(calls)"; IPMITOOL_CALLS=()
assert_eq "label still updated"               "P (31%)" "$CURRENT_FAN_CONTROL_PROFILE"
apply_manual_fan_control_profile "P" 32 0x20
assert_eq "new speed: speed only"             "raw 0x30 0x30 0x02 0xff 0x20" "$(calls)"; IPMITOOL_CALLS=()
apply_Dell_fan_control_profile
assert_eq "manual -> Dell: one command"       "raw 0x30 0x30 0x01 0x01" "$(calls)"; IPMITOOL_CALLS=()
apply_Dell_fan_control_profile
assert_eq "Dell again: nothing sent"          "" "$(calls)"; IPMITOOL_CALLS=()
apply_manual_fan_control_profile "P" 32 0x20
assert_eq "Dell -> manual: enable + speed"    "raw 0x30 0x30 0x01 0x00|raw 0x30 0x30 0x02 0xff 0x20" "$(calls)"; IPMITOOL_CALLS=()
IPMITOOL_FAIL=1
apply_manual_fan_control_profile "P" 40 0x28
assert_eq "failed write resets state"         "" "$APPLIED_FAN_STATE"
IPMITOOL_CALLS=()
IPMITOOL_FAIL=0
apply_manual_fan_control_profile "P" 40 0x28
assert_eq "after failure: full resend"        "raw 0x30 0x30 0x01 0x00|raw 0x30 0x30 0x02 0xff 0x28" "$(calls)"; IPMITOOL_CALLS=()
unset -f ipmitool

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFailures:\033[0m\n'
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure"
  done
  exit 1
fi
