#!/usr/bin/env bash

INST_IMAGE="ghcr.io/xterna/earnapp:alpine"
CONTAINER_NAME="earnapp"
UUID_PREFIX="sdk-node-"
RECOVERY_JOB_ID=1001
RECOVERY_PERIOD_MS=900000
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-10}"
TERMUX_API_DATA_DIR="${TERMUX_API_DATA_DIR:-/data/data/com.termux.api}"

DRY_RUN=0
FLAG_YES=0
FLAG_GENERATE_UUID=0
CLI_UUID=""
MODE="menu"
declare -a REQUESTED=()
declare -a SKIPPED=()

log() {
  local level=$1 color="" reset=""
  shift
  if [ -t 1 ]; then
    case "$level" in
      INFO)  color=$'\033[0;32m' ;;
      WARN)  color=$'\033[0;33m' ;;
      ERROR) color=$'\033[0;31m' ;;
    esac
    reset=$'\033[0m'
  fi
  printf '%b[%s]%b %s\n' "$color" "$level" "$reset" "$*" >&2
}

die() {
  log ERROR "$@"
  exit 1
}

ask_yn() {
  local prompt=$1 default=$2 ans
  if [ "$DRY_RUN" -eq 1 ] || [ "$FLAG_YES" -eq 1 ] || [ ! -t 0 ]; then
    [ "$default" = "y" ]
    return $?
  fi
  while :; do
    if [ "$default" = "y" ]; then
      printf '%s [Y/n] ' "$prompt" >&2
    else
      printf '%s [y/N] ' "$prompt" >&2
    fi
    read -r ans
    case "$ans" in
      [yY]) return 0 ;;
      [nN]) return 1 ;;
      "")   [ "$default" = "y" ] && return 0 || return 1 ;;
    esac
  done
}

step() {
  log INFO "[run] $*"
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  "$@"
}

pkg_upgraded() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[run] apt list --upgradable"
    [ "${PKG_UPGRADABLE:-1}" -eq 1 ]
    return $?
  fi
  apt list --upgradable 2>/dev/null | grep -q upgradable
}

is_termux() {
  [ -n "${PREFIX:-}" ] &&
    [ -d /data/data/com.termux/files/usr ] &&
    [ "$(uname -o 2>/dev/null)" = "Android" ]
}

detect_arch() {
  local arch="${1:-$(uname -m)}"
  case "$arch" in
    aarch64)            echo "linux/arm64" ;;
    armv7l|armv8l)      echo "linux/arm/v7" ;;
    x86_64|amd64)       echo "linux/amd64" ;;
    *) die "Unsupported architecture: $arch" ;;
  esac
}

gen_uuid() {
  local hex
  hex=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf '%s%s\n' "$UUID_PREFIX" "$hex"
}

validate_uuid() {
  [[ "$1" =~ ^${UUID_PREFIX}[0-9a-f]{32}$ ]]
}

normalize_platform() {
  printf '%s\n' "${1%/v[0-9]*}"
}

platform_matches() {
  [ "$(normalize_platform "$1")" = "$(normalize_platform "$2")" ]
}

parse_image_platform() {
  printf '%s\n' "$1" | awk -v img="$INST_IMAGE" 'index($0,img) { print $1; exit }'
}
deps_of() {
  case "$1" in
    boot)        echo base ;;
    sshd)        printf 'base\nboot\n' ;;
    cloudflared) printf 'base\nboot\n' ;;
    udocker)     echo base ;;
    earnapp)     printf 'base\nboot\nudocker\n' ;;
    speedtest-go) echo base ;;
    recovery)    printf 'base\nboot\n' ;;
  esac
}

list_contains() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

declare -a _ord=()
declare -A _seen=()

resolve_request() {
  local c
  _ord=()
  _seen=()
  for c in "$@"; do
    _add_deps "$c"
  done
  [ "${#_ord[@]}" -eq 0 ] && return 0
  printf '%s\n' "${_ord[@]}"
}

_add_deps() {
  local c=$1 d
  if [ -n "${_seen[$c]:-}" ]; then return; fi
  _seen[$c]=1
  for d in $(deps_of "$c"); do
    _add_deps "$d"
  done
  _ord+=("$c")
}

comp_tool_present() {
  case "$1" in
    base)         return 0 ;;
    boot)         command -v sv-enable >/dev/null 2>&1 ;;
    sshd)         command -v sshd >/dev/null 2>&1 ;;
    cloudflared)  command -v cloudflared >/dev/null 2>&1 ;;
    udocker|earnapp) command -v udocker >/dev/null 2>&1 ;;
    speedtest-go) command -v speedtest-go >/dev/null 2>&1 ;;
    recovery)     command -v termux-job-scheduler >/dev/null 2>&1 ;;
    *)            return 0 ;;
  esac
}

plan_tools_present() {
  local c
  for c in "${_ord[@]}"; do
    comp_tool_present "$c" || return 1
  done
  return 0
}

svc_dir() {
  printf '%s/var/service/earnapp\n' "${PREFIX:-}"
}

service_up() {
  local name=$1
  sv status "$name" 2>/dev/null | grep -q "run: $name: (pid"
}

stop_watchdogs() {
  local pid
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  done
}

ensure_pkg() {
  local probe=$1 pkg=$2
  if command -v "$probe" >/dev/null 2>&1; then
    log INFO "$pkg already installed"
    return 0
  fi
  step pkg install "$pkg" -y || die "pkg install $pkg failed"
}

SERVICE_JUST_STARTED=0

wait_for_service_supervision() {
  local name=$1 ready_file="${PREFIX:-}/var/service/$1/supervise/ok" attempt=0
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ -e "$ready_file" ] && return 0
  # A dead supervisor cannot create the endpoint. Bring it back once instead
  # of waiting for something that will never appear.
  if ! supervisor_active; then
    log WARN "termux-services supervisor is not running; restarting it"
    start_termux_services
  fi
  log INFO "Waiting for runit to register service $name"
  while [ "$attempt" -lt 100 ]; do
    [ -e "$ready_file" ] && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -e "$ready_file" ] || die "runit did not create the supervise endpoint for $name within 10 seconds: $ready_file"
}

wait_for_service_up() {
  local name=$1 attempt=0
  [ "$DRY_RUN" -eq 1 ] && return 0
  while [ "$attempt" -lt 20 ]; do
    service_up "$name" && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  service_up "$name"
}

