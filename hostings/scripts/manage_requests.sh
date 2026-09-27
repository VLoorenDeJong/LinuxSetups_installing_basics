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
# What a customer has asked for, and what was said back. Item 106.
#
# A limited admin's Add button does not write a row. It files one of these, and
# a full access admin approves or declines it with a reason. The reason is the
# point: a bare yes or no makes somebody ask again rather than understand.
#
#   manage_requests.sh --list                    every request, as JSON
#   manage_requests.sh --add <who> <<< '<json>'  file one, the row on stdin
#   manage_requests.sh --get <id>                one request
#   manage_requests.sh --approve <id> <who> [reason]
#   manage_requests.sh --decline <id> <who> <reason>
#   manage_requests.sh --seen <id> <who>         the requester read the answer
#
# ONE FILE PER REQUEST, under /var/lib/hosting-manager/requests. The owner,
# 2026-09-10, choosing it over a block in hostings.conf, and the reason is the
# whole design: an unapproved row must never reach the config, because
# everything on this machine reads that file and one missed filter would serve
# it for real. A directory nothing else reads cannot do that.
#
# A DECLINED REQUEST IS KEPT, with its reason. The owner's answer the same
# evening: the requester sees why, and the same thing is not filed three times.
#
# NO PORT IS EVER STORED. The requester never sees a port field, so there is
# nothing to reserve and nothing to collide: the port is assigned when the row
# is written, from the rows that exist by then.
#
# THIS SCRIPT DOES NOT WRITE ROWS. --approve marks the request approved and
# prints the row it holds; the console publishes it through the same path every
# other save takes, so an approved request is checked by check_config.sh like
# anything else. A script that could write a row AND approve it would be two
# ways to change the config.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

usage() {
    echo "Usage: $0 --list" >&2
    echo "       $0 --add <who>              the row as JSON on stdin" >&2
    echo "       $0 --get <id>" >&2
    echo "       $0 --approve <id> <who> [reason]" >&2
    echo "       $0 --decline <id> <who> <reason>" >&2
    echo "       $0 --withdraw <id> <who>" >&2
    echo "       $0 --seen <id> <who>" >&2
    exit 1
}

MODE="${1:-}"
[ -z "$MODE" ] && usage

if [ "$EUID" -ne 0 ]; then
    print_error "This reads and writes under /var/lib/hosting-manager, so it needs root."
    print_action "Run with: sudo $0 $MODE"
    exit 1
fi

REQ_DIR="${REQ_DIR:-/var/lib/hosting-manager/requests}"

# Created here rather than by the installer: this script is the only thing that
# reads or writes the directory, so it owns it.
mkdir -p "$REQ_DIR"
chown root:www-data "$REQ_DIR" 2>/dev/null || true
chmod 0750 "$REQ_DIR"

# A name that becomes a filename and a JSON value, checked before either.
valid_name() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

req_file() { printf '%s/%s.json' "$REQ_DIR" "$1"; }

# Who to tell, and it is a separate script so that "no mail arrived" can be
# reproduced on its own. Best effort by design: the request is already written
# when this runs, and a mail server that is down must never make a decline look
# like it did not happen.
NOTIFIER="${NOTIFIER:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/notify_request.sh}"

notify() {
    [ -x "$NOTIFIER" ] || {
        print_info "No notifier at $NOTIFIER, so nobody was mailed."
        return 0
    }
    "$NOTIFIER" "$1" "$2" || true
}

# -----------------------------------------------------------------------------
# --list: every request, newest first, as one JSON object.
#
# python3 rather than a shell loop over jq: jq is not installed here and the
# page wants one object, not a stream. The same choice manage_auth_users.sh
# made for the same reason.
# -----------------------------------------------------------------------------
if [ "$MODE" = "--list" ]; then
    python3 - "$REQ_DIR" <<'PY' 2>/dev/null || echo '{"requests":[],"pending":0}'
import json, os, sys

d = sys.argv[1]
out = []
try:
    names = os.listdir(d)
except OSError:
    print(json.dumps({"requests": [], "pending": 0}))
    sys.exit(0)

