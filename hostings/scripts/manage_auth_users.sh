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
# The people who may sign in, and nothing else.
#
# One htpasswd file guards everything on this machine that asks for a password:
# the console itself, every machine page with `login yes`, every LAN preview,
# and every row whose AuthProtected names an environment. Until now it was
# edited by typing `htpasswd` on the machine, so adding somebody meant an SSH
# session and nobody could see who already had access.
#
#   manage_auth_users.sh --list
#   manage_auth_users.sh --add <user>          password on stdin
#   manage_auth_users.sh --password <user>     password on stdin
#   manage_auth_users.sh --self-password <user> the person's own, from the
#                                              forgot-password link; stdin
#   manage_auth_users.sh --disable <user>
#   manage_auth_users.sh --enable <user>
#   manage_auth_users.sh --delete <user>
#   manage_auth_users.sh --meta <user> <full|admin|none> [e-mail] [mailboxes]
#   manage_auth_users.sh --role-of <user>          one word on stdout
#   manage_auth_users.sh --email-of <user>         where the console code goes
#
# A CONSOLE ROLE NEEDS AN EXTERNAL ADDRESS. The console's second factor mails a
# code there, and a mailbox on this machine would make the box both factors.
# AUTH_ADMIN_USER is exempt: made by the installer, its code goes to CERT_EMAIL
# (console-2fa-decisions.md, decisions 10 and 12).
#
# WHO A PERSON IS LIVES IN A SIDE FILE, not in htpasswd. An htpasswd line is a
# name and a hash and nothing else, so there is nowhere in it to put an address
# or a role. AUTH_USER_META holds `name | e-mail | role | mailboxes`, keyed by the htpasswd
# name, and --delete drops both halves together.
#
# TWO ROLES AND NO THIRD. `full` is what admin means today: every tab, every
# row, and it approves what `admin` asks for. `admin` sees Applications,
# Websites and Mailboxes only, and only the rows assigned to it.
#
# AN ACCOUNT WITH NO LINE IS `admin`, which is the SMALLER set. A new account is
# assigned nothing, so it sees nothing, and forgetting to write the side file
# cannot produce an account with no limits. AUTH_ADMIN_USER is always `full`
# whatever the file says: it is the one account that can reach the page to fix
# the file.
#
# THE PASSWORD COMES DOWN STDIN, NEVER AS AN ARGUMENT. An argument is visible in
# `ps` to every account on this machine for as long as the process lives, which
# is how set_mail_password.sh does it and for the same reason.
#
# DISABLING IS NOT DELETING, and it is what the console offers first. A deleted
# user cannot be told apart from one who never existed, so the row that named
# them silently loses its access with nothing anywhere saying why. A disabled
# one keeps their line, keeps their hash, and simply cannot match any password:
# the hash is prefixed with `!`, which is not valid in any scheme Apache
# accepts, so every comparison fails. Removing the prefix puts them back with
# the password they had.
#
# WHAT IT REFUSES:
#   - deleting or disabling the admin account, which is the one that can reach
#     this page to undo it. Locking yourself out of the console with the console
#     is a mistake nobody recovers from through a browser.
#   - a username that is not [A-Za-z0-9._-], because it becomes a field in a
#     colon separated file and a config value read by five scripts.
#   - an empty password on --add or --password. add_dovecot.sh:670 refuses the
#     same thing for the same reason: an account with no password is one anybody
#     can try.
#
# Output is JSON on stdout for --list, so the page can read it without parsing
# prose. Everything else prints a line and sets an exit code.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

usage() {
    echo "Usage: $0 --list" >&2
    echo "       $0 --add|--password|--self-password <user>   (password on stdin)" >&2
    echo "       $0 --disable|--enable|--delete <user>" >&2
    echo "       $0 --meta <user> <full|admin|none> [e-mail] [mailboxes]" >&2
    echo "       $0 --role-of <user>" >&2
    echo "       $0 --email-of <user>" >&2
    echo "       $0 --role-holders" >&2
    exit 1
}

MODE="${1:-}"
USER_NAME="${2:-}"
[ -z "$MODE" ] && usage

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 $MODE ${USER_NAME}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/etc/hostings")"

