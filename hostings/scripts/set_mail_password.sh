#!/usr/bin/env bash
set -e

. "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }

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
# Set the password of one mailbox, on behalf of the console.
#
#   set_mail_password.sh --check <local> <domain>
#   set_mail_password.sh --set   <local> <domain>   < the password on stdin
#
# THE PASSWORD NEVER APPEARS IN AN ARGUMENT. ps shows every argument of every
# process to every account on the machine, so a password passed as argv is a
# password published for as long as the process lives. It arrives on stdin,
# goes straight into doveadm, and is never written anywhere but the hash.
#
# This is the DEFAULT password an administrator sets when a mailbox is created.
# The owner changes it themselves afterwards in Roundcube, which writes the same
# file through the same scheme.
#
# WHAT IT WILL NOT DO, AND WHY
#
# 1. IT ONLY TOUCHES AN ADDRESS THE CONFIG CLAIMS. It must be a mailbox row in
#    hostings.conf, or already have a maildir, so the console cannot invent an
#    account out of nothing.
#
#    It used to require the MAILDIR, which is made by the apply. That forced the
#    password to be set in a second visit after the apply, and nobody made it:
#    on 2026-09-01 five of seven mailboxes had no Dovecot account at all, so
#    Postfix stored their mail and nobody could open it. A row in the published
#    config is the same promise the maildir was standing in for, and it is true
#    the moment the row is saved.
#
# 2. IT NEVER TOUCHES THE DKIM DIRECTORY, which sits beside the domains under
#    the mail root and is not a mailbox.
#
# 3. IT REFUSES A SHORT PASSWORD. Eight characters is not a policy, it is a
#    floor: the console offers this box to set a default that is then mailed or
#    read out, and a four character default is one nobody bothers to change.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning".
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

json_out() { printf '%s\n' "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    exit 1
fi

# Fixed path, like the other console scripts. Nothing here is taken from the
# caller; SITES_CONF is honoured only so the script can be tested.
SITES_CONF="${SITES_CONF:-$(conf_active /etc/hostings)}"

MODE="${1:-}"
LOCAL="${2:-}"
DOMAIN="${3:-}"

case "$MODE" in
    --check|--set) : ;;
    *) print_error "Usage: $0 --check|--set <local> <domain>   (password on stdin for --set)"; exit 1 ;;
esac

DOVECOT_USERS="/etc/dovecot/users"
MIN_LENGTH=8

# --- validate the address ----------------------------------------------------

if [ -z "$LOCAL" ] || [ -z "$DOMAIN" ]; then
    json_out '{"error":"a local part and a domain are both needed"}'
    exit 0
fi

# The same local-part rule manage_mail.sh and add_mail_store use.
if ! printf '%s' "$LOCAL" | grep -Eq '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'; then
    json_out '{"error":"the local part is not a usable mailbox name"}'
    exit 0
fi
if ! printf '%s' "$DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'; then
    json_out '{"error":"the domain is not a usable domain name"}'
    exit 0
fi
if [ "$LOCAL" = "dkim" ]; then
    json_out '{"error":"dkim is the signing-key directory, not a mailbox"}'
    exit 0
fi

ADDR="${LOCAL}@${DOMAIN}"

# --- where mail actually lives, from Dovecot ---------------------------------

MAIL_LOCATION="$(doveconf -h mail_location 2>/dev/null || true)"
MAILBASE="${MAIL_LOCATION#maildir:}"
MAILBASE="${MAILBASE%%/\%*}"

if [ -z "$MAILBASE" ] || [ "${MAILBASE#/}" = "$MAILBASE" ]; then
    json_out '{"error":"could not read the mail root from Dovecot"}'
    exit 0
fi
MAILBASE="$(readlink -f -- "$MAILBASE" 2>/dev/null || printf '%s' "$MAILBASE")"

# Rebuilt from parts, never taken from input, then resolved and re-checked, so
# neither ../.. nor a planted symlink lands outside the root.
MAILDIR="${MAILBASE}/${DOMAIN}/${LOCAL}"
# -m, not -f. -f requires every component but the last to EXIST, and a domain
# that has never had a mailbox has no directory under the mail root yet, so it
# returned nothing and the check below read that as "outside the root". Every
# first mailbox on a domain was refused: measured 2026-09-09 on
# contact@example.nl, with /srv/mail holding no domain directories
# at all. -m resolves the symlinks in the components that do exist and is
# purely lexical for the rest, so the bound is unchanged.
RESOLVED="$(readlink -m -- "$MAILDIR" 2>/dev/null || true)"
case "$RESOLVED" in
    "${MAILBASE}/${DOMAIN}/${LOCAL}") : ;;
    *) json_out '{"error":"the maildir path resolves outside the mail root"}'; exit 0 ;;
esac

ADDR_RE="$(printf '%s' "$ADDR" | sed 's/[][\\.^$*+?(){}|/-]/\\&/g')"

has_entry() { [ -f "$DOVECOT_USERS" ] && grep -Eq "^${ADDR_RE}:" "$DOVECOT_USERS"; }

