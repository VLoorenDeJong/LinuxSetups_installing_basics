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
# The status publisher.
#
# The hosting manager runs as hosting-manager and is deliberately unable to ask
# systemd whether a unit is up or openssl when a certificate expires. Rather
# than open a path into the app tree for it, a root service writes the answers
# to /run/hosting-status/status.json and the page reads that.
#
# WHY A FILE AND NOT A SERVICE ON 11001
#
# The 11000+ convention exists for privileged halves, and this could have been
# one. A file wins: the page already reads files this way (is_readable then
# file_get_contents), there is no listener to authenticate, and a page load
# never waits on a request. If the writer dies the file simply stops moving,
# and the page can say how old it is, which is the whole point.
#
# WHY /run
#
# tmpfs. Rewritten every few seconds this would be tens of thousands of writes
# a day onto the boot medium. Status from before a reboot is worthless, so
# losing it on reboot is correct rather than a compromise.
#
# NOTHING IS HARDCODED
#
# Units are discovered by glob, certificates by directory, ports from ss. A row
# added tomorrow is covered without touching this script.
#
# Usage:
#   sudo bash add_hosting_status.sh              install it
#   sudo bash add_hosting_status.sh --check      report what would change
# =============================================================================

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

# The busy indicator the rest of the fleet uses, copied exactly. The first
# sweep takes about fifteen seconds, which is long enough to read as a hang.
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPIN_PID=""
spinner_start() {
    [ "${DEBUG_MODE:-0}" = "1" ] && return 0
    local message="$1"
    (
        local i=0
        while true; do
            printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[i % 10]}" "$message"
            i=$((i + 1))
            sleep 0.2
        done
    ) &
    _SPIN_PID=$!
}
spinner_stop() {
    [ -n "$_SPIN_PID" ] || return 0
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf '\r\033[K'
}

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

SERVICE_NAME="hosting-status"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PAYLOAD_SRC=""
PAYLOAD_DST="/usr/local/sbin/hosting_status.sh"
STATUS_DIR="/run/hosting-status"
# Who must be able to read it: the page's own account since item 146, or
# www-data on a machine where add_hosting_manager.sh has not run yet.
PAGE_USER="hosting-manager"
id "$PAGE_USER" >/dev/null 2>&1 || PAGE_USER="www-data"

MODE="apply"
case "${1:-}" in
    --check) MODE="check" ;;
    "")      ;;
    *)
        print_error "Unknown argument: $1"
        print_action "Use --check, or no argument at all."
        exit 1
        ;;
esac

print_header "Status publisher"

# --- Pre-flight: everything that would stop this finishing, before any write --

# --check still needs root: it reads /etc/systemd/system and asks systemctl what
# is enabled, and a report built from what a non-root account happens to see
# would be a report about permissions rather than about the machine.
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script writes a systemd unit, so it needs root."
    echo "   Run: sudo bash $0 ${1:-}"
    exit 1
fi

ERRORS=0

for tool in systemctl ss openssl grep; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print_error "$tool not found, and the checker needs it."
        case "$tool" in
            ss)      echo "   Install it with: apt-get install -y iproute2" ;;
            openssl) echo "   Install it with: apt-get install -y openssl" ;;
            *)       echo "   Install it before running this again." ;;
        esac
        ERRORS=$((ERRORS + 1))
    fi
done

# The payload sits beside this repo's other deployed files. Resolve it from
# this script's own location so the script works from any working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in \
    "$SCRIPT_DIR/../status/hosting_status.sh" \
    "$SCRIPT_DIR/../status/hosting_status.sh"; do
    if [ -r "$candidate" ]; then
        PAYLOAD_SRC="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
        break
    fi
done

if [ -z "$PAYLOAD_SRC" ]; then
    print_error "Cannot find hosting_status.sh to install."
    echo "   Expected it at /etc/hostings/hosting-status/hosting_status.sh"
    echo "   relative to the repository root. Run this from a full checkout."
    ERRORS=$((ERRORS + 1))
fi

if [ -n "$PAYLOAD_SRC" ] && ! bash -n "$PAYLOAD_SRC" 2>/dev/null; then
    print_error "hosting_status.sh does not parse, so it will not be installed."
    echo "   Check it with: bash -n $PAYLOAD_SRC"
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    print_error "$ERRORS problem(s) found. Nothing was written."
    exit 1
fi

# --- The unit, built before it is compared or written ------------------------
#
# In a variable rather than straight into the file, so --check can diff it
# against what is on the machine. A check that only says "the unit exists"
# reports success against a unit written by an older version of this script.

UNIT_TEXT="$(cat <<UNIT
[Unit]
Description=Publish this machine's service status for the hosting manager
After=network.target

