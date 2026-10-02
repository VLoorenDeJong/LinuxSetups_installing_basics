#!/usr/bin/env bash
set -e
# -d / --debug: trace every command. Stripped from "$@" so it never reaches the
# script's own argument parsing.
# A trace prints the secrets this reads, so only a caller who could read them
# anyway gets one: root, or the sudo group. The console passes -d via a * grant.
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
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x
# =============================================================================
# Take an edited hostings.conf from the console, check it, and write it.
#
#   sudo publish_hostings.sh             save the staged candidate
#   sudo publish_hostings.sh --refresh   bring the config up to date, nothing else
#   sudo publish_hostings.sh --go-live   write the live file from the test pair
#
# This is the privileged half of the console's Save. The page runs as
# hosting-manager and holds no credential: it writes a candidate to a fixed
# path and calls this through sudo. The paths are fixed so sudoers can name a
# literal command with nothing for a caller to smuggle in.
#
# NO GIT IN HERE. Where the config is kept is the machine's business, so
# CONFIG_SAVE_HOOK in the config may name a script, run as root:
#
#   <hook> pre               before anything is compared: bring the config
#                            directory up to date. Failing stops the save.
#   <hook> post <who> <why>  after the file is written: record it, for example
#                            commit and push. Failing is reported; the file
#                            stays written, and the previous one is kept.
#
# No hook: the file on disk is the config, and <file>.previous is the undo.
#
# WHAT IT REFUSES
#
# A candidate built on a file that has moved since the page loaded it (the
# page sends the hash of what it was shown; no hash is a refusal, not a pass),
# and a candidate maintain_services.sh --check rejects. So a typo in a browser
# never reaches the file the machine is built from.
#
# Saving changes nothing on the machine: applying is a separate act, after the
# operator has read the drift report.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || { print_error "config.sh not found beside $0."; exit 1; }

# Installed alone in /usr/local/sbin, so the checker comes from the pipeline tree.
MAINTAIN="$SCRIPT_DIR/maintain_services.sh"
[ -f "$MAINTAIN" ] || MAINTAIN="/usr/local/lib/linuxbasics/hostings/scripts/maintain_services.sh"

# Fixed paths. Nothing here is taken from the caller.
MANAGER_HOME="/var/lib/hosting-manager"
STAGING="${MANAGER_HOME}/hostings.conf.candidate"
BASE_HASH_FILE="${MANAGER_HOME}/candidate.base"
REPORT="${MANAGER_HOME}/last-check.txt"
CHECKED_MARK="${MANAGER_HOME}/checked.sha1"
CONF_DIR="/etc/hostings"
LOCK="/var/lock/publish_hostings.lock"

MODE="save"
case "${1:-}" in
    --refresh) MODE="refresh" ;;
    --go-live) MODE="go-live" ;;
    "") ;;
    *) print_error "Unknown argument '$1'"; exit 1 ;;
esac

# The same hash git gives a file, so the page can compute it without git.
blob_hash() {
    { printf 'blob %s\0' "$(stat -c %s "$1")"; cat "$1"; } | sha1sum | cut -d' ' -f1
}

hook() {
    local h
    h="$(sed -n 's/^[[:space:]]*CONFIG_SAVE_HOOK[[:space:]]*=[[:space:]]*//p' "$(conf_active "$CONF_DIR")" 2>/dev/null \
         | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')"
    [ -z "$h" ] || [ "$h" = "-" ] && return 0
    if [ ! -f "$h" ]; then
        print_error "CONFIG_SAVE_HOOK names $h, which does not exist."
        return 1
    fi
    bash "$h" "$@"
}

# Emptied, never deleted. The directory is 0755 root, so the page can write
# these files but cannot CREATE them: removing one turns every save after the
# first into "Could not write ...".
clear_staging() {
    for f in "$@"; do
        install -m 600 -o hosting-manager -g hosting-manager /dev/null "$f" 2>/dev/null || rm -f "$f"
    done
}

# Written through rather than replaced, so the file keeps its owner and mode.
write_conf() {  # <candidate> <target>
    [ -f "$2" ] && cp -p "$2" "$2.previous"
    cat "$1" > "$2"
}

# maintain_services.sh --check on a candidate, placed beside the file it would
# replace so anything the check reads relative to the config still resolves.
validate() {  # <candidate> <target>
    local probe log rc
    probe="$(dirname "$2")/.candidate-check.$$.conf"
    log="$(mktemp)"
    cp "$1" "$probe"
    set +e
    SITES_CONF="$probe" bash "$MAINTAIN" --check >"$log" 2>&1
    rc=$?
    set -e
    rm -f "$probe"
    {
        echo "Checked $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Command: maintain_services.sh --check, on the config being saved"
        echo "Result:  $([ "$rc" -eq 0 ] && echo "config is valid" || echo "FAILED, exit $rc")"
        echo ""
        sed 's/\x1b\[[0-9;]*m//g' "$log"
    } > "${REPORT}.tmp"
    install -m 0644 -o root -g root "${REPORT}.tmp" "$REPORT"
    rm -f "${REPORT}.tmp"
    if [ "$rc" -ne 0 ]; then
        print_error "The new config is not valid, so it was NOT saved."
        print_info "Nothing on the machine changed. What the check said:"
        sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E '^❌|^⚠️' | head -n 20
        rm -f "$log"
        return 1
    fi
    rm -f "$log"
    print_success "Config is valid."
}

exec 9>"$LOCK"
if ! flock -n 9; then
    print_error "Another save is already running. Try again in a moment."
    exit 1
