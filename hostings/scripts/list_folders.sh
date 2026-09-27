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
# List the folders directly inside one directory, as JSON.
#
# For the console's folder picker. The page runs as hosting-manager and cannot read
# /home or /srv, so it cannot browse for a folder itself.
#
# WHY THIS TAKES AN ARGUMENT WHEN NOTHING ELSE HERE DOES
#
# A picker is a walk, so the path has to come from the caller. That is the whole
# risk, and it is answered by an allow list rather than by trusting the input:
#
#   - the path must be inside one of ROOTS, checked AFTER resolving symlinks,
#     so ../.. and a planted link both land outside and are refused
#   - it lists directory NAMES only, never file contents, never file names
#   - it never follows a symlink out of the tree: -maxdepth 1 -type d and the
#     resolved path are what it reports
#
# So the worst a caller can learn is which folders exist under the roots below.
# Those are the places the thing being picked can point at, which is the entire
# point.
#
# TWO ROOT SETS, BECAUSE TWO THINGS ARE PICKED
#
#   (default)     where a Samba share may live: data folders and homes
#   --for pages   where a machine page's files may live
#
# They are separate because a share pointing into /usr/share is a mistake, and a
# machine page pointing into a home is a different one. Roundcube is installed
# at /var/lib/roundcube by its package, so a picker that cannot reach /var/lib
# cannot be used to add webmail, which is the whole reason a picker is offered.
# =============================================================================

print_error() { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    exit 1
fi

FOR="share"
if [ "${1:-}" = "--for" ]; then
    FOR="${2:-share}"
    shift 2
fi

case "$FOR" in
    pages)
        # Where a machine page's files may live. A packaged web application
        # lands in /usr/share and keeps its writable half in /var/lib, which is
        # exactly where Roundcube is; /opt is where an unpackaged one goes.
        # No homes: a machine page served out of somebody's home directory is
        # not a thing this repo wants to make easy.
        ROOTS=(/var/www /srv /var/lib /usr/share /opt)
        REFUSAL="outside the folders a machine page may use"
        ;;
    *)
        # Where a share may live. Anything outside these is refused rather than
        # listed.
        ROOTS=(/srv /var/www /mnt /media)
        REFUSAL="outside the folders a share may use"
        # The deploy account's home, so backup_files and the repo clone can be
        # reached. Resolved from what is there, never hardcoded.
        for h in /home/*; do
            [ -d "$h" ] && ROOTS+=("$h")
        done
        ;;
esac

TARGET="${1:-}"

# The roots go in every answer, not only the first. The picker needs them to
# know where "up" stops: without them, one press above /home/admin lands on
# /home, which is outside the allow list, and the list goes blank with no way
# back except closing the drawer.
roots_json() {
    local sep="" r out=""
    for r in "${ROOTS[@]}"; do
        [ -d "$r" ] || continue
        out="${out}${sep}\"${r}\""
        sep=","
    done
    printf '%s' "$out"
}

if [ -z "$TARGET" ]; then
    # No argument: the roots themselves, which is where a picker starts.
    printf '{"path":"","roots":[%s],"dirs":[%s]}\n' "$(roots_json)" "$(roots_json)"
    exit 0
fi

# Resolved first. A path is judged by where it ends up, never by how it is
# spelled: /srv/../etc spells like /srv and is not.
RESOLVED="$(readlink -f -- "$TARGET" 2>/dev/null || true)"

if [ -z "$RESOLVED" ] || [ ! -d "$RESOLVED" ]; then
    printf '{"error":"no such folder","roots":[%s]}\n' "$(roots_json)"
    exit 0
fi

allowed=no
for r in "${ROOTS[@]}"; do
    case "$RESOLVED" in
        "$r"|"$r"/*) allowed=yes; break ;;
    esac
done

if [ "$allowed" != "yes" ]; then
    printf '{"error":"%s","roots":[%s]}\n' "$REFUSAL" "$(roots_json)"
    exit 0
fi

# -maxdepth 1 -type d: the folders immediately inside, and nothing about files.
esc_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

printf '{"path":"%s","roots":[%s],"dirs":[' "$(esc_json "$RESOLVED")" "$(roots_json)"
sep=""
while IFS= read -r d; do
    [ "$d" = "$RESOLVED" ] && continue
    # Hidden folders are noise in a picker, and .ssh is worse than noise.
    case "$(basename -- "$d")" in .*) continue ;; esac
    printf '%s"%s"' "$sep" "$(esc_json "$d")"
    sep=","
done < <(find "$RESOLVED" -maxdepth 1 -type d 2>/dev/null | sort)
printf ']}\n'
