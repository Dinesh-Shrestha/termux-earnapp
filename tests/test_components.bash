#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../earnapp-setup.sh"

pass=0
fail=0

check() {
  local name=$1 hay=$2 needle=$3 rc=$4
  if [ "$rc" -ne 0 ]; then
    fail=$((fail + 1))
    printf 'FAIL  %s (exit %s)\n' "$name" "$rc" >&2
    printf '%s\n' "$hay" >&2
  elif case "$hay" in *"$needle"*) true ;; *) false ;; esac; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s (missing: %s)\n' "$name" "$needle" >&2
    printf '%s\n' "$hay" >&2
  fi
}

run_cap() {
  out=$( "$@" 2>&1 )
  rc=$?
}

HEX32="$(printf 'a%.0s' $(seq 1 32))"

reset_state
DRY_RUN=1
REQUESTED=(base)
run_cap setup_base
check "base explicit runs pkg update" "$out" "pkg update -y" "$rc"
check "base force-confold"            "$out" "Dpkg::Options::=--force-confold" "$rc"
check "base force-confdef"            "$out" "Dpkg::Options::=--force-confdef" "$rc"

_wd_home="$(mktemp -d)"

MOCKDIR19="$(mktemp -d)"
out=$(HOME="$_wd_home" PATH="$MOCKDIR19" setup_boot 2>&1); rc=$?
check "boot installs termux-services" "$out" "pkg install termux-services -y" "$rc"
check "boot writes start-services"    "$out" "start-services" "$rc"
check "boot prints boot reminder"      "$out" "Termux:Boot" "$rc"
rm -rf "$MOCKDIR19"

MOCKDIR20="$(mktemp -d)"
printf '#!/usr/bin/env bash\nprintf "down: %%s: 1s, normally down\\n" "$2"\n' > "$MOCKDIR20/sv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR20/sv-enable"
chmod +x "$MOCKDIR20/sv" "$MOCKDIR20/sv-enable"
out=$(HOME="$_wd_home" PATH="$MOCKDIR20" setup_sshd 2>&1); rc=$?
check "sshd installs openssh" "$out" "pkg install openssh -y" "$rc"
check "sshd sv-enable"        "$out" "sv-enable sshd" "$rc"
check "sshd sv up"            "$out" "sv up sshd" "$rc"
case "$out" in
  *password*|*passwd*) _wd_pwleak=1 ;;
  *) _wd_pwleak=0 ;;
esac
if [ "$rc" -eq 0 ] && [ "$_wd_pwleak" -eq 0 ]; then
  pass=$((pass + 1)); printf 'PASS  sshd makes no password claim when not interactive\n'
else
  fail=$((fail + 1)); printf 'FAIL  sshd password claim leaked (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
rm -rf "$MOCKDIR20"

MOCKDIR21="$(mktemp -d)"
out=$(HOME="$_wd_home" PATH="$MOCKDIR21" setup_cloudflared 2>&1); rc=$?
check "cloudflared install only" "$out" "pkg install cloudflared -y" "$rc"
rm -rf "$MOCKDIR21"

MOCKDIR22="$(mktemp -d)"
out=$(PATH="$MOCKDIR22" setup_udocker 2>&1); rc=$?
check "udocker install fallback" "$out" "pkg install udocker -y" "$rc"
rm -rf "$MOCKDIR22"

MOCKDIR23="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR23/udocker"
chmod +x "$MOCKDIR23/udocker"
out=$(PATH="$MOCKDIR23" setup_udocker 2>&1); rc=$?
check "udocker already installed" "$out" "udocker already installed" "$rc"
rm -rf "$MOCKDIR23"

rm -rf "$_wd_home"

reset_state
DRY_RUN=1
REQUESTED=(base)
PKG_UPGRADABLE=0
run_cap setup_base
if [ "$rc" -eq 0 ] \
   && case "$out" in *"No upgradable packages; skipping pkg upgrade"*) true ;; *) false ;; esac \
   && ! case "$out" in *"[run] pkg upgrade"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base explicit skips upgrade when none upgradable\n'
else
  fail=$((fail + 1)); printf 'FAIL  base explicit gate (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
unset PKG_UPGRADABLE

reset_state
DRY_RUN=1
_wd_home="$(mktemp -d)"
mkdir -p "$_wd_home/.termux/boot"
: > "$_wd_home/.termux/boot/start-services"
MOCKDIR4="$(mktemp -d)"
for tool in udocker sv-enable sshd cloudflared; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR4/$tool"
  chmod +x "$MOCKDIR4/$tool"
done
REQUESTED=(earnapp)
resolve_request earnapp >/dev/null
out=$(HOME="$_wd_home" PATH="$MOCKDIR4:$PATH" setup_base 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
   && case "$out" in *"required tools already present; skipping pkg update/upgrade"*) true ;; *) false ;; esac \
   && ! case "$out" in *"[run] pkg update"*) true ;; *) false ;; esac \
   && ! case "$out" in *"[run] pkg upgrade"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base auto skips both when tools present\n'
else
  fail=$((fail + 1)); printf 'FAIL  base auto skip (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
rm -rf "$MOCKDIR4" "$_wd_home"

reset_state
DRY_RUN=1
REQUESTED=(earnapp)
resolve_request earnapp >/dev/null
out=$(setup_base 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
   && case "$out" in *"pkg update -y"*) true ;; *) false ;; esac \
   && ! case "$out" in *"pkg upgrade"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base auto runs update-only when tool missing\n'
else
  fail=$((fail + 1)); printf 'FAIL  base auto update-only (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
REQUESTED=(earnapp)
_wd_savedpath=$PATH
MOCKDIR31="$(mktemp -d)"
cat > "$MOCKDIR31/sv" <<'SH'
#!/usr/bin/env bash
printf 'down: %s: 1s, normally down\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR31/sv-enable"
chmod +x "$MOCKDIR31/sv" "$MOCKDIR31/sv-enable"
PATH="$MOCKDIR31:/usr/bin:/bin"
run_setup >/dev/null 2>&1; rc=$?
PATH="$_wd_savedpath"
rm -rf "$MOCKDIR31"
if [ "$rc" -eq 0 ] && [ "${_ord[*]}" = "base boot udocker earnapp" ]; then
  pass=$((pass + 1)); printf 'PASS  run_setup seeds _ord in calling shell (auto base not vacuous)\n'
else
  fail=$((fail + 1)); printf 'FAIL  run_setup _ord seeding (rc=%s) _ord=%q\n' "$rc" "${_ord[*]}" >&2
fi

reset_state
DRY_RUN=1
CLI_UUID="sdk-node-$HEX32"
MOCKDIR30="$(mktemp -d)"
cat > "$MOCKDIR30/sv" <<'SH'
#!/usr/bin/env bash
printf 'down: %s: 1s, normally down\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR30/sv-enable"
chmod +x "$MOCKDIR30/sv" "$MOCKDIR30/sv-enable"
out=$(PATH="$MOCKDIR30:/usr/bin:/bin" setup_earnapp 2>&1); rc=$?
rm -rf "$MOCKDIR30"
check "earnapp pulls via platform flag" "$out" "udocker pull --platform=" "$rc"
check "earnapp creates container"       "$out" "udocker create --name=earnapp" "$rc"
check "earnapp sv-enable"               "$out" "sv-enable earnapp" "$rc"
check "earnapp sv up"                   "$out" "sv up earnapp" "$rc"
check "earnapp register link"           "$out" "https://earnapp.com/r/sdk-node-$HEX32" "$rc"
check "earnapp echoes chosen uuid"      "$out" "sdk-node-$HEX32" "$rc"

