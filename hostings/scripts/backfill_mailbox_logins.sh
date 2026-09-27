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
# Put the mailboxes that predate the vault into their owner's 1Password entry,
# by giving each one a NEW password.
#
#   backfill_mailbox_logins.sh                 say what it would do, change nothing
#   backfill_mailbox_logins.sh --apply         do it
#   backfill_mailbox_logins.sh --apply a@b.nl  just that address
#
# WHY A NEW PASSWORD AND NOT THE OLD ONE. The machine keeps only a hash, so the
# plaintext of an existing mailbox does not exist anywhere and cannot be
# written to the vault. The owner chose this on 2026-09-20 over the alternatives:
# an entry with the password left blank, a page where the owner types theirs
# once, or leaving each address until somebody next changes it.
#
# SO THIS BREAKS EVERY MAIL CLIENT ON THE ADDRESSES IT TOUCHES, until each is
# reconfigured from the new password in the vault. That is the whole cost, and
# it is why the default is a dry run and --apply is a separate decision. On
# this branch the mailboxes are test data; on a live drive it is a customer's
# phone that stops fetching mail.
#
# IT DOES ONE THING PER ADDRESS: generate, then hand to set_mail_password.sh,
# which sets the hash and writes the owner's entry. Nothing here talks to
# Dovecot or to 1Password directly, so there is no second implementation of
# either to keep in step.
#
# WHAT IT SKIPS, and says so rather than guessing:
#   no owner    no account owns the address's domain, so there is no entry to
#               write into. Give the domain an owner in the console first
#   already in  the entry already holds the address
#   moved       the section is in the wrong person's entry: that is
#               person_entry.sh --sync-owners, not a new password
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning".
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/etc/hostings")"
export SITES_CONF

APPLY=0
ONLY=()
for a in "$@"; do
    case "$a" in
        --apply) APPLY=1 ;;
        --help|-h) sed -n '18,47p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) print_error "Unknown option: $a"; exit 1 ;;
        *)  ONLY+=("$a") ;;
    esac
done

# The console's own copies, in /usr/local/sbin, before the pipeline tree's.
_tool() {
    [ -x "/usr/local/sbin/$1" ] && { printf '/usr/local/sbin/%s' "$1"; return; }
    [ -f "$SCRIPT_DIR/$1" ] && { printf '%s/%s' "$SCRIPT_DIR" "$1"; return; }
    printf '/usr/local/lib/linuxbasics/hostings/scripts/%s' "$1"
}
PERSON_ENTRY="$(_tool person_entry.sh)"
MAIL_PW="$(_tool set_mail_password.sh)"

# -----------------------------------------------------------------------------
# Pre-flight: everything that would stop this halfway, checked before the first
# password is changed. A run that dies on address three leaves two mailboxes
# with new passwords nobody was told about.
# -----------------------------------------------------------------------------
print_header "Pre-flight"
ERRORS=()
[ "$EUID" -eq 0 ]      || ERRORS+=("This changes mailbox passwords and reads the vault token, so it must run as root. Run: sudo bash $0 $*")
[ -f "$SITES_CONF" ]   || ERRORS+=("No config at $SITES_CONF")
[ -f "$PERSON_ENTRY" ] || ERRORS+=("person_entry.sh is not installed: $PERSON_ENTRY")
[ -f "$MAIL_PW" ]      || ERRORS+=("set_mail_password.sh is not installed: $MAIL_PW")
command -v openssl >/dev/null 2>&1 || ERRORS+=("openssl is not installed, so no password can be generated. Run: sudo apt-get install -y openssl")
if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi
print_success "Config, scripts and openssl are all present."

# The audit is the one place that knows the owner rule and what the vault
# already holds. Asking it, rather than working it out again here, is why there
# is no second copy of that rule to drift.
AUDIT="$(SITES_CONF="$SITES_CONF" bash "$PERSON_ENTRY" --audit 2>/dev/null || true)"
if [ -z "$AUDIT" ]; then
    print_info "No mailbox rows in the config, so there is nothing to back-fill."
    exit 0
fi

wanted() {
    [ ${#ONLY[@]} -eq 0 ] && return 0
    local a
    for a in "${ONLY[@]}"; do [ "$a" = "$1" ] && return 0; done
    return 1
}

# 20 characters of base64 with the awkward ones removed: a password that gets
# typed into a phone once and then lives in the vault.
new_password() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-20; }

print_header "What this would change"
TODO=()
SKIPPED=0
while IFS=$'\t' read -r state addr owner note; do
    [ -n "$state" ] || continue
    wanted "$addr" || continue
    case "$state" in
        MISSING)
            TODO+=("$addr"$'\t'"$owner")
            print_status "$addr  ->  new password, into the entry of '$owner'"
            ;;
        NOOWNER)
            SKIPPED=$((SKIPPED + 1))
            print_action "$addr is skipped: $note. Give its domain an owner in the console first."
            ;;
        MOVED)
            SKIPPED=$((SKIPPED + 1))
            print_action "$addr is in the wrong entry. Run: sudo $PERSON_ENTRY --sync-owners"
            ;;
        OK)      print_info "$addr is already in '$owner', unchanged." ;;
        # The same action as MISSING, for the same reason: the live password
        # cannot be recovered, so putting the two back in step means a new one.
        WRONG)
            TODO+=("$addr"$'\t'"$owner")
            print_status "$addr  ->  new password: the entry of '$owner' holds one the machine no longer accepts"
            ;;
        NOBOX)   print_info "$addr has an entry and no login on this machine: report_drift.sh calls that an orphan." ;;
        UNKNOWN) print_error "$note" ;;
    esac
done <<< "$AUDIT"

if [ ${#TODO[@]} -eq 0 ]; then
    echo ""
    print_info "Nothing to back-fill. $SKIPPED address(es) skipped for the reasons above."
    exit 0
fi

echo ""
if [ "$APPLY" -ne 1 ]; then
    print_info "${#TODO[@]} mailbox(es) would get a NEW password. Nothing has been changed."
    print_action "Every mail client on those addresses stops working until it is given the new password."
    print_action "Run it for real: sudo bash $0 --apply"
    exit 0
fi

print_header "Setting new passwords"
DONE=0
FAILED=0
for line in "${TODO[@]}"; do
    ADDR="${line%%$'\t'*}"
    LOCAL="${ADDR%@*}"
    DOMAIN="${ADDR#*@}"
    # Generated here and handed straight down a pipe: never a variable this
    # script could print, and never an argument, which ps would publish.
    if new_password | bash "$MAIL_PW" --set "$LOCAL" "$DOMAIN" >/dev/null 2>&1; then
        print_success "$ADDR has a new password, and it is in the owner's entry."
        DONE=$((DONE + 1))
    else
        print_error "$ADDR was NOT changed. Run it alone to see why: sudo bash $0 --apply $ADDR"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
print_status "$DONE changed, $FAILED failed, $SKIPPED skipped."
[ "$DONE" -gt 0 ] && print_action "Tell each owner to open their 1Password entry: their mail client needs the new password."
[ "$FAILED" -gt 0 ] && exit 1
exit 0
