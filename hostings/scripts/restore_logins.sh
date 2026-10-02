#!/usr/bin/env bash
set -o pipefail

# =============================================================================
# Put the login files back from the secret store, on a fresh drive.
# login-store-decisions.md, decision 3.
#
#   sudo bash restore_logins.sh                  every file whose reader exists
#   sudo bash restore_logins.sh --only <name>    one file. Run it with a name
#                                                that is not in the list to be
#                                                told every name that is
#   sudo bash restore_logins.sh --overwrite      replace a local copy that
#                                                differs from the vault's
#
# A missing or empty file is filled from the vault. A local file that differs
# is KEPT and reported, because it may hold a change the vault never got;
# --overwrite takes the vault's copy instead.
#
# A file whose owner or group does not exist yet is skipped: dovecot-users
# waits for Dovecot, and add_dovecot.sh calls this with --only dovecot-users
# once it is installed.
#
# git-push-key is the one entry not owned by root. It is the key for the FIRST
# clone, so on a fresh drive it is fetched BEFORE this script can run, by
# LinuxBasics/install_scripts/add_first_clone_key.sh. Here it is the repair
# path and the proof that the vault's copy and the drive's agree.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

# The busy indicator. Kill-safe work only: every vault read is bounded.
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

# A killed run leaves no half-written file beside a login file.
tmp=""
trap 'spinner_stop; [ -n "$tmp" ] && rm -f "$tmp"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
export SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
STATE_DIR="/var/lib/hostings-login-store"

ONLY=""
OVERWRITE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --only)      [ $# -ge 2 ] || { print_error "--only needs a name."; exit 1; }
                     ONLY="$2"; shift 2 ;;
        --overwrite) OVERWRITE=1; shift ;;
        *) print_error "Unknown argument '$1'."; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "The login files and the store token are root-only."
    print_action "Run: sudo bash $0"
    exit 1
fi

conf_get() {
    local key="$1" def="$2" v
    v="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
         | head -1 | cut -d= -f2-)"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "${v:-$def}"
}

# name in the store | path on the machine | owner:group | mode.
# Copied from store_logins.sh; the two lists must agree.
LOGIN_FILES=(
    "htpasswd-progress|$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)|root:www-data|0640"
    "htpasswd-progress.meta|$(conf_get AUTH_USER_META /etc/apache2/.htpasswd-progress.meta)|root:www-data|0640"
    "dovecot-users|/etc/dovecot/users|root:dovecot|0640"
    # Root-only, and 0600 rather than 0640: no group reads these, and the
    # backup passwords existed NOWHERE but this drive until 2026-09-20, so
    # losing it lost the ability to read the backups it had made.
    "session-crypto-key|$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)|root:root|0600"
    "docker-backup-password|$(conf_get DOCKER_BACKUP_PASSWORD_FILE /root/.docker_backup_password)|root:root|0600"
    "mail-backup-password|$(conf_get MAIL_BACKUP_PASSWORD_FILE /root/.mail_backup_password)|root:root|0600"
)

# The ONLY entry not owned by root: git reads it as the account that clones.
# It is here so a fresh drive can fetch it before that clone, with
# add_first_clone_key.sh in LinuxBasics. No GIT_PUSH_USER, no entry.
GIT_PUSH_USER="$(conf_get GIT_PUSH_USER "")"
if [ -n "$GIT_PUSH_USER" ]; then
    LOGIN_FILES+=("git-push-key|$(conf_get GIT_PUSH_KEY "/home/$GIT_PUSH_USER/.ssh/id_ed25519")|$GIT_PUSH_USER:$GIT_PUSH_USER|0600")
fi

