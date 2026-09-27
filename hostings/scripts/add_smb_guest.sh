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
# The account every SMB share acts as, SMB_GUEST_USER in hostings.conf.
#
# Item 165, audit C2: the shares used to force admin, whose sudo turned an
# anonymous LAN write into a root one. This account has no shell, no password,
# no home and no sudo. It reaches each share through SMB_GUEST_GROUPS only, so
# nothing it can touch is reached by owning it.
#
# Before add_smb.sh, which creates a missing share folder owned by this account,
# and after Jenkins and Apache, whose groups it joins.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

[ "$EUID" -eq 0 ] || { print_error "This needs root: it creates an account."; print_action "sudo bash $0"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null \
        | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
    printf '%s' "${v:-$2}"
}

GUEST="$(conf_get SMB_GUEST_USER '')"
GROUPS_WANTED="$(conf_get SMB_GUEST_GROUPS '')"

print_header "SMB guest account"
if [ -z "$GUEST" ]; then
    print_info "No SMB_GUEST_USER in $SITES_CONF, so the shares keep their own force user."
    exit 0
fi

if id -u "$GUEST" >/dev/null 2>&1; then
    print_success "$GUEST already exists."
else
    useradd --system --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin "$GUEST"
    print_success "Created $GUEST: no shell, no home, no password."
fi

# The backup group is this project's own, so it is made here if the backup
# scripts have not run yet. Any other missing group is reported, never
# created: making `jenkins` before the Jenkins package does would hand that
# package a group it did not expect.
BACKUP_GROUP="$(conf_get BACKUP_READ_GROUP '')"
if [ -n "$BACKUP_GROUP" ] && ! getent group "$BACKUP_GROUP" >/dev/null; then
    groupadd --system "$BACKUP_GROUP"
    print_status "Created group $BACKUP_GROUP."
fi
MISSING=()
for g in $GROUPS_WANTED; do
    if ! getent group "$g" >/dev/null; then
        MISSING+=("$g")
        continue
    fi
    if id -nG "$GUEST" | tr ' ' '\n' | grep -qx "$g"; then
        print_success "$GUEST is in $g."
    else
        usermod -aG "$g" "$GUEST"
        print_status "Added $GUEST to $g."
    fi
done

# Samba looks the account up when a client connects, and caches it per
# connection, so a reload is enough for the new groups to count.
systemctl reload smbd 2>/dev/null || true

if [ ${#MISSING[@]} -gt 0 ]; then
    print_error "These groups do not exist yet: ${MISSING[*]}"
    print_action "Run the script that makes each, then this again: sudo bash $0"
    exit 1
fi
print_success "SMB guest account ready."