reset_state
DRY_RUN=1
run_cap uuid_resolve
check "uuid_resolve dry-run auto-generates" "$out" "sdk-node-" "$rc"

reset_state
DRY_RUN=0
CLI_UUID="SDK-NODE-$HEX32"
run_cap uuid_resolve
check "uuid_resolve lowercases --uuid" "$out" "sdk-node-$HEX32" "$rc"

reset_state
CLI_UUID="not-a-uuid"
if ( uuid_resolve ) >/dev/null 2>&1; then
  fail=$((fail + 1))
  printf 'FAIL  uuid_resolve rejects invalid --uuid\n' >&2
else
  pass=$((pass + 1))
  printf 'PASS  uuid_resolve rejects invalid --uuid\n'
fi

MOCKDIR="$(mktemp -d)"
cat > "$MOCKDIR/udocker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SCENARIO_LOG"
case "$1" in
  images) if [ "$2" = "-p" ]; then printf '%s\n' "$MOCK_IMAGES_OUT"; fi ;;
  create) exit ${MOCK_CREATE_RC:-0} ;;
  ps) printf '%s\n' "$MOCK_PS_OUT" ;;
  inspect) exit ${MOCK_INSPECT_RC:-1} ;;
  setup) printf 'execmode: %s\nnvidiamode: False\n' "${MOCK_EXECMODE:-R1}" ;;
esac
MOCK
chmod +x "$MOCKDIR/udocker"
export SCENARIO_LOG="$MOCKDIR/calls"
export PATH="$MOCKDIR:$PATH"

UIMG="$INST_IMAGE"
PLAT_HOST="$(normalize_platform "$(detect_arch)")"

check_ud_calls() {
  local name=$1 want_pull=$2 want_rmi=$3 calls
  calls="$(cat "$SCENARIO_LOG" 2>/dev/null)"
  : > "$SCENARIO_LOG"
  if [ "$want_pull" = 1 ] && ! printf '%s\n' "$calls" | grep -q "^pull"; then
    fail=$((fail + 1)); printf 'FAIL  %s (no pull)\n' "$name" >&2
  elif [ "$want_pull" = 0 ] && printf '%s\n' "$calls" | grep -q "^pull"; then
    fail=$((fail + 1)); printf 'FAIL  %s (unexpected pull)\n' "$name" >&2
  elif [ "$want_rmi" = 1 ] && ! printf '%s\n' "$calls" | grep -q "^rmi"; then
    fail=$((fail + 1)); printf 'FAIL  %s (no rmi)\n' "$name" >&2
  elif [ "$want_rmi" = 0 ] && printf '%s\n' "$calls" | grep -q "^rmi"; then
    fail=$((fail + 1)); printf 'FAIL  %s (unexpected rmi)\n' "$name" >&2
  else
    pass=$((pass + 1)); printf 'PASS  %s\n' "$name"
  fi
}

reset_state
DRY_RUN=0
FLAG_YES=0
: > "$SCENARIO_LOG"
MOCK_IMAGES_OUT=""                               ensure_image "$PLAT_HOST" </dev/null >/dev/null 2>&1
check_ud_calls "ensure_image absent image -> pull"         1 0

: > "$SCENARIO_LOG"
MOCK_IMAGES_OUT="      $PLAT_HOST   3   $UIMG"   ensure_image "$PLAT_HOST" </dev/null >/dev/null 2>&1
check_ud_calls "ensure_image matching platform -> keep"    0 0

: > "$SCENARIO_LOG"
MOCK_IMAGES_OUT="      linux/s390x   3   $UIMG"  ensure_image "$PLAT_HOST" </dev/null >/dev/null 2>&1
check_ud_calls "ensure_image wrong platform -> refetch"    1 1

: > "$SCENARIO_LOG"
MOCK_IMAGES_OUT="      amd64   3   $UIMG"        ensure_image "$PLAT_HOST" </dev/null >/dev/null 2>&1
check_ud_calls "ensure_image bare arch -> keep (no rmi)"   0 0

reset_state
DRY_RUN=0
SVCDIR="$MOCKDIR/svc"
CONTROL="$SVCDIR/control"
UUIDX="sdk-node-$HEX32"
write_service_files "$UUIDX" "$SVCDIR" "$CONTROL" >/dev/null 2>&1
if grep -qF -- "-v \"\$PREFIX/etc/resolv.conf:/etc/resolv.conf\"" "$SVCDIR/run" \
   && grep -qF -- "-e EARNAPP_UUID=$UUIDX" "$SVCDIR/run" \
   && [ -x "$SVCDIR/run" ] && [ -x "$CONTROL/t" ] && [ -x "$SVCDIR/finish" ] \
   && [ -x "$SVCDIR/log/run" ] && grep -qF 'share/termux-services/svlogger' "$SVCDIR/log/run"; then
  pass=$((pass + 1)); printf 'PASS  write_service_files verbatim \$PREFIX + uuid + exec bits + Termux logger\n'
else
  fail=$((fail + 1)); printf 'FAIL  write_service_files content\n' >&2
fi

reset_state
DRY_RUN=0
: > "$SCENARIO_LOG"
out=$(MOCK_EXECMODE=R1 PATH="$MOCKDIR:/usr/bin:/bin" ensure_exec_mode 2>&1); rc=$?
if grep -q '^setup earnapp$' "$SCENARIO_LOG" && grep -q 'setup --execmode=P1 earnapp' "$SCENARIO_LOG"; then
  pass=$((pass + 1)); printf 'PASS  ensure_exec_mode switches R1 to P1 when runc/crun unavailable\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_exec_mode R1->P1 (rc=%s)\n%s\n%s\n' "$rc" "$out" "$(cat "$SCENARIO_LOG")" >&2
fi

reset_state
DRY_RUN=0
: > "$SCENARIO_LOG"
out=$(MOCK_EXECMODE=P2 PATH="$MOCKDIR:/usr/bin:/bin" ensure_exec_mode 2>&1); rc=$?
if grep -q '^setup earnapp$' "$SCENARIO_LOG" && grep -q 'setup --execmode=P1 earnapp' "$SCENARIO_LOG"; then
  pass=$((pass + 1)); printf 'PASS  ensure_exec_mode falls back from P2 to P1\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_exec_mode P2->P1 (rc=%s)\n%s\n%s\n' "$rc" "$out" "$(cat "$SCENARIO_LOG")" >&2
fi

