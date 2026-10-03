#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../earnapp-setup.sh"

pass=0
fail=0

t_eq() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s (expected=%q actual=%q)\n' "$name" "$expected" "$actual" >&2
  fi
}

t_contains() {
  local name=$1 needle=$2
  shift 2
  if list_contains "$needle" "$@"; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s (missing %s)\n' "$name" "$needle" >&2
  fi
}

t_not_contains() {
  local name=$1 needle=$2
  shift 2
  if list_contains "$needle" "$@"; then
    fail=$((fail + 1))
    printf 'FAIL  %s (unexpected %s)\n' "$name" "$needle" >&2
  else
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$name"
  fi
}

t_has() {
  local name=$1 needle=$2 hay=$3
  case "$hay" in
    *"$needle"*) pass=$((pass + 1)); printf 'PASS  %s\n' "$name" ;;
    *) fail=$((fail + 1)); printf 'FAIL  %s (missing %s)\n' "$name" "$needle" >&2 ;;
  esac
}

plan_of() {
  printf '%s\n' "$1" | sed -n 's/^.*\[INFO\] Setup plan: //p' | head -n 1
}

reset_state
parse_args
t_eq "no args -> menu mode" "menu" "$MODE"

reset_state
parse_args --earnapp
t_eq "--earnapp sets flags mode" "flags" "$MODE"
t_contains "--earnapp requests earnapp" earnapp "${REQUESTED[@]}"

reset_state
parse_args --speedtest-go
t_contains "--speedtest-go requests package" speedtest-go "${REQUESTED[@]}"
resolve_request speedtest-go >/dev/null
t_eq "speedtest-go resolves base dependency" "base speedtest-go" "${_ord[*]}"

reset_state
parse_args --all
t_contains "--all includes speedtest-go" speedtest-go "${REQUESTED[@]}"

reset_state
parse_args --all --no-speedtest-go
t_not_contains "--no-speedtest-go strips optional package" speedtest-go "${REQUESTED[@]}"

reset_state
parse_args --all --no-sshd
t_contains    "--all keeps boot"              boot        "${REQUESTED[@]}"
t_contains    "--all keeps earnapp"           earnapp     "${REQUESTED[@]}"
t_not_contains "--no-sshd strips sshd"         sshd        "${REQUESTED[@]}"
t_contains    "--no-sshd keeps other comps"   cloudflared "${REQUESTED[@]}"

reset_state
parse_args --no-sshd
t_eq "--no-sshd alone starts from all, flags mode" "flags" "$MODE"
t_contains    "--no-sshd alone keeps udocker" udocker "${REQUESTED[@]}"
t_not_contains "--no-sshd alone strips sshd"   sshd    "${REQUESTED[@]}"

reset_state
parse_args --uuid "sdk-node-$(printf 'a%.0s' $(seq 1 32))"
t_eq "--uuid captured" "sdk-node-$(printf 'a%.0s' $(seq 1 32))" "$CLI_UUID"

reset_state
if ( parse_args --unknown-flag ) >/dev/null 2>&1; then
  fail=$((fail + 1)); printf 'FAIL  unknown flag must die\n' >&2
else
  pass=$((pass + 1)); printf 'PASS  unknown flag dies\n'
fi

if bash "$SCRIPT_DIR/../earnapp-setup.sh" --help >/dev/null 2>&1; then
  pass=$((pass + 1)); printf 'PASS  --help exits 0\n'
else
  fail=$((fail + 1)); printf 'FAIL  --help exits nonzero\n' >&2
fi

reset_state
if ( parse_args --uuid --dry-run ) >/dev/null 2>&1; then
  fail=$((fail + 1)); printf 'FAIL  --uuid with flag value must die\n' >&2
else
  pass=$((pass + 1)); printf 'PASS  --uuid rejects a flag as value\n'
fi

reset_state
t_contains "dep skip rejected" "[ERROR] --no-udocker conflicts with the resolved plan: a requested component depends on udocker" "$( ( parse_args --all --no-udocker; run_setup ) 2>&1 )"

if ( run_component bogus ) >/dev/null 2>&1; then
  fail=$((fail + 1)); printf 'FAIL  unknown component must die\n' >&2
else
  pass=$((pass + 1)); printf 'PASS  unknown component dies\n'
fi

reset_state
is_termux() { return 0; }
if menu </dev/null >/dev/null 2>&1; then
  pass=$((pass + 1)); printf 'PASS  menu EOF exits cleanly\n'
else
  fail=$((fail + 1)); printf 'FAIL  menu EOF must exit 0\n' >&2
fi
unset -f is_termux

reset_state
DRY_RUN=1
MOCKDIR30="$(mktemp -d)"
_wd_home="$(mktemp -d)"
out=$(HOME="$_wd_home" PATH="$MOCKDIR30" menu_run sshd 2>&1); rc=$?
rm -rf "$MOCKDIR30" "$_wd_home"
t_eq "menu_run sshd resolves to base boot sshd" "base boot sshd" "$(plan_of "$out")"
t_has "menu_run sshd refreshes package lists" "pkg update -y" "$out"
t_has "menu_run sshd reaches the sshd component" "=== sshd ===" "$out"

_wd_pu="$(printf '%s\n' "$out" | grep -n 'pkg update -y' | head -n 1 | cut -d: -f1)"
_wd_sshd="$(printf '%s\n' "$out" | grep -n '=== sshd ===' | head -n 1 | cut -d: -f1)"
t_eq "menu_run runs base before sshd" "ordered" \
  "$([ -n "$_wd_pu" ] && [ -n "$_wd_sshd" ] && [ "$_wd_pu" -lt "$_wd_sshd" ] && echo ordered || echo misordered)"

