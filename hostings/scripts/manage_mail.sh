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
# Forward or delete one mailbox, on behalf of the console.
#
#   manage_mail.sh --check    <local> <domain>
#   manage_mail.sh --forward  <local> <domain>     keep the maildir, redirect
#   manage_mail.sh --retire   <local> <domain>     keep the maildir, no redirect
#   manage_mail.sh --unforward <local> <domain>    undo a forward (restore)
#   manage_mail.sh --purge    <local> <domain>     delete the maildir for good
#
# Two ways to remove a mailbox, chosen in the console's delete dialog:
#
#   --forward   Option 1. The account and its maildir stay on disk, so old mail
#               is still readable and creating the same address again reattaches
#               every message. New mail is redirected to contact@<domain> by a
#               Postfix alias, so nothing bounces while the box is "deleted".
#
#   --retire    Option 1 for an address with nowhere to forward, which in
#               practice means contact@<domain>: it IS the forward target, so
#               --forward refuses it and the dialog used to offer deleting
#               everything or nothing. The maildir stays exactly as it is and no
#               alias is written. The row leaving is what stops delivery, and
#               re-creating the address reattaches every message.
#
#   --purge     Option 2. The maildir, the Dovecot account and the mailbox map
#               entry are all removed. Nothing is recoverable, and the same
#               address created again starts empty.
#
# WHAT IT WILL NOT DO, AND WHY
#
# 1. IT ONLY REMOVES contact@<domain> WHEN NOTHING NEEDS IT. That address is
#    where every other mailbox on its domain forwards on removal, so it is
#    refused while any of three things is still true: another maildir exists on
#    the domain, an application is set up to send as it, or a line in the
#    forwards map still points at it. When none of them are, it is the last
#    thing on the domain and there is nothing left for it to serve.
#
# 2. IT NEVER TOUCHES THE DKIM DIRECTORY. `dkim` sits beside the domains under
#    the mail root and holds the signing keys. It is not a mailbox and a local
#    part may not be called that.
#
# 3. IT STAYS UNDER THE MAIL ROOT, taken from Dovecot's own mail_location rather
#    than a config default, because the two disagree on this machine. The
#    maildir path is rebuilt from the root, the domain and the local part, then
#    readlink -f'd and checked to still be under the root: ../.. and a planted
#    symlink both land outside and are refused.
#
# 4. A FORWARD REFUSES IF contact@<domain> HAS NO MAILDIR. A forward to an
#    address that does not exist is a black hole; the console has to provision
#    contact first, which needs a password and cannot be automated here.
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

MODE="${1:-}"
LOCAL="${2:-}"
DOMAIN="${3:-}"

case "$MODE" in
    --check|--forward|--retire|--unforward|--purge) : ;;
    *) print_error "Usage: $0 --check|--forward|--retire|--unforward|--purge <local> <domain>"; exit 1 ;;
esac

# The alias target. One name, referenced everywhere below so it cannot drift.
CONTACT_LOCAL="contact"

FORWARDS="/etc/postfix/virtual_forwards"
MAILBOX_MAP="/etc/postfix/virtual_mailbox_map"
DOVECOT_USERS="/etc/dovecot/users"
SENDER_MAP="/etc/postfix/sender_login_map"

# --- validate the address ----------------------------------------------------

if [ -z "$LOCAL" ] || [ -z "$DOMAIN" ]; then
    json_out '{"error":"a local part and a domain are both needed"}'
    exit 0
fi

# The same local-part rule the console and add_mail_store use.
if ! printf '%s' "$LOCAL" | grep -Eq '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'; then
    json_out '{"error":"the local part is not a usable mailbox name"}'
    exit 0
fi
if ! printf '%s' "$DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'; then
    json_out '{"error":"the domain is not a usable domain name"}'
    exit 0
fi

# Rule 2: dkim is not a mailbox.
if [ "$LOCAL" = "dkim" ]; then
    json_out '{"error":"dkim is the signing-key directory, not a mailbox"}'
    exit 0
fi

ADDR="${LOCAL}@${DOMAIN}"
CONTACT_ADDR="${CONTACT_LOCAL}@${DOMAIN}"

# --- where mail actually lives, from Dovecot ---------------------------------

