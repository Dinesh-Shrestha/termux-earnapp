#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../earnapp-setup.sh"

pass=0
fail=0

check() {
  local name=$1 hay=$2 needle=$3 rc=${4:-0}
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

check_eq() {
  local name=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then
    pass=$((pass + 1)); printf 'PASS  %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL  %s (want=%q got=%q)\n' "$name" "$want" "$got" >&2
  fi
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

_wd_prefix_services="$(mktemp -d)"
_wd_home_services="$(mktemp -d)"
MOCKDIR_SERVICES="$(mktemp -d)"
mkdir -p "$_wd_prefix_services/etc/profile.d"
# The setup must not source the profile hook. It starts the supervisor itself,
# and only when nothing is running yet.
cat > "$_wd_prefix_services/etc/profile.d/start-services.sh" <<'SH'
printf 'hook\n' >> "$TERMUX_SERVICES_TEST_MARKER.hook"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR_SERVICES/sv-enable"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR_SERVICES/apt-config"
cat > "$MOCKDIR_SERVICES/service-daemon" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$TERMUX_SERVICES_TEST_MARKER"
exit 0
SH
# Report a supervisor only after service-daemon started one, so the setup has
# to start it rather than assume it is already running.
cat > "$MOCKDIR_SERVICES/pgrep" <<'SH'
#!/usr/bin/env bash
[ -s "$TERMUX_SERVICES_TEST_MARKER" ]
SH
chmod +x "$MOCKDIR_SERVICES/sv-enable" "$MOCKDIR_SERVICES/apt-config" \
  "$MOCKDIR_SERVICES/service-daemon" "$MOCKDIR_SERVICES/pgrep"
TERMUX_SERVICES_TEST_MARKER="$_wd_prefix_services/started" \
  DRY_RUN=0 PREFIX="$_wd_prefix_services" HOME="$_wd_home_services" \
  PATH="$MOCKDIR_SERVICES:/usr/bin:/bin" setup_boot >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -s "$_wd_prefix_services/started" ] \
   && [ ! -e "$_wd_prefix_services/started.hook" ]; then
  pass=$((pass + 1)); printf 'PASS  boot starts termux-services in the current setup run\n'
else
  fail=$((fail + 1)); printf 'FAIL  boot starts termux-services in the current setup run (exit %s)\n' "$rc" >&2
fi
rm -rf "$MOCKDIR_SERVICES" "$_wd_home_services" "$_wd_prefix_services"

MOCKDIR20="$(mktemp -d)"
printf '#!/usr/bin/env bash\nprintf "down: %%s: 1s, normally down\\n" "$2"\n' > "$MOCKDIR20/sv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR20/sv-enable"
chmod +x "$MOCKDIR20/sv" "$MOCKDIR20/sv-enable"
out=$(HOME="$_wd_home" PATH="$MOCKDIR20" setup_sshd 2>&1); rc=$?
check "sshd installs openssh" "$out" "pkg install openssh -y" "$rc"
check "sshd sv-enable"        "$out" "sv-enable sshd" "$rc"
if [ "$rc" -eq 0 ] && case "$out" in *"[run] sv up sshd"*) false ;; *) true ;; esac; then
  pass=$((pass + 1)); printf 'PASS  sshd relies on sv-enable to start the service\n'
else
  fail=$((fail + 1)); printf 'FAIL  sshd redundantly calls sv up (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
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

MOCKDIR40="$(mktemp -d)"
out=$(PATH="$MOCKDIR40" setup_speedtest_go 2>&1); rc=$?
check "speedtest-go installs through Termux package manager" "$out" "pkg install speedtest-go -y" "$rc"
rm -rf "$MOCKDIR40"

MOCKDIR41="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR41/speedtest-go"
chmod +x "$MOCKDIR41/speedtest-go"
out=$(PATH="$MOCKDIR41" setup_speedtest_go 2>&1); rc=$?
check "speedtest-go skips install when already present" "$out" "speedtest-go already installed" "$rc"
rm -rf "$MOCKDIR41"

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
printf '. "$PREFIX/etc/profile.d/start-services.sh"\n/data/data/com.termux/files/usr/var/lib/earnapp-setup/service-repair.sh boot || true\n' > "$_wd_home/.termux/boot/start-services"
MOCKDIR4="$(mktemp -d)"
for tool in udocker sv-enable sshd cloudflared speedtest-go; do
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
REQUESTED=(boot)
resolve_request boot >/dev/null
_wd_boot_home="$(mktemp -d)"
mkdir -p "$_wd_boot_home/.termux/boot"
printf '. "$PREFIX/etc/profile.d/start-services.sh"\n' > "$_wd_boot_home/.termux/boot/start-services"
_wd_boot_mock="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_wd_boot_mock/sv-enable"
chmod +x "$_wd_boot_mock/sv-enable"
out=$(HOME="$_wd_boot_home" PATH="$_wd_boot_mock:$PATH" setup_base 2>&1); rc=$?
rm -rf "$_wd_boot_home" "$_wd_boot_mock"
if [ "$rc" -eq 0 ] \
   && case "$out" in *"required tools already present; skipping pkg update/upgrade"*) true ;; *) false ;; esac \
   && ! case "$out" in *"[run] pkg update"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base auto skips package work when boot script only needs repair line\n'
else
  fail=$((fail + 1)); printf 'FAIL  base auto boot repair-line readiness (rc=%s)\n%s\n' "$rc" "$out" >&2
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
if [ "$rc" -eq 0 ] && case "$out" in *"[run] sv up earnapp"*) false ;; *) true ;; esac; then
  pass=$((pass + 1)); printf 'PASS  earnapp relies on sv-enable to start the service\n'
else
  fail=$((fail + 1)); printf 'FAIL  earnapp redundantly calls sv up (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
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

# Stopping or restarting EarnApp must only signal EarnApp's own process tree.
# The old finish/control scripts used a broad pkill that matched every
# udocker/proot container on the device.
_scope_prefix="$(mktemp -d)"
_scope_svc="$_scope_prefix/var/service/earnapp"
_scope_ctl="$_scope_svc/control"
mkdir -p "$_scope_svc/supervise" "$_scope_prefix/var/lib/earnapp-setup"
PREFIX="$_scope_prefix" write_service_files "$UUIDX" "$_scope_svc" "$_scope_ctl" >/dev/null 2>&1
_scope_old_kill=0
grep -qF 'pkill' "$_scope_ctl/t" "$_scope_svc/finish" 2>/dev/null && _scope_old_kill=1
if [ "$_scope_old_kill" -eq 0 ] \
   && grep -qF 'supervise/pid' "$_scope_ctl/t" \
   && grep -qF 'earnapp.children' "$_scope_ctl/t" "$_scope_svc/finish" \
   && grep -qF 'earnapp.children' "$_scope_svc/run" \
   && grep -qF 'pgrep -P' "$_scope_ctl/t" \
   && ! grep -qF 'ps -A -o pid' "$_scope_ctl/t" \
   && grep -qF 'runsv|runsvdir' "$_scope_ctl/t" "$_scope_svc/finish"; then
  pass=$((pass + 1)); printf 'PASS  service cleanup is scoped to the EarnApp process tree\n'
else
  fail=$((fail + 1)); printf 'FAIL  service cleanup still contains a broad pkill or lacks scoped cleanup\n' >&2
fi