conf_one() {
    local key="$1" def="$2" v
    v="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
         | head -1 | cut -d= -f2-)"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "${v:-$def}"
}


# How many mailboxes this person already owns. Counted from the config, which is
# the only place that knows: a mailbox row's sixteenth field names its owner.
#
# It is what stops an allowance being set below what somebody already has.
# The owner, 2026-09-10: lowering the number must never make existing addresses
# retroactively unauthorised, because nothing would then be able to fix it
# except deleting mail.
# The three DEFAULT addresses are free and are not counted. The owner, 2026-09-10:
# the allowance is for the extra ones somebody types, not for the ticks.
#
# That also settles a collision this hit: contact@ is mandatory on a new domain,
# so a customer creating a website always gets one, and counting it would have
# spent an allowance on an address they were never offered a choice about.
MAILBOX_FREE="info contact admin"

mailboxes_owned() {
    local who="$1"
    [ -z "$who" ] && { echo 0; return; }
    [ -f "$SITES_CONF" ] || { echo 0; return; }
    # One awk pass: two sed forks per line made --meta take 17 seconds.
    # The owner is field 16 onward, rejoined, as `read` gave the last variable.
    awk -F'|' -v who="$who" -v free=" $MAILBOX_FREE " '
        function tr(s) { gsub(/\r/, "", s); gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        {
            owner = $16
            for (i = 17; i <= NF; i++) owner = owner "|" $i
            if (tr($1) != "mailbox" || tr(owner) != who) next
            if (index(free, " " tr($2) " ")) next
            n++
        }
        END { print n + 0 }' "$SITES_CONF"
}

# The number an account gets when its line says nothing. Named once, here, and
# sent to the page by --list so the script and the console cannot disagree.
MAILBOX_DEFAULT=5
AUTH_FILE="$(conf_one AUTH_USER_FILE /etc/apache2/.htpasswd-progress)"
ADMIN_USER="$(conf_one AUTH_ADMIN_USER admin)"

# The side file that says who a person is and what they may do. Item 107.
# Keyed by the htpasswd name, one line each: name | e-mail | role | mailboxes.
META_FILE="$(conf_one AUTH_USER_META /etc/apache2/.htpasswd-progress.meta)"

# ROLE BASED ACCESS CONTROL, and the roles are the whole of it.
#
#   full   everything, and it answers what admin asks for
#   admin  Applications, Websites and Mailboxes, and only the rows they own
#   none   NO ACCESS AT ALL, and it is what an account with no line here is
#
# DENY BY DEFAULT. The owner, 2026-09-10, correcting the default this started
# with. `none` used to be treated as `admin` on the reasoning that it was the
# smaller set; that was still the wrong direction, because every account in the
# password file exists for a vhost, a preview or a share, and none of that
# should have been a console login.
#
# Ownership is a second thing layered on the roles and is NOT part of them: the
# role says which tabs and which verbs, the row's Owner field says which rows.
role_of() {
    local want="$1" line role
    # AUTH_ADMIN_USER is always full, whatever the side file says. It is the one
    # account that can reach the page to fix the side file.
    [ "$want" = "$ADMIN_USER" ] && { printf 'full'; return 0; }
    # Dots escaped: `c.rol` must not read carol's role.
    line="$(grep -E "^[[:space:]]*${want//./\\.}[[:space:]]*\|" "$META_FILE" 2>/dev/null | head -1)"
    role="$(printf '%s' "$line" | cut -d'|' -f3 | tr -d '\r' \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    # THREE ANSWERS, NOT TWO. The owner, 2026-09-10, correcting the default this
    # started with: an account with no line is `none` and may not sign in at
    # all, rather than being treated as a limited admin.
    #
    # The old default was chosen as "the smaller set". It was still the wrong
    # direction: it meant a password on this machine was a console login, and
    # every account here exists for a vhost, a preview or a share.
    case "$role" in
        full|admin) printf '%s' "$role" ;;
        *)          printf 'none' ;;
    esac
}