ensure_service() {
  local name=$1 down log_file
  SERVICE_JUST_STARTED=0
  if ! command -v sv-enable >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log INFO "sv-enable not found; would require termux-services (menu option 2)"
      return 0
    fi
    die "sv-enable not found; install termux-services first (menu option 2)"
  fi
  down="${PREFIX:-}/var/service/$name/down"
  if service_up "$name" && [ ! -f "$down" ]; then
    log INFO "$name already enabled and running"
    return 0
  fi
  if [ -f "$down" ]; then
    log INFO "$name has a down file; re-enabling"
  fi
  wait_for_service_supervision "$name"
  if ! step sv-enable "$name"; then
    # sv-enable fails with "unable to open supervise/ok" when the supervisor
    # died after leaving a stale endpoint behind. Restart it once and retry.
    if [ "$DRY_RUN" -eq 0 ] && ! supervisor_active; then
      log WARN "sv-enable $name failed; restarting the termux-services supervisor"
      start_termux_services
      wait_for_service_supervision "$name"
      step sv-enable "$name" || die "sv-enable $name failed"
    else
      die "sv-enable $name failed"
    fi
  fi
  SERVICE_JUST_STARTED=1
  if ! wait_for_service_up "$name"; then
    log_file="${PREFIX:-}/var/log/sv/$name/current"
    log ERROR "$name did not come up after sv-enable"
    if [ -r "$log_file" ]; then
      log ERROR "Recent $name log ($log_file):"
      tail -n 20 "$log_file" >&2 || true
    fi
    die "$name failed to start; inspect $log_file"
  fi
}

boot_script() {
  printf '%s/.termux/boot/start-services\n' "$HOME"
}

WATCHDOG_LOOP='svc=${WATCHDOG_SERVICE:-cloudflared}
step=${WATCHDOG_STEP:-2}
acted=0
downs=0
i=0
wlog="${PREFIX}/tmp/${svc}-watchdog.log"
printf "armed at +0s\n" >> "$wlog"
while [ "$i" -lt "${WATCHDOG_WAIT:-600}" ]; do
  st=$(sv status "$svc" 2>/dev/null)
  case "$st" in
    *"run: $svc: (pid"*)
      downs=0
      if [ "$acted" -eq 1 ]; then
        if [ -f "${PREFIX}/var/service/$svc/down" ]; then
          sv-enable "$svc" 2>/dev/null
        else
          printf "recovered at +%ss\n" "$((i * step))" >> "$wlog"
          exit 0
        fi
      fi
      ;;
    *"down: $svc:"*)
      downs=$((downs + 1))
      if [ "$downs" -ge 2 ]; then
        acted=1
        if [ "$downs" -eq 2 ]; then
          printf "%s down at +%ss\n" "$svc" "$((i * step))" >> "$wlog"
        fi
        sv-enable "$svc" 2>/dev/null
      fi
      ;;
  esac
  i=$((i + 1))
  sleep "$step"
done
if [ "$acted" -eq 1 ]; then
  printf "gave up after %ss\n" "$((i * step))" >> "$wlog"
else
  printf "no %s outage in %ss\n" "$svc" "$((i * step))" >> "$wlog"
fi'

SERVICE_REPAIR_HOOK='#!/data/data/com.termux/files/usr/bin/sh
trap "" HUP 2>/dev/null || :
case "$0" in
  */var/lib/earnapp-setup/service-repair.sh) derived_prefix=${0%/var/lib/earnapp-setup/service-repair.sh} ;;
  *) derived_prefix="" ;;
esac
PREFIX=${PREFIX:-$derived_prefix}
[ -n "$PREFIX" ] || exit 0
PATH="$PREFIX/bin:$PATH"
export PATH
SVDIR="$PREFIX/var/service"
export SVDIR
state_dir="$PREFIX/var/lib/earnapp-setup"
pending="$state_dir/pending-services"
log_file="$PREFIX/var/log/service-repair.log"

log_line() {
  phase=$1
  shift
  if [ -f "$log_file" ] && [ "$(wc -l < "$log_file")" -gt 1000 ]; then
    tail -n 500 "$log_file" > "$log_file.tmp.$$" && mv -f "$log_file.tmp.$$" "$log_file"
  fi
  printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" "$*" >> "$log_file" 2>/dev/null
}

is_name() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$1" in
    [A-Za-z0-9]*) return 0 ;;
  esac
  return 1
}

write_pending() {
  if [ -z "$1" ]; then
    rm -f "$pending"
    return 0
  fi
  tmp="$pending.tmp.$$"
  printf "%s\n" "$1" > "$tmp" 2>/dev/null || return 0
  mv -f "$tmp" "$pending" 2>/dev/null || rm -f "$tmp"
}

snapshot() {
  enabled=""
  for d in "$SVDIR"/*; do
    [ -d "$d" ] || continue
    name=${d##*/}
    is_name "$name" || continue
    [ -f "$d/down" ] && continue
    if [ -z "$enabled" ]; then enabled="$name"; else enabled="$enabled
$name"; fi
  done
  old=""
  [ -f "$pending" ] && old=$(cat "$pending")
  merged=""
  count=0
  for name in $old $enabled; do
    [ -n "$name" ] || continue
    is_name "$name" || continue
    case "
$merged
" in *"
$name
"*) continue ;; esac
    if [ -z "$merged" ]; then merged="$name"; else merged="$merged
$name"; fi
    count=$((count + 1))
  done
  current=""
  [ -f "$pending" ] && current=$(cat "$pending")
  [ "$merged" = "$current" ] || write_pending "$merged"
  log_line pre "snapshot $count enabled"
}

repair() {
  phase=$1
  [ -f "$pending" ] || return 0
  if [ ! -d "$SVDIR" ]; then
    log_line "$phase" "pending kept (SVDIR missing)"
    return 0
  fi
  keep=""
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    is_name "$name" || continue
    d="$SVDIR/$name"
    if [ ! -d "$d" ]; then
      log_line "$phase" "dropped $name (service directory missing)"
      continue
    fi
    [ -f "$d/down" ] || continue
    if command -v sv-enable >/dev/null 2>&1; then
      sv-enable "$name" >/dev/null 2>&1 || :
    else
      rm -f "$d/down" 2>/dev/null || :
      sv up "$name" >/dev/null 2>&1 || :
    fi
    if [ -f "$d/down" ]; then
      if [ -z "$keep" ]; then keep="$name"; else keep="$keep
$name"; fi
      log_line "$phase" "retained $name (down still present)"
    else
      log_line "$phase" "repaired $name (down reappeared)"
    fi
  done < "$pending"
  current=""
  [ -f "$pending" ] && current=$(cat "$pending")
  [ "$keep" = "$current" ] || write_pending "$keep"
}

boot() {
  [ -f "$pending" ] || return 0
  repair boot
}