if [ "$_scope_old_kill" -eq 0 ]; then
  sh -c 'sleep 60 & sleep 60 & wait' &
  _scope_pid=$!
  _scope_children=""
  for _ in $(seq 1 50); do
    _scope_children=$(ps -A -o pid=,ppid= 2>/dev/null | awk -v p="$_scope_pid" '$2 == p {print $1}')
    [ -n "$_scope_children" ] && break
    sleep 0.1
  done
  printf '%s\n' "$_scope_pid" > "$_scope_svc/supervise/pid"
  sleep 60 &
  _scope_foreign=$!
  PREFIX="$_scope_prefix" sh "$_scope_ctl/t" >/dev/null 2>&1
  _scope_parent_state=$(ps -o stat= -p "$_scope_pid" 2>/dev/null | tr -d ' ')
  _scope_children_alive=0
  for _scope_child in $_scope_children; do
    _scope_child_state=$(ps -o stat= -p "$_scope_child" 2>/dev/null | tr -d ' ')
    case "$_scope_child_state" in
      ""|Z*) ;;
      *) _scope_children_alive=1 ;;
    esac
  done
  if case "$_scope_parent_state" in
       ""|Z*) true ;;
       *) false ;;
     esac \
     && [ "$_scope_children_alive" -eq 0 ] \
     && kill -0 "$_scope_foreign" 2>/dev/null; then
    pass=$((pass + 1)); printf 'PASS  control/t stops only the EarnApp process tree\n'
  else
    fail=$((fail + 1)); printf 'FAIL  control/t left EarnApp running or signalled an unrelated process\n' >&2
  fi
  wait "$_scope_pid" 2>/dev/null || true
  kill -TERM "$_scope_foreign" 2>/dev/null || true
  wait "$_scope_foreign" 2>/dev/null || true

  # finish reads the snapshot one pid per line, so control/t must record it
  # that way too; a space-separated line makes finish refuse the whole list.
  _scope_state_file="$_scope_prefix/var/lib/earnapp-setup/earnapp.children"
  _scope_recorded_count=$(grep -c . "$_scope_state_file" 2>/dev/null || true)
  _scope_expected_count=0
  for _scope_child in $_scope_children; do
    _scope_expected_count=$((_scope_expected_count + 1))
  done
  if [ -n "$_scope_children" ] \
     && [ "$_scope_recorded_count" = "$_scope_expected_count" ] \
     && ! grep -q ' ' "$_scope_state_file" 2>/dev/null; then
    pass=$((pass + 1)); printf 'PASS  control/t records one EarnApp child pid per line\n'
  else
    fail=$((fail + 1)); printf 'FAIL  control/t snapshot is not one pid per line (expected=%s recorded=%s)\n' \
      "$_scope_expected_count" "$_scope_recorded_count" >&2
  fi

  sleep 60 &
  _scope_finish_pid=$!
  sleep 60 &
  _scope_finish_pid2=$!
  printf '%s\n%s\n' "$_scope_finish_pid" "$_scope_finish_pid2" \
    > "$_scope_prefix/var/lib/earnapp-setup/earnapp.children"
  sleep 60 &
  _scope_finish_foreign=$!
  PREFIX="$_scope_prefix" sh "$_scope_svc/finish" >/dev/null 2>&1
  _scope_finish_state=$(ps -o stat= -p "$_scope_finish_pid" 2>/dev/null | tr -d ' ')
  _scope_finish_state2=$(ps -o stat= -p "$_scope_finish_pid2" 2>/dev/null | tr -d ' ')
  if case "$_scope_finish_state" in
       ""|Z*) true ;;
       *) false ;;
     esac \
     && case "$_scope_finish_state2" in
          ""|Z*) true ;;
          *) false ;;
        esac \
     && kill -0 "$_scope_finish_foreign" 2>/dev/null \
     && [ ! -e "$_scope_prefix/var/lib/earnapp-setup/earnapp.children" ]; then
    pass=$((pass + 1)); printf 'PASS  finish reaps only the recorded EarnApp children\n'
  else
    fail=$((fail + 1)); printf 'FAIL  finish missed its child, hit an unrelated process, or kept the snapshot\n' >&2
  fi
  wait "$_scope_finish_pid" 2>/dev/null || true
  wait "$_scope_finish_pid2" 2>/dev/null || true
  kill -TERM "$_scope_finish_foreign" 2>/dev/null || true
  wait "$_scope_finish_foreign" 2>/dev/null || true

  # A stale or recycled supervise/pid must never let cleanup signal a
  # supervisor. The guard refuses the pid and signals nothing; its non-zero
  # exit lets runsv send its own TERM to the process it forked (never to
  # itself).
  #
  # comm cannot be faked by copying a binary: coreutils is a multi-call
  # executable that refuses to run under an unknown name, so the copy would be
  # dead before the guard looked at it. Rename a live shell instead; it is
  # /proc/<pid>/comm that the guard reads.
  sh -c 'echo runsvdir > "/proc/$$/comm" 2>/dev/null; while :; do sleep 1; done' &
  _guard_pid=$!
  for _ in $(seq 1 50); do
    [ "$(cat "/proc/$_guard_pid/comm" 2>/dev/null)" = "runsvdir" ] && break
    sleep 0.1
  done
  if [ "$(cat "/proc/$_guard_pid/comm" 2>/dev/null)" = "runsvdir" ]; then
    printf '%s\n' "$_guard_pid" > "$_scope_svc/supervise/pid"
    PREFIX="$_scope_prefix" sh "$_scope_ctl/t" >/dev/null 2>&1
    _guard_rc=$?
    if kill -0 "$_guard_pid" 2>/dev/null && [ "$_guard_rc" -ne 0 ]; then
      pass=$((pass + 1)); printf 'PASS  control/t refuses to signal a supervisor pid\n'
    else
      fail=$((fail + 1)); printf 'FAIL  control/t signalled a supervisor pid or did not defer to runsv\n' >&2
    fi
    printf '%s\n' "$_guard_pid" > "$_scope_prefix/var/lib/earnapp-setup/earnapp.children"
    PREFIX="$_scope_prefix" sh "$_scope_svc/finish" >/dev/null 2>&1
    if kill -0 "$_guard_pid" 2>/dev/null; then
      pass=$((pass + 1)); printf 'PASS  finish refuses to reap a supervisor pid\n'
    else
      fail=$((fail + 1)); printf 'FAIL  finish reaped a supervisor pid\n' >&2
    fi
  else
    fail=$((fail + 2)); printf 'FAIL  supervisor guard behaviour not run: cannot stage a fake supervisor\n' >&2
  fi
  kill -TERM "$_guard_pid" 2>/dev/null || true
  wait "$_guard_pid" 2>/dev/null || true
else
  fail=$((fail + 2)); printf 'FAIL  scoped cleanup behaviour not run: broad pkill still present\n' >&2
fi
rm -rf "$_scope_prefix"

# Sourcing the termux-services profile hook starts a second runsvdir when the
# manager already runs one; the setup must start the supervisor itself and
# only when no supervisor is running.
if ! grep -qF '. "$hook"' "$SCRIPT_DIR/../earnapp-setup.sh" \
   && grep -qF 'supervisor_running' "$SCRIPT_DIR/../earnapp-setup.sh"; then
  pass=$((pass + 1)); printf 'PASS  setup starts the supervisor without sourcing the profile hook\n'
else
  fail=$((fail + 1)); printf 'FAIL  setup still sources the termux-services profile hook\n' >&2
fi

# Later service operations still need SVDIR/LOGDIR when the supervisor is
# already running, so the exports cannot sit behind that early return.
reset_state
DRY_RUN=0
_wd_prefix="$(mktemp -d)"
(
  PREFIX="$_wd_prefix"
  unset SVDIR LOGDIR
  supervisor_running() { return 0; }
  start_termux_services >/dev/null 2>&1
  printf '%s\n' "${SVDIR:-}" > "$_wd_prefix/svdir.out"
  printf '%s\n' "${LOGDIR:-}" > "$_wd_prefix/logdir.out"
)
check_eq "start_termux_services exports SVDIR before the early return" \
  "$_wd_prefix/var/service" "$(cat "$_wd_prefix/svdir.out")"
check_eq "start_termux_services exports LOGDIR before the early return" \
  "$_wd_prefix/var/log" "$(cat "$_wd_prefix/logdir.out")"
rm -rf "$_wd_prefix"

# Re-running the installer with the same UUID must refresh old service files.
# Otherwise a patched script leaves the legacy broad-kill cleanup in place.
_upgrade_prefix="$(mktemp -d)"
_upgrade_svc="$_upgrade_prefix/var/service/earnapp"
mkdir -p "$_upgrade_svc/control" "$_upgrade_svc/log"
printf '#!/bin/sh\nexec udocker run -e EARNAPP_UUID=%s earnapp\n' "$UUIDX" > "$_upgrade_svc/run"
printf '#!/bin/sh\npkill -f "/usr/bin/proot.*udocker-"\n' > "$_upgrade_svc/control/t"
printf '#!/bin/sh\npkill -f "/usr/bin/proot.*udocker-"\n' > "$_upgrade_svc/finish"
chmod 700 "$_upgrade_svc/run" "$_upgrade_svc/control/t" "$_upgrade_svc/finish"
PREFIX="$_upgrade_prefix" write_service "$UUIDX" >/dev/null 2>&1
if ! grep -qF 'pkill' "$_upgrade_svc/control/t" "$_upgrade_svc/finish" 2>/dev/null \
   && grep -qF 'earnapp.children' "$_upgrade_svc/control/t" "$_upgrade_svc/finish"; then
  pass=$((pass + 1)); printf 'PASS  same-UUID rerun upgrades legacy service cleanup\n'