reset_state
DRY_RUN=0
MOCKRC="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKRC/runc"
chmod +x "$MOCKRC/runc"
: > "$SCENARIO_LOG"
out=$(MOCK_EXECMODE=R1 PATH="$MOCKRC:$MOCKDIR:/usr/bin:/bin" ensure_exec_mode 2>&1); rc=$?
rm -rf "$MOCKRC"
if [ ! -s "$SCENARIO_LOG" ]; then
  pass=$((pass + 1)); printf 'PASS  ensure_exec_mode leaves mode alone when runc exists\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_exec_mode runc present\n%s\n' "$(cat "$SCENARIO_LOG")" >&2
fi

reset_state
DRY_RUN=0
FLAG_YES=1
: > "$SCENARIO_LOG"
out=$(MOCK_CREATE_RC=1 MOCK_PS_OUT="dc727638-14a1-3f7a-8be7-30a37063ba53 . W ['earnapp']        ghcr.io/xterna/earnapp:alpine" ensure_container 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "^rm -f" "$SCENARIO_LOG" \
   && case "$out" in *"Keeping existing container earnapp"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure_container --yes keeps existing container\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_container --yes keeps existing (rc=%s)\n%s\n%s\n' "$rc" "$out" "$(cat "$SCENARIO_LOG" 2>/dev/null)" >&2
fi

reset_state
DRY_RUN=0
FLAG_YES=1
: > "$SCENARIO_LOG"
out=$(MOCK_CREATE_RC=1 MOCK_PS_OUT="" ensure_container 2>&1); rc=$?
if [ "$rc" -ne 0 ] && case "$out" in *"udocker create failed and no container named earnapp exists"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure_container dies when create fails and no container exists\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_container not-found die (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

if command -v winpty >/dev/null 2>&1; then
  rm -f "$MOCKDIR/askout" "$MOCKDIR/askerr"
  { printf 'n\n'; sleep 1; } | winpty bash -c "source \"$SCRIPT_DIR/../earnapp-setup.sh\"; DRY_RUN=0 FLAG_YES=0; ask_yn \"POLLUTIONMARKER----\" n >\"$MOCKDIR/askout\" 2>\"$MOCKDIR/askerr\"" >/dev/null 2>&1
  if [ ! -s "$MOCKDIR/askout" ] && grep -q "POLLUTIONMARKER" "$MOCKDIR/askerr"; then
    pass=$((pass + 1)); printf 'PASS  ask_yn prompt goes to stderr so uuid=$(uuid_resolve) stays pure\n'
  else
    fail=$((fail + 1)); printf 'FAIL  ask_yn prompt leaked to stdout (uuid capture pollution)\n' >&2
  fi
else
  printf 'SKIP  ask_yn stderr prompt (no winpty on this host)\n'
fi
rm -rf "$MOCKDIR"

reset_state
DRY_RUN=1
PKG_UPGRADABLE=1
out=$(pkg_upgraded 2>&1); rc=$?
if [ "$rc" -eq 0 ] && case "$out" in *"[run] apt list --upgradable"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  pkg_upgraded dry-run asserts upgrades (PKG_UPGRADABLE=1)\n'
else
  fail=$((fail + 1)); printf 'FAIL  pkg_upgraded dry-run knob=1 (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

PKG_UPGRADABLE=0
out=$(pkg_upgraded 2>&1); rc=$?
if [ "$rc" -eq 1 ] && case "$out" in *"[run] apt list --upgradable"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  pkg_upgraded dry-run asserts none (PKG_UPGRADABLE=0)\n'
else
  fail=$((fail + 1)); printf 'FAIL  pkg_upgraded dry-run knob=0 (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
unset PKG_UPGRADABLE

DRY_RUN=0
MOCKDIR2="$(mktemp -d)"
cat > "$MOCKDIR2/apt" <<'MOCKUP'
#!/usr/bin/env bash
if [ "$1" = "list" ] && [ "$2" = "--upgradable" ]; then
  printf 'udocker/stable 1.3.17-1 aarch64 [upgradable from: 1.3.16-1]\n'
fi
MOCKUP
chmod +x "$MOCKDIR2/apt"
if PATH="$MOCKDIR2:$PATH" pkg_upgraded; then
  pass=$((pass + 1)); printf 'PASS  pkg_upgraded real detects upgrades\n'
else
  fail=$((fail + 1)); printf 'FAIL  pkg_upgraded real upgrade list\n' >&2
fi
cat > "$MOCKDIR2/apt" <<'MOCKUP2'
#!/usr/bin/env bash
exit 0
MOCKUP2
chmod +x "$MOCKDIR2/apt"
PATH="$MOCKDIR2:$PATH" pkg_upgraded; rc=$?
if [ "$rc" -eq 1 ]; then
  pass=$((pass + 1)); printf 'PASS  pkg_upgraded real empty list -> no upgrades\n'
else
  fail=$((fail + 1)); printf 'FAIL  pkg_upgraded real empty-list rc=%s\n' "$rc" >&2
fi
rm -rf "$MOCKDIR2"

reset_state
MOCKDIR3="$(mktemp -d)"
_wd_home="$(mktemp -d)"
mkdir -p "$_wd_home/.termux/boot"
: > "$_wd_home/.termux/boot/start-services"
for tool in udocker sv-enable sshd cloudflared; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR3/$tool"
  chmod +x "$MOCKDIR3/$tool"
done
reset_state
resolve_request earnapp >/dev/null
if [ "${_ord[*]}" = "base boot udocker earnapp" ]; then
  pass=$((pass + 1)); printf 'PASS  plan_tools fixture seeds earnapp deps\n'
else
  fail=$((fail + 1)); printf 'FAIL  plan_tools fixture _ord=%q\n' "${_ord[*]}" >&2
fi
if comp_tool_present base; then
  pass=$((pass + 1)); printf 'PASS  comp_tool_present base always true\n'
else
  fail=$((fail + 1)); printf 'FAIL  comp_tool_present base\n' >&2
fi
if PATH="$MOCKDIR3:$PATH" comp_tool_present udocker; then
  pass=$((pass + 1)); printf 'PASS  comp_tool_present udocker present\n'
else
  fail=$((fail + 1)); printf 'FAIL  comp_tool_present udocker\n' >&2
fi
if ( HOME="$_wd_home" PATH="$MOCKDIR3:$PATH" plan_tools_present ); then
  pass=$((pass + 1)); printf 'PASS  plan_tools_present all present\n'
else
  fail=$((fail + 1)); printf 'FAIL  plan_tools_present all present\n' >&2
fi
rm -f "$MOCKDIR3/udocker"
out=$(PATH="$MOCKDIR3:$PATH" plan_tools_present 2>&1); rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
  pass=$((pass + 1)); printf 'PASS  plan_tools_present missing udocker -> not present\n'
else
  fail=$((fail + 1)); printf 'FAIL  plan_tools_present missing udocker (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
out=$(PATH="$MOCKDIR3:$PATH" comp_tool_present udocker 2>&1); rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
  pass=$((pass + 1)); printf 'PASS  comp_tool_present udocker absent\n'
else
  fail=$((fail + 1)); printf 'FAIL  comp_tool_present udocker absent (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
rm -rf "$MOCKDIR3" "$_wd_home"

reset_state
DRY_RUN=1
out=$(service_up nonexistent 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  pass=$((pass + 1)); printf 'PASS  service_up returns false for missing\n'
else
  fail=$((fail + 1)); printf 'FAIL  service_up missing (rc=%s out=%q)\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
MOCKDIR5="$(mktemp -d)"
cat > "$MOCKDIR5/sv" <<'SH'
#!/usr/bin/env bash
name="$2"
case "$1" in
  status) printf 'run: %s: (pid 1234) 5s\n' "$name" ;;
esac
exit 0
SH
chmod +x "$MOCKDIR5/sv"
out=$(PATH="$MOCKDIR5:$PATH" service_up cloudflared 2>&1); rc=$?
rm -rf "$MOCKDIR5"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass=$((pass + 1)); printf 'PASS  service_up true when running\n'
else
  fail=$((fail + 1)); printf 'FAIL  service_up true (rc=%s out=%q)\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
MOCKDIR6="$(mktemp -d)"
cat > "$MOCKDIR6/sv" <<'SH'
#!/usr/bin/env bash
name="$2"
case "$1" in
  status) printf 'down: %s: 1s, normally down\n' "$name" ;;
esac
exit 0
SH
chmod +x "$MOCKDIR6/sv"
out=$(PATH="$MOCKDIR6:$PATH" service_up cloudflared 2>&1); rc=$?
rm -rf "$MOCKDIR6"
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  pass=$((pass + 1)); printf 'PASS  service_up false when down\n'
else
  fail=$((fail + 1)); printf 'FAIL  service_up down (rc=%s out=%q)\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
REQUESTED=(base)
PKG_UPGRADABLE=1
MOCKDIR7="$(mktemp -d)"
cat > "$MOCKDIR7/sv" <<'SH'
#!/usr/bin/env bash
name="$2"
case "$1" in
  status) printf 'run: %s: (pid 18196) 2297s\n' "$name" ;;
