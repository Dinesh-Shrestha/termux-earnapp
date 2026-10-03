#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../earnapp-setup.sh"

pass=0
fail=0

t_ok() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$name" >&2
  fi
}

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

t_not_ok() {
  local name=$1
  shift
  if ( "$@" ) >/dev/null 2>&1; then
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$name" >&2
  else
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$name"
  fi
}

HEX32="$(printf 'a%.0s' $(seq 1 32))"

t_ok "validate_uuid accepts 32 lowercase hex"        validate_uuid "sdk-node-$HEX32"
t_not_ok "validate_uuid rejects 31 hex"              validate_uuid "sdk-node-${HEX32%?}"
t_not_ok "validate_uuid rejects uppercase hex"       validate_uuid "sdk-node-$(printf 'A%.0s' $(seq 1 32))"
t_not_ok "validate_uuid rejects wrong prefix"        validate_uuid "sdk-linux-$HEX32"
t_not_ok "validate_uuid rejects non-hex char"        validate_uuid "sdk-node-${HEX32%?}g"

for i in $(seq 1 5); do
  u=$(gen_uuid)
  t_ok "gen_uuid run $i matches format" validate_uuid "$u"
done

t_eq "detect_arch aarch64"  "linux/arm64"  "$(detect_arch aarch64)"
t_eq "detect_arch armv7l"   "linux/arm/v7" "$(detect_arch armv7l)"
t_eq "detect_arch armv8l"   "linux/arm/v7" "$(detect_arch armv8l)"
t_eq "detect_arch x86_64"   "linux/amd64"  "$(detect_arch x86_64)"
t_eq "detect_arch amd64"    "linux/amd64"  "$(detect_arch amd64)"
t_not_ok "detect_arch unsupported dies" detect_arch mips

t_eq "normalize linux/arm64"    "linux/arm64" "$(normalize_platform linux/arm64)"
t_eq "normalize linux/arm64/v8" "linux/arm64" "$(normalize_platform linux/arm64/v8)"
t_eq "normalize linux/arm/v7"   "linux/arm"   "$(normalize_platform linux/arm/v7)"
t_eq "normalize linux/amd64"    "linux/amd64" "$(normalize_platform linux/amd64)"

t_ok "match arm64==arm64"    platform_matches linux/arm64 linux/arm64
t_ok "match arm64==arm64/v8" platform_matches linux/arm64 linux/arm64/v8
t_ok "match arm/v7==arm/v7"  platform_matches linux/arm/v7 linux/arm/v7
t_not_ok "mismatch arm64!=arm/v7" platform_matches linux/arm64 linux/arm/v7
t_not_ok "mismatch amd64!=arm64"  platform_matches linux/amd64 linux/arm64

t_eq "parse_image_platform real line" "linux/arm64" \
  "$(parse_image_platform 'linux/arm64        . ghcr.io/xterna/earnapp:alpine')"
t_eq "parse_image_platform no match" "" \
  "$(parse_image_platform 'linux/arm64        . busybox:latest')"

plan_one() {
  resolve_request "$@" | tr '\n' ' ' | sed 's/ $//'
}

t_eq "deps_of boot->base"         "base"         "$(deps_of boot)"
t_eq "deps_of earnapp"            "base boot udocker" "$(deps_of earnapp | tr '\n' ' ' | sed 's/ $//')"
t_eq "resolve [earnapp]"          "base boot udocker earnapp"       "$(plan_one earnapp)"
t_eq "resolve [sshd earnapp]"     "base boot sshd udocker earnapp"  "$(plan_one sshd earnapp)"
t_eq "resolve [udocker earnapp udocker]" "base udocker boot earnapp" "$(plan_one udocker earnapp udocker)"
t_eq "resolve [cloudflared]"      "base boot cloudflared"           "$(plan_one cloudflared)"
t_eq "resolve [sshd cloudflared]" "base boot sshd cloudflared"       "$(plan_one sshd cloudflared)"

t_ok "list_contains present" list_contains base base boot sshd
t_not_ok "list_contains absent" list_contains udocker base boot sshd
t_not_ok "list_contains empty"  list_contains base

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
