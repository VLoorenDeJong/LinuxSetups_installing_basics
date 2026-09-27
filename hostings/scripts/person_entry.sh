#!/usr/bin/env bash
set -o pipefail

# =============================================================================
# One entry per person in the secret store (their page login, recovery codes
# and repositories), and one item per mailbox. login-store-decisions.md,
# decision 7 and the 2026-09-26 section.
#
#   person_entry.sh --login <user>        password on stdin
#   person_entry.sh --mailbox <address>   password on stdin; the mailbox's own
#                                         item, with webmail and server settings
#   person_entry.sh --share <user>        share the person's entry to their
#                                         e-mail, mail the link. JSON on stdout
#   person_entry.sh --share-mailbox <address> <e-mail>
#                                         share one mailbox item to any address,
#                                         mail the link. JSON on stdout
#   person_entry.sh --split-mail          move mailbox sections left in entries
#                                         from before 2026-09-26 into items
#   person_entry.sh --delete <user>
#   person_entry.sh --urls <user>         the sign-in links and the
#                                         repositories of the rows they own.
#                                         No password touched
#   person_entry.sh --show <user>         what the entry holds, values left
#                                         out: URLs in full, fields by section
#                                         and label only. Reads only
#   person_entry.sh --recovery <user>     the second factor's recovery codes,
#                                         one per line on stdin
#   person_entry.sh --audit               vault against machine, one line each:
#                                         OK MISSING WRONG STALE NOBOX UNKNOWN.
#                                         Reads only
#   person_entry.sh --sync-owners         nothing since 2026-09-26, kept for
#                                         its callers
#   person_entry.sh --settings            refresh every mailbox item's webmail
#                                         link and server settings
#   person_entry.sh --forget-mailbox <address>
#                                         delete a mailbox item the audit
#                                         calls STALE or NOBOX. The prune
#                                         calls it for a vault orphan
#
# A PASSWORD ONLY REACHES THE ENTRY WHEN IT IS SET. The machine keeps hashes,
# so an entry cannot be rebuilt later: manage_auth_users.sh and
# set_mail_password.sh hand the plaintext here at the moment they receive it.
#
# THE VAULT NEVER BLOCKS A SAVE. --login and --mailbox exit 3 when the store
# was not written, and every caller that sets a password ignores it: the
# password is already set on the machine, and an outside service must not undo
# that (decision 4). Only add_app_vhosts.sh reads it, because it generates a
# password nobody will ever see unless the vault holds it.
#
# SHARING IS A BUTTON, never automatic (decision 8). `op` returns the link and
# sends nothing, so it is mailed from here, to the address the 2FA code goes to.
#
# THE URL LIST IS WHAT AUTOFILL MATCHES, and it holds the console, the
# webmail and every repository the person owns. The owner, 2026-09-20: a site
# several entries match shows a picker, and picking is part of the job. A
# URL-typed field inside a section is a link only, and matches nothing.
# =============================================================================

print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1" >&2; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/var/lib/hosting-manager/config-repo/backup_config")"
export SITES_CONF

# Numbered because 1Password shows sections A to Z. The owner, 2026-09-26: the
# mailboxes first, Mail settings at the bottom. Old names: relabel_sections.
SEC_MAILBOX="01. Mailbox"
SEC_RECOVERY="02. Recovery codes"
SEC_REPOS="03. Repositories"
SEC_MAIL="99. Mail settings"
# The one section of a mailbox item.
SEC_SERVER="Server settings"

usage() {
    echo "Usage: $0 --login <user> | --mailbox <address>   (password on stdin)" >&2
    echo "       $0 --share <user> | --delete <user>" >&2
    echo "       $0 --urls <user>            the sign-in links and repositories, no password" >&2
    echo "       $0 --show <user>            what the entry holds, values left out" >&2
    echo "       $0 --has-login <user>       exit 0 when the entry holds a page password" >&2
    echo "       $0 --recovery <user>        recovery codes on stdin, one per line" >&2
    echo "       $0 --share-mailbox <addr> <e-mail>   share one mailbox item to that address" >&2
    echo "       $0 --forget-mailbox <addr>  delete a stale mailbox item" >&2
    echo "       $0 --audit | --sync-owners | --settings | --relabel | --split-mail   no argument" >&2
    exit 1
}