[Service]
Type=simple
ExecStart=$PAYLOAD_DST
Restart=always
RestartSec=5
# tmpfs, mode 0755 so www-data may traverse it and read the file inside.
RuntimeDirectory=${SERVICE_NAME}
RuntimeDirectoryMode=0755
Environment=STATUS_DIR=$STATUS_DIR
Environment=UNIT_GLOB=app-*
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
ReadWritePaths=-$STATUS_DIR

[Install]
WantedBy=multi-user.target
UNIT
)"

# --- Report, and stop, when asked to check -----------------------------------

if [ "$MODE" = "check" ]; then
    UNIT_PREVIEW="$(mktemp)"
    trap 'rm -f "$UNIT_PREVIEW"' EXIT
    print_header "What would change"
    # Two counts, because they answer different questions. A fault an apply
    # would not fix must not be summarised as "nothing would change".
    CHANGES=0
    FAULTS=0

    if [ ! -f "$PAYLOAD_DST" ]; then
        print_info "Checker:  would be installed at $PAYLOAD_DST"
        CHANGES=$((CHANGES + 1))
    elif ! cmp -s "$PAYLOAD_SRC" "$PAYLOAD_DST"; then
        print_info "Checker:  $PAYLOAD_DST differs from this checkout and would be replaced"
        echo "   See it with: diff $PAYLOAD_DST $PAYLOAD_SRC"
        CHANGES=$((CHANGES + 1))
    else
        print_success "Checker:  already current"
    fi

    if [ ! -f "$UNIT_FILE" ]; then
        print_info "Unit:     would be written to $UNIT_FILE"
        CHANGES=$((CHANGES + 1))
    elif [ "$UNIT_TEXT" != "$(cat "$UNIT_FILE")" ]; then
        print_info "Unit:     $UNIT_FILE differs and would be rewritten"
        # Shown inline rather than as a command to run: the unit this script
        # would write exists only in this process, so a printed `diff` naming a
        # variable is a command nobody can paste.
        printf '%s\n' "$UNIT_TEXT" > "$UNIT_PREVIEW"
        diff "$UNIT_FILE" "$UNIT_PREVIEW" | sed 's/^/   /'
        CHANGES=$((CHANGES + 1))
    else
        print_success "Unit:     already current"
    fi

    # Enabled and running are two questions. A unit that is enabled but dead
    # still publishes nothing, and the page would show a status file going stale.
    if ! systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        print_info "Service:  not enabled, and would be"
        CHANGES=$((CHANGES + 1))
    elif ! systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        print_info "Service:  enabled but not running, and would be restarted"
        CHANGES=$((CHANGES + 1))
    else
        print_success "Service:  enabled and running"
    fi

    # An apply always restarts, so this is a statement about the machine now,
    # not a change that would be made.
    if [ ! -r "$STATUS_DIR/status.json" ]; then
        print_info "Status:   nothing published at $STATUS_DIR/status.json yet"
    elif ! sudo -u "$PAGE_USER" test -r "$STATUS_DIR/status.json" 2>/dev/null; then
        print_error "Status:   published, but $PAGE_USER CANNOT read it, so the page shows nothing"
        echo "   Check RuntimeDirectoryMode in $UNIT_FILE"
        FAULTS=$((FAULTS + 1))
    else
        STATUS_ERRORS=$(sed -n 's/^  "errors": \[\(..*\)\]$/\1/p' "$STATUS_DIR/status.json")
        if [ -n "$STATUS_ERRORS" ]; then
            print_info "Status:   published and readable, but the collector reported problems:"
            echo "   $STATUS_ERRORS"
            FAULTS=$((FAULTS + 1))
        else
            print_success "Status:   published, readable by $PAGE_USER, no collector errors"
        fi
    fi

    print_header "Done"
    if [ "$CHANGES" -gt 0 ]; then
        print_status "$CHANGES thing(s) would change. --check, so nothing was written."
    else
        print_success "An apply would change nothing."
    fi
    if [ "$FAULTS" -gt 0 ]; then
        print_info "$FAULTS thing(s) above are wrong now, and an apply would not fix them."
    fi
    exit 0
fi

# --- Say what will change, then change it ------------------------------------

print_status "Will install:"
echo "   $PAYLOAD_DST      the checker"
echo "   $UNIT_FILE        the unit"
echo "   $STATUS_DIR/status.json   the published file, on tmpfs"

