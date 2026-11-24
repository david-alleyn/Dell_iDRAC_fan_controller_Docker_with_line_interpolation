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

section "retry"
ATTEMPTS_FILE=$(mktemp)
# Fails until the Nth call, recording each call in ATTEMPTS_FILE.
succeed_on () { echo x >> "$ATTEMPTS_FILE"; [ "$(wc -l < "$ATTEMPTS_FILE")" -ge "$1" ]; }
: > "$ATTEMPTS_FILE"
assert_eq "success first try: status 0"   "0" "$(retry 3 0 succeed_on 1 2>/dev/null; echo $?)"
assert_eq "success first try: 1 call"     "1" "$(wc -l < "$ATTEMPTS_FILE")"
: > "$ATTEMPTS_FILE"
assert_eq "success on 3rd try: status 0"  "0" "$(retry 5 0 succeed_on 3 2>/dev/null; echo $?)"
assert_eq "success on 3rd try: 3 calls"   "3" "$(wc -l < "$ATTEMPTS_FILE")"
: > "$ATTEMPTS_FILE"
assert_eq "never succeeds: status 1"      "1" "$(retry 4 0 succeed_on 99 2>/dev/null; echo $?)"
assert_eq "never succeeds: 4 calls"       "4" "$(wc -l < "$ATTEMPTS_FILE")"

section "graceful_exit retries the restore commands"
# Each stubbed ipmitool call consumes one result from IPMITOOL_RESULTS_FILE
# (0 = success, 1 = failure; success once the list runs out).
IPMITOOL_RESULTS_FILE=$(mktemp)
ipmitool () {
  shift 2
  echo "$*" >> "$ATTEMPTS_FILE"
  local RESULT; RESULT=$(head -n 1 "$IPMITOOL_RESULTS_FILE")
  sed -i 1d "$IPMITOOL_RESULTS_FILE"
  return "${RESULT:-0}"
}
run_exit () { ( KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false; EXIT_RESTORE_RETRY_DELAY=0 graceful_exit ) > /dev/null 2>&1; echo $?; }

: > "$ATTEMPTS_FILE"; printf '1\n1\n0\n1\n0\n' > "$IPMITOOL_RESULTS_FILE"
assert_eq "transient failures: exit 0"         "0" "$(run_exit)"
assert_eq "fan restore sent 3x"                "3" "$(grep -c '0x30 0x30 0x01 0x01' "$ATTEMPTS_FILE")"
assert_eq "PCIe restore sent 2x"               "2" "$(grep -c '0x30 0xce' "$ATTEMPTS_FILE")"

: > "$ATTEMPTS_FILE"; printf '1\n1\n1\n1\n1\n0\n' > "$IPMITOOL_RESULTS_FILE"
assert_eq "fan restore never succeeds: exit 1" "1" "$(run_exit)"
assert_eq "fan restore given up after 5"       "5" "$(grep -c '0x30 0x30 0x01 0x01' "$ATTEMPTS_FILE")"
assert_eq "PCIe restore still attempted"       "1" "$(grep -c '0x30 0xce' "$ATTEMPTS_FILE")"
unset -f ipmitool
rm -f "$ATTEMPTS_FILE" "$IPMITOOL_RESULTS_FILE"

section "SDR cache"
CACHE_DIR=$(mktemp -d)
SDR_CACHE_FILE="$CACHE_DIR/sdr.cache"
IPMITOOL_ARGS=(-I stub)
CALLS_FILE="$CACHE_DIR/calls"
# ipmitool runs inside $(...) subshells, so calls are recorded in a file.
reset_calls () { : > "$CALLS_FILE"; }
first_call () { head -n 1 "$CALLS_FILE"; }
reset_calls
# DUMP_MODE: ok = write a cache file, empty = succeed but write nothing, fail = exit 1
DUMP_MODE=ok
ipmitool () {
  shift 2
  echo "$*" >> "$CALLS_FILE"
  if [ "$1 $2" = "sdr dump" ]
  then
    case $DUMP_MODE in
      ok) echo "sdr data" > "$3" ;;
      empty) : > "$3" ;;
      fail) echo "partial" > "$3"; return 1 ;;
    esac
    return 0
  fi
  printf 'Temp | 0Eh | ok | 3.1 | 45 degrees C\n'
}

DUMP_MODE=ok
assert_eq "dump ok: status 0"               "0" "$(build_sdr_cache; echo $?)"
build_sdr_cache
assert_eq "dump ok: cache args set"         "-S $SDR_CACHE_FILE" "${SDR_CACHE_ARGS[*]}"
assert_eq "dump ok: file in place"          "sdr data" "$(cat "$SDR_CACHE_FILE")"
assert_eq "dump ok: no temp file left"      "1" "$(find "$CACHE_DIR" -type f ! -name calls | wc -l)"
reset_calls
retrieve_temperatures false false
assert_eq "read uses -S when cached"        "-S $SDR_CACHE_FILE sdr type temperature" "$(first_call)"
assert_eq "read parses CPU1 with cache"     "45" "$CPU1_TEMPERATURE"

DUMP_MODE=fail
build_sdr_cache
assert_eq "dump fails: status 1"            "1" "$(build_sdr_cache; echo $?)"
assert_eq "dump fails: cache args cleared"  "" "${SDR_CACHE_ARGS[*]}"
assert_eq "dump fails: old cache removed"   "0" "$(find "$CACHE_DIR" -type f ! -name calls | wc -l)"
reset_calls
retrieve_temperatures false false
assert_eq "read without -S when uncached"   "sdr type temperature" "$(first_call)"

rm -f "$SDR_CACHE_FILE"; DUMP_MODE=empty
assert_eq "empty dump: status 1"            "1" "$(build_sdr_cache; echo $?)"
assert_eq "empty dump: no file left"        "0" "$(find "$CACHE_DIR" -type f ! -name calls | wc -l)"

section "stale cache rebuild"
DUMP_MODE=ok; build_sdr_cache; CONSECUTIVE_INVALID_READS=0
dump_count () { grep -c '^sdr dump' "$CALLS_FILE"; }
reset_calls
record_temperature_read_result invalid 2>/dev/null
record_temperature_read_result invalid 2>/dev/null
assert_eq "2 invalid: no rebuild"           "0" "$(dump_count)"
record_temperature_read_result valid
record_temperature_read_result invalid 2>/dev/null
record_temperature_read_result invalid 2>/dev/null
assert_eq "valid read resets the count"     "0" "$(dump_count)"
record_temperature_read_result invalid 2>/dev/null
assert_eq "3 in a row: one rebuild"         "1" "$(dump_count)"
assert_eq "count reset after rebuild"       "0" "$CONSECUTIVE_INVALID_READS"
DUMP_MODE=fail
reset_calls
for _ in 1 2 3; do record_temperature_read_result invalid 2>/dev/null; done
assert_eq "failed rebuild: falls back"      "" "${SDR_CACHE_ARGS[*]}"
reset_calls
for _ in 1 2 3 4 5 6; do record_temperature_read_result invalid 2>/dev/null; done
assert_eq "no cache: never rebuilds"        "0" "$(dump_count)"
unset -f ipmitool
rm -rf "$CACHE_DIR"

printf '\n\033[1mResults:\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFailures:\033[0m\n'
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure"
  done
  exit 1
fi