for _wd_opt in boot udocker; do
  reset_state
  DRY_RUN=1
  _wd_m="$(mktemp -d)"
  _wd_h="$(mktemp -d)"
  _wd_o=$(HOME="$_wd_h" PATH="$_wd_m" menu_run "$_wd_opt" 2>&1)
  rm -rf "$_wd_m" "$_wd_h"
  t_eq "menu_run $_wd_opt resolves dependencies" "base $_wd_opt" "$(plan_of "$_wd_o")"
done

reset_state
DRY_RUN=1
_wd_m="$(mktemp -d)"
_wd_h="$(mktemp -d)"
_wd_o=$(HOME="$_wd_h" PATH="$_wd_m" menu_run cloudflared 2>&1)
rm -rf "$_wd_m" "$_wd_h"
t_eq "menu_run cloudflared includes service prerequisites" "base boot cloudflared" "$(plan_of "$_wd_o")"

reset_state
DRY_RUN=1
MOCKDIR42="$(mktemp -d)"
_wd_h="$(mktemp -d)"
_wd_o=$(HOME="$_wd_h" PATH="$MOCKDIR42" menu_run speedtest-go 2>&1)
rm -rf "$MOCKDIR42" "$_wd_h"
t_eq "menu_run speedtest-go resolves base dependency" "base speedtest-go" "$(plan_of "$_wd_o")"
t_has "menu_run speedtest-go refreshes Termux package lists" "pkg update -y" "$_wd_o"
t_has "menu_run speedtest-go installs Termux package" "pkg install speedtest-go -y" "$_wd_o"

reset_state
DRY_RUN=1
MOCKDIR43="$(mktemp -d)"
_wd_h="$(mktemp -d)"
_wd_o=$( { is_termux() { return 0; }
  HOME="$_wd_h" PATH="$MOCKDIR43:/usr/bin:/bin" menu
} <<< "7" 2>&1 )
rm -rf "$MOCKDIR43" "$_wd_h"
t_has "menu exposes speedtest-go option" "7) speedtest-go (install CLI)" "$_wd_o"
t_eq "menu option 7 dispatches speedtest-go" "base speedtest-go" "$(plan_of "$_wd_o")"

reset_state
DRY_RUN=1
REQUESTED=(stale-garbage)
MOCKDIR31="$(mktemp -d)"
_wd_h="$(mktemp -d)"
_wd_req=$( { HOME="$_wd_h" PATH="$MOCKDIR31" menu_run base >/dev/null 2>&1; printf '%s\n' "${REQUESTED[*]}"; } )
rm -rf "$MOCKDIR31" "$_wd_h"
t_eq "menu_run rebuilds REQUESTED from its arguments" "base" "$_wd_req"

reset_state
DRY_RUN=0
MOCKDIR32="$(mktemp -d)"
_wd_o=$( { PATH="$MOCKDIR32" menu_run sshd; printf 'SENTINEL\n'; } 2>&1)
rm -rf "$MOCKDIR32"
t_has "menu_run survives a failing component" "SENTINEL" "$_wd_o"
t_has "menu_run logs the failure" "Setup did not complete; returning to menu" "$_wd_o"

reset_state
DRY_RUN=1
MOCKDIR33="$(mktemp -d)"
_wd_h="$(mktemp -d)"
_wd_o=$( { is_termux() { return 0; }
  HOME="$_wd_h" PATH="$MOCKDIR33:/usr/bin:/bin" menu
  printf 'SENTINEL\n'; } <<< "3
0" 2>&1 )
rm -rf "$MOCKDIR33" "$_wd_h"
t_eq "menu option 3 resolves dependencies" "base boot sshd" "$(plan_of "$_wd_o")"

reset_state
DRY_RUN=1
MOCKDIR34="$(mktemp -d)"
_wd_h="$(mktemp -d)"
out=$(HOME="$_wd_h" PATH="$MOCKDIR34" menu_run base boot sshd cloudflared udocker earnapp 2>&1)
rm -rf "$MOCKDIR34" "$_wd_h"
t_eq "menu_run keeps every argument" "base boot sshd cloudflared udocker earnapp" "$(plan_of "$out")"

reset_state
DRY_RUN=1
MOCKDIR35="$(mktemp -d)"
_wd_h="$(mktemp -d)"
HOME="$_wd_h" PATH="$MOCKDIR35" menu_run base boot sshd >/dev/null 2>&1; _wd_rc=$?
rm -rf "$MOCKDIR35" "$_wd_h"
t_eq "menu_run returns 0 on success" "0" "$_wd_rc"

reset_state
DRY_RUN=0
MOCKDIR36="$(mktemp -d)"
PATH="$MOCKDIR36" menu_run sshd >/dev/null 2>&1; _wd_rc=$?
rm -rf "$MOCKDIR36"
t_eq "menu_run returns non-zero on failure" "1" "$_wd_rc"

reset_state
DRY_RUN=1
MOCKDIR37="$(mktemp -d)"
_wd_h="$(mktemp -d)"
_wd_o=$( { is_termux() { return 0; }
  HOME="$_wd_h" PATH="$MOCKDIR37:/usr/bin:/bin" menu
  printf 'SENTINEL\n'; } <<< "3
0
3
0" 2>&1 )
rm -rf "$MOCKDIR37" "$_wd_h"
t_eq "menu exits after a successful option" "1" "$(printf '%s\n' "$_wd_o" | grep -c 'Select an option')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
