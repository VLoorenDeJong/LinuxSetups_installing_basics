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
# Give a share's group read, write and execute on its folder.
#
#   set_share_access.sh --check <path> <group>
#   set_share_access.sh --set   <path> <group> <rwx> [--recursive]
#
# <rwx> is three characters, each r/w/x or -, for example "r-x".
#
# WHAT IT WILL NOT DO, AND WHY
#
# 1. IT NEVER TOUCHES "other". A share is reached through its force user, so
#    group access is the mechanism that works. World access is a different
#    decision with a much larger blast radius, and it is not on offer here.
#
# 2. IT REFUSES A FOLDER OWNED BY A SYSTEM ACCOUNT. vmail, _rspamd, postfix and
#    the rest set their modes themselves, on purpose. On 2026-08-26 a share was
#    pointed at the Dovecot mail store, whose 0700 also protects the DKIM
#    SIGNING KEYS: loosening it would have handed anyone on the LAN the ability
#    to send mail as this machine's domains. A web page must not be able to
#    override that, however the button is labelled.
#
# 3. IT STAYS INSIDE THE FOLDERS A SHARE MAY USE, resolved with readlink -f, so
#    ../.. and a planted symlink both land outside and are refused.
#
# 4. IT CHANGES THE FOLDER, NOT ITS CONTENTS. No -R. Recursing would rewrite
#    modes somebody set deliberately on files this script has never seen.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning".
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    exit 1
fi

MODE="${1:-}"
TARGET="${2:-}"
GROUP="${3:-}"
WANT="${4:-}"
RECURSE=no
[ "${5:-}" = "--recursive" ] && RECURSE=yes
RECURSED_CHANGED=0
RECURSED_SKIPPED=0