esac
exit 0
SH
chmod +x "$MOCKDIR7/sv"
out=$(PATH="$MOCKDIR7:$PATH" setup_base 2>&1); rc=$?
rm -rf "$MOCKDIR7"
unset PKG_UPGRADABLE
if [ "$rc" -eq 0 ] \
    && case "$out" in *"[watchdog] arm cloudflared upgrade recovery"*) true ;; *) false ;; esac \
    && case "$out" in *"[watchdog] sv-enable cloudflared"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base arms cloudflared watchdog when up\n'
else
  fail=$((fail + 1)); printf 'FAIL  base watchdog arm (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
REQUESTED=(base)
PKG_UPGRADABLE=1
MOCKDIR8="$(mktemp -d)"
cat > "$MOCKDIR8/sv" <<'SH'
#!/usr/bin/env bash
name="$2"
case "$1" in
  status) printf 'down: %s: 1s, normally down\n' "$name" ;;
esac
exit 0
SH
chmod +x "$MOCKDIR8/sv"
out=$(PATH="$MOCKDIR8:$PATH" setup_base 2>&1); rc=$?
rm -rf "$MOCKDIR8"
unset PKG_UPGRADABLE
if [ "$rc" -eq 0 ] \
   && ! case "$out" in *"[watchdog] arm cloudflared upgrade recovery"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base does not arm watchdog when down\n'
else
  fail=$((fail + 1)); printf 'FAIL  base no-arm when down (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
REQUESTED=(base)
PKG_UPGRADABLE=0
MOCKDIR9="$(mktemp -d)"
cat > "$MOCKDIR9/sv" <<'SH'
#!/usr/bin/env bash
name="$2"
case "$1" in
  status) printf 'run: %s: (pid 18196) 2297s\n' "$name" ;;
esac
exit 0
SH
chmod +x "$MOCKDIR9/sv"
out=$(PATH="$MOCKDIR9:$PATH" setup_base 2>&1); rc=$?
rm -rf "$MOCKDIR9"
unset PKG_UPGRADABLE
if [ "$rc" -eq 0 ] \
   && ! case "$out" in *"[watchdog] arm cloudflared upgrade recovery"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base does not arm watchdog when nothing upgradable\n'
else
  fail=$((fail + 1)); printf 'FAIL  base no-arm when no upgrade (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

WD_MP="$(mktemp -d)"
mkdir -p "$WD_MP/var/service/cloudflared" "$WD_MP/tmp"

write_sv_mock() {
  local md=$1 downs=$2
  cat > "$md/sv" <<SH
#!/usr/bin/env bash
c=\$(cat "\$WATCHDOG_TEST_DIR/poll" 2>/dev/null || printf 0)
c=\$((c + 1))
printf '%s\n' "\$c" > "\$WATCHDOG_TEST_DIR/poll"
case "\$c" in $downs) printf 'down: %s: 1s, normally down\n' "\$2" ;; *) printf 'run: %s: (pid 18196) 2297s\n' "\$2" ;; esac
exit 0
SH
  chmod +x "$md/sv"
}

write_sv_enable_mock() {
  local md=$1 down_dir=$2 clear_on=$3
  cat > "$md/sv-enable" <<SH
#!/usr/bin/env bash
c=\$(cat "\$WATCHDOG_TEST_DIR/enable_count" 2>/dev/null || printf 0)
c=\$((c + 1))
printf '%s\n' "\$c" > "\$WATCHDOG_TEST_DIR/enable_count"
n=\$(cat "\$WATCHDOG_TEST_DIR/poll" 2>/dev/null || printf 0)
printf 'sv-enable at poll %s\n' "\$n" >> "\$WATCHDOG_TEST_DIR/calls"
if [ -n "$clear_on" ] && [ "\$c" -ge "$clear_on" ]; then rm -f "$down_dir/down"; fi
exit 0
SH
  chmod +x "$md/sv-enable"
}

write_sleep_mock() {
  local md=$1
  cat > "$md/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$WATCHDOG_TEST_DIR/sleeps"
exit 0
SH
  chmod +x "$md/sleep"
}

reset_state
WD_MD_A="$(mktemp -d)"
write_sv_mock "$WD_MD_A" '4|5'
write_sv_enable_mock "$WD_MD_A" "$WD_MP/var/service/cloudflared" ''
write_sleep_mock "$WD_MD_A"
rm -f "$WD_MP/var/service/cloudflared/down" "$WD_MP/tmp/cloudflared-watchdog.log"
out=$(PREFIX="$WD_MP" WATCHDOG_TEST_DIR="$WD_MD_A" WATCHDOG_STEP=0 WATCHDOG_WAIT=40 \
      PATH="$WD_MD_A:$PATH" sh -c "$WATCHDOG_LOOP" 2>&1); rc=$?
wlog=$(cat "$WD_MP/tmp/cloudflared-watchdog.log" 2>/dev/null)
wcalls=$(cat "$WD_MD_A/calls" 2>/dev/null)
wfirst_poll="${wcalls##*poll }"
rm -rf "$WD_MD_A"
if [ "$rc" -eq 0 ] \
   && [ -n "$wcalls" ] \
   && [ "$wfirst_poll" -ge 4 ] 2>/dev/null \
   && case "$wlog" in *recovered*) true ;; *) false ;; esac \
   && case "$wlog" in *"cloudflared down at"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  watchdog recovers only after down transition and exits 0\n'
