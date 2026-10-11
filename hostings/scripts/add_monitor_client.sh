#!/usr/bin/env bash
redraw() { [ -t 1 ] || return 0; printf "$@"; }
set -e

# -d / --debug: trace every command. Stripped from "$@" so it never reaches the
# script's own argument parsing.
DEBUG_MODE=0
_dbg_args=()
for _a in "$@"; do
    case "$_a" in
        -d|--debug) DEBUG_MODE=1 ;;
        *)          _dbg_args+=("$_a") ;;
    esac
done
set -- ${_dbg_args+"${_dbg_args[@]}"}
unset _a _dbg_args
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# The Uptime Kuma client the Monitor module needs: python3-venv, and the
# unofficial uptime-kuma-api2 wrapper in its own venv, so nothing lands in the
# system Python. Kuma has no official API for
# adding monitors.
#
#   sudo bash add_monitor_client.sh
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_TICK=0

spin_tick() {
    redraw '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[SPIN_TICK % 10]}" "$1"
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Watch-only spinner: shows the command is alive but never signals it. An apt
# run killed halfway leaves a dpkg lock behind.
show_spinner_watch_only() {
    local message="$1"
    shift
    if [ ! -t 1 ]; then "$@"; return $?; fi

    local log
    log="$(mktemp)"

    if [ "${DEBUG_MODE:-0}" = "1" ]; then
        "$@" 2>&1 | tee "$log"
        local rc=${PIPESTATUS[0]}
        rm -f "$log"
        return "$rc"
    fi

    "$@" >"$log" 2>&1 &
    local cmd_pid=$!
    while kill -0 "$cmd_pid" 2>/dev/null; do
        spin_tick "$message" || break
    done
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    redraw '\r\033[K'

    if [ "$exit_code" -ne 0 ]; then
        print_error "$message failed (exit $exit_code). Last 20 lines:"
        tail -n 20 "$log"
        print_action "Full log: $log"
        return "$exit_code"
    fi

    rm -f "$log"
    return 0
}

export DEBIAN_FRONTEND=noninteractive
VENV=/opt/hosting-monitor/venv
PACKAGE=uptime-kuma-api2

[ "$EUID" -eq 0 ] || { print_error "This needs root: it installs a package."; print_action "sudo bash $0"; exit 2; }

print_header "Uptime Kuma client for the Monitor module"

if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -I -c 'import uptime_kuma_api' 2>/dev/null; then
    print_success "The Kuma client is already in $VENV."
    exit 0
fi

if ! python3 -c 'import ensurepip' 2>/dev/null; then
    print_status "[1/3] python3-venv"
    show_spinner_watch_only "[1/3] Updating package lists" apt-get update -qq || true
    if ! show_spinner_watch_only "[1/3] Installing python3-venv" apt-get install -y -qq python3-venv; then
        print_error "Could not install python3-venv, so the Kuma client cannot be made."
        print_action "Install it by hand: sudo apt-get install -y python3-venv"
        exit 1
    fi
    print_status "Installed python3-venv."
else
    print_info "[1/3] python3-venv is already installed."
fi

print_status "[2/3] venv"
mkdir -p "$(dirname "$VENV")"
python3 -m venv "$VENV"
print_status "Made $VENV."

print_status "[3/3] $PACKAGE"
if ! show_spinner_watch_only "[3/3] Installing $PACKAGE" "$VENV/bin/pip" install -q "$PACKAGE"; then
    print_error "Could not install $PACKAGE from PyPI."
    print_action "Try by hand: sudo $VENV/bin/pip install $PACKAGE"
    exit 1
fi
print_success "Installed $PACKAGE $("$VENV/bin/pip" show "$PACKAGE" 2>/dev/null | sed -n 's/^Version: //p') in $VENV."
