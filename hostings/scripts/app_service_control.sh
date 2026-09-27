#!/usr/bin/env bash
set -e

. "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }

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
# A trace prints the secrets this reads, so only a caller who could read them
# anyway gets one: root, or the sudo group. The console passes -d via a * grant.
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# Start, stop or restart one app row's unit, for the console.
#
#   app_service_control.sh <row> <env> start|stop|restart|log
#
# The page runs as hosting-manager and cannot talk to systemd, so root does it and
# what root will do is bounded here rather than by the page.
#
# WHAT IS BOUNDED, and it is the security of the arrangement:
#
#   - three verbs. Nothing that edits, masks, enables or disables a unit, so a
#     compromised page cannot make a change that survives a reboot;
#   - the row must be an `app` row in the PUBLISHED config, and the environment
#     must be one the config names. The unit name is BUILT here from those two,
#     never taken from the caller, so no other unit on this machine is
#     reachable through it;
#   - the unit file must already exist. This starts what the installer made; it
#     does not create anything.
#
# Stopping live is allowed on purpose. The console is LAN only and behind a
# login, and an operator who can reach it is an operator who could ssh in.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

# Yellow means "this needs you", never "warning".
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }

usage() {
    echo "Usage:"
    echo "  $0 <row> <env> start|stop|restart|log"
}

ROW="${1:-}"
ENV_NAME="${2:-}"
VERB="${3:-}"

if [ -z "$ROW" ] || [ -z "$ENV_NAME" ] || [ -z "$VERB" ]; then
    usage
    exit 1
fi

case "$VERB" in
    # log is READ ONLY and changes nothing. It is here rather than in a script
    # of its own because the unit name is built and bounded here already: a
    # separate reader would have to repeat that, and a second place to get it
    # wrong is how a page reaches a unit it does not own.
    start|stop|restart|log) ;;
    *) print_error "'$VERB' is not one of start, stop, restart or log."; exit 1 ;;
esac

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 $*"
    exit 1
fi

# Fixed paths. Nothing here is taken from the caller.
MANAGER_HOME="/var/lib/hosting-manager"
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "No config at $SITES_CONF, so the row could not be checked."
    exit 1
fi

conf_value() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$SITES_CONF" | tail -n 1
}

conf_has_key() {
    grep -qE "^[[:space:]]*$1[[:space:]]*=" "$SITES_CONF"
}

# Checked against the published config, which is the copy that decides what
# this machine serves. A row name that is not there cannot name a unit.
if ! awk -F'|' -v n="$ROW" '
        /^[[:space:]]*#/ { next }
        NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
                 gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                 if ($1 == "app" && $2 == n) found = 1 }
        END { exit !found }' "$SITES_CONF"; then
    print_error "'$ROW' is not an app row in the published config."
    exit 1
fi

# The environment has to be one the config names, and its suffix comes from the
# config too. An environment with no suffix key is one this machine does not
# have, whatever the caller believes.
SUFFIX_KEY="$(printf '%s' "$ENV_NAME" | tr '[:lower:]' '[:upper:]')_UNIT_SUFFIX"
case "$SUFFIX_KEY" in
    *[!A-Z0-9_]*) print_error "'$ENV_NAME' is not an environment name."; exit 1 ;;
esac
if ! conf_has_key "$SUFFIX_KEY"; then
    print_error "'$ENV_NAME' is not an environment in the published config."
    exit 1
fi

UNIT="app-${ROW}$(conf_value "$SUFFIX_KEY").service"

# The log, and nothing else. Printed raw rather than through print_*, because
# the page shows it as the journal wrote it. --no-pager and a line count, so a
# unit that has been restarting for a day cannot fill the page.
if [ "$VERB" = "log" ]; then
    if [ ! -f "/etc/systemd/system/${UNIT}" ]; then
        echo "There is no ${UNIT} on this machine yet. It is written by the first deploy."
        exit 0
    fi
    journalctl -u "$UNIT" -n "${LOG_LINES:-200}" --no-pager --output=short-iso 2>&1
    exit 0
fi

if [ ! -f "/etc/systemd/system/${UNIT}" ]; then
    print_error "There is no ${UNIT} on this machine, so nothing was ${VERB}ed."
    print_action "Deploy ${ROW} in ${ENV_NAME} first: the unit is written by the deploy."
    exit 1
fi

# A unit whose working directory is not there has never been deployed. Trying
# anyway costs four restarts and twenty lines of journal to say so, which is
# what it did before this check existed.
if [ "$VERB" != "stop" ]; then
    WORKDIR="$(systemctl show -p WorkingDirectory --value "$UNIT" 2>/dev/null || true)"
    if [ -n "$WORKDIR" ] && [ ! -d "$WORKDIR" ]; then
        print_error "Nothing is deployed for ${ROW} in ${ENV_NAME}, so there is nothing to ${VERB}."
        print_status "Its working directory does not exist: $WORKDIR"
        print_action "Build it first: the deploy-${ENV_NAME} job in the ${ROW} folder in Jenkins."
        exit 1
    fi
fi

print_status "systemctl ${VERB} ${UNIT}"

if ! systemctl "$VERB" "$UNIT"; then
    print_error "systemctl ${VERB} failed for ${UNIT}."
    systemctl status "$UNIT" --no-pager --lines=15 || true
    exit 1
fi

STATE="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
print_success "${UNIT} is now ${STATE:-unknown}."

# The page reads a file the status service rewrites every five seconds, so a
# redirect that lands first shows the state from before the button was pressed.
# Waiting here for the file to agree is what makes the row change on the reload
# rather than on the next one.
STATUS_FILE="${STATUS_FILE:-/run/hosting-status/status.json}"
waited=0
while [ "$waited" -lt 8 ]; do
    [ -r "$STATUS_FILE" ] || break
    grep -q "\"unit\":\"${UNIT}\",\"active\":\"${STATE}\"" "$STATUS_FILE" && break
    sleep 1
    waited=$(( waited + 1 ))
done

# A stop is meant to look stopped, so only a start or a restart is judged.
if [ "$VERB" != "stop" ] && [ "$STATE" != "active" ]; then
    print_error "It did not stay running. The last of its journal:"
    journalctl -u "$UNIT" --no-pager --lines=20 || true
    exit 1
fi