status() {
  printf "pending: "
  if [ -f "$pending" ]; then
    while IFS= read -r name || [ -n "$name" ]; do
      [ -n "$name" ] && printf "%s " "$name"
    done < "$pending"
  fi
  printf "\n"
  if [ -f "$pending" ]; then
    while IFS= read -r name || [ -n "$name" ]; do
      [ -n "$name" ] || continue
      if [ ! -d "$SVDIR/$name" ]; then
        printf "service %s: missing\n" "$name"
      elif [ -f "$SVDIR/$name/down" ]; then
        printf "service %s: disabled (down present)\n" "$name"
      else
        printf "service %s: enabled\n" "$name"
      fi
      if command -v sv >/dev/null 2>&1; then
        sv status "$name" 2>/dev/null
      fi
    done < "$pending"
  fi
  printf "log:\n"
  tail -n 20 "$log_file" 2>/dev/null
}

case "${1:-}" in
  snapshot) snapshot ;;
  repair) repair post ;;
  boot) boot ;;
  status) status ;;
  *) : ;;
esac
exit 0'

write_service_repair_helper() {
  local dir="${PREFIX:-}/var/lib/earnapp-setup"
  local target="$dir/service-repair.sh"
  local tmp="$target.tmp.$$"
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[write] $target"
    return 0
  fi
  mkdir -p "$dir" "${PREFIX:-}/var/log" || die "failed to create service-repair state directories"
  if [ -f "$target" ] && [ "$(cat "$target")" = "$SERVICE_REPAIR_HOOK" ]; then
    return 0
  fi
  printf '%s\n' "$SERVICE_REPAIR_HOOK" > "$tmp" || die "failed to write $tmp"
  sh -n "$tmp" || { rm -f "$tmp"; die "service-repair helper failed the POSIX shell syntax check"; }
  chmod +x "$tmp" || { rm -f "$tmp"; die "failed to set the service-repair helper executable"; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; die "failed to install $target"; }
}

ensure_service_repair() {
  local helper="${PREFIX:-}/var/lib/earnapp-setup/service-repair.sh"
  local conf_dir="${PREFIX:-}/etc/apt/apt.conf.d"
  local conf="$conf_dir/earnapp-service-repair"
  local stage="${PREFIX:-}/etc/apt"
  local candidate="$stage/earnapp-service-repair.candidate"
  local backup="$stage/earnapp-service-repair.prev"
  local pre post desired
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[run] apt-config dump"
    write_service_repair_helper
    log INFO "[write] $conf"
    return 0
  fi
  command -v apt-config >/dev/null 2>&1 ||
    die "apt-config not found; cannot validate the APT service-repair hooks"
  apt-config dump >/dev/null 2>&1 ||
    die "existing APT configuration fails to parse; not modifying it"
  write_service_repair_helper
  pre="DPkg::Pre-Invoke { \"trap '' HUP; $helper snapshot || true\"; };"
  post="DPkg::Post-Invoke { \"trap '' HUP; $helper repair || true\"; };"
  desired=$(printf '%s\n%s\n' "$pre" "$post")
  if [ -f "$conf" ] && [ "$(cat "$conf")" = "$desired" ]; then
    log INFO "APT service-repair hooks already configured"
    return 0
  fi
  mkdir -p "$conf_dir" || die "failed to create $conf_dir"
  rm -f "$candidate"
  printf '%s\n%s\n' "$pre" "$post" > "$candidate" || die "failed to stage $candidate"
  apt-config -c "$candidate" dump >/dev/null 2>&1 || {
    rm -f "$candidate"
    die "apt-config rejected the staged service-repair fragment"
  }
  if [ -f "$conf" ]; then
    cp -f "$conf" "$backup" || die "failed to back up $conf"
  else
    rm -f "$backup"
  fi
  mv -f "$candidate" "$conf" || die "failed to activate $conf"
  if ! apt-config dump >/dev/null 2>&1; then
    if [ -f "$backup" ]; then mv -f "$backup" "$conf"; else rm -f "$conf"; fi
    die "APT configuration failed validation after installing the service-repair hooks; previous state restored"
  fi
  rm -f "$backup"
  log INFO "APT service-repair hooks installed"
}

setup_base() {
  ensure_service_repair
  if list_contains base "${REQUESTED[@]}"; then
    log INFO "Base: updating package lists and upgrading packages"
    step pkg update -y || die "pkg update failed"
    if pkg_upgraded; then
      local name watch="" stable="" pids=""
      for name in sshd cloudflared; do
        if service_up "$name"; then
          watch="$watch $name"
        fi
      done
      if [ -n "$watch" ]; then
        sleep 1
        for name in $watch; do
          if service_up "$name"; then
            stable="$stable $name"
          fi
        done
        watch=$stable
      fi
      for name in $watch; do
        log INFO "[watchdog] arm $name upgrade recovery"
        if [ "$DRY_RUN" -eq 1 ]; then
          log INFO "[watchdog] sv-enable $name"
        else
          PREFIX="${PREFIX:-}" SVDIR="${PREFIX:-}/var/service" WATCHDOG_SERVICE="$name" nohup sh -c "$WATCHDOG_LOOP" >/dev/null 2>&1 &
          pids="$pids $!"
        fi
      done
      if ! step pkg upgrade \
        -o 'Dpkg::Options::=--force-confdef' \
        -o 'Dpkg::Options::=--force-confold' \
        -y; then
        stop_watchdogs $pids
        die "pkg upgrade failed"
      fi
      stop_watchdogs $pids
    else
      log INFO "No upgradable packages; skipping pkg upgrade"
    fi
  else
    if plan_tools_present; then
      log INFO "Base: required tools already present; skipping pkg update/upgrade (run --base to update)"
    else
      log INFO "Base: refreshing package lists (tool missing)"
      step pkg update -y || die "pkg update failed"
    fi
  fi
}

write_start_services() {
  local target
  target=$(boot_script)
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[write] $target"
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh

termux-wake-lock
. "$PREFIX/etc/profile.d/start-services.sh"
/data/data/com.termux/files/usr/var/lib/earnapp-setup/service-repair.sh boot || true
EOF
}

supervisor_running() {
  command -v pgrep >/dev/null 2>&1 && pgrep -x runsvdir >/dev/null 2>&1
}