# maildir:/home/admin/mail_files/%d/%n -> /home/admin/mail_files
MAIL_LOCATION="$(doveconf -h mail_location 2>/dev/null || true)"
MAILBASE="${MAIL_LOCATION#maildir:}"
MAILBASE="${MAILBASE%%/\%*}"

if [ -z "$MAILBASE" ] || [ "${MAILBASE#/}" = "$MAILBASE" ]; then
    json_out '{"error":"could not read the mail root from Dovecot"}'
    exit 0
fi

# Resolve the root itself, so the exact-match check below holds even when the
# mail tree lives under a symlinked path.
MAILBASE="$(readlink -f -- "$MAILBASE" 2>/dev/null || printf '%s' "$MAILBASE")"

# Rebuilt from parts, never taken from input, so a crafted domain or local part
# cannot escape the root. Then resolved and re-checked, so a symlink cannot either.
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

# The address as a literal, for anchored greps against the map files. Escaping
# the dots and dashes stops a domain like a-b.com matching aXbYcom.
ADDR_RE="$(printf '%s' "$ADDR" | sed 's/[][\\.^$*+?(){}|/-]/\\&/g')"

has_maildir() { [ -d "$MAILBASE/$1/$2" ]; }
is_forwarded() { [ -f "$FORWARDS" ] && grep -Eq "^${ADDR_RE}[[:space:]]" "$FORWARDS"; }

# --- --check -----------------------------------------------------------------

if [ "$MODE" = "--check" ]; then
    box=false;  has_maildir "$DOMAIN" "$LOCAL" && box=true
    fwd=false;  is_forwarded && fwd=true
    json_out "{\"addr\":\"$ADDR\",\"maildir\":$box,\"forwarded\":$fwd,\"target\":\"$CONTACT_ADDR\"}"
    exit 0
fi

# --- contact@: refuse only while something still needs it --------------------
#
# It is the address every other mailbox forwards to on removal, so deleting it
# while siblings exist breaks their forwarding. Once it is the last mailbox on
# its domain, and no application is set up to send as it, there is nothing left
# for it to serve and keeping it is just a rule nobody can get past.

# Every other maildir on this domain. The maildirs are the truth here rather
# than the config: a row can be deleted while its files are still forwarding.
# Other mailboxes on this domain that Postfix will still DELIVER to.
#
# The delivery map, not the directories on disk. A maildir whose address has
# been deleted stays behind on purpose, because removing a mailbox never
# destroys mail, so counting directories counts the dead as well as the living.
#
# Found 2026-09-03: deleting contact@example.com was refused with "is the
# forward target for 2 other mailbox(es)" while virtual_forwards was EMPTY and
# the config held one mailbox row. The two were abandoned admin/ and info/
# directories from mailboxes deleted days earlier. The message was not merely
# unhelpful, it was false, and it blocked a delete that nothing needed blocked.
siblings_on_domain() {
    local n=0
    [ -f "$MAILBOX_MAP" ] || { printf '0'; return 0; }
    n="$(grep -Eic "^[A-Za-z0-9._%+-]+@${DOMAIN//./\\.}[[:space:]]" "$MAILBOX_MAP" 2>/dev/null || printf '0')"
    # Itself does not count.
    if grep -Eqi "^${CONTACT_LOCAL}@${DOMAIN//./\\.}[[:space:]]" "$MAILBOX_MAP" 2>/dev/null; then
        n=$((n - 1))
    fi
    [ "$n" -lt 0 ] && n=0
    printf '%s' "$n"
}

# Anything still forwarding TO it. This is the register that matters: a maildir
# can be removed outside this script, and the alias pointing at contact@ would
# outlive it, so counting maildirs alone is not enough.
forwards_here() {
    local re
    re="$(printf '%s' "$CONTACT_ADDR" | sed 's/[][\.^$*+?(){}|/-]/\&/g')"
    [ -f "$FORWARDS" ] || return 1
    grep -Eqi "[[:space:]]${re}[[:space:]]*$" "$FORWARDS"
}

# An application told to SEND as this address. Only the two keys that mean
# sending: EmailToAddress names a destination, and pointing the operator at the
# wrong field is worse than not mentioning it. Case-insensitive and anchored on
# both sides, because Contact@Example.dev is the same mailbox and a miss here
# deletes a maildir something is still using.
app_sends_as() {
    local dir="/etc/app-secrets" f
    [ -d "$dir" ] || return 1
    for f in "$dir"/*.env; do
        [ -f "$f" ] || continue
        if grep -Eqis -- "^EmailSettings__(EmailFromAddress|UserName)=.*${ADDR_RE}([^A-Za-z0-9.-]|\$)" "$f"; then
            printf '%s' "${f##*/}"
            return 0
        fi
    done
    return 1
}