fi

if [ ! -d "$CONF_DIR" ]; then
    print_error "No config directory at $CONF_DIR, so nothing was saved."
    print_action "Run install_hostings.sh first."
    exit 1
fi

# =============================================================================
# --refresh: the hook's pre step and nothing else
# =============================================================================
if [ "$MODE" = "refresh" ]; then
    if hook pre; then
        print_success "Config directory up to date."
        exit 0
    fi
    print_error "The config directory could not be refreshed."
    exit 1
fi

# =============================================================================
# --go-live: the live file, from the test pair
# =============================================================================
if [ "$MODE" = "go-live" ]; then
    hook pre || { print_error "The config directory could not be refreshed. Nothing went live."; exit 1; }
    LIVE_FILE="$CONF_DIR/hostings.conf"
    NEW="$(mktemp)"
    if ! conf_golive "$CONF_DIR" > "$NEW"; then
        rm -f "$NEW"
        print_error "Refused: hostings.conf already holds a live config, or there is no test file."
        exit 1
    fi
    if ! validate "$NEW" "$LIVE_FILE"; then
        rm -f "$NEW"
        exit 1
    fi
    write_conf "$NEW" "$LIVE_FILE"
    rm -f "$NEW"
    if ! hook post "go_live.sh" "Go live: hostings.conf becomes the live config"; then
        print_error "hostings.conf is written, but recording it failed. The previous one is $LIVE_FILE.previous."
        exit 1
    fi
    print_success "hostings.conf is the live config now."
    exit 0
fi

# =============================================================================
# Save
# =============================================================================
if [ ! -s "$STAGING" ]; then
    print_error "The candidate file is empty, which would delete every site."
    exit 1
fi

if ! hook pre; then
    print_error "The config directory could not be refreshed, so nothing was saved."
    exit 1
fi

# The file in force after the refresh: MACHINE_IS_LIVE may have just changed.
CONF_FILE="$(conf_active "$CONF_DIR")"

# Line one is the hash the page was shown, line two who pressed Save.
SEEN="$(sed -n 1p "$BASE_HASH_FILE" 2>/dev/null || true)"
SAVED_BY="$(sed -n 2p "$BASE_HASH_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9._@-' | cut -c1-64 || true)"
SAVED_BY="${SAVED_BY:-unknown}"
NOW="$(blob_hash "$CONF_FILE")"

if [ -z "$SEEN" ]; then
    print_error "The page did not say which version it was editing, so nothing was saved."
    print_info "That file is ${BASE_HASH_FILE}, and it must be writable by hosting-manager, the page's account:"
    print_action "  sudo install -m 600 -o hosting-manager -g hosting-manager /dev/null ${BASE_HASH_FILE}"
    print_info "Nothing was lost: the config is untouched."
    clear_staging "$STAGING"
    exit 1
fi

if [ "$SEEN" != "$NOW" ]; then
    print_error "The config changed while the page was open, so nothing was saved."
    print_action "Reload the hosting manager and make the edit again."
    print_info "Nothing was lost: the config is untouched."
    clear_staging "$STAGING" "$BASE_HASH_FILE"
    exit 1
fi

CANDIDATE="$(mktemp)"
trap 'rm -f "$CANDIDATE"' EXIT
tr -d '\r' < "$STAGING" > "$CANDIDATE"
CANDIDATE_SHA="$(sha1sum "$CANDIDATE" | cut -d' ' -f1)"

# The candidate file is shared by every request. Another save may have staged
# its own edit while this one ran, and emptying that loses it silently.
clear_staging_if_ours() {
    if [ "$(tr -d '\r' < "$STAGING" 2>/dev/null | sha1sum | cut -d' ' -f1)" = "$CANDIDATE_SHA" ]; then
        clear_staging "$@"
    else
        print_info "A newer edit was staged while this one saved. It was left in place."
    fi
}

# Exit 3, not 0: the page must not report "saved" for a press that saved nothing.
# The hook still runs: a save whose recording failed is retried by saving again,
# and the hook must treat "nothing new to record" as success.
if cmp -s "$CANDIDATE" "$CONF_FILE"; then
    print_success "No change: the config already matches what was submitted."
    hook post "$SAVED_BY" "Edit $(basename "$CONF_FILE") from the hosting manager" \
        || print_error "Recording the saved config still fails."
    clear_staging_if_ours "$STAGING"
    exit 3
fi

# check_hostings.sh leaves the sha1 of the bytes it found valid, and the page
# runs it on exactly these bytes first, so the check is not repeated.
if [ "$(cat "$CHECKED_MARK" 2>/dev/null || true)" = "$CANDIDATE_SHA" ]; then
    print_success "Already checked: these exact bytes passed, so the check was not repeated."
else
    print_status "Validating the new config..."
    validate "$CANDIDATE" "$CONF_FILE" || exit 1
fi
rm -f "$CHECKED_MARK"

write_conf "$CANDIDATE" "$CONF_FILE"
print_success "Saved $CONF_FILE (the previous one is $(basename "$CONF_FILE").previous)."

if ! hook post "$SAVED_BY" "Edit $(basename "$CONF_FILE") from the hosting manager"; then
    print_error "The config is saved on this machine, but recording it failed."
    print_action "Fix the cause, then press Save again: that retries the recording."
    clear_staging_if_ours "$STAGING" "$BASE_HASH_FILE"
    exit 1
fi
clear_staging_if_ours "$STAGING" "$BASE_HASH_FILE"

print_success "Nothing on the machine has changed yet."
print_status "Read the report, then press Apply."