supervisor_active() {
  local pidfile="${PREFIX:-}/var/run/service-daemon.pid" pid=""
  supervisor_running && return 0
  [ -r "$pidfile" ] || return 1
  read -r pid < "$pidfile" 2>/dev/null || pid=""
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

start_termux_services() {
  local pidfile="${PREFIX:-}/var/run/service-daemon.pid" pid="" attempt=0
  # Export the values the profile hook would have provided before any early
  # return, so later service operations always have the expected layout.
  export SVDIR="${PREFIX:-}/var/service"
  export LOGDIR="${PREFIX:-}/var/log"
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[run] service-daemon start"
    return 0
  fi
  if supervisor_running; then
    log INFO "termux-services supervisor is already running"
    return 0
  fi
  if [ -r "$pidfile" ]; then
    read -r pid < "$pidfile" 2>/dev/null || pid=""
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "$pid" 2>/dev/null; then
          log INFO "termux-services supervisor is already running"
          return 0
        fi
        ;;
    esac
  fi
  log INFO "Starting the termux-services supervisor"
  # Do not source the profile hook: it starts a second daemon when the
  # manager already runs one, and it runs third-party shell code in-process.
  if command -v service-daemon >/dev/null 2>&1; then
    nohup service-daemon start >/dev/null 2>&1 </dev/null &
  fi
  while [ "$attempt" -lt 50 ]; do
    supervisor_running && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  # A stale service-daemon.pid can make service-daemon start a no-op; fall
  # back to runsvdir only when pgrep can confirm no supervisor is running.
  if command -v runsvdir >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1; then
    nohup runsvdir -P "$SVDIR" >/dev/null 2>&1 </dev/null &
    attempt=0
    while [ "$attempt" -lt 50 ]; do
      supervisor_running && return 0
      sleep 0.1
      attempt=$((attempt + 1))
    done
  fi
  log WARN "The termux-services supervisor did not report as running yet"
  return 0
}

ensure_wake_lock() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[run] termux-wake-lock"
    return 0
  fi
  if ! command -v termux-wake-lock >/dev/null 2>&1; then
    log WARN "termux-wake-lock is not available; background services may be paused"
    return 0
  fi
  if step termux-wake-lock; then
    log INFO "Termux wake lock acquired for background services"
  else
    log WARN "termux-wake-lock failed; background services may be paused"
  fi
  return 0
}

append_boot_line() {
  local script=$1 pattern=$2 line=$3
  [ -f "$script" ] || return 0
  grep -Fq -- "$pattern" "$script" 2>/dev/null && return 0
  log INFO "[append] $script"
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  if [ -s "$script" ] && [ -n "$(tail -c 1 "$script")" ]; then
    printf '\n' >> "$script" || die "failed to append to $script"
  fi
  printf '%s\n' "$line" >> "$script" || die "failed to append to $script"
}

setup_boot() {
  local script created=0
  log INFO "Boot: ensuring termux-services and configuring Termux:Boot"
  ensure_pkg sv-enable termux-services
  ensure_service_repair
  start_termux_services
  ensure_wake_lock
  step sh "${PREFIX:-}/var/lib/earnapp-setup/service-repair.sh" repair || true
  script=$(boot_script)
  if [ -f "$script" ] && boot_script_configured "$script"; then
    log INFO "Termux:Boot start-services script already configured"
  elif [ -f "$script" ] && grep -Fq 'start-services.sh' "$script"; then
    append_boot_line "$script" 'termux-wake-lock' 'termux-wake-lock'
    append_boot_line "$script" 'service-repair.sh boot' '/data/data/com.termux/files/usr/var/lib/earnapp-setup/service-repair.sh boot || true'
  elif [ -f "$script" ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ "$FLAG_YES" -eq 0 ] && ask_yn "start-services already exists. Replace it?" n; then
      write_start_services
      created=1
    else
      log INFO "Keeping existing $script"
    fi
  else
    write_start_services
    created=1
  fi
  if [ ! -x "$script" ]; then
    step chmod +x "$script"
  fi
  if [ "$created" -eq 1 ]; then
    log WARN "Reminder: open the Termux:Boot app once; disable battery optimization for Termux and Termux:Boot"
  fi
}

boot_script_configured() {
  local script=${1:-$(boot_script)}
  [ -f "$script" ] && grep -Fq 'start-services.sh' "$script" \
    && grep -Fq 'termux-wake-lock' "$script" \
    && grep -Fq 'service-repair.sh boot' "$script"
}

setup_recovery() {
  local script job_id=$RECOVERY_JOB_ID period=$RECOVERY_PERIOD_MS rc=0
  log INFO "Recovery: scheduling the termux-job-scheduler auto-restart job"
  ensure_pkg termux-job-scheduler termux-api
  if [ ! -d "$TERMUX_API_DATA_DIR" ]; then
    log ERROR "Termux:API app is not installed (missing $TERMUX_API_DATA_DIR)"
    log WARN "Install Termux:API from F-Droid, open it once, then re-run: bash earnapp-setup.sh --recovery"
    return 1
  fi
  script=$(boot_script)
  if [ ! -f "$script" ]; then
    log WARN "Boot script missing: $script (run --boot to create it)"
  elif ! grep -Fq 'start-services.sh' "$script"; then
    log WARN "$script does not start termux-services; job $job_id will run it unchanged"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[run] timeout -k 5 $RECOVERY_TIMEOUT termux-job-scheduler --script $script --job-id $job_id --period-ms $period --persisted true --battery-not-low false --network none"
    return 0
  fi
  timeout -k 5 "$RECOVERY_TIMEOUT" termux-job-scheduler --script "$script" --job-id "$job_id" \
    --period-ms "$period" --persisted true --battery-not-low false --network none || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    log WARN "termux-job-scheduler did not respond within ${RECOVERY_TIMEOUT}s; the job was not scheduled"
    log WARN "Termux:API is installed but not answering; open the Termux:API app once, then re-run: bash earnapp-setup.sh --recovery"
    return 1
  fi
  if [ "$rc" -eq 127 ]; then
    log ERROR "timeout command not found; install coreutils with: pkg install coreutils"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    log WARN "termux-job-scheduler exited $rc; the job may still be scheduled (known Termux:API output bug)"
    log WARN "If it never runs, open the Termux:API app once and re-run: bash earnapp-setup.sh --recovery"
  fi
  log INFO "Recovery job $job_id scheduled: runs every 15-30 minutes and survives reboot"
  log INFO "Silence from termux-job-scheduler with --network none is expected"
  log INFO "Verify over ADB: adb shell cmd jobscheduler get-job-state com.termux.api $job_id"
  log INFO "Cancel over ADB: adb shell cmd jobscheduler cancel com.termux.api $job_id"
}

sshd_port() {
  local config="${PREFIX:-}/etc/ssh/sshd_config" port=""
  if [ -f "$config" ]; then
    port=$(awk 'tolower($1)=="port" { print $2; exit }' "$config" 2>/dev/null)
  fi
  case "$port" in
    ""|*[!0-9]*) port=8022 ;;
    *) [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || port=8022 ;;
  esac
  printf '%s\n' "$port"
}

parse_ifconfig_ipv4() {
  awk -v wanted="${1:-}" '
    wanted != "" && $1 == wanted ":" { in_wanted = 1; next }
    wanted != "" && in_wanted && /^[^[:space:]]/ { in_wanted = 0 }
    /inet / && (wanted == "" || in_wanted) {
      for (i = 1; i <= NF; i++) {
        if ($i == "inet") {
          value = $(i + 1)
          sub(/^addr:/, "", value)
          print value
          exit
        }
      }
    }'
}