email_of() {
    local want="$1" mail
    mail="$(grep -E "^[[:space:]]*${want//./\\.}[[:space:]]*\|" "$META_FILE" 2>/dev/null | head -1 \
            | cut -d'|' -f2 | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$mail" ] && [ "$want" = "$ADMIN_USER" ] && mail="$(conf_one CERT_EMAIL '')"
    # Also checked on read: a line written before the rule existed must not
    # make this box both factors.
    is_local_address "$mail" && mail=""
    printf '%s' "$mail"
}

# True when the address is on a domain this machine controls, subdomains and a
# trailing dot included.
is_local_address() {
    local dom d
    dom="$(printf '%s' "${1##*@}" | tr '[:upper:]' '[:lower:]')"
    dom="${dom%.}"
    [ -z "$dom" ] && return 1
    while IFS= read -r d; do
        case "$dom" in "$d"|*".$d") return 0 ;; esac
    done < <(local_domains)
    return 1
}

# Every domain this machine answers mail for or controls, lower case, one per
# line: the DNS zones and every mailbox row's domain.
local_domains() {
    {
        printf '%s,%s\n' "$(conf_one DNS_DOMAINS '')" "$(conf_one DEPRECATED_DOMAINS '')" | tr ',' '\n'
        awk -F'|' 'function tr(s){gsub(/\r/,"",s);gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
                   tr($1)=="mailbox"{print tr($5)}' "$SITES_CONF" 2>/dev/null
    } | tr -d ' \t\r' | tr '[:upper:]' '[:lower:]' | grep -v '^$' | sort -u
}

# Rewrites the whole file rather than editing a line in place, because a name
# that is not there yet has no line to edit and both cases then take one path.
meta_write() {
    local want="$1" mail="$2" role="$3" boxes="$4" tmp
    tmp="$(mktemp)"
    {
        echo "# Written by manage_auth_users.sh. One line per account:"
        echo "#   name | e-mail | role | mailboxes    role is full, admin or none"
        echo "#   mailboxes is how many this person may have. A dash means the default."
        if [ -f "$META_FILE" ]; then
            grep -vE "^[[:space:]]*${want//./\\.}[[:space:]]*\|" "$META_FILE" 2>/dev/null \
                | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' || true
        fi
        printf '%s | %s | %s | %s\n' "$want" "$mail" "$role" "${boxes:--}"
    } > "$tmp"
    mv "$tmp" "$META_FILE"
    chown root:www-data "$META_FILE" 2>/dev/null || true
    chmod 0640 "$META_FILE"
}

meta_drop() {
    [ -f "$META_FILE" ] || return 0
    sed -i "/^[[:space:]]*${1//./\\.}[[:space:]]*|/d" "$META_FILE"
}

# -----------------------------------------------------------------------------
# --list: who exists, whether they are switched off, and what names them.
#
# The rows are what makes this worth reading: an account nothing refers to is a
# password that opens nothing, and one named by four rows is not a name to
# delete without looking.
# -----------------------------------------------------------------------------
if [ "$MODE" = "--list" ]; then
    if [ ! -f "$AUTH_FILE" ]; then
        echo '{"users":[],"file":null}'
        exit 0
    fi
    # AuthUsers is the LAST field of a row, and AuthProtected the eighth. A name
    # appearing in either is a name in use. Both are comma separated and may
    # carry env:user pairs, so the match is on the word, not on the field.
    python3 - "$AUTH_FILE" "$SITES_CONF" "$ADMIN_USER" "$META_FILE" "$MAILBOX_DEFAULT" "$(email_of "$ADMIN_USER")" <<'PY' 2>/dev/null || echo '{"users":[],"file":null}'
import json, re, sys

auth_file, conf_file, admin, meta_file = sys.argv[1:5]
DEFAULT = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5].isdigit() else 5
# The admin's address as email_of finds it, fallback included, so the page and
# --email-of never disagree.
ADMIN_MAIL = sys.argv[6] if len(sys.argv) > 6 else ""