else
  fail=$((fail + 1)); printf 'FAIL  same-UUID rerun kept the legacy broad kill\n' >&2
fi
rm -rf "$_upgrade_prefix"

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
printf '. "$PREFIX/etc/profile.d/start-services.sh"\n/data/data/com.termux/files/usr/var/lib/earnapp-setup/service-repair.sh boot || true\n' > "$_wd_home/.termux/boot/start-services"
for tool in udocker sv-enable sshd cloudflared speedtest-go; do
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
if PATH="$MOCKDIR3:$PATH" comp_tool_present speedtest-go; then
  pass=$((pass + 1)); printf 'PASS  comp_tool_present speedtest-go present\n'
else
  fail=$((fail + 1)); printf 'FAIL  comp_tool_present speedtest-go present\n' >&2
fi
if ( HOME="$_wd_home" PATH="$MOCKDIR3:$PATH" plan_tools_present ); then
  pass=$((pass + 1)); printf 'PASS  plan_tools_present all present\n'
else
  fail=$((fail + 1)); printf 'FAIL  plan_tools_present all present\n' >&2
fi
rm -f "$MOCKDIR3/udocker"
rm -f "$MOCKDIR3/speedtest-go"
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
out=$(PATH="$MOCKDIR3:$PATH" comp_tool_present speedtest-go 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  pass=$((pass + 1)); printf 'PASS  comp_tool_present speedtest-go absent\n'
else
  fail=$((fail + 1)); printf 'FAIL  comp_tool_present speedtest-go absent\n' >&2
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
MOCKDIR_SSHD="$(mktemp -d)"
cat > "$MOCKDIR_SSHD/sv" <<'SH'
#!/usr/bin/env bash
name="$2"
case "$1" in
  status) printf 'run: %s: (pid 18196) 2297s\n' "$name" ;;
esac
exit 0
SH
chmod +x "$MOCKDIR_SSHD/sv"
out=$(PATH="$MOCKDIR_SSHD:$PATH" setup_base 2>&1); rc=$?
rm -rf "$MOCKDIR_SSHD"
unset PKG_UPGRADABLE
if [ "$rc" -eq 0 ] \
    && case "$out" in *"[watchdog] arm sshd upgrade recovery"*) true ;; *) false ;; esac \
    && case "$out" in *"[watchdog] sv-enable sshd"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base arms sshd watchdog when up\n'
else
  fail=$((fail + 1)); printf 'FAIL  base sshd watchdog arm (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=0
REQUESTED=(base)
_wd_stop_prefix="$(mktemp -d)"
_wd_stop_mock="$(mktemp -d)"
_wd_stop_pids="$_wd_stop_mock/pids"
cat > "$_wd_stop_mock/pkg" <<'SH'
#!/usr/bin/env bash
case "$*" in *upgrade*) sleep 0.3 ;; esac
exit 0
SH
cat > "$_wd_stop_mock/apt" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "list" ] && [ "$2" = "--upgradable" ]; then
  printf 'cloudflared/stable 2026.9.0 aarch64 [upgradable from: 2026.8.0]\n'
fi
exit 0
SH
cat > "$_wd_stop_mock/sv" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) printf 'run: %s: (pid 18196) 2297s\n' "$2" ;;
esac
exit 0
SH
cat > "$_wd_stop_mock/nohup" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "${WATCHDOG_PID_FILE:?}"
exec sleep 30
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$_wd_stop_mock/apt-config"
chmod +x "$_wd_stop_mock/pkg" "$_wd_stop_mock/apt" "$_wd_stop_mock/sv" \
  "$_wd_stop_mock/nohup" "$_wd_stop_mock/apt-config"
out=$(PREFIX="$_wd_stop_prefix" WATCHDOG_PID_FILE="$_wd_stop_pids" \
      PATH="$_wd_stop_mock:/usr/bin:/bin" setup_base 2>&1); rc=$?
_wd_stop_wait=0
while [ "$_wd_stop_wait" -lt 50 ] \
  && [ "$(wc -l < "$_wd_stop_pids" 2>/dev/null || printf 0)" -lt 2 ]; do
  sleep 0.1
  _wd_stop_wait=$((_wd_stop_wait + 1))
done
_wd_stop_count=$(wc -l < "$_wd_stop_pids" 2>/dev/null || printf 0)
_wd_stop_alive=0
if [ -f "$_wd_stop_pids" ]; then
  while IFS= read -r _wd_stop_pid; do
    [ -n "$_wd_stop_pid" ] || continue
    if kill -0 "$_wd_stop_pid" 2>/dev/null; then
      _wd_stop_alive=$((_wd_stop_alive + 1))
    fi
    kill "$_wd_stop_pid" 2>/dev/null || :
  done < "$_wd_stop_pids"
fi
rm -rf "$_wd_stop_prefix" "$_wd_stop_mock"
if [ "$rc" -eq 0 ] && [ "$_wd_stop_count" -ge 2 ] && [ "$_wd_stop_alive" -eq 0 ]; then
  pass=$((pass + 1)); printf 'PASS  base stops watchdogs after pkg upgrade returns\n'
else
  fail=$((fail + 1)); printf 'FAIL  base watchdog cleanup (rc=%s launched=%s alive=%s)\n%s\n' \
    "$rc" "$_wd_stop_count" "$_wd_stop_alive" "$out" >&2
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
   && ! case "$out" in *"[watchdog] arm cloudflared upgrade recovery"*) true ;; *) false ;; esac \
   && ! case "$out" in *"[watchdog] arm sshd upgrade recovery"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base does not arm watchdog when down\n'
else
  fail=$((fail + 1)); printf 'FAIL  base no-arm when down (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

reset_state
DRY_RUN=1
REQUESTED=(base)
PKG_UPGRADABLE=1
MOCKDIR_MIXED="$(mktemp -d)"
cat > "$MOCKDIR_MIXED/sv" <<'SH'
#!/usr/bin/env bash
case "$1:$2" in
  status:sshd) printf 'down: sshd: 1s, normally down\n' ;;
  status:cloudflared) printf 'run: cloudflared: (pid 18196) 2297s\n' ;;
esac
exit 0
SH
chmod +x "$MOCKDIR_MIXED/sv"
out=$(PATH="$MOCKDIR_MIXED:$PATH" setup_base 2>&1); rc=$?
rm -rf "$MOCKDIR_MIXED"
unset PKG_UPGRADABLE
if [ "$rc" -eq 0 ] \
   && case "$out" in *"[watchdog] arm cloudflared upgrade recovery"*) true ;; *) false ;; esac \
   && ! case "$out" in *"[watchdog] arm sshd upgrade recovery"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  base arms only services that were up\n'
else
  fail=$((fail + 1)); printf 'FAIL  base mixed service arm (rc=%s)\n%s\n' "$rc" "$out" >&2
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
WD_MP_SSHD="$(mktemp -d)"
mkdir -p "$WD_MP_SSHD/var/service/sshd" "$WD_MP_SSHD/tmp"
WD_MD_G="$(mktemp -d)"
write_sv_mock "$WD_MD_G" '4|5'
write_sv_enable_mock "$WD_MD_G" "$WD_MP_SSHD/var/service/sshd" ''
write_sleep_mock "$WD_MD_G"
out=$(PREFIX="$WD_MP_SSHD" WATCHDOG_SERVICE=sshd WATCHDOG_TEST_DIR="$WD_MD_G" WATCHDOG_STEP=0 WATCHDOG_WAIT=40 \
      PATH="$WD_MD_G:$PATH" sh -c "$WATCHDOG_LOOP" 2>&1); rc=$?