MODE="${1:-}"; ARG="${2:-}"; TO="${3:-}"; BY="${4:-}"
case "$MODE" in
    --audit|--sync-owners|--settings|--relabel|--split-mail) ;;
    --login|--mailbox|--share|--delete|--recovery|--urls|--show|--has-login|--forget-mailbox) [ -n "$ARG" ] || usage ;;
    --share-mailbox) [ -n "$ARG" ] && [ -n "$TO" ] || usage ;;
    *) usage ;;
esac
# The name becomes an item title and a grep pattern.
# Never a leading dash, or it reaches op and awk as a flag.
if [ -n "$ARG" ] && ! [[ "$ARG" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]]; then
    print_error "'$ARG' is not a user name or an address."
    exit 1
fi
# One address or several, comma separated: 1Password shares to the list.
if [ -n "$TO" ]; then
    TO="${TO// /}"
    IFS=',' read -r -a TO_LIST <<< "$TO"
    for t in "${TO_LIST[@]}"; do
        [[ "$t" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && continue
        print_error "'$t' is not an e-mail address."
        exit 1
    done
    TO="$(IFS=,; printf '%s' "${TO_LIST[*]}")"
fi
# Who pressed Share, for the owner's notice only. Anything else is dropped.
[[ "$BY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || BY=""

if [ "$EUID" -ne 0 ]; then
    print_error "The store token is root-only."
    print_action "Run: sudo bash $0 $*"
    exit 1
fi

conf_get() {
    local key="$1" def="$2" v
    v="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
         | head -1 | cut -d= -f2-)"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$def}"
}

# A script installed to /usr/local/sbin has no siblings; the pipeline tree does.
_sib() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}
# The console's own copies, in /usr/local/sbin, before the pipeline tree's.
_tool() {
    [ -x "/usr/local/sbin/$1" ] && { printf "/usr/local/sbin/%s" "$1"; return; }
    _sib "$1"
}

BASE_DOMAIN="$(conf_get BASE_DOMAIN "$(hostname)")"
entry_name() { printf '%s on %s' "$1" "$BASE_DOMAIN"; }

# JSON for the console on --share and --share-mailbox; a line on stderr for
# everything else.
answer() {
    if [ "$MODE" = "--share" ] || [ "$MODE" = "--share-mailbox" ]; then
        jq -cn --arg e "$2" --arg to "${3:-}" '{ok: ($e == ""), error: $e, to: $to}'
    fi
    [ -n "$2" ] && print_error "$2"
    exit "$1"
}

SECRET_OPTIONAL=1 . "$(_sib secret_store.sh)" 2>/dev/null
if [ "$SECRET_READY" != "1" ]; then
    answer 3 "The secret store could not be loaded, so the 1Password entry was not changed."
fi

# The forge, for the repository links only. Optional on purpose: a machine that
# cannot reach it still writes every password in the entry, and the links are
# simply left out. No provider is named here, per project-context principle 2b.
REPO_HOST_OPTIONAL=1 . "$(_sib repo_host.sh)" 2>/dev/null || true
if [ "${REPO_HOST_READY:-0}" != "1" ]; then
    repo_https_url() { return 1; }
fi

# Every mailbox with its owner, `address<TAB>owner`. A mailbox belongs to
# whoever owns its DOMAIN, and its own Owner field is not read: index.php's
# ownership() and rowDomain(), the owner 2026-09-16. Keep the two in step.
#
# A DOMAIN NOBODY OWNS FALLS BACK TO THE ADMIN. The owner, 2026-09-20: "for now
# lets set missing to admin". Before this, every such mailbox belonged to
# nobody, so it reached no entry at all and the back-fill had nothing to do.
# It is a fallback, not a claim: the moment a row gives the domain an owner,
# that owner wins and --sync-owners moves the section across.
mailbox_owners() {
    awk -F'|' -v base="$(conf_get BASE_DOMAIN "")" -v known="$(conf_get DNS_DOMAINS '')" \
              -v admin="$(conf_get AUTH_ADMIN_USER admin)" '
        function tr(s) { gsub(/\r/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function row_domain(d,   w, i) {
            d = tr(d)
            if (d == "" || d == "-") return ""
            if (substr(d, 1, 1) != "=") return base
            w = substr(d, 2)
            for (i = 1; i <= nk; i++)
                if (w == k[i] || substr(w, length(w) - length(k[i])) == "." k[i]) return k[i]
            return w
        }
        BEGIN { n = split(known, raw, ","); for (i = 1; i <= n; i++) if (tr(raw[i]) != "") k[++nk] = tr(raw[i]) }
        /^[[:space:]]*#/ || !/\|/ || /^[[:space:]]*(PANEL|SHARE)[[:space:]]*=/ { next }
        tolower(tr($1)) == "mailbox" { d = tr($5); sub(/^=/, "", d); if (d == "" || d == "-") d = base
                                       box[tr($2) "@" d] = d; next }
        { who = tr($16); d = row_domain($5)
          if (who == "" || who == "-" || d == "" || d == base || (d in owner)) next
          owner[d] = who }
        END { for (a in box) print a "\t" ((box[a] in owner) ? owner[box[a]] : admin) }' "$SITES_CONF"
}

owned_mailboxes() { mailbox_owners | awk -F'\t' -v who="$1" '$2 == who { print $1 }' | sort; }
owner_of()        { mailbox_owners | awk -F'\t' -v a="$1" '$1 == a { print $2; exit }'; }

# One op call at a time per machine: set is read-modify-write, and two at once
# would drop one of the fields. In /run, which only root writes: /run/lock is
# world-writable, so a planted link there would be followed.
exec 9>/run/person-entry.lock
# A console save waits on this, and the 35 s that used to be promised here is
# no longer true: --login is three writes (login, links, repositories), each a
# four-attempt retry loop since Connect's writes started retrying, so a bad
# minute is minutes. The 15 s is what the WAITING caller gives up after, and
# that is the number a console save actually depends on.
flock -w 15 9 || answer 3 "Another 1Password update is still running."
export SECRET_TIMEOUT="${SECRET_TIMEOUT:-10}"

# The rows a person owns that name a repository, `name<TAB>repo` per line.
# Owner is read straight off the row here: a repository belongs to the row, not
# to a domain, so mailbox_owners' domain rule does not apply.
owned_repos() {  # <user>
    awk -F'|' -v who="$1" '
        function tr(s) { gsub(/\r/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^[[:space:]]*#/ || !/\|/ || /^[[:space:]]*(PANEL|SHARE)[[:space:]]*=/ { next }
        tolower(tr($1)) == "mailbox" { next }
        { r = tr($9)
          if (r == "" || r == "-" || tolower(r) == "new") next
          if (tr($16) != who) next
          print tr($2) "\t" r }' "$SITES_CONF" | sort -u
}

# Where the person's code lives. URL-typed, so 1Password renders a link rather
# than a string, and in a section rather than in the item's URL list: a
# repository is not signed into with the console password.
#
# The clone address is kept exactly as the row has it, ssh form included, and
# that one cannot be a link at all. It is there to copy.
put_repositories() {  # <entry> <user>
    local name repo https out=""
    while IFS=$'\t' read -r name repo; do
        [ -n "$name" ] && [ -n "$repo" ] || continue
        https="$(repo_https_url "$repo" 2>/dev/null)" || https=""
        [ -n "$https" ] && out="${out}$(printf '%s repo\turl\t%s' "$name" "${https%.git}")"$'\n'
        out="${out}$(printf '%s clone\ttext\t%s' "$name" "$repo")"$'\n'
    done < <(owned_repos "$2")
    [ -n "$out" ] || return 0
    printf '%s' "$out" | SECRET_ENTRY_REPLACE=replace secret_entry_set "$1" "$SEC_REPOS"
}

# THE ITEM'S URL LIST, which is the only thing 1Password matches on when it
# offers a login. The console first, because that is the login this entry
# holds.
#
# Webmail and the repositories are in the list too. The owner, 2026-09-20: a site
# several items match shows a PICKER, not the wrong password, "and that is part
# of the developer's life". The cost is that the picker on github.com grows by
# one line per customer.
#
# Replaced whole on every write, so a repository leaving a row leaves the list.
put_urls() {  # <entry> <user>
    local console addr url name repo https lines=""
    # Same fallback as notify_request.sh:100. With the key unset and no
    # fallback, the PRIMARY url silently became the webmail link instead.
    console="$(conf_get NOTIFY_CONSOLE_URL "https://admin.${BASE_DOMAIN}")"
    [ -n "$console" ] && lines="${lines}$(printf 'console\t%s' "$console")"$'\n'
    # No webmail: each mailbox is its own item with its own link since
    # 2026-09-26, so this entry offers the console and the code only.
    while IFS=$'\t' read -r name repo; do
        https="$(repo_https_url "$repo" 2>/dev/null)" || continue
        [ -n "$https" ] && lines="${lines}$(printf '%s\t%s' "$name" "${https%.git}")"$'\n'
    done < <(owned_repos "$2")
    [ -n "$lines" ] || return 0
    printf '%s' "$lines" | secret_entry_urls "$1"
}

# Everything an entry holds that is NOT a secret: the URL list in full, and
# every field by section and label with its value dropped. It exists so the
# entry can be checked without anything being able to print a password.
#
# The item is fetched ONCE and the status of that fetch is the function's own:
# "no such entry", "the store could not tell" and "an entry holding nothing"
# are three different answers, and a mode that exists to CHECK an entry may not
# print nothing and exit 0 for all three.
show_entry() {  # <entry>
    local item rc
    item="$(secret_entry_get "$1" --urls 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s\n' "$item" | awk -F'\t' 'NF { print "url\t" $1 "\t" $2 }'
    secret_entry_get "$1" 2>/dev/null \
        | awk -F'\t' '{ printf "field\t%s\t%s\n", ($1 == "" ? "(login)" : $1), $2 }' | sort -u
}

# A MAILBOX IS ITS OWN LOGIN ITEM, titled by its address, in the E-mail vault
# (the store routes a title holding an @ there). login-store-decisions.md,
# 2026-09-26: 1Password's suggestion list offers an item's own login only, so
# mailboxes kept as sections of a person's entry never showed on webmail.
#
#   login               the address and its password
#   URL list            its webmail, which is what autofill matches
#   Server settings     what to type into a mail app, read off the machine
#
# Whose it is follows from the domain (mailbox_owners) and is not stored: the
# item does not move when a domain changes hands.
put_mailbox_item() {  # <address> <password>
    printf 'username\ttext\t%s\npassword\tpassword\t%s\n' "$1" "$2" | secret_entry_set "$1" "" || return 2
    put_mailbox_extras "$1"
}

# The webmail link and the server settings, no password touched. 0 written or
# nothing to write, 1 no item, 2 the store refused. A missing settings tool is
# not an error: the password is what matters.
put_mailbox_extras() {  # <address>
    local j url
    j="$("$(_tool mail_client_settings.sh)" "$1" 2>/dev/null)" || return 0
    [ -n "$j" ] || return 0
    url="$(printf '%s' "$j" | jq -r '.webmail // empty')"
    if [ -n "$url" ]; then
        printf 'webmail\t%s\n' "$url" | secret_entry_urls "$1" || return $?
    fi
    printf '%s' "$j" | jq -r '
        ["incoming server", .imap.host], ["incoming port", .imap.port], ["incoming security", .imap.security],
        ["outgoing server", .smtp.host], ["outgoing port", .smtp.port], ["outgoing security", .smtp.security]
        | select(.[1] != null) | [.[0], "text", (.[1] | tostring)] | @tsv' \
    | SECRET_ENTRY_REPLACE=replace secret_entry_set "$1" "$SEC_SERVER" || return 2
}

# The password a mailbox item holds, on stdout. 0 found, 1 no item, 2 could
# not tell.
mailbox_password() {  # <address>
    local out rc
    out="$(secret_entry_get "$1" "" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s\n' "$out" | awk -F'\t' '$1 == "" && $2 == "password" { print $3; exit }'
}

# Sections still under the names used before 2026-09-26 get the numbered ones.
# 0 nothing left to rename, 2 the store refused.
relabel_sections() {  # <entry>
    local s pairs=""
    while IFS= read -r s; do
        case "$s" in
            "Mail settings")  pairs+="$s"$'\t'"$SEC_MAIL"$'\n' ;;
            "Recovery codes") pairs+="$s"$'\t'"$SEC_RECOVERY"$'\n' ;;
            "Repositories")   pairs+="$s"$'\t'"$SEC_REPOS"$'\n' ;;
            "Mailbox "*)      pairs+="$s"$'\t'"$SEC_MAILBOX ${s#Mailbox }"$'\n' ;;
        esac
    done < <(secret_entry_get "$1" 2>/dev/null | cut -f1 | sort -u)
    [ -n "$pairs" ] || return 0
    printf '%s' "$pairs" | secret_entry_relabel "$1" || return 2
}

# A username and a password, as one write to one section.
put_login() {  # <entry> <section> <username> <password>
    printf 'username\ttext\t%s\npassword\tpassword\t%s\n' "$3" "$4" | secret_entry_set "$1" "$2"
}

# -----------------------------------------------------------------------------
# Drift between the vault and the machine
#
# The machine keeps HASHES and the vault keeps PLAINTEXT, so the two cannot be
# diffed. They can be TESTED: fetch what the vault stores and try it against
# Dovecot's hash. That is what makes WRONG a fact rather than a suspicion.
#
# Why drift exists at all, now that set_mail_password.sh writes the entry on
# every change (Roundcube goes through it too, via mail_chpasswd.sh):
#   deleted    a mailbox removed from the config leaves its section behind
#   pre-vault  a mailbox that existed before the vault did was never written
#   moved      a domain changing owner leaves the section on the old person
#   by hand    doveadm, or a restored users file, bypasses every script here
#
# THE PASSWORD NEVER REACHES argv. It is piped to php, exactly as
# mail_chpasswd.sh does it, because `ps` is readable by every local account.
# -----------------------------------------------------------------------------
DOVECOT_USERS="${DOVECOT_USERS:-/etc/dovecot/users}"

# The crypt hash Dovecot holds for an address, without its {SCHEME} prefix.
dovecot_hash() {
    local h
    h="$(awk -F: -v a="$1" '$1 == a { print $2; exit }' "$DOVECOT_USERS" 2>/dev/null)"
    printf '%s' "${h#\{*\}}"
}

# 0 the password matches the hash, 1 it does not, 2 cannot tell.
# Password on stdin.
password_matches() {
    local hash="$1" pw
    [ -n "$hash" ] || return 2
    command -v php >/dev/null 2>&1 || return 2
    IFS= read -r pw || true
    [ -n "$pw" ] || return 1
    printf '%s\n%s\n' "$hash" "$pw" | php -r '
        $h = rtrim(fgets(STDIN), "\n");
        $p = rtrim(fgets(STDIN), "\n");
        exit(hash_equals($h, crypt($p, $h)) ? 0 : 1);'
}

# STATE<TAB>subject<TAB>owner<TAB>note, one line each, for report_drift.sh.
#
#   OK       the item's password is the one Dovecot accepts
#   MISSING  a mailbox row with no item
#   WRONG    an item whose password Dovecot refuses
#   NOBOX    an item for a row whose login the machine does not have
#   STALE    an item no mailbox row claims
#   UNKNOWN  the store did not answer
audit() {
    local a owner hash pw rc titles
    declare -A WANT=() OWNER_OF=()
    while IFS=$'\t' read -r a owner; do
        [ -n "$a" ] || continue
        WANT["$a"]=1
        OWNER_OF["$a"]="${owner:--}"
    done < <(mailbox_owners)

    for a in "${!WANT[@]}"; do
        owner="${OWNER_OF[$a]}"
        pw="$(mailbox_password "$a")"; rc=$?
        case "$rc" in
            1) printf 'MISSING\t%s\t%s\tno item in the E-mail vault, set the password once\n' "$a" "$owner"; continue ;;
            0) ;;
            *) printf 'UNKNOWN\t%s\t%s\tthe store did not answer for %s\n' "$a" "$owner" "$a"; continue ;;
        esac
        hash="$(dovecot_hash "$a")"
        if [ -z "$hash" ]; then
            printf 'NOBOX\t%s\t%s\tthe vault holds a password, the machine has no such login\n' "$a" "$owner"
            continue
        fi
        printf '%s\n' "$pw" | password_matches "$hash"
        case $? in
            0) printf 'OK\t%s\t%s\t\n' "$a" "$owner" ;;
            1) printf 'WRONG\t%s\t%s\tthe stored password is not the one the machine accepts\n' "$a" "$owner" ;;
            *) printf 'UNKNOWN\t%s\t%s\tno php here, so the password could not be tested\n' "$a" "$owner" ;;
        esac
    done

    # An item no row claims. Listed rather than guessed, so a vault that could
    # not be read says so instead of reading as "nothing stale".
    if titles="$(secret_entry_titles "probe@${BASE_DOMAIN}" 2>/dev/null)"; then
        while IFS= read -r a; do
            case "$a" in *@*) ;; *) continue ;; esac
            [ -n "${WANT[$a]:-}" ] && continue
            printf 'STALE\t%s\t-\tin the E-mail vault, but no mailbox row claims it\n' "$a"
        done <<< "$titles"
    else
        printf 'UNKNOWN\t-\t-\tthe E-mail vault could not be listed, so nothing stale was looked for\n'
    fi
}

