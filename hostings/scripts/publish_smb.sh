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
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x
# =============================================================================
# Take an edited smb.conf from the console, check it, write it, reload Samba.
#
# The same shape as publish_hostings.sh: the page runs as hosting-manager,
# holds no credential, writes a candidate to a fixed path and calls this
# through sudo with no arguments. CONFIG_SAVE_HOOK records it the same way.
#
# WHY THIS ONE ALSO RELOADS
#
# hostings.conf describes units, vhosts and certificates, so applying it is a
# separate act with a drift report in front of it. smb.conf IS the running
# config: /etc/samba/smb.conf is a symlink to /etc/hostings/smb/smb.conf, so
# saving and reloading are one act.
#
# testparm's EXIT CODE IS NOT A VALIDATION: a share with no path and an
# invented parameter both return 0. Its output is what has to be read.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_hint()    { printf "   %s\n" "$1"; }
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

MANAGER_HOME="/var/lib/hosting-manager"
STAGING="${MANAGER_HOME}/smb.conf.candidate"
BASE_HASH_FILE="${MANAGER_HOME}/smb.candidate.base"
REPORT="${MANAGER_HOME}/last-smb-check.txt"
CONF_DIR="/etc/hostings"
TRACKED="${CONF_DIR}/smb/smb.conf"
LOCK="/var/lock/publish_smb.lock"

blob_hash() {
    { printf 'blob %s\0' "$(stat -c %s "$1")"; cat "$1"; } | sha1sum | cut -d' ' -f1
}

hook() {
    local h
    h="$(sed -n 's/^[[:space:]]*CONFIG_SAVE_HOOK[[:space:]]*=[[:space:]]*//p' "$(conf_active "$CONF_DIR")" 2>/dev/null \
         | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')"
    [ -z "$h" ] || [ "$h" = "-" ] && return 0
    [ -f "$h" ] || { print_error "CONFIG_SAVE_HOOK names $h, which does not exist."; return 1; }
    bash "$h" "$@"
}

clear_staging() {
    for f in "$@"; do
        install -m 600 -o hosting-manager -g hosting-manager /dev/null "$f" 2>/dev/null || rm -f "$f"
    done
}

check_with_testparm() {  # <file> <what>
    local file="$1" what="$2" log rc faults
    log="$(mktemp)"
    set +e
    # No --parameter-name: that prints one value and skips the checks wanted here.
    testparm --suppress-prompt "$file" >"$log" 2>&1
    rc=$?
    set -e
    faults="$(grep -iE 'Unknown parameter|No path in service|^ERROR|Rejecting|Invalid' "$log" || true)"
    {
        echo "Checked $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Command: testparm --suppress-prompt, on $what"
        echo "Result:  $([ "$rc" -eq 0 ] && [ -z "$faults" ] && echo "smb.conf is valid" || echo "FAILED")"
        echo ""
        cat "$log"
    } > "${REPORT}.tmp"
    install -m 0644 -o root -g root "${REPORT}.tmp" "$REPORT"
    rm -f "${REPORT}.tmp"
    if [ "$rc" -ne 0 ] || [ -n "$faults" ]; then
        print_error "smb.conf is not valid, so it was NOT saved."
        print_info "Nothing on the machine changed. What testparm said:"
        if [ -n "$faults" ]; then printf '%s\n' "$faults" | head -n 20; else tail -n 20 "$log"; fi
        print_info "The whole check is in $REPORT"
        rm -f "$log"
        return 1
    fi
    rm -f "$log"
}

exec 9>"$LOCK"
flock -n 9 || { print_error "Another save is already running. Try again in a moment."; exit 1; }

ERRORS=()
command -v testparm >/dev/null 2>&1 || ERRORS+=("testparm is not installed. Install samba-common-bin.")
for t in smbcontrol smbclient; do
    command -v "$t" >/dev/null 2>&1 || ERRORS+=("$t is not installed. Install samba.")
done
[ -s "$STAGING" ] || ERRORS+=("The candidate file is empty, which would remove every share.")
[ -f "$TRACKED" ]  || ERRORS+=("No $TRACKED. Run add_smb.sh first.")
if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Cannot save smb.conf. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