# WRITTEN BESIDE, THEN MOVED INTO PLACE. `install` truncates and rewrites the
# destination, and bash reads a script LAZILY: the copy already running holds
# an open file handle and keeps reading it by offset. Rewriting underneath it
# makes the running process read whatever now sits at that offset, mid-file.
#
# That is not theoretical. On 2026-08-23 the running checker died with
# "unexpected EOF while looking for matching )" and dumped core, from a syntax
# error in a file that was perfectly valid, because it was reading the new one
# from the old one's position.
#
# `mv` within the same filesystem is a rename: the running process keeps the
# old inode until it exits, and the new one is complete from its first byte.
PAYLOAD_TMP="${PAYLOAD_DST}.new.$$"
install -m 0755 -o root -g root "$PAYLOAD_SRC" "$PAYLOAD_TMP"
mv -f "$PAYLOAD_TMP" "$PAYLOAD_DST"
print_success "Checker installed at $PAYLOAD_DST"

printf '%s\n' "$UNIT_TEXT" > "$UNIT_FILE"
print_success "Unit written to $UNIT_FILE"

systemctl daemon-reload

# Captured, never discarded: the one moment the message is needed is the moment
# it would have been thrown away.
START_LOG="$(mktemp)"
# enable --now is a no-op against a service that is already running, so a
# re-run left the previous checker in memory and the new file unread. restart
# starts a stopped service too, so it covers both cases.
# Captured into a variable, not read from `$?` in the then-branch: `$?` there is
# the status of the negation, so it reported 1 whatever systemctl actually said.
START_RC=0
systemctl enable "${SERVICE_NAME}.service" >"$START_LOG" 2>&1 || START_RC=$?
[ "$START_RC" -eq 0 ] && { systemctl restart "${SERVICE_NAME}.service" >>"$START_LOG" 2>&1 || START_RC=$?; }
if [ "$START_RC" -ne 0 ]; then
    print_error "The service did not start (exit $START_RC)."
    tail -20 "$START_LOG"
    echo "   Full log: $START_LOG"
    echo "   Look at:  systemctl status ${SERVICE_NAME}.service"
    echo "   And at:   journalctl -u ${SERVICE_NAME}.service -n 40"
    exit 1
fi
rm -f "$START_LOG"

# FORTY-FIVE SECONDS, NOT TEN. The first pass probes every unit, vhost and
# certificate on the machine, and measured 2026-08-23 it takes 15 seconds here.
# Ten seconds meant a warning on every single install telling the operator to
# go and read a journal about a service that was working perfectly and simply
# had not finished its first sweep.
#
# A wait that is too short does not report a slow start, it reports a fault.
WAIT_SECONDS=45
spinner_start "Waiting for the first status file, up to ${WAIT_SECONDS}s..."
_waited=0
while [ "$_waited" -lt "$WAIT_SECONDS" ]; do
    [ -r "$STATUS_DIR/status.json" ] && break
    sleep 1
    _waited=$((_waited + 1))
done
spinner_stop
[ -r "$STATUS_DIR/status.json" ] && print_info "First sweep finished in ${_waited}s."

if [ -r "$STATUS_DIR/status.json" ]; then
    print_success "Publishing to $STATUS_DIR/status.json"
    # null is not zero. A collector that could not run must never be reported
    # as a machine with nothing on it.
    if grep -q '"units": null' "$STATUS_DIR/status.json"; then
        print_info "Units: UNKNOWN, the collector could not look"
    else
        print_status "Units seen: $(grep -o '"unit"' "$STATUS_DIR/status.json" | wc -l)"
    fi
    if grep -q '"certificates": null' "$STATUS_DIR/status.json"; then
        print_info "Certificates: UNKNOWN, the collector could not look"
    else
        print_status "Certificates seen: $(grep -o '"days"' "$STATUS_DIR/status.json" | wc -l)"
    fi
    STATUS_ERRORS=$(sed -n 's/^  "errors": \[\(..*\)\]$/\1/p' "$STATUS_DIR/status.json")
    if [ -n "$STATUS_ERRORS" ]; then
        print_info "The collector reported problems:"
        echo "   $STATUS_ERRORS"
    fi
    # The whole point is that the page can read it. A green install and an
    # unreadable file is the failure this catches.
    if sudo -u "$PAGE_USER" test -r "$STATUS_DIR/status.json" 2>/dev/null; then
        print_success "$PAGE_USER can read it, which is what the page needs"
    else
        print_error "$PAGE_USER CANNOT read $STATUS_DIR/status.json"
        echo "   The page will show nothing. Check RuntimeDirectoryMode in $UNIT_FILE"
    fi
else
    print_info "The service is running but has written nothing yet."
    echo "   Look at: journalctl -u ${SERVICE_NAME}.service -n 40"
fi

print_header "Done"
echo "The console reads this file on every tab. Hard-refresh it to see the change."