users = []
try:
    with open(auth_file, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\r\n")
            if not line or line.startswith("#") or ":" not in line:
                continue
            name, _, hashed = line.partition(":")
            users.append({
                "name": name,
                # A hash that begins with ! can never match: that is how this
                # script switches somebody off without losing their password.
                "enabled": not hashed.startswith("!"),
            })
except OSError:
    print(json.dumps({"users": [], "file": None}))
    sys.exit(0)

# Which rows name each user. Read as words so env:user pairs match too.
named = {}

# Who each person is and what they may do, out of the side file. A name with no
# line here is `admin`, the limited role: assigned nothing, so it sees nothing.
meta = {}
try:
    with open(meta_file, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "|" not in line:
                continue
            parts = [p.strip() for p in line.split("|")]
            name = parts[0]
            mail = parts[1] if len(parts) > 1 else ""
            role  = parts[2] if len(parts) > 2 else ""
            boxes = parts[3] if len(parts) > 3 else ""
            meta[name] = {
                "email": mail,
                "role": role if role in ("full", "admin") else "none",
                # A dash or anything unreadable means the default, named once
                # below rather than copied onto every line.
                "mailboxes": int(boxes) if boxes.isdigit() else None,
            }
except OSError:
    pass
try:
    with open(conf_file, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.lstrip().startswith("#") or "|" not in line:
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 2:
                continue
            row = parts[1]
            blob = " ".join(parts[7:])
            for w in re.split(r"[,\s:]+", blob):
                if w:
                    named.setdefault(w, set()).add(row)
except OSError:
    pass

for u in users:
    u["rows"] = sorted(named.get(u["name"], []))
    u["admin"] = (u["name"] == admin)
    m = meta.get(u["name"], {})
    u["email"] = m.get("email", "") or (ADMIN_MAIL if u["admin"] else "")
    # How many mailboxes this person may have. None means the default.
    u["mailboxes"] = m.get("mailboxes")
    # The admin account is always full, whatever the side file says: it is the
    # one account that can reach this page to fix the side file.
    u["role"]  = "full" if u["admin"] else m.get("role", "none")

# The default, named ONCE and sent to the page, so the number lives in one
# place rather than in the script, the page and a comment.
print(json.dumps({"users": users, "file": auth_file, "mailbox_default": DEFAULT}))
PY
    exit 0
fi


# Every name that holds a role, space separated, for an Apache `Require user`
# line. The HARD GATE: a roleless account is refused before it ever reaches
# index.php, which refuses it again for the case where a role was taken away
# and Apache has not been rewritten yet.
#
# AUTH_ADMIN_USER is always in it, whatever the side file says, so a broken or
# missing side file cannot lock the operator out of the page that fixes it.
# That is the one place where failing OPEN is right, and it opens to exactly
# one account.
#
# Above the name check, like --list: it names nobody.
role_holders() {
    local _n _m _r _b
    HOLDERS="$ADMIN_USER"
    if [ -f "$META_FILE" ]; then
        # FOUR variables, not three. The last one absorbs everything after it,
        # so reading three made the role read "admin | 3" the moment the
        # mailbox column existed, and every customer silently dropped out of
        # Require user. Same shape as the Enabled trap in the row parsers, and
        # found the same day: a customer got 401 at a door they had passed
        # through an hour earlier.
        while IFS='|' read -r _n _m _r _b; do
            _n="$(printf '%s' "$_n" | tr -d '\r' | xargs)"
            _r="$(printf '%s' "$_r" | tr -d '\r' | xargs)"
            case "$_n" in ''|\#*) continue ;; esac
            [ "$_n" = "$ADMIN_USER" ] && continue
            case "$_r" in full|admin) HOLDERS="$HOLDERS $_n" ;; esac
        done < "$META_FILE"
    fi
    echo "$HOLDERS"
}

# THE DOORS FOLLOW THE ROLES AT ONCE. The owner, 2026-09-18: a new full admin got
# 401 at the console, because only its installer and the apply wrote this line.
# Every vhost carrying the role holders is rewritten, tested, and reloaded;
# a failing configtest puts the files back rather than leave Apache broken.
refresh_doors() {
    local holders f out rc=0 bak
    local changed=()
    holders="$(role_holders)"
    # Only names that can be written into a config line: a hand-edited side
    # file or AUTH_ADMIN_USER must not reach sed or Apache as anything else.
    case "$holders" in
        *[!A-Za-z0-9._\ -]*)
            print_error "The sign-in list holds a name that is not a username, so the doors were not rewritten: ${holders}"
            return 1 ;;
    esac
    exec 9>/run/manage_auth_users.lock
    flock -w 30 9 || { print_error "Another change to the sign-in list is still running."; return 1; }
    bak="$(mktemp -d)"
    # Each of these files carries exactly one `Require user`, the role holders
    # line (add_hosting_manager.sh, add_admin_vhosts.sh).
    for f in /etc/apache2/sites-available/hosting-manager.conf /etc/apache2/sites-available/admin-*.conf; do
        [ -f "$f" ] || continue
        grep -q "^[[:space:]]*Require user " "$f" || continue
        grep -qx "[[:space:]]*Require user ${holders}" "$f" && continue
        cp -p "$f" "$bak/" && sed -i "s/^\([[:space:]]*Require user \).*/\1${holders}/" "$f" || rc=1
        changed+=("$f")
    done
    if [ "${#changed[@]}" -gt 0 ]; then
        if [ "$rc" = 0 ] && out="$(apache2ctl configtest 2>&1)" && systemctl reload apache2; then
            print_info "The console now lets in: ${holders}."
        else
            for f in "${changed[@]}"; do cp -p "$bak/${f##*/}" "$f" || true; done
            print_error "Apache refused the new sign-in list, so the old one was kept. The role IS saved: fix Apache, then save the role again."
            [ -n "${out:-}" ] && printf '%s\n' "$out" | tail -5
            rc=1
        fi
    fi
    rm -rf "$bak"
    flock -u 9
    return "$rc"
}

if [ "$MODE" = "--role-holders" ]; then
    role_holders
    exit 0
fi
# Everything below changes something, so the name is checked first.
[ -z "$USER_NAME" ] && usage
case "$USER_NAME" in
    *[!A-Za-z0-9._-]*|'')
        print_error "'$USER_NAME' is not a username. Letters, digits, dot, underscore and hyphen only."
        exit 1
        ;;
