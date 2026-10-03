#!/usr/bin/env bash
set -u

SITE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/site/index.html"
pass=0
fail=0

check() {
  local name=$1 pattern=$2
  if grep -Eq "$pattern" "$SITE_FILE"; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$name" >&2
  fi
}

check "copy action is a labeled button" '<button[^>]*id="copy-command"[^>]*>Copy command</button>'
check "copy feedback is announced accessibly" 'id="copy-status"[^>]*aria-live="polite"'
check "copy action uses clipboard API" 'navigator\.clipboard\.writeText'
check "copy action has a fallback" 'execCommand\(["\x27]copy["\x27]\)'
check "page includes mobile viewport metadata" 'name="viewport"'
check "page includes a responsive layout breakpoint" '@media'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