# Mailbox sections a person's entry still holds from before 2026-09-26 become
# items, and then leave the entry with its mail settings, in one write. An
# item that already exists is kept: it is the newer of the two.
split_mail() {  # <user>
    local e s a pw drop="" rc=0
    e="$(entry_name "$1")"
    while IFS= read -r s; do
        case "$s" in
            "$SEC_MAILBOX "*) a="${s#"$SEC_MAILBOX "}" ;;
            "Mailbox "*)      a="${s#Mailbox }" ;;
            "$SEC_MAIL"|"Mail settings"|"Mail settings "*) drop+="$s"$'\n'; continue ;;
            *) continue ;;
        esac
        mailbox_password "$a" >/dev/null 2>&1
        case $? in
            0) ;;
            1) pw="$(secret_entry_get "$e" "$s" 2>/dev/null | awk -F'\t' '$1 == "password" { print $2; exit }')"
               if [ -z "$pw" ] || ! put_mailbox_item "$a" "$pw"; then
                   print_action "1Password: $a could not be made an item, so it stays in '$e'."
                   rc=2; continue
               fi
               print_success "1Password: $a is its own item now." ;;
            *) rc=2; continue ;;
        esac
        drop+="$s"$'\n'
    done < <(secret_entry_get "$e" 2>/dev/null | cut -f1 | sort -u)
    if [ -n "$drop" ]; then
        secret_entry_unset "$e" "$drop" || { print_action "1Password: the old mail sections stay in '$e' for now."; rc=2; }
    fi
    put_urls "$e" "$1" || true
    return "$rc"
}