hook pre || { print_error "The config directory could not be refreshed, so nothing was saved."; exit 1; }

SEEN="$(sed -n 1p "$BASE_HASH_FILE" 2>/dev/null || true)"
SAVED_BY="$(sed -n 2p "$BASE_HASH_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9._@-' | cut -c1-64 || true)"
SAVED_BY="${SAVED_BY:-unknown}"
NOW="$(blob_hash "$TRACKED")"

if [ -z "$SEEN" ]; then
    print_error "The page did not say which version it was editing, so nothing was saved."
    print_info "That file is ${BASE_HASH_FILE}, and it must be writable by hosting-manager, the page's account:"
    print_action "  sudo install -m 600 -o hosting-manager -g hosting-manager /dev/null ${BASE_HASH_FILE}"
    clear_staging "$STAGING"
    exit 1
fi
if [ "$SEEN" != "$NOW" ]; then
    print_error "smb.conf changed while the page was open, so nothing was saved."
    print_action "Reload the hosting manager and make the edit again."
    clear_staging "$STAGING" "$BASE_HASH_FILE"
    exit 1
fi

CANDIDATE="$(mktemp)"
trap 'rm -f "$CANDIDATE"' EXIT
tr -d '\r' < "$STAGING" > "$CANDIDATE"

if cmp -s "$CANDIDATE" "$TRACKED"; then
    print_success "No change: smb.conf already matches what was submitted."
    hook post "$SAVED_BY" "Edit smb.conf from the hosting manager" \
        || print_error "Recording the saved smb.conf still fails."
    clear_staging "$STAGING"
    exit 0
fi

check_with_testparm "$CANDIDATE" "the config being saved" || { clear_staging "$STAGING"; exit 1; }

cp -p "$TRACKED" "$TRACKED.previous"
cat "$CANDIDATE" > "$TRACKED"
print_success "Saved $TRACKED (the previous one is smb.conf.previous)."

RECORD_FAILED=0
hook post "$SAVED_BY" "Edit smb.conf from the hosting manager" || RECORD_FAILED=1
clear_staging "$STAGING" "$BASE_HASH_FILE"

# Reload, then read back what Samba serves rather than trusting the broadcast.
if ! systemctl is-active --quiet smbd; then
    print_error "smbd is not running, so there was nothing to reload."
    print_info "The saved config is in place and will be read when it starts."
    print_action "  sudo systemctl status smbd"
    exit 1
fi
RELOAD_LOG="$(mktemp)"
if ! smbcontrol all reload-config >"$RELOAD_LOG" 2>&1; then
    print_error "smbcontrol failed, so the new config is not in use."
    tail -n 10 "$RELOAD_LOG"
    rm -f "$RELOAD_LOG"
    exit 1
fi
rm -f "$RELOAD_LOG"

SHARES="$(smbclient -L localhost -N 2>/dev/null | awk '$2 == "Disk" {print $1}' | tr '\n' ' ')"
if [ -z "$SHARES" ]; then
    print_error "Samba reloaded but lists no shares, which is not what was saved."
    print_action "  sudo systemctl status smbd && sudo testparm $TRACKED"
    exit 1
fi
print_success "Samba reloaded. It now serves: $SHARES"

# Serving and being findable are two things: Windows browses with
# WS-Discovery, which Samba does not speak. add_wsdd.sh answers those probes
# and is idempotent, so running it on every save is free after the first.
WSDD=""
for candidate in "$SCRIPT_DIR/add_wsdd.sh" "$SCRIPT_DIR/../../install_scripts/add_wsdd.sh"; do
    [ -x "$candidate" ] && { WSDD="$candidate"; break; }
done
if [ -n "$WSDD" ]; then
    "$WSDD" || print_action "Discovery setup failed. Shares still work: sudo $WSDD --status"
else
    print_info "add_wsdd.sh was not found, so discovery was not set up."
    print_hint "without it the shares work but the machine is invisible under Network."
fi

if [ "$RECORD_FAILED" = 1 ]; then
    print_error "smb.conf is saved and in use, but recording it failed. Save again to retry."
    exit 1
fi
