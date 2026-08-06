#!/bin/bash
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

# Attaches this machine to an Ubuntu Pro subscription.
#
# The token is NEVER stored in this script. Provide it one of two ways:
#   sudo env PRO_TOKEN=<YOUR_PRO_TOKEN> ./add_ubuntu_pro.sh     (unattended)
#   sudo ./add_ubuntu_pro.sh                                    (prompts on the terminal)
#
# `sudo env VAR=...` is required — a bare `VAR=... sudo ...` is stripped by
# sudo's env_reset and the variable silently never arrives.
#
# Free personal subscriptions cover 5 machines (50 for Ubuntu Members). Get a
# token at https://ubuntu.com/pro/dashboard

export DEBIAN_FRONTEND=noninteractive

print_status() {
    printf "\e[34m🔧 %s\e[0m\n" "$1"
}

print_success() {
    printf "\e[32m✅ %s\e[0m\n" "$1"
}

print_warning() {
    printf "\e[33m⚠️ %s\e[0m\n" "$1"
}

print_error() {
    printf "\e[31m❌ %s\e[0m\n" "$1"
}

if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31mThis script requires sudo privileges to run properly.\e[0m"
    echo -e "\e[33mPlease run with: sudo $0\e[0m"
    exit 1
fi

# Watch-only progress for irreversible package transactions: reports elapsed
# time but never kills the command — a SIGKILL mid-dpkg can corrupt package state
show_progress_watch_only() {
    local message="$1"
    shift
    echo -e "\e[34m${message}\e[0m"
    "$@" &
    local cmd_pid=$!
    while kill -0 "$cmd_pid" 2>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo
    wait "$cmd_pid"
    return $?
}

PRO_LOG="/tmp/add_ubuntu_pro.log"
# The log can contain the token on some failure paths — keep it owner-only
umask 077

# Print a log tail with the token redacted, so a token never lands on screen,
# in a scrollback buffer, or in an orchestrator's captured output.
show_log_tail() {
    local lines="${1:-20}"
    [ -f "$PRO_LOG" ] || return 0
    if [ -n "$PRO_TOKEN" ]; then
        tail -n "$lines" "$PRO_LOG" | sed "s/${PRO_TOKEN//\//\\/}/<REDACTED>/g"
    else
        tail -n "$lines" "$PRO_LOG"
    fi
}

# Ubuntu-only — the Pro client is not packaged for other distributions
if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    print_error "This is not an Ubuntu system — Ubuntu Pro is not available here."
    exit 1
fi

# The client ships on 16.04+ by default, but install it if this image lacks it
if ! command -v pro &> /dev/null; then
    print_status "Ubuntu Pro client not found, installing..."
    # Package-list update is kill-safe/retryable — timeout is fine here
    timeout 180 apt-get update -qq --fix-missing
    # The install is an irreversible dpkg transaction — never run it under a kill timeout
    if ! show_progress_watch_only "📦 Installing ubuntu-pro-client" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ubuntu-pro-client; then
        print_warning "ubuntu-pro-client unavailable, trying legacy ubuntu-advantage-tools..."
        if ! show_progress_watch_only "📦 Installing ubuntu-advantage-tools" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ubuntu-advantage-tools; then
            print_error "Failed to install the Ubuntu Pro client"
            exit 1
        fi
    fi
fi

# Idempotency: an already-attached machine is a success, not an error. Re-running
# `pro attach` on an attached host fails, so bail out early and just report.
if pro status --format=json 2>/dev/null | grep -q '"attached": *true'; then
    print_success "This machine is already attached to an Ubuntu Pro subscription."
    pro status || true
    exit 0
fi

# Resolve the token: environment first, then the controlling terminal.
# Read from /dev/tty rather than stdin so a parent script that already consumed
# or redirected stdin can't silently feed buffered input into this prompt.
if [ -z "$PRO_TOKEN" ]; then
    if [ -e /dev/tty ]; then
        printf "\e[34mPaste your Ubuntu Pro token (input hidden):\e[0m "
        read -r -s PRO_TOKEN < /dev/tty || true
        echo
    fi
fi

if [ -z "$PRO_TOKEN" ]; then
    print_error "No Ubuntu Pro token supplied."
    print_warning "Get one at https://ubuntu.com/pro/dashboard then run:"
    print_warning "  sudo env PRO_TOKEN=<YOUR_PRO_TOKEN> $0"
    exit 1
fi

print_status "Attaching this machine to Ubuntu Pro..."
# Attach is a network + package-source operation; capture everything, discard nothing
if ! show_progress_watch_only "🔗 Contacting Ubuntu Pro" \
    bash -c 'pro attach "$1" >"$2" 2>&1' _ "$PRO_TOKEN" "$PRO_LOG"; then
    print_error "Failed to attach to Ubuntu Pro (see $PRO_LOG) — output:"
    show_log_tail 20
    exit 1
fi

print_success "Attached to Ubuntu Pro."
print_status "Enabled services:"
pro status || true

print_warning "Run 'sudo apt-get update && sudo apt-get upgrade' to pull in ESM updates."
