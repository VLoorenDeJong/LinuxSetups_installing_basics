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
# Runs on the machine with Uptime Kuma and PULLS what to watch from git:
#
#   git remote (the config repository) → git fetch → <branch>:<config> → list_served_hostnames.sh
#        → probe each hostname → Kuma on this machine (monitor.sh)
#
# One MONITOR_SOURCE line per watched config, in this machine's hostings.conf:
#
#   MONITOR_SOURCE = <label> | <branch> | <path to the config> | <LAN IP or ->
#
# Monitors are named "<label> <hostname>"; a source only touches its own. The
# IP probes that machine directly with the hostname as Host header: until a
# drive swap DNS names another machine. "-" probes through DNS.
#
# A NEW HOSTNAME IS ADDED ONLY ONCE IT ANSWERS (any HTTP code below 500). A row
# saved but not applied yet would otherwise page the phone for a site that was
# never meant to exist yet. A hostname gone from the config is removed at once.
#
#   sudo bash sync_monitors.sh             sync now
#   sudo bash sync_monitors.sh --list      what would be watched, change nothing
#   sudo bash sync_monitors.sh --install   a timer that syncs every 5 minutes
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

MODE=sync
case "${1:-}" in
    "")        ;;
    --list)    MODE=list ;;
    --install) MODE=install ;;
    -h|--help) sed -n '18,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print_error "Unknown option '$1'"; exit 2 ;;
esac

[ "$EUID" -eq 0 ] || { print_error "This needs root: it reads Kuma's admin login."; print_action "sudo bash $0 $*"; exit 2; }

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
trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }

print_header "Uptime monitors"

if [ -z "$(conf_get MONITOR_URL "")" ]; then
    print_info "No MONITOR_URL in $SITES_CONF, so this machine runs no monitor sync."
    exit 0
fi

# --- Timer -------------------------------------------------------------------
if [ "$MODE" = "install" ]; then
    cat > /etc/systemd/system/monitor-sync.service <<UNIT
[Unit]
Description=Sync Uptime Kuma's monitors with the watched hostings configs
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_DIR/sync_monitors.sh
UNIT
    cat > /etc/systemd/system/monitor-sync.timer <<'UNIT'
[Unit]
Description=Sync Uptime Kuma's monitors every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    if systemctl enable --now monitor-sync.timer >/dev/null 2>&1; then
        print_success "monitor-sync.timer syncs every 5 minutes, from $SCRIPT_DIR."
    else
        print_error "Could not start monitor-sync.timer."
        print_action "See why: systemctl status monitor-sync.timer"
        exit 1
    fi
    exit 0
fi

# --- Pre-flight: every source line, and the repository ------------------------
mapfile -t SOURCES < <(sed -n 's/^[[:space:]]*MONITOR_SOURCE[[:space:]]*=//p' "$SITES_CONF" | sed 's/#.*//; s/\r//')
ERRORS=()
[ ${#SOURCES[@]} -gt 0 ] || ERRORS+=("No MONITOR_SOURCE line in $SITES_CONF: nothing to watch.")
declare -A SEEN=()
for s in "${SOURCES[@]}"; do
    IFS='|' read -r label branch path ip _extra <<< "$s"
    label="$(trim "$label")"; branch="$(trim "$branch")"; path="$(trim "$path")"; ip="$(trim "$ip")"
    [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || ERRORS+=("MONITOR_SOURCE '$s': label must be letters, digits, . _ or -.")
    [ -n "$branch" ] && [ -n "$path" ] || ERRORS+=("MONITOR_SOURCE '$s': needs a branch and a config path.")
    [ "$ip" = "-" ] || [ -z "$ip" ] || [[ "$ip" =~ ^[0-9a-fA-F.:]+$ ]] || ERRORS+=("MONITOR_SOURCE '$s': '$ip' is not an IP address or -.")
    [ -z "${SEEN[$label]:-}" ] || ERRORS+=("MONITOR_SOURCE label '$label' is used twice.")
    SEEN[$label]=1
done

# A checkout whose origin holds the watched branches.
REPO="$(conf_get MONITOR_REPO "")"
[ -n "$REPO" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || ERRORS+=("MONITOR_REPO in $SITES_CONF names no git checkout of the config repository.")

if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

# Fetched as the checkout's owner: the GitHub credential is theirs, not root's.
OWNER="$(stat -c %U "$REPO")"
print_status "Fetching from GitHub into $REPO, as $OWNER"
if ! fetch_out="$(sudo -u "$OWNER" git -C "$REPO" fetch -q origin 2>&1)"; then
    print_error "git fetch failed, so the monitors stay as they are:"
    printf '%s\n' "$fetch_out" | tail -n 5
    exit 1
fi

# --- Per source: hostnames, probe, sync ----------------------------------------
if [ "$MODE" = "sync" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/monitor.sh"
    [ "$MONITOR_READY" = "1" ] || { print_error "The monitor provider could not be loaded."; exit 1; }
    if ! reasons="$(monitor_preflight)"; then
        print_error "Kuma cannot be synced yet:"
        while IFS= read -r line; do [ -n "$line" ] && print_action "  $line"; done <<< "$reasons"
        exit 1
    fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

for s in "${SOURCES[@]}"; do
    IFS='|' read -r label branch path ip _extra <<< "$s"
    label="$(trim "$label")"; branch="$(trim "$branch")"; path="$(trim "$path")"; ip="$(trim "$ip")"
    [ "$ip" = "-" ] && ip=""
    echo ""
    print_status "$label: $branch:$path"

    conf="$WORK/$label.conf"
    if ! git -C "$REPO" show "origin/$branch:$path" > "$conf" 2>/dev/null; then
        print_error "$label: origin/$branch has no $path. Its monitors are left alone."
        FAILED=1; continue
    fi
    if ! hosts="$(SITES_CONF="$conf" bash "$SCRIPT_DIR/list_served_hostnames.sh" 2>"$WORK/err")"; then
        print_error "$label: the hostname list failed, so its monitors are left alone:"
        tail -n 5 "$WORK/err"
        FAILED=1; continue
    fi

    wanted=""
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        if [ -n "$ip" ]; then
            url="https://$ip/"; [[ "$ip" == *:* ]] && url="https://[$ip]/"
            code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$h:443:$ip" "https://$h/" 2>/dev/null || true)"
            hdr="$h"
        else
            url="https://$h/"
            code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/" 2>/dev/null || true)"
            hdr=""
        fi
        answers=0; [ "${code:-000}" != "000" ] && [ "$code" -lt 500 ] && answers=1
        wanted+="$label $h"$'\t'"$url"$'\t'"$hdr"$'\t'"$answers"$'\n'
    done <<< "$hosts"

    if [ "$MODE" = "list" ]; then
        printf '%s' "$wanted" | awk -F'\t' '{ printf "   %-50s %s%s\n", $1, ($4 == "1" ? "answers" : "no answer yet"), ($3 ? "  via " $2 : "") }'
        continue
    fi
    if ! report="$(printf '%s' "$wanted" | monitor_sync "$label" 2>&1)"; then
        print_error "$label: Kuma refused the sync:"
        printf '%s\n' "$report" | tail -n 20
        FAILED=1; continue
    fi
    printf '%s\n' "$report" | sed 's/^/   /'
done

echo ""
[ "$FAILED" -eq 0 ] || exit 1
[ "$MODE" = "list" ] || print_success "Monitors match every MONITOR_SOURCE."