if [ "$LOCAL" = "$CONTACT_LOCAL" ] && { [ "$MODE" = "--forward" ] || [ "$MODE" = "--retire" ] || [ "$MODE" = "--purge" ]; }; then
    _sib="$(siblings_on_domain)"
    if [ "$_sib" -gt 0 ]; then
        json_out "{\"error\":\"${ADDR} is the forward target for ${_sib} other mailbox(es) on ${DOMAIN}. Remove those first.\"}"
        exit 0
    fi
    if _env="$(app_sends_as)"; then
        json_out "{\"error\":\"${ADDR} is what ${_env} sends as. Change that application's mail settings first.\"}"
        exit 0
    fi
    if forwards_here; then
        json_out "{\"error\":\"something in ${FORWARDS} still forwards to ${ADDR}. Remove those forwards first.\"}"
        exit 0
    fi
    if [ "$MODE" = "--forward" ]; then
        json_out "{\"error\":\"${ADDR} has nothing to forward to: it IS the forward target. Delete it instead.\"}"
        exit 0
    fi
fi

reload_postfix() {
    if [ -f "$FORWARDS" ]; then
        postmap "$FORWARDS"
    fi
    postfix reload >/dev/null 2>&1 || systemctl reload postfix >/dev/null 2>&1 || true
}

# The alias file has to be reachable by Postfix, or the lines are written and
# ignored. Reported rather than assumed: pointing virtual_alias_maps at it is a
# one-time main.cf change that belongs to the mail-stack script, not here.
warn_if_alias_map_unwired() {
    local maps
    maps="$(postconf -h virtual_alias_maps 2>/dev/null || true)"
    case "$maps" in
        *"$FORWARDS"*) : ;;
        *) print_action "virtual_alias_maps does not include $FORWARDS, so forwards are written but not used. Run the mail-stack script to wire it." ;;
    esac
}

# --- --forward: keep the maildir, redirect new mail --------------------------

if [ "$MODE" = "--forward" ]; then
    if ! has_maildir "$DOMAIN" "$CONTACT_LOCAL"; then
        json_out "{\"error\":\"${CONTACT_ADDR} has no maildir, so a forward would bounce; provision contact first\"}"
        exit 0
    fi

    print_header "Forward ${ADDR} to ${CONTACT_ADDR}"
    touch "$FORWARDS"
    chmod 644 "$FORWARDS"

    # Idempotent: drop any existing line for this address, then add exactly one.
    tmp="$(mktemp)"
    grep -Ev "^${ADDR_RE}[[:space:]]" "$FORWARDS" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\n' "$ADDR" "$CONTACT_ADDR" >> "$tmp"
    cat "$tmp" > "$FORWARDS"
    rm -f "$tmp"

    warn_if_alias_map_unwired
    reload_postfix

    print_success "New mail to ${ADDR} now goes to ${CONTACT_ADDR}. The maildir is untouched."
    print_info "Re-creating ${ADDR} in the console reattaches every message it already holds."
    json_out "{\"addr\":\"$ADDR\",\"forwarded\":true,\"target\":\"$CONTACT_ADDR\",\"maildir\":true}"
    exit 0
fi

# --- --retire: keep the maildir, write no alias ------------------------------
#
# The soft delete for an address that cannot forward. Nothing on disk changes:
# what removes the address is its row leaving, which takes it out of the
# delivery map on the next apply. Any stale alias FROM it is dropped, so a
# retired address cannot keep redirecting mail it no longer accepts.

if [ "$MODE" = "--retire" ]; then
    print_header "Retire ${ADDR}"
    if [ -f "$FORWARDS" ]; then
        tmp="$(mktemp)"
        grep -Ev "^${ADDR_RE}[[:space:]]" "$FORWARDS" > "$tmp" 2>/dev/null || true
        cat "$tmp" > "$FORWARDS"
        rm -f "$tmp"
        reload_postfix
    fi
    print_success "The maildir for ${ADDR} is untouched and no forward was written."
    print_info "Re-creating ${ADDR} in the console reattaches every message it already holds."
    json_out "{\"addr\":\"$ADDR\",\"retired\":true,\"maildir\":true}"
    exit 0