wlog=$(cat "$WD_MP_SSHD/tmp/sshd-watchdog.log" 2>/dev/null)
wcalls=$(cat "$WD_MD_G/calls" 2>/dev/null)
rm -rf "$WD_MD_G" "$WD_MP_SSHD"
if [ "$rc" -eq 0 ] \
   && [ -n "$wcalls" ] \
   && case "$wlog" in *recovered*) true ;; *) false ;; esac \
   && case "$wlog" in *"sshd down at"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  watchdog watches the requested service (sshd)\n'
else
  fail=$((fail + 1)); printf 'FAIL  watchdog requested service (rc=%s)\ncalls=%s\nlog=%s\n' "$rc" "$wcalls" "$wlog" >&2
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
PREFIX="$WD_MP"
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
printf 'PREFIX=%s\nSVDIR=%s\nWATCHDOG_SERVICE=%s\n' \
  "\${PREFIX:-}" "\${SVDIR:-}" "\${WATCHDOG_SERVICE:-}" >> "$WD_MP/nohup-env"
: > "$WD_MP/nohup-real-invoked"
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$WD_MD_I/apt-config"
chmod +x "$WD_MD_I/pkg" "$WD_MD_I/apt" "$WD_MD_I/sv" "$WD_MD_I/nohup" "$WD_MD_I/apt-config"
rm -f "$WD_MP/nohup-env" "$WD_MP/nohup-real-invoked"
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
check "watchdog child receives PREFIX" "$(cat "$WD_MP/nohup-env" 2>/dev/null)" "PREFIX=$WD_MP"
check "watchdog child receives an explicit SVDIR" "$(cat "$WD_MP/nohup-env" 2>/dev/null)" "SVDIR=$WD_MP/var/service"
check "watchdog child receives sshd service" "$(cat "$WD_MP/nohup-env" 2>/dev/null)" "WATCHDOG_SERVICE=sshd"
check "watchdog child receives cloudflared service" "$(cat "$WD_MP/nohup-env" 2>/dev/null)" "WATCHDOG_SERVICE=cloudflared"

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
   && case "$out" in *"[run] sv up sshd"*) false ;; *) true ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure_service starts a stopped service\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_service start (rc=%s started=%s)\n%s\n' "$rc" "$_wd_started" "$out" >&2
fi

reset_state
DRY_RUN=0
_wd_saved=${PREFIX:-}
_wd_savedpath=$PATH
_wd_prefix="$(mktemp -d)"
mkdir -p "$_wd_prefix/var/service/earnapp"
MOCKDIR_SERVICE_WAIT="$(mktemp -d)"
cat > "$MOCKDIR_SERVICE_WAIT/sv" <<'SH'
#!/usr/bin/env bash
if [ "$1" = status ]; then
  if [ -e "$TERMUX_SERVICE_PREFIX/var/service/$2/supervise/ok" ]; then
    printf 'run: %s: (pid 1234) 1s\n' "$2"
  else
    printf 'down: %s: 1s, normally down\n' "$2"
  fi
elif [ "$1" = up ]; then
  printf 'up\n' >> "$TERMUX_SERVICE_CALLS"
  [ -e "$TERMUX_SERVICE_PREFIX/var/service/$2/supervise/ok" ]
fi
SH
cat > "$MOCKDIR_SERVICE_WAIT/sv-enable" <<'SH'
#!/usr/bin/env bash
[ -e "$TERMUX_SERVICE_PREFIX/var/service/$1/supervise/ok" ]
sv up "$1"
SH
chmod +x "$MOCKDIR_SERVICE_WAIT/sv" "$MOCKDIR_SERVICE_WAIT/sv-enable"
PREFIX="$_wd_prefix"
export TERMUX_SERVICE_PREFIX="$_wd_prefix"
export TERMUX_SERVICE_CALLS="$_wd_prefix/sv-calls"
PATH="$MOCKDIR_SERVICE_WAIT:$_wd_savedpath"
(
  sleep 0.2
  mkdir -p "$_wd_prefix/var/service/earnapp/supervise"
  : > "$_wd_prefix/var/service/earnapp/supervise/ok"
) &
out=$(ensure_service earnapp 2>&1); rc=$?
_wd_started=$SERVICE_JUST_STARTED
wait
_wd_up_calls=0
[ -f "$TERMUX_SERVICE_CALLS" ] && _wd_up_calls=$(wc -l < "$TERMUX_SERVICE_CALLS")
PATH="$_wd_savedpath"
rm -rf "$MOCKDIR_SERVICE_WAIT" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -eq 0 ] && [ "$_wd_started" -eq 1 ] \
   && case "$out" in *"sv-enable earnapp"*) true ;; *) false ;; esac \
   && [ "$_wd_up_calls" -eq 1 ]; then
  pass=$((pass + 1)); printf 'PASS  ensure_service waits for supervision and starts once via sv-enable\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_service waits for supervision and starts once (rc=%s started=%s sv-up-calls=%s)\n%s\n' "$rc" "$_wd_started" "$_wd_up_calls" "$out" >&2
fi

# A service that never reports run must fail loudly and show its recent log,
# otherwise setup prints "All done" while the service is down.
reset_state
DRY_RUN=0
_wd_saved=${PREFIX:-}
_wd_savedpath=$PATH
_wd_prefix="$(mktemp -d)"
mkdir -p "$_wd_prefix/var/service/earnapp/supervise" "$_wd_prefix/var/log/sv/earnapp"
: > "$_wd_prefix/var/service/earnapp/supervise/ok"
printf 'earnapp-startup-marker\n' > "$_wd_prefix/var/log/sv/earnapp/current"
MOCKDIR_SERVICE_DOWN="$(mktemp -d)"
cat > "$MOCKDIR_SERVICE_DOWN/sv" <<'SH'
#!/usr/bin/env bash
if [ "$1" = status ]; then
  printf 'down: %s: 96s, normally up\n' "$2"
fi
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR_SERVICE_DOWN/sv-enable"
chmod +x "$MOCKDIR_SERVICE_DOWN/sv" "$MOCKDIR_SERVICE_DOWN/sv-enable"
PREFIX="$_wd_prefix"
out=$(PATH="$MOCKDIR_SERVICE_DOWN:$_wd_savedpath" ensure_service earnapp 2>&1); rc=$?
PATH="$_wd_savedpath"
rm -rf "$MOCKDIR_SERVICE_DOWN" "$_wd_prefix"
PREFIX="$_wd_saved"
if [ "$rc" -ne 0 ] \
   && case "$out" in *"did not come up after sv-enable"*) true ;; *) false ;; esac \
   && case "$out" in *"earnapp-startup-marker"*) true ;; *) false ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure_service fails and shows the log when a service stays down\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure_service did not fail on a down service (rc=%s)\n%s\n' "$rc" "$out" >&2
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
if [ "$rc" -eq 0 ]; then
  pass=$((pass + 1)); printf 'PASS  comp_tool_present boot true without boot script\n'
else
  fail=$((fail + 1)); printf 'FAIL  comp_tool_present boot requires only sv-enable (rc=%s)\n' "$rc" >&2
fi

reset_state
DRY_RUN=1
_wd_home="$(mktemp -d)"
mkdir -p "$_wd_home/.termux/boot"
printf '. "$PREFIX/etc/profile.d/start-services.sh"\n/data/data/com.termux/files/usr/var/lib/earnapp-setup/service-repair.sh boot || true\n' > "$_wd_home/.termux/boot/start-services"
MOCKDIR17="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR17/sv-enable"
chmod +x "$MOCKDIR17/sv-enable"
( HOME="$_wd_home" PATH="$MOCKDIR17:/usr/bin:/bin" comp_tool_present boot ); rc=$?
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
_wd_saved_prefix=${PREFIX:-}
_wd_ssh_prefix="$(mktemp -d)"
mkdir -p "$_wd_ssh_prefix/etc/ssh" "$_wd_ssh_prefix/var/service/sshd"
printf 'Port 2222\n' > "$_wd_ssh_prefix/etc/ssh/sshd_config"
MOCKDIR_SSHINFO="$(mktemp -d)"
cat > "$MOCKDIR_SSHINFO/sv" <<'SH'
#!/usr/bin/env bash
printf 'run: %s: (pid 1234) 5s\n' "$2"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR_SSHINFO/sshd"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKDIR_SSHINFO/sv-enable"
printf '#!/usr/bin/env bash\nprintf "tester\\n"\n' > "$MOCKDIR_SSHINFO/whoami"
cat > "$MOCKDIR_SSHINFO/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-4 -o addr show dev wlan0")
    printf '3: wlan0    inet 192.168.1.42/24 brd 192.168.1.255 scope global wlan0\n'
    ;;
