#!/bin/bash
# =============================================================================
# Which rows did the last publish change?
#
# One question, one script. Prints one row name per line, for feeding to
# maintain_services.sh --only-row, so an apply writes the rows that moved
# instead of all sixteen.
#
# THE RECORD IS GIT, NOT A FILE THIS WRITES.
#
# publish_hostings.sh commits hostings.conf on every publish, so the previous
# commit of that file is what the machine was last told. Comparing against it
# needs no state of our own, and a state file is exactly the thing that is
# wrong when a machine has been touched by hand.
#
# WHAT IT REFUSES TO ANSWER
#
# A change to a SETTING rather than a row (ENVS, a port band, a host prefix)
# can move every row at once, so no narrow answer is honest. It prints nothing
# and exits 2, meaning "apply everything". Same for a first commit, a missing
# git, or a file that is not in a repository: every unknown answers "all".
#
# Exit codes are the interface:
#   0   the names printed are the rows that changed
#   2   cannot narrow it, apply everything
#
# Usage:
#   ./changed_rows.sh
#   ./changed_rows.sh --since HEAD~3
# =============================================================================

set -e

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

SINCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since)   SINCE="$2"; shift 2 ;;
        --since=*) SINCE="${1#--since=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [--since REF]" >&2
            exit 1 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
SINCE="${SINCE:-HEAD~1}"

command -v git >/dev/null 2>&1 || exit 2
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || exit 2
git -C "$REPO_ROOT" rev-parse --verify --quiet "$SINCE" >/dev/null 2>&1 || exit 2

REL="${SITES_CONF#$REPO_ROOT/}"
[ "$REL" = "$SITES_CONF" ] && exit 2   # config lives outside the repo

DIFF="$(git -C "$REPO_ROOT" diff --unified=0 "$SINCE" -- "$REL" 2>/dev/null || true)"
[ -z "$DIFF" ] && exit 0               # nothing changed, nothing to apply

# The name is the second field of a row. A changed line that is not a row is a
# setting, and a setting can move every row at once.
row_name() {
    local line="$1" name
    case "$line" in
        *"|"*) ;;
        *) return 1 ;;
    esac
    # A setting holds an = before any pipe: PANEL = id | port | name.
    case "${line%%|*}" in
        *=*) return 1 ;;
    esac
    name="$(printf '%s' "$line" | cut -d'|' -f2 | xargs)"
    [ -z "$name" ] && return 1
    printf '%s\n' "$name"
}

NAMES=()
while IFS= read -r line; do
    case "$line" in
        +++*|---*) continue ;;
        +*|-*) ;;
        *) continue ;;
    esac
    body="${line:1}"
    # A comment-only change moves nothing.
    body="${body%%#*}"
    [ -z "$(printf '%s' "$body" | xargs)" ] && continue

    # A mailbox is not maintain_services' business: it writes no vhost and no
    # unit, and manage_mail.sh acts on it instead. Skip it rather than name it,
    # or the apply is handed a row it cannot find and fails the whole run.
    case "$body" in
        *"|"*)
            _t="$(printf '%s' "${body%%|*}" | xargs)"
            [ "$_t" = "mailbox" ] && continue
            ;;
    esac

    # Two settings do NOT move any row, and saying they might costs a full
    # apply for a one line edit: PANEL is read by add_panel_vhosts.sh alone and
    # PREVIEW_ROWS by add_preview_vhosts.sh alone. Both of those run outside the
    # "no row changed" guard in maintain_services.sh, so reporting no rows still
    # applies them, and the eleven units, fifteen vhosts and nineteen
    # certificates that a PANEL edit cannot possibly affect are left alone.
    #
    # Measured 2026-08-28: adding one machine page rewrote every row on the
    # machine and asked certbot about nineteen names, because a PANEL line is
    # not a row and every non-row was treated as "could move anything".
    case "$(printf '%s' "${body%%=*}" | xargs)" in
        PANEL|PREVIEW_ROWS) continue ;;
    esac

    if ! n="$(row_name "$body")"; then
        # Any other setting. No narrow answer is honest.
        exit 2
    fi
    NAMES+=("$n")
done < <(printf '%s\n' "$DIFF")

[ ${#NAMES[@]} -eq 0 ] && exit 0
printf '%s\n' "${NAMES[@]}" | awk '!seen[$0]++'
exit 0