else
  fail=$((fail + 1)); printf 'FAIL  watchdog recover-after-down (rc=%s first_poll=%s)\ncalls=%s\nlog=%s\n' "$rc" "$wfirst_poll" "$wcalls" "$wlog" >&2
fi

reset_state
WD_MD_B="$(mktemp -d)"
write_sv_mock "$WD_MD_B" '2'
write_sv_enable_mock "$WD_MD_B" "$WD_MP/var/service/cloudflared" ''
write_sleep_mock "$WD_MD_B"
rm -f "$WD_MP/var/service/cloudflared/down" "$WD_MP/tmp/cloudflared-watchdog.log"
out=$(PREFIX="$WD_MP" WATCHDOG_TEST_DIR="$WD_MD_B" WATCHDOG_STEP=0 WATCHDOG_WAIT=6 \
      PATH="$WD_MD_B:$PATH" sh -c "$WATCHDOG_LOOP" 2>&1); rc=$?
wlog=$(cat "$WD_MP/tmp/cloudflared-watchdog.log" 2>/dev/null)
wcalls=$(cat "$WD_MD_B/calls" 2>/dev/null)
rm -rf "$WD_MD_B"
if [ "$rc" -eq 0 ] \
   && [ -z "$wcalls" ] \
   && ! case "$wlog" in *recovered*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  watchdog ignores a single down poll (no sv-enable)\n'
else
  fail=$((fail + 1)); printf 'FAIL  watchdog single down poll (rc=%s)\ncalls=%s\nlog=%s\n' "$rc" "$wcalls" "$wlog" >&2
fi

reset_state
WD_MD_C="$(mktemp -d)"
write_sv_mock "$WD_MD_C" '4|5'
write_sv_enable_mock "$WD_MD_C" "$WD_MP/var/service/cloudflared" 2
write_sleep_mock "$WD_MD_C"
: > "$WD_MP/var/service/cloudflared/down"
rm -f "$WD_MP/tmp/cloudflared-watchdog.log"
out=$(PREFIX="$WD_MP" WATCHDOG_TEST_DIR="$WD_MD_C" WATCHDOG_STEP=0 WATCHDOG_WAIT=40 \
      PATH="$WD_MD_C:$PATH" sh -c "$WATCHDOG_LOOP" 2>&1); rc=$?
wlog=$(cat "$WD_MP/tmp/cloudflared-watchdog.log" 2>/dev/null)
wcalls=$(cat "$WD_MD_C/calls" 2>/dev/null)
wcount=$(printf '%s\n' "$wcalls" | grep -c .)
rm -rf "$WD_MD_C"
if [ "$rc" -eq 0 ] \
   && [ "$wcount" -eq 2 ] \
   && case "$wlog" in *recovered*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  watchdog retries while down file persists, then recovers\n'
else
  fail=$((fail + 1)); printf 'FAIL  watchdog down-file retry (rc=%s count=%s)\ncalls=%s\nlog=%s\n' "$rc" "$wcount" "$wcalls" "$wlog" >&2
fi

reset_state
DRY_RUN=1
REQUESTED=(base)
PKG_UPGRADABLE=1
WD_MD_D="$(mktemp -d)"
cat > "$WD_MD_D/sv" <<'SH'
#!/usr/bin/env bash
name="$2"
case "$1" in
  status) printf 'run: %s: (pid 18196) 2297s\n' "$name" ;;
esac
exit 0
SH
cat > "$WD_MD_D/nohup" <<SH
#!/usr/bin/env bash
: > "$WD_MP/nohup-invoked"
exit 0
SH
chmod +x "$WD_MD_D/sv" "$WD_MD_D/nohup"
rm -f "$WD_MP/nohup-invoked"
out=$(PATH="$WD_MD_D:$PATH" setup_base 2>&1); rc=$?
wd_w=0
while [ "$wd_w" -lt 10 ] && [ ! -e "$WD_MP/nohup-invoked" ]; do
  sleep 0.1
  wd_w=$((wd_w + 1))
done
wd_marker="$WD_MP/nohup-invoked"
wd_marked=0
[ -e "$wd_marker" ] && wd_marked=1
rm -rf "$WD_MD_D"
unset PKG_UPGRADABLE
if [ "$rc" -eq 0 ] \
   && [ "$wd_marked" -eq 0 ] \
   && case "$out" in *"[watchdog] arm cloudflared upgrade recovery"*) true ;; *) false ;; esac \
   && case "$out" in *"[watchdog] sv-enable cloudflared"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  dry-run arms no background watchdog (nohup never invoked)\n'
else
  fail=$((fail + 1)); printf 'FAIL  dry-run background purity (rc=%s nohup-invoked=%s)\n%s\n' "$rc" "$wd_marked" "$out" >&2
fi

reset_state
WD_MD_E="$(mktemp -d)"
cat > "$WD_MD_E/sv-enable" <<'SH'
#!/usr/bin/env bash
printf 'e' >> "$WD_SVCOUNT.e"
exit 0
SH
chmod +x "$WD_MD_E/sv-enable"
WD_E_FNS='exec 9>>"$WD_SVCOUNT"
sv() {
  printf "p" >&9
  printf "run: %s: (pid 18196) 2297s\n" "$2"
}
sleep() {
  wd_sleepn=$((wd_sleepn + 1))
  case ",$wd_sleepargs" in
    *",$1,"*) ;;
    *) wd_sleepargs="$wd_sleepargs$1," ;;
  esac
  return 0
}
grep() {
  wd_pat=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      -?*) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || return 2
  wd_pat=$1
  wd_rc=1
  while IFS= read -r wd_line || [ -n "$wd_line" ]; do
    case "$wd_line" in
      *"$wd_pat"*) wd_rc=0; break ;;
    esac
  done
  return "$wd_rc"
}
wd_sleepn=0
wd_sleepargs=
wd_gup=0
wd_gdown=0
printf "run: cloudflared: (pid 18196) 2297s\n" | grep -q "run: cloudflared: (pid" && wd_gup=1
printf "down: cloudflared: 1s, normally down\n" | grep -q "run: cloudflared: (pid" && wd_gdown=1
'
WD_E_REPORT='printf "PROBE %s|%s|%s|%s|%s|%s\n" "$(wc -c < "$WD_SVCOUNT" | tr -d " ")" "$(wc -c < "$WD_SVCOUNT.e" 2>/dev/null | tr -d " " || printf 0)" "$wd_sleepargs" "$wd_sleepn" "$wd_gup" "$wd_gdown"'
rm -f "$WD_MP/var/service/cloudflared/down" "$WD_MP/tmp/cloudflared-watchdog.log"
out=$(PREFIX="$WD_MP" WD_SVCOUNT="$WD_MD_E/svcount" PATH="$WD_MD_E:$PATH" sh -c "$WD_E_FNS
$WATCHDOG_LOOP
$WD_E_REPORT" 2>&1); rc=$?
wlog=$(cat "$WD_MP/tmp/cloudflared-watchdog.log" 2>/dev/null)
wprobe=$(printf '%s\n' "$out" | sed -n 's/^PROBE //p')
IFS='|' read -r wpolls wenable wsleepargs wsleepn wgup wgdown <<EOF
$wprobe
EOF
wpolls=${wpolls:-0}
wenable=${wenable:-0}
wsleepn=${wsleepn:-0}
wgup=${wgup:-0}
wgdown=${wgdown:-0}
wsleepargs=${wsleepargs:-}
rm -rf "$WD_MD_E"
if [ "$rc" -eq 0 ] \
   && [ "$wpolls" -eq 600 ] \
   && [ "$wenable" -eq 0 ] \
   && [ "$wsleepargs" = "2," ] \
   && [ "$wsleepn" -eq 600 ] \
   && [ "$wgup" -eq 1 ] \
   && [ "$wgdown" -eq 0 ] \
   && case "$wlog" in *"armed at"*) true ;; *) false ;; esac \
   && case "$wlog" in *"no cloudflared outage in 1200s"*) true ;; *) false ;; esac \
   && ! case "$wlog" in *"gave up"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  watchdog defaults are 600 polls x 2s; never-up path logs benign idle-out\n'