esac

# --add creates the file, and --meta and --role-of do not read it at all: the
# side file is keyed by name, not by a line in this one.
if [ ! -f "$AUTH_FILE" ] && [ "$MODE" != "--add" ] \
                        && [ "$MODE" != "--meta" ] && [ "$MODE" != "--role-of" ] && [ "$MODE" != "--email-of" ]; then
    print_error "No password file at $AUTH_FILE, so there is nobody to change."
    exit 1
fi

# The name as a pattern. A dot is legal in a name and matches anything in a
# regex, so `.....` would otherwise match, and delete, `admin`.
NAME_RE="${USER_NAME//./\\.}"
user_line() { grep -n "^${NAME_RE}:" "$AUTH_FILE" 2>/dev/null | head -1; }

case "$MODE" in
    --meta)
        # Who this person is and what they may do. The name has already been
        # checked above; the role and the address are checked here.
        #
        # It does NOT require the account to exist. A line for a name nothing
        # can sign in as is harmless and readable; the reverse, an account with
        # no line, is the safe default anyway.
        META_ROLE="${3:-}"
        META_MAIL="${4:-}"
        case "$META_ROLE" in
            full|admin|none) ;;
            *) print_error "'$META_ROLE' is not a role. It is 'full', 'admin' or 'none'."
               exit 1 ;;
        esac
        # A dash means deliberately none, so clearing an address is possible.
        if [ "$META_MAIL" = "-" ]; then
            META_MAIL=""
        elif [ -n "$META_MAIL" ]; then
            case "$META_MAIL" in
                # No pipe: it is the field separator. No space, no comment
                # marker, and it has to look like an address at all.
                *[\|\ \#]*|*[[:cntrl:]]*|*@*@*) print_error "'$META_MAIL' is not an e-mail address."; exit 1 ;;
                ?*@?*.?*) ;;
                *) print_error "'$META_MAIL' is not an e-mail address."; exit 1 ;;
            esac
        fi
        if [ "$USER_NAME" != "$ADMIN_USER" ] && [ "$META_ROLE" != "none" ]; then
            if [ -z "$META_MAIL" ]; then
                print_error "'$USER_NAME' needs an e-mail address to be $META_ROLE: the console mails its sign-in code there."
                exit 1
            fi
            if is_local_address "$META_MAIL"; then
                print_error "'$META_MAIL' is a mailbox on this machine. The console code must go to an address elsewhere."
                print_info "Otherwise this machine would be both the password and the code."
                exit 1
            fi
        fi
        if [ "$USER_NAME" = "$ADMIN_USER" ] && [ "$META_ROLE" != "full" ]; then
            print_error "'$USER_NAME' is the admin account, so it is always 'full'."
            print_info "It is the account that can reach this page to undo the change."
            exit 1
        fi
        # A role of none is a LINE saying none, not a missing line. Both mean
        # no access; a line says somebody decided it.
        # How many mailboxes this person may have. The owner, 2026-09-10: he
        # cancelled a fixed cap of 5 and made it a number per user, so one
        # customer can have two and another twenty.
        #
        # How many mailboxes this person may have. The owner, 2026-09-10: a number
        # per user rather than one cap for everybody, and it is the point at
        # which a REQUEST is filed rather than the point at which a refusal
        # happens.
        #
        # A dash means "the default", and it is written out as the NUMBER on
        # save: his call, so the file says what somebody actually has rather
        # than deferring to a figure that may move under them.
        META_BOXES="${5:--}"
        case "$META_BOXES" in
            -|'') META_BOXES="$MAILBOX_DEFAULT" ;;
            *[!0-9]*) print_error "'$META_BOXES' is not a number of mailboxes."
                      exit 1 ;;
        esac
        # NEVER BELOW WHAT THEY ALREADY HAVE. Lowering it past that would make
        # existing addresses retroactively unauthorised, and nothing could then
        # put it right except deleting somebody's mail.
        _HAVE="$(mailboxes_owned "$USER_NAME")"
        if [ "$META_BOXES" -lt "$_HAVE" ]; then
            print_error "'$USER_NAME' already has $_HAVE mailboxes, so the number cannot be $META_BOXES."
            print_info "Delete the addresses first, or set it to $_HAVE or more."
            exit 1
        fi
        meta_write "$USER_NAME" "$META_MAIL" "$META_ROLE" "$META_BOXES"
        refresh_doors || exit 1
        print_success "'$USER_NAME' is $META_ROLE${META_MAIL:+, at $META_MAIL}$([ "$META_BOXES" = "-" ] || echo ", $META_BOXES mailboxes")."
        exit 0
        ;;

    --role-of)
        # One word on stdout, for anything that has to decide what somebody may
        # do. Never fails: a name with no line is 'admin', the limited role.
        role_of "$USER_NAME"
        echo
        exit 0
        ;;

    --email-of)
        # Empty output and exit 0 for nobody: the page reads empty as "no code
        # can be sent" and says so.
        email_of "$USER_NAME"
        echo
        exit 0
        ;;

    --add|--password|--self-password)
        # stdin, never an argument. See the header.
        IFS= read -r PW || true
        if [ -z "$PW" ]; then
            print_error "No password was given, so nothing was changed."
            print_info "An account with no password is one anybody can try."
            exit 1
        fi
        if [ "$MODE" = "--add" ] && [ -n "$(user_line)" ]; then
            print_error "'$USER_NAME' already exists. Use --password to change it."
            exit 1
        fi
        if [ "$MODE" != "--add" ] && [ -z "$(user_line)" ]; then
            print_error "'$USER_NAME' does not exist, so there is no password to change."
            exit 1
        fi
        # The link must not re-enable a switched-off account, since htpasswd
        # replaces the whole line, nor reach an account that is no console login.
        if [ "$MODE" = "--self-password" ]; then
            if grep -q "^${NAME_RE}:!" "$AUTH_FILE"; then
                print_error "'$USER_NAME' is switched off, so its password cannot be set by link."
                exit 1
            fi
            case " $(role_holders) " in
                *" $USER_NAME "*) ;;
                *) print_error "'$USER_NAME' holds no console role, so its password cannot be set by link."
                   exit 1 ;;
            esac
        fi
        # -i reads the password from stdin, -B is bcrypt. The file is created
        # with -c only when it does not exist: -c on an existing file TRUNCATES
        # it, which would delete every other account on the machine.
        if [ -f "$AUTH_FILE" ]; then
            printf '%s' "$PW" | htpasswd -i -B "$AUTH_FILE" "$USER_NAME" >/dev/null 2>&1
        else
            printf '%s' "$PW" | htpasswd -i -c -B "$AUTH_FILE" "$USER_NAME" >/dev/null 2>&1
            chown root:www-data "$AUTH_FILE"
            chmod 0640 "$AUTH_FILE"
        fi
        print_success "$([ "$MODE" = "--add" ] && echo "Added" || echo "Changed the password for") '$USER_NAME'."
        # Their 1Password entry gets it now: after this only the hash exists.
        # A password the person chose is theirs alone: the entry says when, not
        # what. login-store-decisions.md, open question 5.
        [ "$MODE" = "--self-password" ] && PW="set by the user on $(date +%F)"
        PERSON_ENTRY=/usr/local/sbin/person_entry.sh
        [ -f "$PERSON_ENTRY" ] || PERSON_ENTRY="$SCRIPT_DIR/person_entry.sh"
        if [ -f "$PERSON_ENTRY" ]; then
            printf '%s\n' "$PW" | SITES_CONF="$SITES_CONF" bash "$PERSON_ENTRY" --login "$USER_NAME" || true
        fi
        exit 0
        ;;

    --disable|--delete)
        if [ "$USER_NAME" = "$ADMIN_USER" ]; then
            print_error "'$USER_NAME' is the admin account, so it cannot be $([ "$MODE" = "--delete" ] && echo removed || echo switched off) from here."
            print_info "It is the account that can reach this page to undo the change."
            exit 1
        fi
        if [ -z "$(user_line)" ]; then
            print_error "'$USER_NAME' is not in $AUTH_FILE, so nothing was changed."
            exit 1
        fi
        if [ "$MODE" = "--delete" ]; then
            sed -i "/^${NAME_RE}:/d" "$AUTH_FILE"
            # The side file goes with them. A line left behind is a role and an
            # address for a name nothing can sign in as.
            meta_drop "$USER_NAME"
            # And their 1Password entry: it holds a login that no longer works.
            PERSON_ENTRY=/usr/local/sbin/person_entry.sh
            [ -f "$PERSON_ENTRY" ] || PERSON_ENTRY="$SCRIPT_DIR/person_entry.sh"
            [ -f "$PERSON_ENTRY" ] && { SITES_CONF="$SITES_CONF" bash "$PERSON_ENTRY" --delete "$USER_NAME" || true; }
            # And their second-factor state. Found 2026-09-20: a day of
            # throwaway accounts left twelve .recovery files behind, so a name
            # created again would have inherited the deleted account's codes.
            # The .<pid> forms are the half-written temporaries second_factor.php
            # renames over; one is left behind whenever a rename fails. The name
            # is validated above, so the glob cannot reach outside this folder.
            TFA_DIR_LOCAL="/var/lib/hosting-manager/2fa"
            rm -f "${TFA_DIR_LOCAL}/${USER_NAME}.recovery" "${TFA_DIR_LOCAL}/${USER_NAME}.code" \
                  "${TFA_DIR_LOCAL}/${USER_NAME}.recovery."* "${TFA_DIR_LOCAL}/${USER_NAME}.code."*
            refresh_doors || exit 1
            print_success "Deleted '$USER_NAME'."
            print_info "Any row still naming them now refuses them, with nothing saying why."
        else
            # Prefix the HASH, not the name: the line stays findable and the
            # password survives, and no scheme Apache accepts starts with !.
            sed -i "s/^\(${NAME_RE}:\)\([^!]\)/\1!\2/" "$AUTH_FILE"
            print_success "Switched '$USER_NAME' off. Their password is kept."
        fi
        exit 0
        ;;

    --enable)
        if [ -z "$(user_line)" ]; then
            print_error "'$USER_NAME' is not in $AUTH_FILE, so there is nothing to switch on."
            exit 1
        fi
        sed -i "s/^\(${NAME_RE}:\)!/\1/" "$AUTH_FILE"
        print_success "Switched '$USER_NAME' back on, with the password they had."
        exit 0
        ;;

    *)
        print_error "'$MODE' is not something this script does."
        usage
        ;;
esac
