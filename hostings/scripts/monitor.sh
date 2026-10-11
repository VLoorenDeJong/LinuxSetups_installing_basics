#!/usr/bin/env bash
# =============================================================================
# The uptime monitor, in verbs. The interface; the provider is a config value.
#
#   . "$SCRIPT_DIR/monitor.sh"
#   monitor_sync <prefix>     makes the monitors named "<prefix> ..." match the
#                             `name<TAB>url<TAB>host_header<TAB>answers` lines
#                             on stdin: adds, updates, deletes. A monitor that
#                             does not exist yet is only added when answers is
#                             1, so a site saved but not applied raises no
#                             alarm. Prints a drift report. Monitors without
#                             the prefix are never touched
#   monitor_states            name<TAB>up|down|pending|maintenance, read-only
#   monitor_preflight         0 if this provider can work, or one reason per
#                             line and 1
#
# NO CALLER NAMES A PROVIDER. `MONITOR_PROVIDER` in hostings.conf names the
# service file, as DNS_PROVIDER does for dns.sh (principle 2b).
#
# MONITORING IS OPTIONAL. With no MONITOR_URL the provider is not loaded and
# MONITOR_READY stays 0: a machine without a monitor is a normal machine.
# =============================================================================

print_error()  { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
print_action() { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }

MONITOR_READY=0
MONITOR_PROVIDER_FILE=""

_mon_conf_get() {
    local v
    [ -n "${SITES_CONF:-}" ] || { printf '%s' "$2"; return 0; }
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"; v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

MONITOR_REQUIRED_VERBS="monitor_sync monitor_states monitor_preflight"

_mon_load() {
    local dir name cand
    MONITOR_URL="${MONITOR_URL:-$(_mon_conf_get MONITOR_URL "")}"
    [ -n "$MONITOR_URL" ] || return 0
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    name="${MONITOR_PROVIDER:-$(_mon_conf_get MONITOR_PROVIDER monitor_provider_uptimekuma.sh)}"
    # Sourced as root from a value the console can write: a bare file name only.
    if ! [[ "$name" =~ ^monitor_provider_[a-z0-9_]+\.sh$ ]]; then
        print_error "MONITOR_PROVIDER '$name' is not a monitor_provider_<name>.sh file name."
        return 1
    fi
    for cand in "$dir/$name" "/usr/local/lib/linuxbasics/hostings/scripts/$name"; do
        [ -f "$cand" ] && { MONITOR_PROVIDER_FILE="$cand"; break; }
    done
    if [ -z "$MONITOR_PROVIDER_FILE" ]; then
        print_error "No monitor provider file called '$name' beside monitor.sh."
        return 1
    fi
    # shellcheck source=/dev/null
    . "$MONITOR_PROVIDER_FILE" || { print_error "$MONITOR_PROVIDER_FILE could not be sourced."; return 1; }
    local v missing=""
    for v in $MONITOR_REQUIRED_VERBS; do
        declare -F "$v" >/dev/null 2>&1 || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
        print_error "$MONITOR_PROVIDER_FILE does not provide:$missing"
        return 1
    fi
    MONITOR_READY=1
}

_mon_load || print_action "Carrying on without the uptime monitor."
