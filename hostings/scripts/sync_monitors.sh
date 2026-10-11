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
# One uptime monitor per hostname this machine serves, kept in step with
# hostings.conf. Monitors are named "<hostname> <served name>", so a sync only
# ever touches this machine's own.
#
#   hostings.conf → list_served_hostnames.sh → monitor.sh → Uptime Kuma
#
# Until the drive swap public DNS names the live machine, so MONITOR_TARGET_IP
# sends every probe to this machine's LAN address with the hostname as Host
# header. Empty it at the swap and probes go through DNS.
#
#   sudo bash sync_monitors.sh            sync
#   sudo bash sync_monitors.sh --list     print what would be monitored, change nothing
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

MODE=sync
case "${1:-}" in
    "")     ;;
    --list) MODE=list ;;
    -h|--help) sed -n '18,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print_error "Unknown option '$1'"; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
export SITES_CONF

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"; v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

print_header "Uptime monitors"

if [ -z "$(conf_get MONITOR_URL "")" ]; then
    print_info "No MONITOR_URL in $SITES_CONF, so this machine is not monitored."
    exit 0
fi

MACHINE="$(hostname)"
TARGET_IP="$(conf_get MONITOR_TARGET_IP "")"
if [ -n "$TARGET_IP" ] && ! [[ "$TARGET_IP" =~ ^[0-9a-fA-F.:]+$ ]]; then
    print_error "MONITOR_TARGET_IP '$TARGET_IP' is not an IP address."
    exit 1
fi

# --- What should be monitored ------------------------------------------------
if ! hosts="$(bash "$SCRIPT_DIR/list_served_hostnames.sh")"; then
    print_error "list_served_hostnames.sh failed, so the monitor list would be incomplete."
    exit 1
fi

wanted=""
while IFS= read -r h; do
    [ -n "$h" ] || continue
    if [ -n "$TARGET_IP" ]; then
        url="https://$TARGET_IP/"; [[ "$TARGET_IP" == *:* ]] && url="https://[$TARGET_IP]/"
        wanted+="$MACHINE $h"$'\t'"$url"$'\t'"$h"$'\n'
    else
        wanted+="$MACHINE $h"$'\t'"https://$h/"$'\t'$'\n'
    fi
done <<< "$hosts"

count="$(printf '%s' "$wanted" | grep -c . || true)"
if [ -n "$TARGET_IP" ]; then
    print_info "$count hostnames, probed at $TARGET_IP (MONITOR_TARGET_IP) until the drive swap."
else
    print_info "$count hostnames, probed through DNS."
fi

if [ "$MODE" = "list" ]; then
    printf '%s' "$wanted" | awk -F'\t' '{ printf "   %s  →  %s%s\n", $1, $2, ($3 ? "  (Host: " $3 ")" : "") }'
    exit 0
fi

# --- Sync --------------------------------------------------------------------
# shellcheck source=/dev/null
. "$SCRIPT_DIR/monitor.sh"
if [ "$MONITOR_READY" != "1" ]; then
    print_error "The monitor provider could not be loaded."
    exit 1
fi
if ! reasons="$(monitor_preflight)"; then
    print_error "This machine cannot reach its uptime monitor yet:"
    while IFS= read -r line; do [ -n "$line" ] && print_action "  $line"; done <<< "$reasons"
    exit 1
fi

print_status "Syncing monitors named '$MACHINE ...' at $MONITOR_URL"
if ! report="$(printf '%s' "$wanted" | monitor_sync "$MACHINE" 2>&1)"; then
    print_error "Kuma refused the sync:"
    printf '%s\n' "$report" | tail -n 20
    exit 1
fi
printf '%s\n' "$report" | sed 's/^/   /'
print_success "Monitors match $SITES_CONF"