for n in names:
    if not n.endswith(".json"):
        continue
    try:
        with open(os.path.join(d, n), "r", encoding="utf-8") as fh:
            r = json.load(fh)
    except (OSError, ValueError):
        # A half-written or hand-edited file is reported rather than skipped:
        # a request that silently vanishes is worse than one that shows as
        # broken, because the person waiting for it has no way to tell.
        out.append({"id": n[:-5], "state": "unreadable", "filed": 0})
        continue
    r.setdefault("id", n[:-5])
    out.append(r)

out.sort(key=lambda r: r.get("filed", 0), reverse=True)
print(json.dumps({
    "requests": out,
    "pending": sum(1 for r in out if r.get("state") == "pending"),
}))
PY
    exit 0
fi

case "$MODE" in
    --add)
        WHO="${2:-}"
        valid_name "$WHO" || { print_error "'$WHO' is not a username."; exit 1; }
        # The row arrives on stdin as JSON. It is NOT parsed here: this script
        # stores what was asked for and the console validates it, once, on the
        # way in and again at approval through check_config.sh.
        ROW="$(cat)"
        [ -z "$ROW" ] && { print_error "Nothing was asked for."; exit 1; }
        # Seconds plus the pid, so two requests filed in the same second by two
        # A SECOND REQUEST ON A ROW REPLACES THE FIRST. The owner, 2026-09-10.
        #
        # The old one is marked superseded rather than deleted: replacing was
        # his call and its only real cost was that a half-written answer would
        # vanish with no trace. Keeping the file removes that and changes
        # nothing else.
        #
        # Matched on the row NAME, which is what a request is about. A request
        # with no name is an add for a row that does not exist yet, and two of
        # those are two different things rather than a replacement.
        ROW_NAME="$(printf '%s' "$ROW" | python3 -c 'import json,sys
try:
    r = json.load(sys.stdin)
    print(str((r.get("row") or r).get("name", "")).strip())
except Exception:
    print("")' 2>/dev/null || true)"
        if [ -n "$ROW_NAME" ]; then
            python3 - "$REQ_DIR" "$WHO" "$ROW_NAME" <<'PY' 2>/dev/null || true
import json, os, sys, time
d, who, name = sys.argv[1], sys.argv[2], sys.argv[3]
for n in os.listdir(d):
    if not n.endswith(".json"):
        continue
    p = os.path.join(d, n)
    try:
        with open(p, "r", encoding="utf-8") as fh:
            r = json.load(fh)
    except (OSError, ValueError):
        continue
    if r.get("state") != "pending" or r.get("by") != who:
        continue
    if str((r.get("row") or {}).get("name", "")).strip() != name:
        continue
    r["state"] = "superseded"
    r["answered"] = int(time.time())
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(r, fh)
PY
        fi
        # people cannot land on one filename.
        ID="$(date +%Y%m%d-%H%M%S)-$$"
        python3 - "$(req_file "$ID")" "$ID" "$WHO" <<PY || { print_error "That is not a request."; exit 1; }
import json, sys, time
path, rid, who = sys.argv[1], sys.argv[2], sys.argv[3]
raw = """$ROW"""
try:
    row = json.loads(raw)
except ValueError:
    sys.exit(1)
if not isinstance(row, dict):
    sys.exit(1)
# The port is dropped rather than trusted: the requester has no port field, so
# anything arriving in one came from somewhere it should not have.
row.pop("port", None)
# The OWNER is forced to whoever filed it, never taken from what was sent. A
# request naming somebody else as the owner would be a way to hand a row to an
# account, or to take one, through the one path that writes rows for customers.
row["owner"] = who
json.dump({
    "id": rid, "by": who, "filed": int(time.time()),
    "state": "pending", "row": row,
    "comment": row.get("comment", ""),
    "answer": "", "answered_by": "", "answered": 0, "seen": 0,
}, open(path, "w", encoding="utf-8"))
PY
        chown root:www-data "$(req_file "$ID")" 2>/dev/null || true
        chmod 0640 "$(req_file "$ID")"
        print_success "Filed request $ID for '$WHO'."
        notify "$ID" filed
        # LAST, after the notification: --add's contract is that its final line
        # is the id, and the console reads it.
        echo "$ID"
        exit 0
        ;;

    --get)
        ID="${2:-}"
        valid_name "$ID" || { print_error "'$ID' is not a request."; exit 1; }
        [ -f "$(req_file "$ID")" ] || { print_error "No request $ID."; exit 1; }
        cat "$(req_file "$ID")"
        exit 0
        ;;

    --approve|--decline)
        ID="${2:-}"
        WHO="${3:-}"
        REASON="${4:-}"
        valid_name "$ID"  || { print_error "'$ID' is not a request."; exit 1; }
        valid_name "$WHO" || { print_error "'$WHO' is not a username."; exit 1; }
        [ -f "$(req_file "$ID")" ] || { print_error "No request $ID."; exit 1; }
        # A decline with no reason is the thing this whole feature exists to
        # prevent: the requester learns no, and nothing else.
        if [ "$MODE" = "--decline" ] && [ -z "$REASON" ]; then
            print_error "A decline needs a reason."
            print_info "The reason is what the requester reads. Without it they only learn no."
            exit 1
        fi
        STATE="approved"; [ "$MODE" = "--decline" ] && STATE="declined"
        if ! python3 - "$(req_file "$ID")" "$STATE" "$WHO" "$REASON" <<'PY'
