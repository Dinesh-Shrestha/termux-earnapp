#!/usr/bin/env bash

INST_IMAGE="ghcr.io/xterna/earnapp:alpine"
CONTAINER_NAME="earnapp"
UUID_PREFIX="sdk-node-"

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
    boot)         command -v sv-enable >/dev/null 2>&1 && boot_script_configured "$(boot_script)" ;;
    sshd)         command -v sshd >/dev/null 2>&1 ;;
    cloudflared)  command -v cloudflared >/dev/null 2>&1 ;;
    udocker|earnapp) command -v udocker >/dev/null 2>&1 ;;
    speedtest-go) command -v speedtest-go >/dev/null 2>&1 ;;
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
  log INFO "Waiting for runit to register service $name"
  while [ "$attempt" -lt 100 ]; do
    [ -e "$ready_file" ] && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -e "$ready_file" ] || die "runit did not create the supervise endpoint for $name within 10 seconds: $ready_file"
}

ensure_service() {
  local name=$1 down
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
  step sv-enable "$name" || die "sv-enable $name failed"
  SERVICE_JUST_STARTED=1
}

boot_script() {
  printf '%s/.termux/boot/start-services\n' "$HOME"
}

WATCHDOG_LOOP='step=${WATCHDOG_STEP:-2}
acted=0
downs=0
i=0
printf "armed at +0s\n" >> "${PREFIX}/tmp/cloudflared-watchdog.log"
while [ "$i" -lt "${WATCHDOG_WAIT:-600}" ]; do
  st=$(sv status cloudflared 2>/dev/null)
  case "$st" in
    *"run: cloudflared: (pid"*)
      downs=0
      if [ "$acted" -eq 1 ]; then
        if [ -f "${PREFIX}/var/service/cloudflared/down" ]; then
          sv-enable cloudflared 2>/dev/null
        else
          printf "recovered at +%ss\n" "$((i * step))" >> "${PREFIX}/tmp/cloudflared-watchdog.log"
          exit 0
        fi
      fi
      ;;
    *"down: cloudflared:"*)
      downs=$((downs + 1))
      if [ "$downs" -ge 2 ]; then
        acted=1
        if [ "$downs" -eq 2 ]; then
          printf "cloudflared down at +%ss\n" "$((i * step))" >> "${PREFIX}/tmp/cloudflared-watchdog.log"
        fi
        sv-enable cloudflared 2>/dev/null
      fi
      ;;
  esac
  i=$((i + 1))
  sleep "$step"
done
if [ "$acted" -eq 1 ]; then
  printf "gave up after %ss\n" "$((i * step))" >> "${PREFIX}/tmp/cloudflared-watchdog.log"
else
  printf "no cloudflared outage in %ss\n" "$((i * step))" >> "${PREFIX}/tmp/cloudflared-watchdog.log"
fi'

setup_base() {
  if list_contains base "${REQUESTED[@]}"; then
    log INFO "Base: updating package lists and upgrading packages"
    step pkg update -y || die "pkg update failed"
    if pkg_upgraded; then
      local cfd_up=0
      if service_up cloudflared; then
        sleep 1
        if service_up cloudflared; then
          cfd_up=1
        fi
      fi
      if [ "$cfd_up" -eq 1 ]; then
        log INFO "[watchdog] arm cloudflared upgrade recovery"
        if [ "$DRY_RUN" -eq 1 ]; then
          log INFO "[watchdog] sv-enable cloudflared"
        else
          PREFIX="${PREFIX:-}" nohup sh -c "$WATCHDOG_LOOP" >/dev/null 2>&1 &
        fi
      fi
      step pkg upgrade \
        -o 'Dpkg::Options::=--force-confdef' \
        -o 'Dpkg::Options::=--force-confold' \
        -y || die "pkg upgrade failed"
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
EOF
}

start_termux_services() {
  local hook="${PREFIX:-}/etc/profile.d/start-services.sh"
  if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "[source] $hook"
    return 0
  fi
  [ -r "$hook" ] || die "termux-services startup hook not found: $hook"
  log INFO "Starting termux-services supervisor for this setup run"
  . "$hook" || die "failed to start the termux-services supervisor"
}

