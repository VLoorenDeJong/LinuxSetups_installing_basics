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
# A trace prints the secrets this reads, so only a caller who could read them
# anyway gets one: root, or the sudo group. The console passes -d via a * grant.
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# Run maintain_services.sh --check against the published config, and leave the
# result where the hosting manager can read it.
#
# The page cannot run this itself: --check reads /etc, systemd and certbot. So
# it calls this through sudo with no arguments, exactly like the publisher, and
# reads the report out of a file afterwards.
#
# WHAT IT CHECKS
#
# The candidate the page staged, when there is one, so an edit can be validated
# BEFORE it is committed and pushed. Otherwise the config in the clone, which is
# what the branch holds and therefore what Jenkins would apply.
#
# Either way it is only ever read: --check never writes, and the candidate is
# handed to maintain_services.sh as SITES_CONF rather than copied over anything.
#
# IT CHANGES NOTHING. --check is read-only, which is what makes it safe to hand
# to a page behind a login.
#
# The report keeps a timestamp because a drift report from three weeks ago looks
# exactly like one from an hour ago.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

# --- Inline utility functions (always defined, no sourcing required) ---
print_status() {
    printf "\033[34m🔧 %s\033[0m\n" "$1"
}

print_success() {
    printf "\033[32m✅ %s\033[0m\n" "$1"
}

print_warning() {
    printf "\033[33m⚠️ %s\033[0m\n" "$1"
}

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

# Fixed paths. Nothing here is taken from the caller.
MANAGER_HOME="/var/lib/hosting-manager"
CLONE="${MANAGER_HOME}/config-repo"
REPORT="${MANAGER_HOME}/last-check.txt"
LOCK="/var/lock/check_hostings.lock"

print_header "Check the published config"

if [ ! -d "$CLONE/.git" ]; then
    print_error "No clone at $CLONE. Run add_hosting_manager.sh first."
    exit 1
fi

# One at a time. Two checks racing write the same report file and the loser's
# half ends up interleaved with the winner's.
exec 9>"$LOCK"
if ! flock -n 9; then
    print_error "A check is already running. Try again in a moment."
    exit 1
fi

RAW="$(mktemp)"
STARTED="$(date '+%Y-%m-%d %H:%M:%S %Z')"

STAGING="${MANAGER_HOME}/hostings.conf.candidate"
. "/usr/local/lib/linuxbasics/hostings/scripts/config.sh" 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
PUBLISHED="$(conf_active "/etc/hostings")"
# A candidate that matches the branch file is not an edit, so it is not reported
# as one.
if [ -s "$STAGING" ] && ! cmp -s "$STAGING" "$PUBLISHED"; then
    TARGET="$STAGING"
    SUBJECT="your unsaved changes"
else
    TARGET="$PUBLISHED"
    SUBJECT="the published config"
fi
print_status "Checking $SUBJECT"

set +e
SITES_CONF="$TARGET" \
    bash "/usr/local/lib/linuxbasics/hostings/scripts/maintain_services.sh" --check >"$RAW" 2>&1
RC=$?
set -e

# Colour codes are for a terminal. The page renders this as text.
{
    echo "Checked ${STARTED}, against ${SUBJECT}"
    echo "Command: maintain_services.sh --check"
    echo "Result:  $([ "$RC" -eq 0 ] && echo "config is valid" || echo "FAILED, exit $RC")"
    echo ""
    sed 's/\x1b\[[0-9;]*m//g' "$RAW"
} > "${REPORT}.tmp"

# 0644: the page reads it, and nothing in it is secret. It is the same text the
# operator would see running the command by hand.
install -m 0644 -o root -g root "${REPORT}.tmp" "$REPORT"
rm -f "${REPORT}.tmp" "$RAW"

cat "$REPORT"

# What passed, so publish_hostings.sh does not check the same bytes again. The
# whole check is 4.5s and a save used to run it three times: here, in the
# publisher, and in the Jenkins job. Written only on success, and removed on
# failure, so a missing or stale marker means "check it yourself".
#
# It records the CONFIG, not the machine: this says these bytes were found valid,
# never that the machine is still as it was.
CHECKED_MARK="${MANAGER_HOME}/checked.sha1"
if [ "$RC" -eq 0 ]; then
    sha1sum "$TARGET" | cut -d' ' -f1 > "${CHECKED_MARK}.tmp"
    install -m 0644 -o root -g root "${CHECKED_MARK}.tmp" "$CHECKED_MARK"
    rm -f "${CHECKED_MARK}.tmp"
else
    rm -f "$CHECKED_MARK"
fi

if [ "$RC" -ne 0 ]; then
    print_error "The check failed. The report above says why."
    exit 1
fi

print_success "Report written to $REPORT"