# DKIM signing keys, one per domain: a reflash restores the key whose public
# half DNS already publishes, instead of making a new one.
DKIM_DIR="$(conf_get MAIL_DKIM_DIR /var/lib/rspamd/dkim)"
DKIM_SEL="$(conf_get MAIL_DKIM_SELECTOR mail)"
for k in "$DKIM_DIR"/*."$DKIM_SEL".key; do
    [ -f "$k" ] || continue
    LOGIN_FILES+=("dkim-$(basename "$k" ".$DKIM_SEL.key")|$k|_rspamd:_rspamd|0600")
done
# add_rspamd.sh asks for one by name before the key exists on this drive.
case "$ONLY" in
    dkim-*) printf '%s\n' "${LOGIN_FILES[@]}" | grep -q "^${ONLY}|" \
                || LOGIN_FILES+=("$ONLY|$DKIM_DIR/${ONLY#dkim-}.$DKIM_SEL.key|_rspamd:_rspamd|0600") ;;
esac

if [ -n "$ONLY" ] && ! printf '%s\n' "${LOGIN_FILES[@]}" | grep -q "^${ONLY}|"; then
    print_error "'$ONLY' is not a login file. It is one of: $(printf '%s\n' "${LOGIN_FILES[@]}" | cut -d'|' -f1 | paste -sd, - | sed 's/,/, /g')."
    exit 1
fi

print_header "Login files from the secret store"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/secret_store.sh" || exit 1
if ! reasons="$(secret_preflight)"; then
    print_error "The secret store cannot be used, so nothing was restored:"
    printf '   %s\n' "$reasons"
    exit 1
fi

# 0711 and a 0644 status: the console reads the status, nobody lists the rest.
umask 077
install -d -m 0711 "$STATE_DIR"
sha() { sha256sum "$1" | cut -d' ' -f1; }

FAILED=0
for entry in "${LOGIN_FILES[@]}"; do
    IFS='|' read -r name path owner_group mode <<< "$entry"
    mode="${mode:-0640}"
    [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue

    owner="${owner_group%%:*}"
    group="${owner_group##*:}"
    if ! getent group "$group" >/dev/null; then
        print_info "$name: group $group does not exist yet, so its reader is not installed. Skipped."
        continue
    fi
    if ! getent passwd "$owner" >/dev/null; then
        print_info "$name: user $owner does not exist yet, so its owner is not installed. Skipped."
        continue
    fi

    # Only for an entry owned by a person: their .ssh may not exist yet on a
    # fresh drive, and nothing else creates it. NEVER for a root-owned entry,
    # because creating /etc/apache2 as 0700 here would make Apache unable to
    # traverse to its own htpasswd file, with nothing in the config to say why.
    if [ "$owner" != "root" ] && [ ! -d "$(dirname "$path")" ]; then
        install -d -m 0700 -o "$owner" -g "$group" "$(dirname "$path")"
        print_status "$name: made $(dirname "$path") ($owner:$group 0700)"
    fi
    tmp="$(mktemp "$(dirname "$path")/.restore.XXXXXX" 2>/dev/null)" || {
        print_error "$name: cannot write in $(dirname "$path")."
        FAILED=1; continue
    }
    chmod 0600 "$tmp"
    spinner_start "Reading $name from the vault..."
    secret_file_get "$name" > "$tmp"
    rc=$?
    spinner_stop
    if [ "$rc" = 1 ]; then
        rm -f "$tmp"
        print_info "$name: the vault has no copy yet. store_logins.sh makes one."
        continue
    elif [ "$rc" != 0 ]; then
        rm -f "$tmp"
        print_error "$name: could not read the vault."
        FAILED=1; continue
    fi

    if [ -s "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        sha "$path" > "$STATE_DIR/$name.sha256"
        print_success "$name: already the same as the vault."
        continue
    fi
    if [ -s "$path" ] && [ "$OVERWRITE" = 0 ]; then
        rm -f "$tmp"
        print_action "$name: this drive's copy (dated $(date -r "$path" '+%Y-%m-%d %H:%M')) differs from the vault's. Kept this drive's for now."
        print_action "  You made or changed it on this drive on purpose? Keep it: sudo bash $SCRIPT_DIR/store_logins.sh --keep-local"
        print_action "  Otherwise, take the vault's:                              sudo bash $0 --only $name --overwrite"
        print_action "  (--keep-local stores EVERY file that differs, not only this one.)"
        continue
    fi

    # --overwrite is the only way here, and it replaces a file that differed.
    # For a key that is the machine's only way to clone, "the vault had the
    # wrong one" must not be unrecoverable.
    if [ -s "$path" ]; then
        backup="$path.before-vault.$(date +%Y%m%d-%H%M%S)"
        cp -p "$path" "$backup"
        chmod 0600 "$backup"
        print_status "$name: kept the file that was there as $backup"
    fi
    if ! { chown "$owner:$group" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$path"; }; then
        rm -f "$tmp"
        print_error "$name: could not replace $path."
        FAILED=1; continue
    fi
    tmp=""
    # A restored private key leaves a stale .pub beside it, and a mismatched
    # pair fails as "the server refused the key" rather than as what it is.
    if [ "$owner" != "root" ] && pub="$(ssh-keygen -y -f "$path" 2>/dev/null)"; then
        printf '%s\n' "$pub" > "$path.pub"
        chown "$owner:$group" "$path.pub"
        chmod 0644 "$path.pub"
        print_status "$name: rewrote $path.pub to match"
    fi
    sha "$path" > "$STATE_DIR/$name.sha256"
    print_success "$name: restored to $path ($(wc -l < "$path") lines, $owner:$group $mode)."
done

exit "$FAILED"
