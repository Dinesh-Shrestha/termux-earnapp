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

_prefix_port="$(mktemp -d)"
mkdir -p "$_prefix_port/etc/ssh"
printf 'Port 2222\n' > "$_prefix_port/etc/ssh/sshd_config"
t_eq "sshd_port reads configured port" "2222" \
  "$(PREFIX="$_prefix_port" sshd_port)"
printf '#Port 22\nPort 2200\nPort 2201\n' > "$_prefix_port/etc/ssh/sshd_config"
t_eq "sshd_port uses the first configured port" "2200" \
  "$(PREFIX="$_prefix_port" sshd_port)"
printf 'Port nope\n' > "$_prefix_port/etc/ssh/sshd_config"
t_eq "sshd_port defaults on invalid config" "8022" \
  "$(PREFIX="$_prefix_port" sshd_port)"
rm -rf "$_prefix_port"

_prefix_empty="$(mktemp -d)"
t_eq "sshd_port defaults without config" "8022" \
  "$(PREFIX="$_prefix_empty" sshd_port)"
rm -rf "$_prefix_empty"

_mock_ip="$(mktemp -d)"
cat > "$_mock_ip/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-4 -o addr show dev wlan0")
    printf '3: wlan0    inet 192.168.1.42/24 brd 192.168.1.255 scope global wlan0\n'
    ;;
esac
SH
chmod +x "$_mock_ip/ip"
t_eq "local_ipv4 uses wlan0 address" "192.168.1.42" \
  "$(PATH="$_mock_ip:$PATH" local_ipv4)"
rm -rf "$_mock_ip"

_mock_route="$(mktemp -d)"
cat > "$_mock_route/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-4 -o addr show dev wlan0") ;;
  "-4 route get 1.1.1.1")
    printf '1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.43 uid 0\n'
    ;;
esac
SH
chmod +x "$_mock_route/ip"
t_eq "local_ipv4 falls back to the route source" "192.168.1.43" \
  "$(PATH="$_mock_route:$PATH" local_ipv4)"
rm -rf "$_mock_route"

t_eq "parse_ifconfig_ipv4 accepts net-tools output" "192.168.1.44" \
  "$(printf 'wlan0: flags=4163<UP>\n        inet addr:192.168.1.44  Bcast:192.168.1.255  Mask:255.255.255.0\n' | parse_ifconfig_ipv4)"
t_eq "parse_ifconfig_ipv4 accepts toybox output" "192.168.1.46" \
  "$(printf 'wlan0   Link encap:Ethernet\n          inet 192.168.1.46  netmask 255.255.255.0\n' | parse_ifconfig_ipv4)"
t_eq "parse_ifconfig_ipv4 selects a named interface" "192.168.1.65" \
  "$(printf 'lo: flags=73<UP>\n        inet 127.0.0.1  netmask 255.0.0.0\nrmnet5: flags=4305<UP>\n        inet 10.33.77.62  netmask 255.255.255.0\nwlan0: flags=4163<UP>\n        inet 192.168.1.65  netmask 255.255.255.0\n' | parse_ifconfig_ipv4 wlan0)"

_mock_ifconfig="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$_mock_ifconfig/ip"
cat > "$_mock_ifconfig/ifconfig" <<'SH'
#!/usr/bin/env bash
if [ "$#" -gt 0 ]; then
  exit 1
fi
cat <<'OUT'
lo: flags=73<UP>
        inet 127.0.0.1  netmask 255.0.0.0
rmnet5: flags=4305<UP>
        inet 10.33.77.62  netmask 255.255.255.0
wlan0: flags=4163<UP>
        inet 192.168.1.65  netmask 255.255.255.0
OUT
SH
chmod +x "$_mock_ifconfig/ip" "$_mock_ifconfig/ifconfig"
t_eq "local_ipv4 falls back to full ifconfig" "192.168.1.65" \
  "$(PATH="$_mock_ifconfig:$PATH" local_ipv4)"
rm -rf "$_mock_ifconfig"

_mock_getprop="$(mktemp -d)"
printf '#!/bin/sh\nprintf "192.168.1.45\\n"\n' > "$_mock_getprop/getprop"
chmod +x "$_mock_getprop/getprop"
t_eq "local_ipv4 falls back to getprop" "192.168.1.45" \
  "$(PATH="$_mock_getprop" local_ipv4)"
rm -rf "$_mock_getprop"

_mock_none="$(mktemp -d)"
t_eq "local_ipv4 falls back to localhost" "localhost" \
  "$(PATH="$_mock_none" local_ipv4)"
rm -rf "$_mock_none"

_mock_target="$(mktemp -d)"
printf '#!/usr/bin/env bash\nprintf "tester\\n"\n' > "$_mock_target/whoami"
cat > "$_mock_target/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-4 -o addr show dev wlan0")
    printf '3: wlan0    inet 192.168.1.42/24 brd 192.168.1.255 scope global wlan0\n'
    ;;
esac
SH
chmod +x "$_mock_target/whoami" "$_mock_target/ip"
t_eq "ssh_target combines user and local address" "tester@192.168.1.42" \
  "$(PATH="$_mock_target:$PATH" ssh_target)"
rm -rf "$_mock_target"

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