local_ipv4() {
  local ip="" ip_cmd
  ip_cmd=$(command -v ip 2>/dev/null || true)
  if [ -n "$ip_cmd" ]; then
    ip=$("$ip_cmd" -4 -o addr show dev wlan0 2>/dev/null \
      | awk '$3 == "inet" { sub(/\/.*/, "", $4); print $4; exit }')
    if [ -z "$ip" ]; then
      ip=$("$ip_cmd" -4 route get 1.1.1.1 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    fi
  fi
  if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
    ip=$(ifconfig wlan0 2>/dev/null | parse_ifconfig_ipv4)
    [ -n "$ip" ] || ip=$(ifconfig 2>/dev/null | parse_ifconfig_ipv4 wlan0)
  fi
  if [ -z "$ip" ] && command -v getprop >/dev/null 2>&1; then
    ip=$(getprop dhcp.wlan0.ipaddress 2>/dev/null)
  fi
  case "$ip" in
    ""|127.*|0.0.0.0|255.*) ip=localhost ;;
  esac
  printf '%s\n' "$ip"
}

ssh_target() {
  printf '%s@%s\n' "$(whoami 2>/dev/null)" "$(local_ipv4)"
}

setup_sshd() {
  log INFO "SSH: ensuring openssh and a supervised sshd service"
  ensure_pkg sshd openssh
  ensure_service sshd
  if [ "$DRY_RUN" -eq 0 ] && [ "$FLAG_YES" -eq 0 ] && [ -t 0 ]; then
    if [ "$SERVICE_JUST_STARTED" -eq 1 ]; then
      log INFO "Setting a new SSH password (passwd)"
      step passwd
    else
      log INFO "SSH password unchanged"
    fi
  fi
  log INFO "SSH command: ssh -p $(sshd_port) $(ssh_target)"
  step sv status sshd
  log INFO "SSH log: ${PREFIX:-}/var/log/sv/sshd/current"
}

setup_cloudflared() {
  log INFO "Cloudflared: ensuring the package and Termux service prerequisites (service setup is manual)"
  ensure_pkg cloudflared cloudflared
  log INFO "Configure tunnels manually: cloudflared tunnel login && cloudflared service install"
}

setup_speedtest_go() {
  log INFO "Speedtest-Go: ensuring the CLI package is installed"
  ensure_pkg speedtest-go speedtest-go
  log INFO "Run speedtest-go whenever you want to test this device's internet connection"
}

setup_udocker() {
  log INFO "udocker: ensuring the udocker package is installed and working"
  ensure_pkg udocker udocker
  step udocker version
}

uuid_lower() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

installed_uuid() {
  local dir
  dir=$(svc_dir)
  if [ -f "$dir/run" ]; then
    grep -oE "${UUID_PREFIX}[0-9a-f]{32}" "$dir/run" | head -n 1
  fi
  return 0
}

uuid_resolve() {
  local installed answer
  if [ -n "$CLI_UUID" ]; then
    CLI_UUID=$(uuid_lower "$CLI_UUID")
    if validate_uuid "$CLI_UUID"; then
      echo "$CLI_UUID"
      return 0
    fi
    die "Invalid --uuid value: $CLI_UUID (expected ${UUID_PREFIX}<32 hex characters>)"
  fi
  if [ "$FLAG_GENERATE_UUID" -eq 1 ]; then
    gen_uuid
    return 0
  fi
  installed=$(installed_uuid)
  if [ -n "$installed" ]; then
    log INFO "Existing UUID found: $installed"
    if [ "$DRY_RUN" -eq 0 ] && [ "$FLAG_YES" -eq 0 ] && ask_yn "Generate a new UUID instead?" n; then
      gen_uuid
      return 0
    fi
    echo "$installed"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ] || [ "$FLAG_YES" -eq 1 ] || [ ! -t 0 ]; then
    gen_uuid
    return 0
  fi
  while :; do
    printf 'Enter a custom UUID (or press Enter to auto-generate): ' >&2
    read -r answer
    if [ -n "$answer" ]; then
      answer=$(uuid_lower "$answer")
      if validate_uuid "$answer"; then
        echo "$answer"
        return 0
      fi
      log WARN "Invalid format: expected ${UUID_PREFIX}<32 hex characters>"
    else
      gen_uuid
      return 0
    fi
  done
}

image_platform_from_udocker() {
  parse_image_platform "$(udocker images -p 2>/dev/null)"
}

image_present() {
  udocker images -p 2>/dev/null | grep -qw "$INST_IMAGE"
}

ensure_image() {
  local plat=$1 reported
  log INFO "EarnApp: ensuring image $INST_IMAGE for platform $plat"
  if [ "$DRY_RUN" -eq 1 ]; then
    step udocker pull --platform="$plat" "$INST_IMAGE"
    return 0
  fi
  if ! command -v udocker >/dev/null 2>&1; then
    die "udocker not found (run --udocker or --earnapp again)"
  fi
  if ! image_present; then
    log INFO "No local image $INST_IMAGE found; pulling"
    step udocker pull --platform="$plat" "$INST_IMAGE" || die "udocker pull failed"
    return 0
  fi
  reported=$(image_platform_from_udocker)
  if [ -z "$reported" ]; then
    reported=$(udocker inspect "$INST_IMAGE" 2>/dev/null |
      sed -n 's/.*"architecture": *"\([^"]*\)".*/\1/p' | head -n 1)
    case "$reported" in
      amd64) reported="linux/amd64" ;;
      arm64) reported="linux/arm64" ;;
      arm)   reported="linux/arm" ;;
    esac
  fi
  if [ -z "$reported" ] || [[ "$reported" != *"/"* ]]; then
    if [ "$FLAG_YES" -eq 0 ] && ask_yn "Image $INST_IMAGE local platform is unknown. Refetch (delete + re-pull)?" n; then
      step udocker rmi -f "$INST_IMAGE" || die "udocker rmi failed"
      step udocker pull --platform="$plat" "$INST_IMAGE" || die "udocker pull failed"
    else
      log INFO "Keeping existing image $INST_IMAGE (platform undetermined)"
    fi
    return 0
  fi
  log INFO "Local image platform reported: $reported"
  if platform_matches "$reported" "$plat"; then
    log INFO "Image platform matches host ($plat)"
    if [ "$FLAG_YES" -eq 0 ] && ask_yn "Refetch the image (delete + re-pull)?" n; then
      step udocker rmi -f "$INST_IMAGE" || die "udocker rmi failed"
      step udocker pull --platform="$plat" "$INST_IMAGE" || die "udocker pull failed"
    fi
  else
    log WARN "Image platform $reported does not match required $plat; refetching"
    step udocker rmi -f "$INST_IMAGE" || die "udocker rmi failed"
    step udocker pull --platform="$plat" "$INST_IMAGE" || die "udocker pull failed"
  fi
}