# Where a share may live. The same list list_folders.sh uses, and for the same
# reason: these are the only places a share can point at.
ROOTS=(/srv /var/www /mnt /media)
for h in /home/*; do
    [ -d "$h" ] && ROOTS+=("$h")
done

# Accounts whose folders are theirs to set. A service that runs as one of these
# chose its own modes; this script is not the place to argue with that.
SYSTEM_OWNERS="vmail _rspamd postfix dovecot mysql postgres redis systemd-resolve
systemd-network messagebus syslog landscape tss uuidd _apt nobody"

json_out() { printf '%s\n' "$1"; }

if [ "$MODE" != "--check" ] && [ "$MODE" != "--set" ]; then
    print_error "Usage: $0 --check <path> <group> | --set <path> <group> <rwx>"
    exit 1
fi

if [ -z "$TARGET" ] || [ -z "$GROUP" ]; then
    json_out '{"error":"a folder and a group are both needed"}'
    exit 0
fi

RESOLVED="$(readlink -f -- "$TARGET" 2>/dev/null || true)"

if [ -z "$RESOLVED" ] || [ ! -d "$RESOLVED" ]; then
    json_out '{"error":"no such folder"}'
    exit 0
fi

allowed=no
for r in "${ROOTS[@]}"; do
    case "$RESOLVED" in
        "$r"|"$r"/*) allowed=yes; break ;;
    esac
done

if [ "$allowed" != "yes" ]; then
    json_out '{"error":"outside the folders a share may use"}'
    exit 0
fi

OWNER="$(stat -c %U "$RESOLVED")"
NOW_GROUP="$(stat -c %G "$RESOLVED")"
NOW_MODE="$(stat -c %a "$RESOLVED")"

# Rule 2. Reported rather than silently ignored: the page has to be able to say
# WHY the boxes are not on offer.
protected=no
for s in $SYSTEM_OWNERS; do
    [ "$OWNER" = "$s" ] && { protected=yes; break; }
done

# The three group bits, as r/w/x or -, read off the current mode.
group_rwx() {
    local perms
    perms="$(stat -c %A "$RESOLVED")"
    printf '%s' "${perms:4:3}" | tr 's' 'x'
}

if [ "$protected" = "yes" ]; then
    json_out "{\"path\":\"$RESOLVED\",\"owner\":\"$OWNER\",\"group\":\"$NOW_GROUP\",\"mode\":\"$NOW_MODE\",\"rwx\":\"$(group_rwx)\",\"protected\":true}"
    exit 0
fi

if [ "$MODE" = "--check" ]; then
    json_out "{\"path\":\"$RESOLVED\",\"owner\":\"$OWNER\",\"group\":\"$NOW_GROUP\",\"mode\":\"$NOW_MODE\",\"rwx\":\"$(group_rwx)\",\"protected\":false}"
    exit 0
fi

# --- from here it writes -----------------------------------------------------

if ! getent group "$GROUP" >/dev/null 2>&1; then
    json_out '{"error":"no such group"}'
    exit 0
fi

case "$WANT" in
    [r-][w-][x-]) : ;;
    *) json_out '{"error":"permissions must be three characters, each r/w/x or -"}'; exit 0 ;;
esac

print_header "Folder access for a share"
print_status "Folder: $RESOLVED"
print_status "Owner:  $OWNER"
print_status "Group:  $NOW_GROUP -> $GROUP"
print_status "Mode:   $NOW_MODE, group bits $(group_rwx) -> $WANT"

if [ "$NOW_GROUP" != "$GROUP" ]; then
    chgrp "$GROUP" "$RESOLVED"
    print_success "Group is now $GROUP."
fi

# Built from the three characters, so the owner's and other's bits are left
# exactly as they were. g=... rather than g+...: unticking a box has to remove
# the access, or the boxes only ever go one way.
BITS=""
case "$WANT" in *r*) BITS="${BITS}r" ;; esac
case "$WANT" in *w*) BITS="${BITS}w" ;; esac
case "$WANT" in *x*) BITS="${BITS}x" ;; esac

# =============================================================================
# And everything inside it
#
# Off unless --recursive is passed, because recursing rewrites modes somebody
# may have set deliberately on files this script has never seen.
#
# Three things it does differently from a plain chmod -R:
#
#   g=rwX, capital X, so a FILE only gets execute if it already had it
#   somewhere. A blanket g=rwx would make every document executable.
#
#   -xdev, so a mount point inside the folder is not walked into. A share of
#   /mnt should not rewrite whatever is mounted under it.
#
#   entries owned by a system account are skipped, one by one, not just at the
#   top. A folder can perfectly well contain something vmail or postfix owns.
# =============================================================================
recurse_access() {
    local root="$1" group="$2" want="$3"
    local bits_dir="" changed=0 skipped=0 owner

    case "$want" in *r*) bits_dir="${bits_dir}r" ;; esac
    case "$want" in *w*) bits_dir="${bits_dir}w" ;; esac
    # Capital X: directories always, files only where execute already exists.
    case "$want" in *x*) bits_dir="${bits_dir}X" ;; esac

    while IFS= read -r -d '' entry; do
        [ "$entry" = "$root" ] && continue
        owner="$(stat -c %U "$entry" 2>/dev/null || echo '')"
        [ -z "$owner" ] && continue

        local is_system=no
        for s in $SYSTEM_OWNERS; do
            [ "$owner" = "$s" ] && { is_system=yes; break; }
        done
        if [ "$is_system" = "yes" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        chgrp "$group" "$entry" 2>/dev/null || true
        chmod "g=${bits_dir}" "$entry" 2>/dev/null || true
        changed=$((changed + 1))
    done < <(find "$root" -xdev \! -type l -print0 2>/dev/null)

    print_success "Inside it: $changed changed, $skipped left alone."
    if [ "$skipped" -gt 0 ]; then
        print_info "Skipped entries belong to a system account and set their own permissions."
    fi
    RECURSED_CHANGED="$changed"
    RECURSED_SKIPPED="$skipped"
}

chmod "g=${BITS}" "$RESOLVED"

AFTER="$(stat -c %a "$RESOLVED")"
print_success "Mode is now $AFTER, group $(group_rwx)."

if [ "$RECURSE" = "yes" ]; then
    print_status "And everything inside it..."
    recurse_access "$RESOLVED" "$GROUP" "$WANT"
fi

# A folder without x on the group cannot be entered, so read alone lists
# nothing. Said here rather than left to be discovered from Windows.
case "$WANT" in
    *x*) : ;;
    *)   print_action "Without execute, the group cannot enter the folder, so a share of it will be empty." ;;
esac

json_out "{\"path\":\"$RESOLVED\",\"owner\":\"$OWNER\",\"group\":\"$GROUP\",\"mode\":\"$AFTER\",\"rwx\":\"$(group_rwx)\",\"protected\":false,\"recursed\":$RECURSED_CHANGED,\"skipped\":$RECURSED_SKIPPED}"