else
  fail=$((fail + 1)); printf 'FAIL  watchdog production defaults (rc=%s polls=%s sv-enable=%s sleep args=%s sleeps=%s grep up/down=%s/%s)\nlog=%s\nprobe=%s\n' "$rc" "$wpolls" "$wenable" "$wsleepargs" "$wsleepn" "$wgup" "$wgdown" "$wlog" "$wprobe" >&2
fi

reset_state
WD_MD_F="$(mktemp -d)"
cat > "$WD_MD_F/sv" <<'SH'
#!/usr/bin/env bash
printf 'down: %s: 1s, normally down\n' "$2"
exit 0
SH
chmod +x "$WD_MD_F/sv"
write_sv_enable_mock "$WD_MD_F" "$WD_MP/var/service/cloudflared" ''
write_sleep_mock "$WD_MD_F"
rm -f "$WD_MP/tmp/cloudflared-watchdog.log"
out=$(PREFIX="$WD_MP" WATCHDOG_TEST_DIR="$WD_MD_F" WATCHDOG_STEP=1 WATCHDOG_WAIT=4 \
      PATH="$WD_MD_F:$PATH" sh -c "$WATCHDOG_LOOP" 2>&1); rc=$?
wlog=$(cat "$WD_MP/tmp/cloudflared-watchdog.log" 2>/dev/null)
wcalls=$(cat "$WD_MD_F/calls" 2>/dev/null)
wcount=$(printf '%s\n' "$wcalls" | grep -c .)
rm -rf "$WD_MD_F"
if [ "$rc" -eq 0 ] \
   && [ "$wcount" -ge 1 ] \
   && case "$wlog" in *"gave up after 4s"*) true ;; *) false ;; esac \
   && ! case "$wlog" in *recovered*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  watchdog logs gave up only after acting (actuated, never recovered)\n'
else
  fail=$((fail + 1)); printf 'FAIL  watchdog gave-up path (rc=%s sv-enable calls=%s)\ncalls=%s\nlog=%s\n' "$rc" "$wcount" "$wcalls" "$wlog" >&2
fi

reset_state
WD_MD_G="$(mktemp -d)"
cat > "$WD_MD_G/sv" <<'SH'
#!/usr/bin/env bash
c=$(cat "$WATCHDOG_TEST_DIR/poll" 2>/dev/null || printf 0)
c=$((c + 1))
printf '%s\n' "$c" > "$WATCHDOG_TEST_DIR/poll"
if [ "$c" -le 2 ]; then
  exit 1
fi
printf 'run: %s: (pid 18196) 2297s\n' "$2"
exit 0
SH
chmod +x "$WD_MD_G/sv"
write_sv_enable_mock "$WD_MD_G" "$WD_MP/var/service/cloudflared" ''
write_sleep_mock "$WD_MD_G"
rm -f "$WD_MP/var/service/cloudflared/down" "$WD_MP/tmp/cloudflared-watchdog.log"
out=$(PREFIX="$WD_MP" WATCHDOG_TEST_DIR="$WD_MD_G" WATCHDOG_STEP=0 WATCHDOG_WAIT=10 \
      PATH="$WD_MD_G:$PATH" sh -c "$WATCHDOG_LOOP" 2>&1); rc=$?
wlog=$(cat "$WD_MP/tmp/cloudflared-watchdog.log" 2>/dev/null)
wcalls=$(cat "$WD_MD_G/calls" 2>/dev/null)
wcount=$(printf '%s\n' "$wcalls" | grep -c .)
wn=$(cat "$WD_MD_G/sleeps" 2>/dev/null | grep -c .)
rm -rf "$WD_MD_G"
if [ "$rc" -eq 0 ] \
   && [ "$wcount" -eq 0 ] \
   && [ "$wn" -eq 10 ] \
   && ! case "$wlog" in *recovered*) true ;; *) false ;; esac \
   && ! case "$wlog" in *"cloudflared down at"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  watchdog treats sv failure as unusable, not down (no sv-enable, no recovery)\n'
else
  fail=$((fail + 1)); printf 'FAIL  watchdog sv-unusable handling (rc=%s sv-enable calls=%s polls=%s)\ncalls=%s\nlog=%s\n' "$rc" "$wcount" "$wn" "$wcalls" "$wlog" >&2
fi

reset_state
DRY_RUN=1
REQUESTED=(base)
PKG_UPGRADABLE=1
WD_MD_H="$(mktemp -d)"
cat > "$WD_MD_H/sv" <<'SH'
#!/usr/bin/env bash
c=$(cat "$WATCHDOG_TEST_DIR/poll" 2>/dev/null || printf 0)
c=$((c + 1))
printf '%s\n' "$c" > "$WATCHDOG_TEST_DIR/poll"
if [ "$c" -le 1 ]; then
  printf 'run: %s: (pid 18196) 2297s\n' "$2"
else
  printf 'down: %s: 1s, normally down\n' "$2"
fi
exit 0
SH
chmod +x "$WD_MD_H/sv"
out=$(WATCHDOG_TEST_DIR="$WD_MD_H" PATH="$WD_MD_H:$PATH" setup_base 2>&1); rc=$?
rm -rf "$WD_MD_H"
unset PKG_UPGRADABLE
if [ "$rc" -eq 0 ] \
   && ! case "$out" in *"[watchdog] arm cloudflared upgrade recovery"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  arm gate needs two up samples (up then down arms nothing)\n'
else
  fail=$((fail + 1)); printf 'FAIL  arm gate two-sample confirmation (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=0
REQUESTED=(base)
unset PREFIX
WD_MD_I="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WD_MD_I/pkg"
cat > "$WD_MD_I/apt" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "list" ] && [ "$2" = "--upgradable" ]; then
  printf 'cloudflared/stable 2026.9.0 aarch64 [upgradable from: 2026.8.0]\n'