ensure_container() {
  log INFO "EarnApp: ensuring container named $CONTAINER_NAME"
  if [ "$DRY_RUN" -eq 1 ]; then
    step udocker create --name="$CONTAINER_NAME" "$INST_IMAGE"
    return 0
  fi
  if udocker create --name="$CONTAINER_NAME" "$INST_IMAGE" >/dev/null 2>&1; then
    log INFO "Container $CONTAINER_NAME created"
    return 0
  fi
  if udocker ps 2>/dev/null | grep -F "['$CONTAINER_NAME']" >/dev/null \
     || udocker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    log WARN "Container $CONTAINER_NAME already exists"
    if ask_yn "Recreate the container (delete + create)?" n; then
      step udocker rm -f "$CONTAINER_NAME" || die "udocker rm failed"
      step udocker create --name="$CONTAINER_NAME" "$INST_IMAGE" || die "udocker create failed"
    else
      log INFO "Keeping existing container $CONTAINER_NAME"
    fi
  else
    die "udocker create failed and no container named $CONTAINER_NAME exists"
  fi
}

ensure_exec_mode() {
  local mode
  if command -v runc >/dev/null 2>&1 || command -v crun >/dev/null 2>&1; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[write] udocker setup --execmode=P1 $CONTAINER_NAME"
    return 0
  fi
  mode=$(udocker setup "$CONTAINER_NAME" 2>/dev/null | sed -n 's/^execmode:[[:space:]]*//p')
  if [ "$mode" = "P1" ]; then
    return 0
  fi
  log INFO "udocker exec mode is ${mode:-unknown}; switching to P1 (Termux PRoot)"
  step udocker setup --execmode=P1 "$CONTAINER_NAME" || log WARN "Could not set udocker exec mode to P1"
}

write_service() {
  local uuid=$1 dir control log_run before after
  SERVICE_FILES_CHANGED=0
  dir=$(svc_dir)
  control="$dir/control"
  log_run="$dir/log/run"
  [ -f "$dir/run" ] && before=$(cat "$dir/run" 2>/dev/null || true)
  if [ -f "$dir/run" ] && [ "$DRY_RUN" -eq 0 ]; then
    if grep -q "$uuid" "$dir/run"; then
      log INFO "earnapp service already configured for $uuid; refreshing its files"
      write_service_files "$uuid" "$dir" "$control" || die "earnapp service files failed"
      if [ ! -x "$log_run" ] \
         || ! grep -Fq 'share/termux-services/svlogger' "$log_run" \
         || [ ! -p "$dir/log/supervise/ok" ]; then
        write_service_logger "$dir" || die "earnapp service logger setup failed"
        EARNAPP_LOGGER_REPAIRED=1
      fi
    elif ask_yn "earnapp service exists with a different UUID. Rewrite it?" y; then
      write_service_files "$uuid" "$dir" "$control" || die "earnapp service files failed"
    else
      log INFO "Keeping existing earnapp service"
    fi
  else
    write_service_files "$uuid" "$dir" "$control" || die "earnapp service files failed"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    after=$(cat "$dir/run" 2>/dev/null || true)
    [ "$before" = "$after" ] || SERVICE_FILES_CHANGED=1
  fi
}

write_service_logger() {
  local dir=$1
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[write] $dir/log/run"
    return 0
  fi
  mkdir -p "$dir/log" || die "mkdir -p $dir/log failed"
  cat > "$dir/log/run" <<'EOF' || die "write $dir/log/run failed"
#!/data/data/com.termux/files/usr/bin/sh

exec "${PREFIX:-/data/data/com.termux/files/usr}/share/termux-services/svlogger"
EOF
  chmod +x "$dir/log/run" || die "chmod $dir/log/run failed"
}

write_service_files() {
  local uuid=$1 dir=$2 control=$3
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[write] $dir/run"
    log INFO "[write] $control/t"
    log INFO "[write] $dir/finish"
    log INFO "[write] $dir/log/run"
    return 0
  fi
  mkdir -p "$control" "$dir/log" || die "mkdir -p $control failed"
  cat > "$dir/run" <<EOF || die "write $dir/run failed"
#!/data/data/com.termux/files/usr/bin/sh

# Clear EarnApp processes that were reparented out of the service tree before
# starting a new container. Match the command line because the app runs under
# the Termux linker, so its process name is never earnapp.
sweep_earnapp() {
  command -v pgrep >/dev/null 2>&1 || return 0
  targets=""
  for pid in \$(pgrep -f 'earnapp (run|autoupgrade)' 2>/dev/null) \$(pgrep -f 'udocker run .*earnapp' 2>/dev/null); do
    case "\$pid" in ''|*[!0-9]*) continue ;; esac
    [ "\$pid" -gt 1 ] || continue
    [ "\$pid" = "\$\$" ] && continue
    case "\$(cat "/proc/\$pid/comm" 2>/dev/null)" in
      runsv|runsvdir) continue ;;
    esac
    targets="\$targets \$pid"
  done
  [ -n "\$targets" ] || return 0
  for pid in \$targets; do
    kill -TERM "\$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in \$targets; do
    kill -KILL "\$pid" 2>/dev/null || true
  done
}

sweep_earnapp
termux-wake-lock

rm -f "\${PREFIX:-/data/data/com.termux/files/usr}/var/lib/earnapp-setup/earnapp.children" 2>/dev/null || true

exec udocker run \\
  -v "\$PREFIX/etc/resolv.conf:/etc/resolv.conf" \\
  -e EARNAPP_UUID=$uuid \\
  $CONTAINER_NAME
EOF
  cat > "$control/t" <<'EOF' || die "write $control/t failed"
#!/data/data/com.termux/files/usr/bin/sh
# Scoped cleanup: signal only this service's process tree. Never signal a
# supervisor, this script, one of its ancestors, or an unidentifiable pid:
# other services share the same udocker/proot processes and the same runsvdir.
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
service_dir="$PREFIX/var/service/earnapp"
state_file="$PREFIX/var/lib/earnapp-setup/earnapp.children"

parent_of() {
  awk 'sub(/^[^)]*\) /, "") { print $2 }' "/proc/$1/stat" 2>/dev/null
}

refuse_pid() {
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  [ "$1" -gt 1 ] || return 0
  [ "$1" = "$$" ] && return 0
  [ -d "/proc/$1" ] || return 0
  case "$(cat "/proc/$1/comm" 2>/dev/null)" in
    runsv|runsvdir) return 0 ;;
  esac
  p=$$
  while : ; do
    p=$(parent_of "$p")
    case "$p" in ''|*[!0-9]*) break ;; esac
    [ "$p" -le 1 ] && break
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