# The link by mail, from here: `op` returns it and sends nothing.
send_link() {  # <to> <subject> <first line> <link>
    local sendmail from
    sendmail="$(command -v sendmail 2>/dev/null || echo /usr/sbin/sendmail)"
    from="$(conf_get NOTIFY_FROM "noreply@${BASE_DOMAIN}")"
    {
        printf 'From: %s\nTo: %s\nSubject: %s\n' "$from" "$1" "$2"
        printf 'Content-Type: text/plain; charset=utf-8\n\n'
        printf '%s\n\n%s\n\n' "$3" "$4"
        printf 'Only %s can open the link, and it expires in %s.\n' "$1" "${SECRET_SHARE_EXPIRES:-7d}"
    } | "$sendmail" -t -oi
}

send_notice() {  # <to> <subject> <text>
    local sendmail from
    sendmail="$(command -v sendmail 2>/dev/null || echo /usr/sbin/sendmail)"
    from="$(conf_get NOTIFY_FROM "noreply@${BASE_DOMAIN}")"
    {
        printf 'From: %s\nTo: %s\nSubject: %s\n' "$from" "$1" "$2"
        printf 'Content-Type: text/plain; charset=utf-8\n\n%s\n' "$3"
    } | "$sendmail" -t -oi
}

case "$MODE" in
    --login)
        IFS= read -r PW || true
        [ -n "$PW" ] || answer 1 "No password on stdin."
        E="$(entry_name "$ARG")"
        if put_login "$E" "" "$ARG" "$PW"; then
            print_success "1Password: login of '$ARG' kept in '$E'."
        else
            print_action "1Password: the login of '$ARG' was set here but NOT kept in the vault."
            exit 3
        fi
        # The links come after the password, never instead of it: a failure
        # here leaves a usable entry, so it is reported and not fatal.
        put_urls "$E" "$ARG" || print_action "1Password: the sign-in links of '$ARG' were not written."
        put_repositories "$E" "$ARG" || print_action "1Password: the repositories of '$ARG' were not written."
        exit 0
        ;;

    # The links alone, no password touched. Safe to re-run, and it is how an
    # entry written before the links existed catches up.
    --urls)
        E="$(entry_name "$ARG")"
        # 1 is "there is no entry to put links in", and that has a remedy worth
        # naming: secret_entry_urls edits an item, it cannot create one.
        put_urls "$E" "$ARG" || case $? in
            1) answer 1 "No 1Password entry for '$ARG' yet. Set their password once: sudo $0 --login $ARG" ;;
            *) answer 2 "1Password: the sign-in links of '$ARG' were not written." ;;
        esac
        put_repositories "$E" "$ARG" || answer 2 "1Password: the repositories of '$ARG' were not written."
        print_success "1Password: links of '$ARG' refreshed in '$E'."
        exit 0
        ;;

    # What the entry holds, minus every value. The point is that it can be run
    # by anything, including an assistant, without a password reaching a log.
    --show)
        show_entry "$(entry_name "$ARG")" \
            || answer 1 "'$ARG' has no entry in 1Password, or it could not be read."
        exit 0
        ;;

    # Does the entry hold a page password, as opposed to an empty field?
    #
    # A Login item ALWAYS shows a username and a password, so their presence
    # says nothing: on 2026-09-20 eight of nine entries listed both and held
    # neither. Only the LENGTH is tested and nothing is printed, so this cannot
    # be turned into a way to read the password.
    #
    # 0 it holds one, 1 it does not or there is no entry, 2 could not tell.
    --has-login)
        OUT="$(secret_entry_get "$(entry_name "$ARG")" "" 2>/dev/null)"; RC=$?
        [ "$RC" -eq 0 ] || exit "$RC"
        printf '%s\n' "$OUT" \
            | awk -F'\t' '$1 == "" && $2 == "password" && length($3) > 0 { found = 1 }
                          END { exit found ? 0 : 1 }'
        exit $?
        ;;

    # The mailbox's own item. Nobody's entry is touched: whose it is follows
    # from the domain and is not stored.
    --mailbox)
        IFS= read -r PW || true
        [ -n "$PW" ] || answer 1 "No password on stdin."
        if put_mailbox_item "$ARG" "$PW"; then
            print_success "1Password: $ARG kept in its own item."
        else
            print_action "1Password: the password of $ARG was set here but NOT kept in the vault."
            exit 3
        fi
        exit 0
        ;;


    # The codes are shown once by the console and then only their hashes are
    # kept, which in practice meant they were lost and `sudo console_otp` was
    # the real recovery path. The owner, 2026-09-20: put them in the entry.
    #
    # THE COST, said here because it is not obvious: the console password and
    # the second factor's fallback now sit behind ONE vault, so a vault
    # compromise is both factors. Against that, a code nobody can find is not a
    # second factor either. login-store-decisions.md.
    --recovery)
        CODES="$(cat)"
        [ -n "$CODES" ] || answer 1 "No recovery codes on stdin."
        E="$(entry_name "$ARG")"
        # REPLACE, not merge. secret_entry_set only adds and updates, so a
        # shorter set left the previous one's extra fields in place: after the
        # move from ten codes to a pair every entry still listed code 1 to
        # code 10 while only the first two worked.
        #
        # Unsetting first and setting after does NOT fix it, measured on seven
        # accounts 2026-09-20: the set re-reads an item the provider has not
        # caught up with and merges the ten back in. It has to be one write.
        if printf '%s\n' "$CODES" \
           | awk 'NF { printf "code %d\tpassword\t%s\n", ++n, $0 }' \
           | SECRET_ENTRY_REPLACE=replace secret_entry_set "$E" "$SEC_RECOVERY"; then
            print_success "1Password: recovery codes of '$ARG' kept in '$E'."
        else
            print_action "1Password: the recovery codes of '$ARG' were generated but NOT kept in the vault."
            exit 3
        fi
        exit 0
        ;;

    # Every console account's entry, old section names to numbered ones. Run
    # once after 2026-09-26; safe to re-run, it only renames what is left.
    --relabel)
        N=0; F=0
        while IFS= read -r U; do
            [ -n "$U" ] || continue
            if relabel_sections "$(entry_name "$U")"; then N=$((N + 1)); else F=$((F + 1)); fi
        done < <("$(_tool manage_auth_users.sh)" --list 2>/dev/null | jq -r '.users[]?.name // empty')
        print_success "1Password: sections renamed in $N entry/entries, $F refused."
        [ "$F" -eq 0 ]; exit $?
        ;;

    # Mailbox sections out of every account's entry into items of their own.
    # Run once after 2026-09-26; safe to re-run, it only moves what is left.
    --split-mail)
        N=0; F=0
        while IFS= read -r U; do
            [ -n "$U" ] || continue
            if split_mail "$U"; then N=$((N + 1)); else F=$((F + 1)); fi
        done < <("$(_tool manage_auth_users.sh)" --list 2>/dev/null | jq -r '.users[]?.name // empty')
        print_success "1Password: $N entry/entries checked, $F with something left."
        [ "$F" -eq 0 ]; exit $?
        ;;

    # The webmail link and server settings of every mailbox item, read off the
    # running machine. No password touched; a row with no item is skipped.
    --settings)
        N=0
        while IFS=$'\t' read -r A _O; do
            [ -n "$A" ] || continue
            put_mailbox_extras "$A" && N=$((N + 1))
        done < <(mailbox_owners)
        print_success "1Password: settings refreshed on $N mailbox item(s)."
        exit 0
        ;;

    # An item the machine no longer backs: no row claims it (STALE) or the
    # login is gone (NOBOX). Refuses anything the audit does not call stale, so
    # a live mailbox cannot be forgotten by passing its address.
    --forget-mailbox)
        FOUND=0; UNSURE=0
        while IFS=$'\t' read -r STATE A _O; do
            case "$STATE" in
                UNKNOWN)     UNSURE=1; continue ;;
                STALE|NOBOX) ;;
                *)           continue ;;
            esac
            [ "$A" = "$ARG" ] || continue
            FOUND=1
            secret_entry_delete "$A" || answer 2 "1Password: the item for $A could NOT be deleted."
            print_success "1Password: the item for $A was deleted."
        done < <(audit | cut -f1-3)
        [ "$FOUND" -eq 1 ] && exit 0
        [ "$UNSURE" -eq 0 ] \
            || answer 2 "1Password: the vault could not be read, so '$ARG' was left alone."
        print_info "1Password: nothing stale for '$ARG', so nothing was removed."
        exit 0
        ;;

    --audit)
        audit
        exit 0
        ;;

    # Kept for its callers. A mailbox item does not belong to a person's entry
    # any more, so there is nothing to move when a domain changes hands.
    --sync-owners)
        exit 0
        ;;
    --delete)
        secret_entry_delete "$(entry_name "$ARG")" || answer 0 "1Password: the entry of '$ARG' could not be deleted."
        print_success "1Password: entry of '$ARG' deleted."
        exit 0
        ;;

    # The person's own entry, nothing else: one press, one link. Mailboxes are
    # shared from their own row (--share-mailbox).
    --share)
        EMAIL="$("$(_tool manage_auth_users.sh)" --email-of "$ARG" 2>/dev/null)"
        [ -n "$EMAIL" ] || answer 1 "'$ARG' has no external e-mail address to share with."
        E="$(entry_name "$ARG")"
        put_urls "$E" "$ARG" || print_action "1Password: the sign-in links were not refreshed."
        put_repositories "$E" "$ARG" || print_action "1Password: the repositories were not refreshed."

        LINK="$(secret_entry_share "$E" "$EMAIL")"
        case $? in
            0) ;;
            1) answer 1 "'$ARG' has no entry in 1Password yet. Set their password once, then share." ;;
            *) answer 2 "1Password could not share the entry." ;;
        esac
        # Same wording as a mailbox share: nothing about what it unlocks.
        send_link "$EMAIL" "Credentials shared with you" \
            "Credentials were shared with you in 1Password:" "$LINK" \
            || answer 2 "The entry was shared, but the mail with the link could not be sent."
        print_success "Shared '$E' with $EMAIL."
        answer 0 "" "$EMAIL"
        ;;

    # One mailbox item to one address, which need not be the owner's: the
    # staff member who reads info@. The console asks for the address.
    --share-mailbox)
        put_mailbox_extras "$ARG" || true
        LINK="$(secret_entry_share "$ARG" "$TO")"
        case $? in
            0) ;;
            1) answer 1 "$ARG has no item in 1Password yet. Set its password once, then share." ;;
            *) answer 2 "1Password could not share $ARG." ;;
        esac
        for T in "${TO_LIST[@]}"; do
            # Nothing about which mailbox: a mail read on the way should not
            # say what it unlocks. The owner, 2026-09-26.
            send_link "$T" "Credentials shared with you" \
                "Credentials were shared with you in 1Password:" "$LINK" \
                || answer 2 "$ARG was shared, but the mail with the link could not be sent to $T."
        done
        print_success "Shared $ARG with $TO."

        # THE OWNER HEARS OF IT, whenever it went to someone else. The owner,
        # 2026-09-26: an owner must at least know who holds their mailbox's
        # login. No link in it: the notice is not a second share.
        OWNER="$(owner_of "$ARG")"
        OWNER_MAIL=""
        [ -n "$OWNER" ] && OWNER_MAIL="$("$(_tool manage_auth_users.sh)" --email-of "$OWNER" 2>/dev/null)"
        if [ -n "$OWNER_MAIL" ] && [ "${OWNER_MAIL,,}" != "${TO,,}" ]; then
            # Any recipient other than the owner, the owner among them or not.
            send_notice "$OWNER_MAIL" "Mailbox $ARG was shared" \
                "The 1Password login of your mailbox $ARG was shared with $TO by ${BY:-the console}." \
                || print_action "The owner, $OWNER, could not be told by mail."
        fi
        answer 0 "" "$TO"
        ;;
esac