fi
exit 0
SH
cat > "$WD_MD_I/sv" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) printf 'run: %s: (pid 18196) 2297s\n' "$2" ;;
esac
exit 0
SH
cat > "$WD_MD_I/nohup" <<SH
#!/usr/bin/env bash
: > "$WD_MP/nohup-real-invoked"
exit 0
SH
chmod +x "$WD_MD_I/pkg" "$WD_MD_I/apt" "$WD_MD_I/sv" "$WD_MD_I/nohup"
rm -f "$WD_MP/nohup-real-invoked"
out=$(PATH="$WD_MD_I:$PATH" setup_base 2>&1); rc=$?
wd_w=0
while [ "$wd_w" -lt 20 ] && [ ! -e "$WD_MP/nohup-real-invoked" ]; do
  sleep 0.1
  wd_w=$((wd_w + 1))
done
wd_real=0
[ -e "$WD_MP/nohup-real-invoked" ] && wd_real=1
rm -rf "$WD_MD_I"
if [ "$rc" -eq 0 ] && [ "$wd_real" -eq 1 ]; then
  pass=$((pass + 1)); printf 'PASS  real run reaches nohup under set -u with PREFIX unset\n'
else
  fail=$((fail + 1)); printf 'FAIL  real-run watchdog launch (rc=%s nohup-invoked=%s)\n%s\n' "$rc" "$wd_real" "$out" >&2
fi

rm -rf "$WD_MP"

reset_state
DRY_RUN=1
MOCKDIR10="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR10/sshd"
chmod +x "$MOCKDIR10/sshd"
out=$(PATH="$MOCKDIR10" ensure_pkg sshd openssh 2>&1); rc=$?
rm -rf "$MOCKDIR10"
check "ensure_pkg skips install when probe present" "$out" "openssh already installed" "$rc"

reset_state
DRY_RUN=1
MOCKDIR11="$(mktemp -d)"
out=$(PATH="$MOCKDIR11" ensure_pkg sshd openssh 2>&1); rc=$?
rm -rf "$MOCKDIR11"
check "ensure_pkg installs when probe absent" "$out" "pkg install openssh -y" "$rc"

reset_state
DRY_RUN=1
_wd_saved=${PREFIX:-}
_wd_savedpath=$PATH
_wd_prefix="$(mktemp -d)"
mkdir -p "$_wd_prefix/var/service/sshd"
MOCKDIR12="$(mktemp -d)"
cat > "$MOCKDIR12/sv" <<'SH'
#!/usr/bin/env bash
printf 'run: %s: (pid 1234) 5s\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR12/sv-enable"
chmod +x "$MOCKDIR12/sv" "$MOCKDIR12/sv-enable"
PREFIX="$_wd_prefix"
PATH="$MOCKDIR12:$PATH"
ensure_service sshd >"$MOCKDIR12/out" 2>&1; rc=$?
out=$(cat "$MOCKDIR12/out")
_wd_started=$SERVICE_JUST_STARTED
PATH="$_wd_savedpath"
rm -rf "$MOCKDIR12" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -eq 0 ] && [ "$_wd_started" -eq 0 ] \
   && case "$out" in *"already enabled and running"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure_service no-op when running and unmanaged\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_service healthy (rc=%s started=%s)\n%s\n' "$rc" "$_wd_started" "$out" >&2
fi

reset_state
DRY_RUN=1
_wd_saved=${PREFIX:-}
_wd_savedpath=$PATH
_wd_prefix="$(mktemp -d)"
mkdir -p "$_wd_prefix/var/service/sshd"
: > "$_wd_prefix/var/service/sshd/down"
MOCKDIR13="$(mktemp -d)"
cat > "$MOCKDIR13/sv" <<'SH'
#!/usr/bin/env bash
printf 'run: %s: (pid 1234) 5s\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR13/sv-enable"
chmod +x "$MOCKDIR13/sv" "$MOCKDIR13/sv-enable"
PREFIX="$_wd_prefix"
PATH="$MOCKDIR13:$PATH"
ensure_service sshd >"$MOCKDIR13/out" 2>&1; rc=$?
out=$(cat "$MOCKDIR13/out")
_wd_started=$SERVICE_JUST_STARTED
PATH="$_wd_savedpath"
rm -rf "$MOCKDIR13" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -eq 0 ] && [ "$_wd_started" -eq 1 ] \
   && case "$out" in *"has a down file; re-enabling"*) true ;; *) false ;; esac \
   && case "$out" in *"sv-enable sshd"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure_service repairs running-but-disabled service\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_service down-file repair (rc=%s started=%s)\n%s\n' "$rc" "$_wd_started" "$out" >&2
fi

reset_state
DRY_RUN=1
_wd_saved=${PREFIX:-}
_wd_savedpath=$PATH
_wd_prefix="$(mktemp -d)"
mkdir -p "$_wd_prefix/var/service/sshd"
MOCKDIR14="$(mktemp -d)"
cat > "$MOCKDIR14/sv" <<'SH'
#!/usr/bin/env bash
printf 'down: %s: 1s, normally down\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR14/sv-enable"
chmod +x "$MOCKDIR14/sv" "$MOCKDIR14/sv-enable"
PREFIX="$_wd_prefix"
PATH="$MOCKDIR14:$PATH"
ensure_service sshd >"$MOCKDIR14/out" 2>&1; rc=$?
out=$(cat "$MOCKDIR14/out")
_wd_started=$SERVICE_JUST_STARTED
PATH="$_wd_savedpath"
rm -rf "$MOCKDIR14" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -eq 0 ] && [ "$_wd_started" -eq 1 ] \
   && case "$out" in *"sv-enable sshd"*) true ;; *) false ;; esac \
   && case "$out" in *"sv up sshd"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure_service starts a stopped service\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_service start (rc=%s started=%s)\n%s\n' "$rc" "$_wd_started" "$out" >&2
fi