fi

# --- --unforward: undo a forward (restore) -----------------------------------

if [ "$MODE" = "--unforward" ]; then
    if ! is_forwarded; then
        json_out "{\"addr\":\"$ADDR\",\"forwarded\":false}"
        exit 0
    fi
    print_header "Stop forwarding ${ADDR}"
    tmp="$(mktemp)"
    grep -Ev "^${ADDR_RE}[[:space:]]" "$FORWARDS" > "$tmp" 2>/dev/null || true
    cat "$tmp" > "$FORWARDS"
    rm -f "$tmp"
    reload_postfix
    print_success "${ADDR} is delivered to its own maildir again."
    json_out "{\"addr\":\"$ADDR\",\"forwarded\":false}"
    exit 0
fi

# --- --purge: delete the maildir, the account and the map entry --------------

if [ "$MODE" = "--purge" ]; then
    print_header "Delete ${ADDR} for good"

    # Any forward for this address goes first: the target may be about to lose
    # its reason to exist, and a stale alias is worse than none.
    if is_forwarded; then
        tmp="$(mktemp)"
        grep -Ev "^${ADDR_RE}[[:space:]]" "$FORWARDS" > "$tmp" 2>/dev/null || true
        cat "$tmp" > "$FORWARDS"
        rm -f "$tmp"
    fi

    # The mailbox map entry. Keyed by the address, value the relative maildir.
    if [ -f "$MAILBOX_MAP" ] && grep -Eq "^${ADDR_RE}[[:space:]]" "$MAILBOX_MAP"; then
        tmp="$(mktemp)"
        grep -Ev "^${ADDR_RE}[[:space:]]" "$MAILBOX_MAP" > "$tmp" 2>/dev/null || true
        cat "$tmp" > "$MAILBOX_MAP"
        rm -f "$tmp"
        postmap "$MAILBOX_MAP"
    fi

    # The Dovecot account. passwd-file lines are `addr:hash:...`.
    if [ -f "$DOVECOT_USERS" ] && grep -Eq "^${ADDR_RE}:" "$DOVECOT_USERS"; then
        tmp="$(mktemp)"
        grep -Ev "^${ADDR_RE}:" "$DOVECOT_USERS" > "$tmp" 2>/dev/null || true
        cat "$tmp" > "$DOVECOT_USERS"
        rm -f "$tmp"
    fi

    # The right to SEND AS this address. Left behind until 2026-09-02, so a
    # purged address stayed in sender_login_map: Postfix's two maps then
    # disagreed, which is the fault that stopped anyone sending at all on
    # 2026-08-28. Nothing could authenticate as it any more, the Dovecot line
    # being gone, so it was inert rather than dangerous.
    if [ -f "$SENDER_MAP" ] && grep -Eq "^${ADDR_RE}[[:space:]]" "$SENDER_MAP"; then
        tmp="$(mktemp)"
        grep -Ev "^${ADDR_RE}[[:space:]]" "$SENDER_MAP" > "$tmp" 2>/dev/null || true
        cat "$tmp" > "$SENDER_MAP"
        rm -f "$tmp"
        postmap "$SENDER_MAP"
    fi

    # The maildir itself. RESOLVED is already proven to be exactly
    # $MAILBASE/$DOMAIN/$LOCAL, so this rm cannot walk outside it.
    removed=false
    if [ -d "$RESOLVED" ]; then
        owner="$(stat -c %U "$RESOLVED" 2>/dev/null || echo '')"
        if [ "$owner" != "vmail" ]; then
            json_out "{\"error\":\"the maildir is owned by ${owner}, not vmail, so it was not deleted\"}"
            exit 0
        fi
        rm -rf -- "$RESOLVED"
        removed=true
    fi

    reload_postfix
    print_success "${ADDR} is gone: maildir, account, mailbox map and sender map entries all removed."
    json_out "{\"addr\":\"$ADDR\",\"purged\":true,\"maildir_removed\":$removed}"
    exit 0
fi