esac
SH
chmod +x "$MOCKDIR_SSHINFO/sv" "$MOCKDIR_SSHINFO/sshd" \
  "$MOCKDIR_SSHINFO/sv-enable" "$MOCKDIR_SSHINFO/whoami" "$MOCKDIR_SSHINFO/ip"
out=$(PREFIX="$_wd_ssh_prefix" PATH="$MOCKDIR_SSHINFO:$PATH" setup_sshd 2>&1); rc=$?
PREFIX="$_wd_saved_prefix"
rm -rf "$MOCKDIR_SSHINFO" "$_wd_ssh_prefix"
check "sshd prints a copyable connection command" "$out" \
  "SSH command: ssh -p 2222 tester@192.168.1.42" "$rc"

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

# The status tail used to dump every matching process command line, which
# leaked other services' credentials. Nothing should print that again.
if ! grep -qF 'pgrep -af' "$SCRIPT_DIR/../earnapp-setup.sh"; then
  pass=$((pass + 1)); printf 'PASS  earnapp status does not dump process command lines\n'
else
  fail=$((fail + 1)); printf 'FAIL  earnapp status still dumps process command lines with pgrep -af\n' >&2
fi

REPAIR_ROOT="$(mktemp -d)"
REPAIR_STUB="$REPAIR_ROOT/stub"
REPAIR_PREFIX="$REPAIR_ROOT/prefix"
REPAIR_HELPER="$REPAIR_ROOT/service-repair.sh"
mkdir -p "$REPAIR_STUB"
cat > "$REPAIR_STUB/sv-enable" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$REPAIR_TEST_DIR/enabled"
[ "${REPAIR_STUB_KEEP_DOWN:-0}" = 1 ] || rm -f "${SVDIR:?}/$1/down"
exit "${REPAIR_STUB_RC:-0}"
SH
chmod +x "$REPAIR_STUB/sv-enable"

write_repair_helper() {
  printf '%s\n' "${SERVICE_REPAIR_HOOK:-}" > "$REPAIR_HELPER"
}

write_repair_prefix() {
  rm -rf "$REPAIR_PREFIX"
  mkdir -p "$REPAIR_PREFIX/var/service" \
           "$REPAIR_PREFIX/var/lib/earnapp-setup" \
           "$REPAIR_PREFIX/var/log" \
           "$REPAIR_PREFIX/tmp"
  : > "$REPAIR_PREFIX/var/log/service-repair.log"
  rm -f "$REPAIR_STUB/enabled"
}

run_helper() {
  PATH="$REPAIR_STUB:/usr/bin:/bin" PREFIX="$REPAIR_PREFIX" \
    REPAIR_TEST_DIR="$REPAIR_STUB" sh "$REPAIR_HELPER" "$@"
}

write_repair_helper
write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd" \
         "$REPAIR_PREFIX/var/service/ssh-agent" \
         "$REPAIR_PREFIX/var/service/cloudflared"
: > "$REPAIR_PREFIX/var/service/ssh-agent/down"
: > "$REPAIR_PREFIX/var/service/README"
out=$(run_helper snapshot 2>&1); rc=$?
check_eq "helper snapshot exits 0" "0" "$rc"
check_eq "helper snapshot records only enabled services" "cloudflared
sshd" "$(cat "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services" 2>/dev/null)"

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/cloudflared" "$REPAIR_PREFIX/var/service/sshd"
: > "$REPAIR_PREFIX/var/service/sshd/down"
printf 'sshd\nstale-svc\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
out=$(run_helper snapshot 2>&1); rc=$?
check_eq "helper snapshot unions prior pending names" "sshd
stale-svc
cloudflared" "$(cat "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services")"

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/bad name" "$REPAIR_PREFIX/var/service/-dash"
out=$(run_helper snapshot 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services" ]; then
  pass=$((pass + 1)); printf 'PASS  helper snapshot ignores malformed names and writes nothing when empty\n'
else
  fail=$((fail + 1)); printf 'FAIL  helper snapshot empty/malformed (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd" "$REPAIR_PREFIX/var/service/cloudflared"
: > "$REPAIR_PREFIX/var/service/sshd/down"
printf 'sshd\ncloudflared\ngone-svc\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
out=$(run_helper repair 2>&1); rc=$?
check_eq "helper repair exits 0" "0" "$rc"
check_eq "helper repair enables only down services" "sshd" "$(cat "$REPAIR_STUB/enabled" 2>/dev/null)"
check "helper repair drops missing directories" "$(cat "$REPAIR_PREFIX/var/log/service-repair.log")" "[post] dropped gone-svc (service directory missing)"
check "helper repair logs the repair" "$(cat "$REPAIR_PREFIX/var/log/service-repair.log")" "[post] repaired sshd (down reappeared)"
if [ ! -e "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services" ]; then
  pass=$((pass + 1)); printf 'PASS  helper repair removes the empty pending file\n'
else
  fail=$((fail + 1)); printf 'FAIL  helper repair left pending state\n' >&2
fi

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
: > "$REPAIR_PREFIX/var/service/sshd/down"
printf 'sshd\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
export REPAIR_STUB_KEEP_DOWN=1 REPAIR_STUB_RC=1
out=$(run_helper repair 2>&1); rc=$?
unset REPAIR_STUB_KEEP_DOWN REPAIR_STUB_RC
check_eq "helper repair stays successful when sv-enable fails" "0" "$rc"
check_eq "helper repair retains unresolved names" "sshd" "$(cat "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services")"
check "helper repair logs retention" "$(cat "$REPAIR_PREFIX/var/log/service-repair.log")" "[post] retained sshd (down still present)"

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
: > "$REPAIR_PREFIX/var/service/sshd/down"
printf 'sshd\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
out=$(run_helper repair 2>&1); rc=$?
check_eq "stale pending re-enables a manual disable (accepted ambiguity)" "sshd" \
  "$(cat "$REPAIR_STUB/enabled" 2>/dev/null)"

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
: > "$REPAIR_PREFIX/var/service/sshd/down"
printf 'sshd\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
rm -rf "$REPAIR_PREFIX/var/service"
out=$(run_helper repair 2>&1); rc=$?
check_eq "helper repair preserves pending when SVDIR is missing" "sshd" "$(cat "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services")"
check "helper repair logs the preserved pending" "$(cat "$REPAIR_PREFIX/var/log/service-repair.log")" "[post] pending kept (SVDIR missing)"

write_repair_prefix
out=$(run_helper boot 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$REPAIR_STUB/enabled" ] && [ ! -s "$REPAIR_PREFIX/var/log/service-repair.log" ]; then
  pass=$((pass + 1)); printf 'PASS  helper boot is silent without pending state\n'
else
  fail=$((fail + 1)); printf 'FAIL  helper boot silent case (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
: > "$REPAIR_PREFIX/var/service/sshd/down"
printf 'sshd\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
out=$(run_helper boot 2>&1); rc=$?
check_eq "helper boot repairs pending state" "sshd" "$(cat "$REPAIR_STUB/enabled" 2>/dev/null)"
check "helper boot tags log lines" "$(cat "$REPAIR_PREFIX/var/log/service-repair.log")" "[boot] repaired sshd (down reappeared)"

out=$(run_helper bogus 2>&1); rc=$?
check_eq "helper unknown subcommand exits 0" "0" "$rc"

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
printf 'sshd\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
: > "$REPAIR_PREFIX/var/service/sshd/down"
mv "$REPAIR_STUB/sv-enable" "$REPAIR_ROOT/sv-enable.off"
out=$(run_helper repair 2>&1); rc=$?
mv "$REPAIR_ROOT/sv-enable.off" "$REPAIR_STUB/sv-enable"
check_eq "helper repair without sv-enable exits 0" "0" "$rc"
if [ ! -e "$REPAIR_PREFIX/var/service/sshd/down" ] \
   && [ ! -e "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services" ]; then
  pass=$((pass + 1)); printf 'PASS  helper repair removes down without sv-enable\n'
else
  fail=$((fail + 1)); printf 'FAIL  helper repair fallback without sv-enable\n' >&2
fi

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
rm -rf "$REPAIR_PREFIX/var/lib/earnapp-setup"
: > "$REPAIR_PREFIX/var/lib/earnapp-setup"
out=$(run_helper snapshot 2>&1); rc=$?
check_eq "helper snapshot exits 0 with unwritable state" "0" "$rc"

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
cp "$REPAIR_HELPER" "$REPAIR_PREFIX/var/lib/earnapp-setup/service-repair.sh"
out=$(env -u PREFIX PATH="$REPAIR_STUB:/usr/bin:/bin" REPAIR_TEST_DIR="$REPAIR_STUB" \
  sh "$REPAIR_PREFIX/var/lib/earnapp-setup/service-repair.sh" snapshot 2>&1); rc=$?
check_eq "helper derives PREFIX from its installed path" "sshd" \
  "$(cat "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services" 2>/dev/null)"
check_eq "helper prefix derivation exits 0" "0" "$rc"

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
awk 'BEGIN { for (i = 0; i < 1001; i++) print "2020-01-01T00:00:00Z [pre] filler" }' \
  > "$REPAIR_PREFIX/var/log/service-repair.log"
out=$(run_helper snapshot 2>&1); rc=$?
lines=$(wc -l < "$REPAIR_PREFIX/var/log/service-repair.log")
if [ "$rc" -eq 0 ] && [ "$lines" -le 502 ]; then
  pass=$((pass + 1)); printf 'PASS  helper log rotation keeps the repair log bounded\n'
else
  fail=$((fail + 1)); printf 'FAIL  helper log rotation (rc=%s lines=%s)\n' "$rc" "$lines" >&2
fi
check "helper log uses UTC Z timestamps" "$(tail -n 1 "$REPAIR_PREFIX/var/log/service-repair.log")" "[pre] snapshot 1 enabled"

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
: > "$REPAIR_PREFIX/var/service/sshd/down"
printf 'sshd\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
before=$(cksum < "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services")
out=$(run_helper status 2>&1); rc=$?
after=$(cksum < "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services")
check_eq "helper status exits 0" "0" "$rc"
check "helper status reports pending services" "$out" "sshd"
check_eq "helper status is read-only" "$before" "$after"

write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
printf 'sshd\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
out=$(run_helper repair 2>&1)
if grep -Eq 'sdk-node-[0-9a-f]{32}' "$REPAIR_PREFIX/var/log/service-repair.log"; then
  fail=$((fail + 1)); printf 'FAIL  helper log leaked a UUID\n' >&2
else
  pass=$((pass + 1)); printf 'PASS  helper log contains no UUIDs\n'
fi

write_repair_helper
_repair_saved_prefix=${PREFIX:-}
_repair_saved_dry=$DRY_RUN
write_repair_prefix
DRY_RUN=1
PREFIX="$REPAIR_PREFIX"
out=$(write_service_repair_helper 2>&1); rc=$?
check_eq "helper writer dry run exits 0" "0" "$rc"
check "helper writer dry run logs the write" "$out" "[write] $REPAIR_PREFIX/var/lib/earnapp-setup/service-repair.sh"
if [ ! -e "$REPAIR_PREFIX/var/lib/earnapp-setup/service-repair.sh" ]; then
  pass=$((pass + 1)); printf 'PASS  helper writer dry run writes nothing\n'
else
  fail=$((fail + 1)); printf 'FAIL  helper writer dry run wrote a file\n' >&2
fi
DRY_RUN=0
out=$(write_service_repair_helper 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -x "$REPAIR_PREFIX/var/lib/earnapp-setup/service-repair.sh" ]; then
  pass=$((pass + 1)); printf 'PASS  helper writer installs an executable helper\n'
else
  fail=$((fail + 1)); printf 'FAIL  helper writer install (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
if [ -f "$REPAIR_PREFIX/var/lib/earnapp-setup/service-repair.sh" ]; then
  check_eq "helper writer installs the embedded content" "${SERVICE_REPAIR_HOOK:-}" \
    "$(cat "$REPAIR_PREFIX/var/lib/earnapp-setup/service-repair.sh")"
else
  fail=$((fail + 1)); printf 'FAIL  helper writer did not create the helper file\n' >&2
fi
out=$(write_service_repair_helper 2>&1)
if case "$out" in *"[write]"*) false ;; *) true ;; esac; then
  pass=$((pass + 1)); printf 'PASS  helper writer is idempotent\n'