pid=${1:-}
[ -n "$pid" ] || pid=$(cat "$service_dir/supervise/pid" 2>/dev/null)
if refuse_pid "$pid"; then
  # No trustworthy target. Signal nothing ourselves. A non-zero exit tells
  # runsv to send TERM to the service process it forked, which is always the
  # right process and never a supervisor.
  exit 1
fi

kids=""
queue=$pid
if command -v pgrep >/dev/null 2>&1; then
  while [ -n "$queue" ]; do
    next=""
    for p in $queue; do
      for c in $(pgrep -P "$p" 2>/dev/null); do
        refuse_pid "$c" && continue
        kids="$kids $c"
        next="$next $c"
      done
    done
    queue=$next
  done
fi

mkdir -p "${state_file%/*}" 2>/dev/null || true
{
  for p in $kids; do
    printf '%s\n' "$p"
  done
} > "$state_file" 2>/dev/null || true
for p in $kids; do
  kill -TERM "$p" 2>/dev/null || true
done
kill -TERM "$pid" 2>/dev/null || true
sleep 1
for p in $kids; do
  kill -KILL "$p" 2>/dev/null || true
done
kill -KILL "$pid" 2>/dev/null || true
exit 0
EOF
  cat > "$dir/finish" <<'EOF' || die "write $dir/finish failed"
#!/data/data/com.termux/files/usr/bin/sh
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
state_file="$PREFIX/var/lib/earnapp-setup/earnapp.children"

parent_of() {
  awk 'sub(/^[^)]*\) /, "") { print $2 }' "/proc/$1/stat" 2>/dev/null
}

refuse_pid() {
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  [ "$1" -gt 1 ] || return 0
  [ "$1" = "$$" ] && return 0
  [ -d "/proc/$1" ] || return 0
  case "$(cat "/proc/$1/comm" 2>/dev/null)" in
    runsv|runsvdir) return 0 ;;
  esac
  p=$$
  while : ; do
    p=$(parent_of "$p")
    case "$p" in ''|*[!0-9]*) break ;; esac
    [ "$p" -le 1 ] && break
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

if [ -f "$state_file" ]; then
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    refuse_pid "$pid" && continue
    kill -TERM "$pid" 2>/dev/null || true
  done < "$state_file"
  sleep 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    refuse_pid "$pid" && continue
    kill -KILL "$pid" 2>/dev/null || true
  done < "$state_file"
  rm -f "$state_file"
fi

# control/t only walks descendants of the live supervisor, so a process that
# was reparented after a crash is invisible to it. Match the command line to
# reap those orphans without touching another service's udocker processes.
sweep_earnapp() {
  command -v pgrep >/dev/null 2>&1 || return 0
  targets=""
  for pid in $(pgrep -f 'earnapp (run|autoupgrade)' 2>/dev/null) $(pgrep -f 'udocker run .*earnapp' 2>/dev/null); do
    refuse_pid "$pid" && continue
    targets="$targets $pid"
  done
  [ -n "$targets" ] || return 0
  for pid in $targets; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $targets; do
    kill -KILL "$pid" 2>/dev/null || true
  done
}
sweep_earnapp
exit 0
EOF
  chmod +x "$dir/run" "$control/t" "$dir/finish" || die "chmod service files failed"
  write_service_logger "$dir" || die "earnapp service logger setup failed"
}

setup_earnapp() {
  local uuid plat service_dir attempt log_file
  uuid=$(uuid_resolve)
  log INFO "Using UUID: $uuid"
  if ! command -v udocker >/dev/null 2>&1; then
    log INFO "udocker missing; installing"
    setup_udocker
  fi
  plat=$(detect_arch)
  ensure_image "$plat"
  ensure_container
  ensure_exec_mode
  EARNAPP_LOGGER_REPAIRED=0
  write_service "$uuid" || die "earnapp service files failed"
  ensure_service earnapp
  if [ "$EARNAPP_LOGGER_REPAIRED" -eq 1 ]; then
    service_dir=$(svc_dir)
    log INFO "Restarting earnapp supervision to activate its repaired logger"
    step sv exit earnapp || die "Could not restart earnapp supervision for its logger"
    attempt=0
    while [ "$attempt" -lt 10 ]; do
      if [ -p "$service_dir/log/supervise/ok" ] && service_up earnapp; then
        break
      fi
      attempt=$((attempt + 1))
      sleep 1
    done
    if [ ! -p "$service_dir/log/supervise/ok" ]; then
      die "EarnApp logger did not start; inspect $service_dir/log/run"
    fi
  elif [ "$SERVICE_FILES_CHANGED" -eq 1 ] && [ "$SERVICE_JUST_STARTED" -eq 0 ]; then
    log INFO "Restarting earnapp to apply the updated service files"
    step sv restart earnapp || die "Could not restart earnapp after updating its service files"
    if ! wait_for_service_up earnapp; then
      log_file="${PREFIX:-}/var/log/sv/earnapp/current"
      log ERROR "earnapp did not come up after restart"
      if [ -r "$log_file" ]; then
        log ERROR "Recent earnapp log ($log_file):"
        tail -n 20 "$log_file" >&2 || true
      fi
      die "earnapp failed to restart; inspect $log_file"
    fi
  fi
  log INFO "Registration link: https://earnapp.com/r/$uuid"
  log INFO "EarnApp log: ${PREFIX:-}/var/log/sv/earnapp/current (follow with: tail -f \"\${PREFIX}/var/log/sv/earnapp/current\")"
  step sv status earnapp
}

run_component() {
  case "$1" in
    base)        setup_base ;;
    boot)        setup_boot ;;
    sshd)        setup_sshd ;;
    cloudflared) setup_cloudflared ;;
    udocker)     setup_udocker ;;
    earnapp)     setup_earnapp ;;
    speedtest-go) setup_speedtest_go ;;
    recovery)    setup_recovery ;;
    *)           die "Unknown component: $1" ;;
  esac
}

usage() {
  cat <<'USAGE'
earnapp-setup — one-shot EarnApp setup for Termux using udocker

Usage:
  earnapp-setup.sh [OPTIONS]

Run with no options to open the interactive menu.

Components:
  --all, -a            Run all components
  --base               pkg update; upgrade only when packages exist
  --boot               Termux:Boot + termux-services
  --sshd               OpenSSH + supervised sshd service
  --cloudflared        Install cloudflared only
  --udocker            Install + verify udocker
  --earnapp            Full EarnApp bring-up (base + boot + udocker + image + service)
  --speedtest-go       Install the speedtest-go CLI
  --recovery           Schedule the Termux:API auto-recovery job (needs Termux:API app)
  --no-<component>     Strip a component (useful with --all), e.g. --no-sshd

UUID:
  --uuid <value>       Use a custom UUID (sdk-node-<32 hex>)
  --generate-uuid      Generate a new UUID

Behavior:
  --yes, -y            Assume defaults; no prompts (auto-generates UUID if needed)
  --dry-run            Print the plan and commands without executing them
  --help, -h           Show this help and exit

Examples:
  earnapp-setup.sh
  earnapp-setup.sh --earnapp --yes
  earnapp-setup.sh --speedtest-go
  earnapp-setup.sh --all --no-sshd --no-speedtest-go
  earnapp-setup.sh --earnapp --uuid sdk-node-00000000000000000000000000000000
  wget -qO- https://example.com/earnapp-setup.sh | bash
USAGE
}