setup_boot() {
  local script created=0
  log INFO "Boot: ensuring termux-services and configuring Termux:Boot"
  ensure_pkg sv-enable termux-services
  start_termux_services
  script=$(boot_script)
  if [ -f "$script" ] && boot_script_configured "$script"; then
    log INFO "Termux:Boot start-services script already configured"
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
  [ -f "$script" ] && grep -Fq 'start-services.sh' "$script"
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
  log INFO "Current username: $(whoami 2>/dev/null)@$(hostname 2>/dev/null)"
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
  local uuid=$1 dir control log_run
  dir=$(svc_dir)
  control="$dir/control"
  log_run="$dir/log/run"
  if [ -f "$dir/run" ] && [ "$DRY_RUN" -eq 0 ]; then
    if grep -q "$uuid" "$dir/run"; then
      log INFO "earnapp service already configured for $uuid"
      if [ ! -x "$log_run" ] \
         || ! grep -Fq 'share/termux-services/svlogger' "$log_run" \
         || [ ! -p "$dir/log/supervise/ok" ]; then
        write_service_logger "$dir" || die "earnapp service logger setup failed"
        EARNAPP_LOGGER_REPAIRED=1
      fi
    elif [ "$FLAG_YES" -eq 0 ] && ask_yn "earnapp service exists with a different UUID. Rewrite it?" y; then
      write_service_files "$uuid" "$dir" "$control" || die "earnapp service files failed"
    else
      log INFO "Keeping existing earnapp service"
    fi
  else
    write_service_files "$uuid" "$dir" "$control" || die "earnapp service files failed"
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

termux-wake-lock

exec udocker run \\
  -v "\$PREFIX/etc/resolv.conf:/etc/resolv.conf" \\
  -e EARNAPP_UUID=$uuid \\
  $CONTAINER_NAME
EOF
  cat > "$control/t" <<'EOF' || die "write $control/t failed"
#!/data/data/com.termux/files/usr/bin/sh

pkill -TERM -f 'earnapp run' 2>/dev/null
pkill -TERM -f 'earnapp autoupgrade' 2>/dev/null
pkill -TERM -f '/usr/bin/proot.*udocker-' 2>/dev/null
pkill -TERM -f 'udocker run.*EARNAPP_UUID' 2>/dev/null

sleep 1

pkill -KILL -f 'earnapp run' 2>/dev/null
pkill -KILL -f 'earnapp autoupgrade' 2>/dev/null
pkill -KILL -f '/usr/bin/proot.*udocker-' 2>/dev/null
pkill -KILL -f 'udocker run.*EARNAPP_UUID' 2>/dev/null

exit 0
EOF
  cat > "$dir/finish" <<'EOF' || die "write $dir/finish failed"
#!/data/data/com.termux/files/usr/bin/sh

pkill -TERM -f 'earnapp run' 2>/dev/null
pkill -TERM -f 'earnapp autoupgrade' 2>/dev/null
pkill -TERM -f '/usr/bin/proot.*udocker-' 2>/dev/null
pkill -TERM -f 'udocker run.*EARNAPP_UUID' 2>/dev/null

sleep 1

pkill -KILL -f 'earnapp run' 2>/dev/null
pkill -KILL -f 'earnapp autoupgrade' 2>/dev/null
pkill -KILL -f '/usr/bin/proot.*udocker-' 2>/dev/null
pkill -KILL -f 'udocker run.*EARNAPP_UUID' 2>/dev/null

exit 0
EOF
  chmod +x "$dir/run" "$control/t" "$dir/finish" || die "chmod service files failed"
  write_service_logger "$dir" || die "earnapp service logger setup failed"
}

setup_earnapp() {
  local uuid plat service_dir attempt
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
  fi
  log INFO "Registration link: https://earnapp.com/r/$uuid"
  log INFO "EarnApp log: ${PREFIX:-}/var/log/sv/earnapp/current (follow with: tail -f \"\${PREFIX}/var/log/sv/earnapp/current\")"
  step sv status earnapp
  if [ "$DRY_RUN" -eq 0 ]; then
    pgrep -af 'earnapp|udocker|proot' 2>/dev/null || true
  fi
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
      --all|-a)         REQUESTED+=(base boot sshd cloudflared udocker earnapp speedtest-go) ;;
      --base)           REQUESTED+=(base) ;;
      --boot)           REQUESTED+=(boot) ;;
      --sshd)           REQUESTED+=(sshd) ;;
      --cloudflared)    REQUESTED+=(cloudflared) ;;
      --udocker)        REQUESTED+=(udocker) ;;
      --earnapp)        REQUESTED+=(earnapp) ;;
      --speedtest-go)   REQUESTED+=(speedtest-go) ;;
      --no-base)        SKIPPED+=(base) ;;
      --no-boot)        SKIPPED+=(boot) ;;
      --no-sshd)        SKIPPED+=(sshd) ;;
      --no-cloudflared) SKIPPED+=(cloudflared) ;;
      --no-udocker)     SKIPPED+=(udocker) ;;
      --no-earnapp)     SKIPPED+=(earnapp) ;;
      --no-speedtest-go) SKIPPED+=(speedtest-go) ;;
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
      REQUESTED=(base boot sshd cloudflared udocker earnapp speedtest-go)
    else
      MODE="menu"
      return 0
    fi
  fi
  MODE="flags"
  local -a finals=()
  local c
  for c in base boot sshd cloudflared udocker earnapp speedtest-go; do
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
  local plan c s
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
    printf 'Architecture: %s   User: %s@%s\n' "$(detect_arch)" "$(whoami 2>/dev/null)" "$(hostname 2>/dev/null)"
    printf '%s\n' '-------------------------------------------'
    printf ' 1) Base system update/upgrade\n'
    printf ' 2) Termux:Boot + termux-services\n'
    printf ' 3) OpenSSH (sshd service + password)\n'
    printf ' 4) Cloudflared + service prerequisites\n'
    printf ' 5) udocker (install + verify)\n'
    printf ' 6) EarnApp full bring-up (includes 1, 2, 5)\n'
    printf ' 7) speedtest-go (install CLI)\n'
    printf ' 8) Everything (1-7)\n'
    printf ' 0) Quit\n'
    printf 'Select an option [0-8]: '
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
      8) menu_run base boot sshd cloudflared udocker earnapp speedtest-go ;;
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