else
  fail=$((fail + 1)); printf 'FAIL  helper writer rewrote identical content\n' >&2
fi
PREFIX="$_repair_saved_prefix"
DRY_RUN="$_repair_saved_dry"

write_repair_helper
write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd"
if command -v dash >/dev/null 2>&1; then
  if dash -n "$REPAIR_HELPER" \
     && PATH="$REPAIR_STUB:/usr/bin:/bin" PREFIX="$REPAIR_PREFIX" \
        REPAIR_TEST_DIR="$REPAIR_STUB" dash "$REPAIR_HELPER" snapshot \
     && [ "$(cat "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services" 2>/dev/null)" = "sshd" ]; then
    pass=$((pass + 1)); printf 'PASS  helper passes dash syntax and snapshot\n'
  else
    fail=$((fail + 1)); printf 'FAIL  helper dash compatibility\n' >&2
  fi
else
  printf 'SKIP  helper POSIX check (dash not installed)\n'
fi

write_apt_config_stub() {
  local dir=$1 mode=$2
  mkdir -p "$dir"
  cat > "$dir/apt-config" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${APT_TEST_DIR:-/dev/null}/calls"
case "$mode" in
  ok) exit 0 ;;
  fail-baseline) exit 1 ;;
  fail-candidate)
    case " \$* " in *" -c "*) exit 1 ;; esac
    exit 0 ;;
  fail-final)
    case " \$* " in *" -c "*) exit 0 ;; esac
    if [ -f "\${PREFIX:?}/etc/apt/apt.conf.d/earnapp-service-repair" ] &&
       grep -q "DPkg::Pre-Invoke" "\$PREFIX/etc/apt/apt.conf.d/earnapp-service-repair"; then
      exit 1
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$dir/apt-config"
}

APT_T="$(mktemp -d)"
REPAIR_CONF="$REPAIR_PREFIX/etc/apt/apt.conf.d/earnapp-service-repair"
REPAIR_INSTALLED="$REPAIR_PREFIX/var/lib/earnapp-setup/service-repair.sh"
_repair_saved_prefix=${PREFIX:-}
_repair_saved_dry=$DRY_RUN
PREFIX="$REPAIR_PREFIX"
export PREFIX

write_apt_config_stub "$APT_T" ok
write_repair_prefix
DRY_RUN=0
APT_TEST_DIR="$APT_T"
export APT_TEST_DIR
out=$(PATH="$APT_T:/usr/bin:/bin" ensure_service_repair 2>&1); rc=$?
check_eq "ensure exits 0 on a valid configuration" "0" "$rc"
if [ -x "$REPAIR_INSTALLED" ]; then
  pass=$((pass + 1)); printf 'PASS  ensure installs the executable helper\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure did not install the helper\n' >&2
fi
check_eq "ensure writes the absolute pre-hook" "yes" \
  "$(grep -Fq "trap '' HUP; $REPAIR_INSTALLED snapshot || true" "$REPAIR_CONF" && echo yes)"
check_eq "ensure writes the absolute post-hook" "yes" \
  "$(grep -Fq "trap '' HUP; $REPAIR_INSTALLED repair || true" "$REPAIR_CONF" && echo yes)"
check_eq "ensure validates the candidate with apt-config -c" "yes" \
  "$(grep -Fq -- '-c ' "$APT_T/calls" && echo yes)"