import json, sys, time
path, state, who, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, "r", encoding="utf-8") as fh:
    r = json.load(fh)
# Answering an answered request would overwrite somebody else's decision and
# the reason they gave for it.
if r.get("state") != "pending":
    sys.stderr.write("already " + str(r.get("state")) + "\n")
    sys.exit(1)
r["state"] = state
r["answer"] = reason
r["answered_by"] = who
r["answered"] = int(time.time())
r["seen"] = 0
with open(path, "w", encoding="utf-8") as fh:
    json.dump(r, fh)
PY
        then
            print_error "Could not answer $ID: it may already have been answered."
            exit 1
        fi
        print_success "Request $ID is $STATE."
        # BEFORE the row is printed, never after: --approve's contract is that
        # its LAST line is the row, and the console reads exactly that line.
        notify "$ID" answered
        # The row it holds, so the caller can publish it. Printed rather than
        # written: see the header.
        python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["row"]))' \
            "$(req_file "$ID")" 2>/dev/null || true
        exit 0
        ;;

    --withdraw)
        # Taking back something you asked for, before it is answered. Only the
        # person who filed it, and only while it is still pending: withdrawing
        # an approved request would undo a decision somebody already made.
        ID="${2:-}"
        WHO="${3:-}"
        valid_name "$ID"  || { print_error "'$ID' is not a request."; exit 1; }
        valid_name "$WHO" || { print_error "'$WHO' is not a username."; exit 1; }
        [ -f "$(req_file "$ID")" ] || { print_error "No request $ID."; exit 1; }
        if ! python3 - "$(req_file "$ID")" "$WHO" <<'PY'
import json, sys, time
path, who = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    r = json.load(fh)
if r.get("by") != who or r.get("state") != "pending":
    sys.exit(1)
r["state"] = "withdrawn"
r["answered"] = int(time.time())
r["seen"] = int(time.time())
with open(path, "w", encoding="utf-8") as fh:
    json.dump(r, fh)
PY
        then
            print_error "$ID is not yours to withdraw, or it has been answered."
            exit 1
        fi
        print_success "Withdrew $ID."
        exit 0
        ;;

    --seen)
        ID="${2:-}"
        WHO="${3:-}"
        valid_name "$ID"  || { print_error "'$ID' is not a request."; exit 1; }
        valid_name "$WHO" || { print_error "'$WHO' is not a username."; exit 1; }
        [ -f "$(req_file "$ID")" ] || { print_error "No request $ID."; exit 1; }
        # Only the person who filed it can mark it read. Anybody else doing so
        # would clear the one thing telling them there is an answer waiting.
        if ! python3 - "$(req_file "$ID")" "$WHO" <<'PY'
import json, sys, time
path, who = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    r = json.load(fh)
if r.get("by") != who:
    sys.exit(1)
r["seen"] = int(time.time())
with open(path, "w", encoding="utf-8") as fh:
    json.dump(r, fh)
PY
        then
            print_error "That is not yours to mark read."
            exit 1
        fi
        print_success "Marked $ID read."
        exit 0
        ;;

    *)
        print_error "'$MODE' is not something this script does."
        usage
        ;;
esac
