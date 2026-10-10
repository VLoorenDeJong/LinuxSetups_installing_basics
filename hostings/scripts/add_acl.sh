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
# Installs acl (setfacl, getfacl), which the Shared folders module needs: the
# console's share unlock button opens and closes folders with ACLs, and a
# minimal image ships without them.
#
#   sudo bash add_acl.sh
# =============================================================================

# --- Inline utility functions (always defined, no sourcing required) ---
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
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

[ "$EUID" -eq 0 ] || { print_error "This needs root: it installs a package."; print_action "sudo bash $0"; exit 2; }

print_header "ACL tools for the shared folders"

if command -v setfacl >/dev/null 2>&1; then
    print_success "acl is already installed."
    exit 0
fi

print_status "[1/2] Package lists"
show_spinner_watch_only "[1/2] Updating package lists" apt-get update -qq || true
print_status "[2/2] acl"
if show_spinner_watch_only "[2/2] Installing acl" apt-get install -y -qq acl; then
    print_success "Installed acl."
else
    print_error "Could not install acl, so the share unlock button will refuse."
    print_action "Install it by hand: sudo apt-get install -y acl"
    exit 1
fi