write_apt_config_stub "$APT_T" fail-baseline
write_repair_prefix
out=$(PATH="$APT_T:/usr/bin:/bin" ensure_service_repair 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$REPAIR_INSTALLED" ] && [ ! -e "$REPAIR_CONF" ]; then
  pass=$((pass + 1)); printf 'PASS  baseline parse failure modifies nothing\n'
else
  fail=$((fail + 1)); printf 'FAIL  baseline failure wrote files (rc=%s)\n%s\n' "$rc" "$out" >&2
fi
check "baseline failure is reported" "$out" "fails to parse"

write_apt_config_stub "$APT_T" fail-candidate
write_repair_prefix
mkdir -p "$REPAIR_PREFIX/etc/apt/apt.conf.d"
printf 'OLD\n' > "$REPAIR_CONF"
out=$(PATH="$APT_T:/usr/bin:/bin" ensure_service_repair 2>&1); rc=$?
check_eq "candidate failure keeps the active fragment" "OLD" "$(cat "$REPAIR_CONF")"
check "candidate failure is reported" "$out" "rejected the staged"
if [ -x "$REPAIR_INSTALLED" ]; then
  pass=$((pass + 1)); printf 'PASS  helper is staged before fragment validation\n'
else
  fail=$((fail + 1)); printf 'FAIL  helper missing after candidate failure\n' >&2
fi

write_apt_config_stub "$APT_T" fail-final
write_repair_prefix
mkdir -p "$REPAIR_PREFIX/etc/apt/apt.conf.d"
printf 'OLD\n' > "$REPAIR_CONF"
out=$(PATH="$APT_T:/usr/bin:/bin" ensure_service_repair 2>&1); rc=$?
check_eq "final validation failure restores the previous fragment" "OLD" "$(cat "$REPAIR_CONF")"
check "final validation failure is reported" "$out" "previous state restored"

write_apt_config_stub "$APT_T" fail-final
write_repair_prefix
out=$(PATH="$APT_T:/usr/bin:/bin" ensure_service_repair 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$REPAIR_CONF" ]; then
  pass=$((pass + 1)); printf 'PASS  final validation failure removes a new fragment\n'
else
  fail=$((fail + 1)); printf 'FAIL  new fragment survived final validation failure\n' >&2
fi

write_apt_config_stub "$APT_T" ok
write_repair_prefix
PATH="$APT_T:/usr/bin:/bin" ensure_service_repair >/dev/null 2>&1
out=$(PATH="$APT_T:/usr/bin:/bin" ensure_service_repair 2>&1); rc=$?
if [ "$rc" -eq 0 ] && case "$out" in *"[write]"*) false ;; *) true ;; esac; then
  pass=$((pass + 1)); printf 'PASS  ensure is idempotent\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure rewrote identical files (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

write_repair_prefix
DRY_RUN=1
out=$(PATH="$REPAIR_ROOT/none:/usr/bin:/bin" ensure_service_repair 2>&1); rc=$?
check_eq "ensure dry run exits 0 without apt-config" "0" "$rc"
check "ensure dry run logs the baseline" "$out" "[run] apt-config dump"
check "ensure dry run logs the helper write" "$out" "[write] $REPAIR_INSTALLED"
check "ensure dry run logs the fragment write" "$out" "[write] $REPAIR_CONF"
if [ ! -e "$REPAIR_INSTALLED" ] && [ ! -e "$REPAIR_CONF" ]; then
  pass=$((pass + 1)); printf 'PASS  ensure dry run writes nothing\n'
else
  fail=$((fail + 1)); printf 'FAIL  ensure dry run wrote files\n' >&2
fi

DRY_RUN=0
write_repair_prefix
out=$(PATH="$REPAIR_ROOT/none" ensure_service_repair 2>&1); rc=$?
check_eq "ensure fails without apt-config" "1" "$rc"
check "missing apt-config is reported" "$out" "apt-config not found"

PREFIX="$_repair_saved_prefix"
DRY_RUN="$_repair_saved_dry"
unset APT_TEST_DIR

reset_state
DRY_RUN=1
REQUESTED=(base)
PKG_UPGRADABLE=1
_repair_saved_prefix=${PREFIX:-}
_repair_saved_dry=$DRY_RUN
PREFIX="$REPAIR_PREFIX"
out=$(PATH="$REPAIR_STUB:/usr/bin:/bin" setup_base 2>&1); rc=$?
_apt_i=$(printf '%s\n' "$out" | grep -n '\[run\] apt-config dump' | head -n 1 | cut -d: -f1)
_upd_i=$(printf '%s\n' "$out" | grep -n 'pkg update -y' | head -n 1 | cut -d: -f1)
check_eq "base validates repair hooks before pkg update" "yes" \
  "$([ -n "$_apt_i" ] && [ -n "$_upd_i" ] && [ "$_apt_i" -lt "$_upd_i" ] && echo yes)"
check_eq "base dry run still exits 0" "0" "$rc"
unset PKG_UPGRADABLE

reset_state
DRY_RUN=0
REQUESTED=(base)
write_repair_prefix
_repair_order="$(mktemp -d)"
cat > "$_repair_order/pkg" <<'SH'
#!/usr/bin/env bash
[ -f "${PREFIX:?}/etc/apt/apt.conf.d/earnapp-service-repair" ] && printf 'conf-present\n' >> "$ORDER_DIR/calls"
printf 'pkg %s\n' "$*" >> "$ORDER_DIR/calls"
exit 0
SH
chmod +x "$_repair_order/pkg"
write_apt_config_stub "$_repair_order" ok
PREFIX="$REPAIR_PREFIX"
ORDER_DIR="$_repair_order"
export PREFIX ORDER_DIR
PATH="$_repair_order:/usr/bin:/bin" setup_base >/dev/null 2>&1; rc=$?
check_eq "base installs the hooks before invoking pkg" "conf-present" \
  "$(head -n 1 "$_repair_order/calls" 2>/dev/null)"
check_eq "base real run exits 0 with a valid configuration" "0" "$rc"

reset_state
DRY_RUN=1
write_repair_prefix
_repair_home="$(mktemp -d)"
_repair_empty="$(mktemp -d)"
out=$(HOME="$_repair_home" PREFIX="$REPAIR_PREFIX" PATH="$_repair_empty:/usr/bin:/bin" setup_boot 2>&1); rc=$?
_pkg_i=$(printf '%s\n' "$out" | grep -n 'pkg install termux-services -y' | head -n 1 | cut -d: -f1)
_apt_i=$(printf '%s\n' "$out" | grep -n '\[run\] apt-config dump' | head -n 1 | cut -d: -f1)
_sup_i=$(printf '%s\n' "$out" | grep -n '\[run\] service-daemon start' | head -n 1 | cut -d: -f1)
_rep_i=$(printf '%s\n' "$out" | grep -n '\[run\] sh .*service-repair.sh repair' | head -n 1 | cut -d: -f1)
_wr_i=$(printf '%s\n' "$out" | grep -n '\[write\].*start-services' | head -n 1 | cut -d: -f1)
check_eq "boot starts the supervisor then repairs before writing hooks" "yes" \
  "$([ -n "$_pkg_i" ] && [ -n "$_apt_i" ] && [ -n "$_sup_i" ] && [ -n "$_rep_i" ] && [ -n "$_wr_i" ] \
     && [ "$_pkg_i" -lt "$_apt_i" ] && [ "$_apt_i" -lt "$_sup_i" ] \
     && [ "$_sup_i" -lt "$_rep_i" ] && [ "$_rep_i" -lt "$_wr_i" ] && echo yes)"
check_eq "boot dry run exits 0" "0" "$rc"

reset_state
DRY_RUN=0
write_repair_prefix
mkdir -p "$REPAIR_PREFIX/var/service/sshd" "$REPAIR_PREFIX/etc/profile.d"
: > "$REPAIR_PREFIX/var/service/sshd/down"
printf 'sshd\n' > "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services"
_repair_marker="$REPAIR_PREFIX/supervisor.started"
_repair_hook_marker="$REPAIR_PREFIX/hook.sourced"
cat > "$REPAIR_PREFIX/etc/profile.d/start-services.sh" <<SH
printf 'sourced\n' > "$_repair_hook_marker"
SH
_repair_boot_stub="$(mktemp -d)"
cat > "$_repair_boot_stub/service-daemon" <<SH
#!/usr/bin/env bash
printf 'started\n' > "$_repair_marker"
exit 0
SH
cat > "$_repair_boot_stub/pgrep" <<SH
#!/usr/bin/env bash
[ -s "$_repair_marker" ]
SH
cat > "$_repair_boot_stub/sv-enable" <<SH
#!/usr/bin/env bash
if [ -f "$_repair_marker" ]; then
  printf 'after-supervisor %s\n' "\$1" >> "$_repair_boot_stub/calls"
