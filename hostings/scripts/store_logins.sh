#!/usr/bin/env bash
set -o pipefail

# =============================================================================
# Copy the login files to the secret store, so a fresh drive gets them back.
# login-store-decisions.md, decision 4.
#
#   sudo bash store_logins.sh            store every file that changed
#   sudo bash store_logins.sh --status   print the last result and exit
#   sudo bash store_logins.sh --keep-local
#                                        store this machine's copy even where
#                                        the vault holds a different one
#
# Run by login-store.path whenever one of the files changes, and hourly by
# login-store.timer as the retry (add_login_store.sh installs both). A console
# save never waits for it: the save happens on the machine, and the store
# catches up here.
#
# IT NEVER OVERWRITES A VAULT COPY IT HAS NOT SEEN. A changed file is only
# stored when the vault has no copy, or the vault copy is the one last stored
# or restored here. A fresh drive that made its own admin login
# before restore_logins.sh ran would otherwise replace every real login in the
# vault with that one line.
#
# The last result is one line in $STATE_DIR/status, for the console to show:
#   ok <time>  |  failed <time> <reason>
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
export SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
STATE_DIR="/var/lib/hostings-login-store"

if [ "${1:-}" = "--status" ]; then
    cat "$STATE_DIR/status" 2>/dev/null || echo "never run"
    exit 0
fi

KEEP_LOCAL=0
[ "${1:-}" = "--keep-local" ] && KEEP_LOCAL=1

if [ "$EUID" -ne 0 ]; then
    print_error "The login files and the store token are root-only."
    print_action "Run: sudo bash $0 $*"
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
# Copied in restore_logins.sh; the two lists must agree.
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

# 0711 and a 0644 status: the console reads the status, nobody lists the rest.
umask 077
install -d -m 0711 "$STATE_DIR"
chmod 0600 "$STATE_DIR"/*.sha256 2>/dev/null || true

# One run at a time: two overlapping first stores would create two items with
# the same title, and every later read of that name fails.
exec 9>"$STATE_DIR/lock"
flock -n 9 || { print_info "Already running."; exit 0; }

# The snapshot below is a plaintext copy of whatever is being stored, and one
# of those is now a private key. A Ctrl-C between the copy and line 161 would
# leave it on disk with nothing to clean it.
trap 'rm -f "$STATE_DIR/.snapshot"' EXIT

record_status() {
    printf '%s %s%s\n' "$1" "$(date -Is)" "${2:+ $2}" > "$STATE_DIR/status"
    chmod 0644 "$STATE_DIR/status"
}

# shellcheck source=/dev/null
if ! . "$SCRIPT_DIR/secret_store.sh"; then
    record_status failed "the secret store could not be loaded"
    exit 1
fi
if ! reasons="$(secret_preflight)"; then
    print_error "The secret store cannot be used:"
    printf '   %s\n' "$reasons"
    record_status failed "$(printf '%s' "$reasons" | head -1)"
    exit 1
fi

sha() { sha256sum "$1" | cut -d' ' -f1; }

FAILED=""
for entry in "${LOGIN_FILES[@]}"; do
    IFS="|" read -r name path _owner_group _mode <<< "$entry"
    rec="$STATE_DIR/$name.sha256"
    if [ ! -s "$path" ]; then
        print_info "$name: $path does not exist or is empty, nothing to store."
        continue
    fi
    # One snapshot is hashed, stored and recorded: a save landing mid-run must
    # not make the stored copy differ from the recorded hash.
    snap="$STATE_DIR/.snapshot"
    cp "$path" "$snap"
    here="$(sha "$snap")"
    # --keep-local always asks the vault: the record may be what is wrong.
    if [ "$KEEP_LOCAL" = 0 ] && [ "$here" = "$(cat "$rec" 2>/dev/null)" ]; then
        print_info "$name: unchanged since last stored."
        continue
    fi

    # Look before writing, every time: the vault copy must be the one last
    # stored or restored here, or somebody else changed it since.
    vault_sha="$(secret_file_get "$name" | sha256sum | cut -d' ' -f1)"
    rc=$?
    if [ "$rc" = 0 ]; then
        if [ "$vault_sha" = "$here" ]; then
            echo "$here" > "$rec"
            print_success "$name: the vault already holds this copy."
            continue
        fi
        if [ "$KEEP_LOCAL" = 0 ] && [ "$vault_sha" != "$(cat "$rec" 2>/dev/null)" ]; then
            print_error "$name: the vault holds a copy this machine never stored or restored. Not overwritten."
            print_action "  You made or changed it on this drive on purpose? Keep it: sudo bash $0 --keep-local"
            print_action "  Otherwise, take the vault's:                              sudo bash $SCRIPT_DIR/restore_logins.sh --only $name --overwrite"
            print_action "  (--keep-local stores EVERY file that differs, not only this one.)"
            FAILED="${FAILED:+$FAILED, }$name differs from the vault"
            continue
        fi
    elif [ "$rc" != 1 ]; then
        FAILED="${FAILED:+$FAILED, }$name: could not read the vault"
        continue
    fi

    if secret_file_put "$name" < "$snap"; then
        echo "$here" > "$rec"
        print_success "$name: stored."
    else
        print_error "$name: storing failed."
        FAILED="${FAILED:+$FAILED, }$name: store failed"
    fi
done

rm -f "$STATE_DIR/.snapshot"

if [ -n "$FAILED" ]; then
    record_status failed "$FAILED"
    exit 1
fi

# The path unit does not fire again for a change made while this ran, so look
# once more before calling it done. Bounded, and a file still changing after
# the last pass is reported, not called ok: the hourly timer picks it up.
PASS="${LOGIN_STORE_PASS:-1}"
for entry in "${LOGIN_FILES[@]}"; do
    IFS="|" read -r name path _owner_group _mode <<< "$entry"
    [ -s "$path" ] || continue
    [ "$(sha "$path")" = "$(cat "$STATE_DIR/$name.sha256" 2>/dev/null)" ] && continue
    if [ "$PASS" -lt 10 ]; then
        print_info "$name changed during this run. Storing again."
        LOGIN_STORE_PASS=$((PASS + 1)) exec bash "$0"
    fi
    record_status failed "$name kept changing during ten passes"
    exit 1
done
record_status ok