# Is there a mailbox row for this address? Field 1 is the local part and field 5
# is the domain, and a blank or `-` domain means BASE_DOMAIN. The carriage
# returns are stripped for the same reason every conf_get strips them.
#
# Trimming here is shell expansion, not a pipeline, and the loop is fed only the
# mailbox lines. It used to read all 1168 lines of hostings.conf and spend a
# printf, a sed, a tr and an xargs on each one before deciding the line was a
# comment: measured at 17.3s of a 21s --check on 2026-09-07, nearly all of it in
# the kernel forking. The drawer waits on this call, so it read "Reading the
# account…" for twenty seconds every time a mailbox was opened.
trim() {
    local s="${1//$'\r'/}"
    s="${s%%#*}"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

is_row() {
    local base type local_part dom
    [ -f "$SITES_CONF" ] || return 1
    base="$(sed -n 's/^[[:space:]]*BASE_DOMAIN[[:space:]]*=//p' "$SITES_CONF" | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
    while IFS='|' read -r type local_part _ _ dom _; do
        type="${type//$'\r'/}"; type="${type%%#*}"
        type="${type#"${type%%[![:space:]]*}"}"; type="${type%"${type##*[![:space:]]}"}"
        [ "$type" = 'mailbox' ] || continue

        local_part="${local_part//$'\r'/}"
        local_part="${local_part#"${local_part%%[![:space:]]*}"}"
        local_part="${local_part%"${local_part##*[![:space:]]}"}"

        dom="${dom//$'\r'/}"
        dom="${dom#"${dom%%[![:space:]]*}"}"
        dom="${dom%"${dom##*[![:space:]]}"}"
        dom="${dom#=}"

        { [ -z "$dom" ] || [ "$dom" = '-' ]; } && dom="$base"
        [ "$local_part" = "$LOCAL" ] && [ "$dom" = "$DOMAIN" ] && return 0
    done < <(grep -E '^[[:space:]]*mailbox[[:space:]]*\|' "$SITES_CONF" 2>/dev/null || true)
    return 1
}

# --- --check -----------------------------------------------------------------

if [ "$MODE" = "--check" ]; then
    box=false;  [ -d "$MAILDIR" ] && box=true
    ent=false;  has_entry && ent=true
    row=false;  is_row && row=true
    json_out "{\"addr\":\"$ADDR\",\"maildir\":$box,\"account\":$ent,\"row\":$row,\"minLength\":$MIN_LENGTH}"
    exit 0
fi

# --- --set -------------------------------------------------------------------

if [ ! -d "$MAILDIR" ] && ! is_row; then
    json_out "{\"error\":\"${ADDR} is not a mailbox row in the config and has no maildir, so there is nothing to give a password to\"}"
    exit 0
fi

if ! command -v doveadm >/dev/null 2>&1; then
    json_out '{"error":"Dovecot is not installed, so no password can be hashed"}'
    exit 0
fi

# One line, and only the first: a paste that carried a newline must not silently
# set half a password.
IFS= read -r PASSWORD || true

if [ "${#PASSWORD}" -lt "$MIN_LENGTH" ]; then
    unset PASSWORD
    json_out "{\"error\":\"the password is shorter than ${MIN_LENGTH} characters\"}"
    exit 0
fi

# doveadm asks twice and reads both from stdin when stdin is not a terminal, so
# the plaintext never reaches the command line where ps would show it.
#
# NOT `-p /dev/stdin`: -p takes a value, not a file, so that hashes the literal
# string "/dev/stdin" and every account set that way shares one password.
HASH="$(printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | doveadm pw -s SHA512-CRYPT 2>/dev/null || true)"

if [ -z "$HASH" ]; then
    unset PASSWORD
    json_out '{"error":"doveadm could not hash the password"}'
    exit 0
fi

print_header "Password for ${ADDR}"

LINE="${ADDR}:${HASH}:5000:5000::${MAILBASE}/${DOMAIN}/${LOCAL}::"
TMP="$(mktemp)"
chmod 600 "$TMP"
grep -Ev "^${ADDR_RE}:" "$DOVECOT_USERS" 2>/dev/null > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
# 0640 root:dovecot, matching add_dovecot.sh: auth runs as dovecot and has to
# read this file, and 0600 made every delivery fail with a userdb lookup error.
install -m 0640 -o root -g dovecot "$TMP" "$DOVECOT_USERS"
rm -f "$TMP"

systemctl reload dovecot >/dev/null 2>&1 || true

# The owner's 1Password entry gets it now: after this only the hash exists.
# stderr only, because stdout is the console's JSON.
PERSON_ENTRY=/usr/local/sbin/person_entry.sh
[ -f "$PERSON_ENTRY" ] || PERSON_ENTRY="$(dirname "${BASH_SOURCE[0]}")/person_entry.sh"
if [ -f "$PERSON_ENTRY" ]; then
    printf '%s\n' "$PASSWORD" | SITES_CONF="$SITES_CONF" bash "$PERSON_ENTRY" --mailbox "$ADDR" >&2 || true
fi
unset PASSWORD

print_success "Password set for ${ADDR}."
json_out "{\"addr\":\"$ADDR\",\"set\":true}"