reset_state
DRY_RUN=0
_wd_saved=${PREFIX:-}
MOCKDIR15="$(mktemp -d)"
_wd_prefix="$(mktemp -d)"
PREFIX="$_wd_prefix"
out=$(PATH="$MOCKDIR15:/usr/bin:/bin" ensure_service sshd 2>&1); rc=$?
rm -rf "$MOCKDIR15" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -eq 1 ] && case "$out" in *"termux-services"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure_service dies clearly when sv-enable missing\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_service missing sv-enable (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
_wd_saved=${PREFIX:-}
MOCKDIR32="$(mktemp -d)"
_wd_prefix="$(mktemp -d)"
PREFIX="$_wd_prefix"
out=$(PATH="$MOCKDIR32:/usr/bin:/bin" ensure_service sshd 2>&1); rc=$?
rm -rf "$MOCKDIR32" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -eq 0 ] && case "$out" in *"termux-services"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure_service dry run previews instead of dying\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_service dry run missing sv-enable (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
_wd_home="$(mktemp -d)"
MOCKDIR16="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR16/sv-enable"
chmod +x "$MOCKDIR16/sv-enable"
( HOME="$_wd_home" PATH="$MOCKDIR16" comp_tool_present boot ); rc=$?
rm -rf "$MOCKDIR16" "$_wd_home"
if [ "$rc" -eq 1 ]; then
  pass=$((pass + 1)); printf 'PASS  comp_tool_present boot false without boot script\n'
else
  fail=$((fail + 1)); printf 'FAIL  comp_tool_present boot missing script (rc=%s)\n' "$rc" >&2
fi

reset_state
DRY_RUN=1
_wd_home="$(mktemp -d)"
mkdir -p "$_wd_home/.termux/boot"
: > "$_wd_home/.termux/boot/start-services"
MOCKDIR17="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR17/sv-enable"
chmod +x "$MOCKDIR17/sv-enable"
( HOME="$_wd_home" PATH="$MOCKDIR17" comp_tool_present boot ); rc=$?
rm -rf "$MOCKDIR17" "$_wd_home"
if [ "$rc" -eq 0 ]; then
  pass=$((pass + 1)); printf 'PASS  comp_tool_present boot true with sv-enable and script\n'
else
  fail=$((fail + 1)); printf 'FAIL  comp_tool_present boot complete (rc=%s)\n' "$rc" >&2
fi

reset_state
DRY_RUN=1
_wd_home="$(mktemp -d)"
mkdir -p "$_wd_home/.termux/boot"
: > "$_wd_home/.termux/boot/start-services"
MOCKDIR18="$(mktemp -d)"
( HOME="$_wd_home" PATH="$MOCKDIR18" comp_tool_present boot ); rc=$?
rm -rf "$MOCKDIR18" "$_wd_home"
if [ "$rc" -eq 1 ]; then
  pass=$((pass + 1)); printf 'PASS  comp_tool_present boot false without sv-enable\n'
else
  fail=$((fail + 1)); printf 'FAIL  comp_tool_present boot missing sv-enable (rc=%s)\n' "$rc" >&2
fi

reset_state
DRY_RUN=1
_wd_saved=${PREFIX:-}
_wd_savedpath=$PATH
_wd_prefix="$(mktemp -d)"
mkdir -p "$_wd_prefix/var/service/sshd"
MOCKDIR24="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR24/sshd"
cat > "$MOCKDIR24/sv" <<'SH'
#!/usr/bin/env bash
printf 'run: %s: (pid 1234) 5s\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR24/sv-enable"
chmod +x "$MOCKDIR24/sshd" "$MOCKDIR24/sv" "$MOCKDIR24/sv-enable"
PREFIX="$_wd_prefix"
PATH="$MOCKDIR24:/usr/bin:/bin"
out=$(setup_sshd 2>&1); rc=$?
PATH="$_wd_savedpath"
rm -rf "$MOCKDIR24" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -eq 0 ] \
   && case "$out" in *"pkg install openssh"*) false ;; *) true ;; esac \
   && case "$out" in *"already enabled and running"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  sshd re-run reinstalls nothing and reuses the running service\n'
else
  fail=$((fail + 1)); printf 'FAIL  sshd reinstall guard (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
_wd_saved=${PREFIX:-}
_wd_prefix="$(mktemp -d)"
mkdir -p "$_wd_prefix/var/service/sshd"
MOCKDIR25="$(mktemp -d)"
cat > "$MOCKDIR25/sv" <<'SH'
#!/usr/bin/env bash
printf 'run: %s: (pid 1234) 5s\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR25/sv-enable"
chmod +x "$MOCKDIR25/sv" "$MOCKDIR25/sv-enable"
PREFIX="$_wd_prefix"
out=$(PREFIX="$_wd_prefix" PATH="$MOCKDIR25:/usr/bin:/bin" setup_sshd 2>&1); rc=$?
rm -rf "$MOCKDIR25" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -eq 0 ] \
   && case "$out" in *"sv-enable sshd"*) false ;; *) true ;; esac \
   && case "$out" in *password*|*passwd*) false ;; *) true ;; esac; then
  pass=$((pass + 1)); printf 'PASS  sshd re-run is a no-op and makes no password claim\n'
else
  fail=$((fail + 1)); printf 'FAIL  sshd idempotent (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
_wd_home2="$(mktemp -d)"
MOCKDIR26="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR26/sv-enable"
chmod +x "$MOCKDIR26/sv-enable"
out=$(HOME="$_wd_home2" PATH="$MOCKDIR26" setup_boot 2>&1); rc=$?
rm -rf "$MOCKDIR26" "$_wd_home2"
check "boot skips termux-services install when present" "$out" "termux-services already installed" "$rc"

reset_state
DRY_RUN=1
MOCKDIR27="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR27/cloudflared"
chmod +x "$MOCKDIR27/cloudflared"
out=$(PATH="$MOCKDIR27" setup_cloudflared 2>&1); rc=$?
rm -rf "$MOCKDIR27"
if case "$out" in *"pkg install cloudflared"*) false ;; *) true ;; esac; then
  pass=$((pass + 1)); printf 'PASS  cloudflared does not reinstall when present\n'
else
  fail=$((fail + 1)); printf 'FAIL  cloudflared reinstall guard\n%s\n' "$out" >&2
fi

reset_state
DRY_RUN=1
_wd_saved=${PREFIX:-}
_wd_prefix="$(mktemp -d)"
mkdir -p "$_wd_prefix/var/service/earnapp"
MOCKDIR28="$(mktemp -d)"
cat > "$MOCKDIR28/sv" <<'SH'
#!/usr/bin/env bash
printf 'run: %s: (pid 4711) 12s\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR28/sv-enable"
chmod +x "$MOCKDIR28/sv" "$MOCKDIR28/sv-enable"
PREFIX="$_wd_prefix"
out=$( ( PREFIX="$_wd_prefix"
  uuid_resolve(){ printf 'test-uuid'; }
  ensure_image(){ :; }
  ensure_container(){ :; }
  write_service(){ return 0; }
  PATH="$MOCKDIR28:/usr/bin:/bin" setup_earnapp ) 2>&1 ); rc=$?
rm -rf "$MOCKDIR28" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -eq 0 ] && case "$out" in *"sv-enable earnapp"*) false ;; *) true ;; esac; then
  pass=$((pass + 1)); printf 'PASS  earnapp does not re-enable a healthy service\n'
else
  fail=$((fail + 1)); printf 'FAIL  earnapp re-enable guard (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
_wd_saved=${PREFIX:-}
_wd_prefix="$(mktemp -d)"
mkdir -p "$_wd_prefix/var/service/earnapp"
: > "$_wd_prefix/var/service/earnapp/down"
MOCKDIR29="$(mktemp -d)"
cat > "$MOCKDIR29/sv" <<'SH'
#!/usr/bin/env bash
printf 'run: %s: (pid 4711) 12s\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR29/sv-enable"
chmod +x "$MOCKDIR29/sv" "$MOCKDIR29/sv-enable"
PREFIX="$_wd_prefix"
out=$( ( PREFIX="$_wd_prefix"
  uuid_resolve(){ printf 'test-uuid'; }
  ensure_image(){ :; }
  ensure_container(){ :; }
  write_service(){ return 0; }
  PATH="$MOCKDIR29:/usr/bin:/bin" setup_earnapp ) 2>&1 ); rc=$?
rm -rf "$MOCKDIR29" "$_wd_prefix"
PREFIX="$_wd_saved"
check "earnapp re-enables when a down file is present" "$out" "sv-enable earnapp" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