reset_state() {
  DRY_RUN=0
  FLAG_YES=0
  FLAG_GENERATE_UUID=0
  CLI_UUID=""
  MODE="menu"
  REQUESTED=()
  SKIPPED=()
  _ord=()
  _seen=()
}

parse_args() {
  local a
  while [ $# -gt 0 ]; do
    a=$1
    shift
    case "$a" in
      --all|-a)         REQUESTED+=(base boot sshd cloudflared udocker earnapp speedtest-go recovery) ;;
      --base)           REQUESTED+=(base) ;;
      --boot)           REQUESTED+=(boot) ;;
      --sshd)           REQUESTED+=(sshd) ;;
      --cloudflared)    REQUESTED+=(cloudflared) ;;
      --udocker)        REQUESTED+=(udocker) ;;
      --earnapp)        REQUESTED+=(earnapp) ;;
      --speedtest-go)   REQUESTED+=(speedtest-go) ;;
      --recovery)       REQUESTED+=(recovery) ;;
      --no-base)        SKIPPED+=(base) ;;
      --no-boot)        SKIPPED+=(boot) ;;
      --no-sshd)        SKIPPED+=(sshd) ;;
      --no-cloudflared) SKIPPED+=(cloudflared) ;;
      --no-udocker)     SKIPPED+=(udocker) ;;
      --no-earnapp)     SKIPPED+=(earnapp) ;;
      --no-speedtest-go) SKIPPED+=(speedtest-go) ;;
      --no-recovery)    SKIPPED+=(recovery) ;;
      --uuid)
        [ $# -gt 0 ] || die "--uuid requires a value"
        case "$1" in
          -*) die "--uuid requires a value" ;;
        esac
        CLI_UUID=$1
        shift
        ;;
      --generate-uuid)  FLAG_GENERATE_UUID=1 ;;
      --yes|-y)         FLAG_YES=1 ;;
      --dry-run)        DRY_RUN=1 ;;
      --help|-h)        usage; exit 0 ;;
      *)                die "Unknown option: $a (use --help)" ;;
    esac
  done
  if [ "${#REQUESTED[@]}" -eq 0 ]; then
    if [ "${#SKIPPED[@]}" -gt 0 ]; then
      REQUESTED=(base boot sshd cloudflared udocker earnapp speedtest-go recovery)
    else
      MODE="menu"
      return 0
    fi
  fi
  MODE="flags"
  local -a finals=()
  local c
  for c in base boot sshd cloudflared udocker earnapp speedtest-go recovery; do
    if ! list_contains "$c" "${SKIPPED[@]}" && list_contains "$c" "${REQUESTED[@]}"; then
      finals+=("$c")
    fi
  done
  REQUESTED=("${finals[@]}")
  if [ "${#REQUESTED[@]}" -eq 0 ]; then
    die "Nothing to do (use --help)"
  fi
}

run_setup() {
  local plan c s svdir_at_launch=${SVDIR:-}
  resolve_request "${REQUESTED[@]}" >/dev/null
  plan=("${_ord[@]}")
  for s in "${SKIPPED[@]}"; do
    if list_contains "$s" "${plan[@]}"; then
      die "--no-$s conflicts with the resolved plan: a requested component depends on $s"
    fi
  done
  log INFO "Setup plan: ${plan[*]}"
  for c in "${plan[@]}"; do
    log INFO "=== $c ==="
    run_component "$c" || die "Component $c failed"
  done
  log INFO "All done."
  if [ "$svdir_at_launch" != "${PREFIX:-}/var/service" ] \
     && { list_contains boot "${plan[@]}" \
       || list_contains sshd "${plan[@]}" \
       || list_contains cloudflared "${plan[@]}" \
       || list_contains earnapp "${plan[@]}"; }; then
    log INFO "This shell hasn't loaded Termux services. To use sv here, run:"
    log INFO '  . "$PREFIX/etc/profile.d/start-services.sh"'
    log INFO "Or exit and open a new Termux session; skip if sv status already works."
  fi
  return 0
}

menu_run() {
  local c rc=0
  REQUESTED=()
  for c in "$@"; do REQUESTED+=("$c"); done
  ( run_setup ) || { rc=$?; log WARN "Setup did not complete; returning to menu"; }
  return "$rc"
}

menu() {
  local opt rc
  if ! is_termux; then
    die "This script must run inside Termux"
  fi
  while :; do
    printf '\nEarnApp Termux Setup\n'
    printf 'Architecture: %s   User: %s\n' "$(detect_arch)" "$(ssh_target)"
    printf '%s\n' '-------------------------------------------'
    printf ' 1) Base system update/upgrade\n'
    printf ' 2) Termux:Boot + termux-services\n'
    printf ' 3) OpenSSH (sshd service + password)\n'
    printf ' 4) Cloudflared + service prerequisites\n'
    printf ' 5) udocker (install + verify)\n'
    printf ' 6) EarnApp full bring-up (includes 1, 2, 5)\n'
    printf ' 7) speedtest-go (install CLI)\n'
    printf ' 8) Auto-recovery job (termux-job-scheduler)\n'
    printf ' 9) Everything (1-8)\n'
    printf ' 0) Quit\n'
    printf 'Select an option [0-9]: '
    if ! read -r opt; then
      log WARN "No input (EOF); exiting"
      return 0
    fi
    case "$opt" in
      1) menu_run base ;;
      2) menu_run boot ;;
      3) menu_run sshd ;;
      4) menu_run cloudflared ;;
      5) menu_run udocker ;;
      6) menu_run earnapp ;;
      7) menu_run speedtest-go ;;
      8) menu_run recovery ;;
      9) menu_run base boot sshd cloudflared udocker earnapp speedtest-go recovery ;;
      0) return 0 ;;
      *) log WARN "Invalid option: $opt"; continue ;;
    esac
    rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
  done
}

main() {
  parse_args "$@"
  if [ "$MODE" = "menu" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log INFO "Dry-run: menu mode requires Termux; nothing to show"
      return 0
    fi
    menu
    return $?
  fi
  if [ "$DRY_RUN" -eq 0 ] && ! is_termux; then
    die "This script must run inside Termux (PREFIX='${PREFIX:-}', uname='$(uname -o 2>/dev/null)')"
  fi
  run_setup
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
