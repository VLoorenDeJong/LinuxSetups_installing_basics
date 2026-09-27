#!/usr/bin/env bash
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
# Install operating system updates in their own systemd unit, and follow it.
#
# The machine--update-packages job used to run the update script inside its own
# shell step. An update that upgrades Jenkins restarts Jenkins, which kills that
# step, which killed apt halfway through dpkg. On 2026-09-19 that left forty
# packages half configured, Jenkins among them.
#
# So apt runs in a transient unit that belongs to systemd, not to Jenkins. This
# script only reads the unit's journal. If Jenkins dies, the reader dies and
# the install carries on.
#
# Usage:
#   sudo bash run_updates_detached.sh
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "Run as root: sudo bash $0"
    exit 1
fi

UPDATES="/usr/local/lib/linuxbasics/install_scripts/updates_install_and_clean.sh"

print_header "Operating system updates, detached"

ERRORS=()
[ -f "$UPDATES" ] || ERRORS+=("No update script at $UPDATES. Run add_pipeline_scripts.sh to install the tree.")
command -v systemd-run >/dev/null || ERRORS+=("systemd-run is missing, so the update cannot be detached.")
RUNNING="$(systemctl list-units 'os-updates-*' --state=active,activating --no-legend --plain | awk '{print $1}')"
[ -z "$RUNNING" ] || ERRORS+=("An update is already running: $RUNNING. Follow it with: journalctl -fu $RUNNING")
if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

UNIT="os-updates-$(date +%Y%m%d-%H%M%S)"
systemd-run --quiet --unit="$UNIT" --setenv=DEBIAN_FRONTEND=noninteractive \
    /usr/bin/bash "$UPDATES"
print_status "Started $UNIT"
print_info "If this log stops early, the install is still running. Follow it with: journalctl -fu $UNIT"

journalctl -fu "$UNIT" -o cat &
FOLLOW_PID=$!
trap 'kill "$FOLLOW_PID" 2>/dev/null || true' EXIT

while systemctl is-active --quiet "$UNIT" \
   || [ "$(systemctl show "$UNIT" -p ActiveState --value)" = "activating" ]; do
    sleep 5
done
# The journal lags the unit by a moment; let the last lines arrive.
sleep 2

RESULT="$(systemctl show "$UNIT" -p Result --value)"
STATUS="$(systemctl show "$UNIT" -p ExecMainStatus --value)"
if [ "$RESULT" = "success" ]; then
    print_success "$UNIT finished."
    exit 0
fi
print_error "$UNIT ended with $RESULT, exit $STATUS."
print_action "Read the whole run: journalctl -u $UNIT"
exit 1