else
  printf 'before-supervisor %s\n' "\$1" >> "$_repair_boot_stub/calls"
fi
rm -f "\${SVDIR:?}/\$1/down"
exit 0
SH
chmod +x "$_repair_boot_stub/service-daemon" "$_repair_boot_stub/pgrep" \
  "$_repair_boot_stub/sv-enable"
write_apt_config_stub "$_repair_boot_stub" ok
_repair_home="$(mktemp -d)"
PREFIX="$REPAIR_PREFIX"
export PREFIX
out=$(HOME="$_repair_home" PATH="$_repair_boot_stub:/usr/bin:/bin" setup_boot </dev/null 2>&1); rc=$?
check_eq "boot repairs pending state after starting the supervisor" "after-supervisor sshd" \
  "$(cat "$_repair_boot_stub/calls" 2>/dev/null)"
check_eq "boot starts the supervisor without sourcing the profile hook" "no" \
  "$([ -e "$_repair_hook_marker" ] && echo yes || echo no)"
if [ "$rc" -eq 0 ] && [ ! -e "$REPAIR_PREFIX/var/lib/earnapp-setup/pending-services" ]; then
  pass=$((pass + 1)); printf 'PASS  boot clears repaired pending state\n'
else
  fail=$((fail + 1)); printf 'FAIL  boot pending repair (rc=%s)\n%s\n' "$rc" "$out" >&2
fi

write_repair_prefix
_repair_one="$(mktemp)"
printf '. "$PREFIX/etc/profile.d/start-services.sh"\n' > "$_repair_one"
boot_script_configured "$_repair_one"; rc=$?
check_eq "one-marker boot script is not configured" "1" "$rc"
printf '/data/data/com.termux/files/usr/var/lib/earnapp-setup/service-repair.sh boot || true\n' >> "$_repair_one"
boot_script_configured "$_repair_one"; rc=$?
check_eq "two-marker boot script is configured" "0" "$rc"

reset_state
DRY_RUN=0
write_repair_prefix
mkdir -p "$REPAIR_PREFIX/etc/profile.d"
printf ':\n' > "$REPAIR_PREFIX/etc/profile.d/start-services.sh"
_repair_home="$(mktemp -d)"
mkdir -p "$_repair_home/.termux/boot"
_repair_script="$_repair_home/.termux/boot/start-services"
printf '. "$PREFIX/etc/profile.d/start-services.sh"\n' > "$_repair_script"
chmod +x "$_repair_script"
_repair_boot_stub="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_repair_boot_stub/sv-enable"
chmod +x "$_repair_boot_stub/sv-enable"
write_apt_config_stub "$_repair_boot_stub" ok
out=$(HOME="$_repair_home" PATH="$_repair_boot_stub:/usr/bin:/bin" setup_boot </dev/null 2>&1); rc=$?
check "migration logs the real append" "$out" "[append] $_repair_script"
check_eq "migration appends the repair line once" "1" \
  "$(grep -c 'service-repair.sh boot' "$_repair_script")"
check_eq "migration keeps the start-services line" "1" \
  "$(grep -c 'start-services.sh' "$_repair_script")"
check_eq "migration preserves the original first line" \
  '. "$PREFIX/etc/profile.d/start-services.sh"' "$(head -n 1 "$_repair_script")"
check_eq "migration exits 0" "0" "$rc"

reset_state
DRY_RUN=0
write_repair_prefix
mkdir -p "$REPAIR_PREFIX/etc/profile.d"
printf ':\n' > "$REPAIR_PREFIX/etc/profile.d/start-services.sh"
_repair_home="$(mktemp -d)"
mkdir -p "$_repair_home/.termux/boot"
_repair_script="$_repair_home/.termux/boot/start-services"
printf '. "$PREFIX/etc/profile.d/start-services.sh"' > "$_repair_script"
chmod +x "$_repair_script"
_repair_boot_stub="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_repair_boot_stub/sv-enable"
chmod +x "$_repair_boot_stub/sv-enable"
write_apt_config_stub "$_repair_boot_stub" ok
out=$(HOME="$_repair_home" PATH="$_repair_boot_stub:/usr/bin:/bin" setup_boot </dev/null 2>&1); rc=$?
check_eq "migration keeps a complete start-services line without a trailing newline" "1" \
  "$(grep -cxF '. "$PREFIX/etc/profile.d/start-services.sh"' "$_repair_script")"
check_eq "migration appends the repair line once without a trailing newline" "1" \
  "$(grep -cxF '/data/data/com.termux/files/usr/var/lib/earnapp-setup/service-repair.sh boot || true' "$_repair_script")"
check_eq "migration without a trailing newline exits 0" "0" "$rc"

reset_state
DRY_RUN=1
write_repair_prefix
_repair_home="$(mktemp -d)"
mkdir -p "$_repair_home/.termux/boot"
_repair_script="$_repair_home/.termux/boot/start-services"
printf '. "$PREFIX/etc/profile.d/start-services.sh"\n' > "$_repair_script"
out=$(HOME="$_repair_home" PATH="$_repair_empty:/usr/bin:/bin" setup_boot 2>&1); rc=$?
check "boot dry run logs the append" "$out" "[append] $_repair_script"
check_eq "boot dry run leaves the old script unchanged" \
  '. "$PREFIX/etc/profile.d/start-services.sh"' "$(cat "$_repair_script")"
check_eq "boot append dry run exits 0" "0" "$rc"

reset_state
DRY_RUN=0
write_repair_prefix
mkdir -p "$REPAIR_PREFIX/etc/profile.d"
printf ':\n' > "$REPAIR_PREFIX/etc/profile.d/start-services.sh"
_repair_home="$(mktemp -d)"
mkdir -p "$_repair_home/.termux/boot"
_repair_script="$_repair_home/.termux/boot/start-services"
printf '#!/bin/sh\nprintf custom\n' > "$_repair_script"
chmod +x "$_repair_script"
_repair_hash_before=$(cksum < "$_repair_script")
out=$(HOME="$_repair_home" PATH="$_repair_boot_stub:/usr/bin:/bin" setup_boot </dev/null 2>&1); rc=$?
check "custom boot script keeps the replace prompt path" "$out" "Keeping existing"
check_eq "custom boot script is unchanged" "$_repair_hash_before" "$(cksum < "$_repair_script")"

reset_state
DRY_RUN=0
write_repair_prefix
mkdir -p "$REPAIR_PREFIX/etc/profile.d"
printf ':\n' > "$REPAIR_PREFIX/etc/profile.d/start-services.sh"
_repair_home="$(mktemp -d)"
out=$(HOME="$_repair_home" PATH="$_repair_boot_stub:/usr/bin:/bin" setup_boot </dev/null 2>&1); rc=$?
_repair_script="$_repair_home/.termux/boot/start-services"
check_eq "absent boot script gets the repair line" "1" \
  "$(grep -c 'service-repair.sh boot' "$_repair_script" 2>/dev/null)"
_src_i=$(grep -n 'start-services.sh' "$_repair_script" | head -n 1 | cut -d: -f1)
_rep_i=$(grep -n 'service-repair.sh boot' "$_repair_script" | head -n 1 | cut -d: -f1)
check_eq "boot script sources services before repairing" "yes" \
  "$([ -n "$_src_i" ] && [ -n "$_rep_i" ] && [ "$_src_i" -lt "$_rep_i" ] && echo yes)"
check_eq "boot write exits 0" "0" "$rc"

reset_state
DRY_RUN=1
REQUESTED=(base)
_repair_empty="$(mktemp -d)"
( set -u; unset PREFIX; PATH="$_repair_empty:/usr/bin:/bin" setup_base ) >/dev/null 2>&1; rc=$?
check_eq "base dry run works with PREFIX unset under set -u" "0" "$rc"

PREFIX="$_repair_saved_prefix"
DRY_RUN="$_repair_saved_dry"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
