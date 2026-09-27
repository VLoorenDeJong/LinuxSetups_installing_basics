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
# Telling somebody a request happened. Item 106.
#
#   notify_request.sh <id> filed       every full access admin hears about it
#   notify_request.sh <id> answered    the requester hears what was said back
#
# A SEPARATE SCRIPT, not a function inside manage_requests.sh, for one reason:
# when no mail arrives this can be run by hand against the same request and
# made to say why. A branch buried inside another script cannot be.
#
# IT NEVER FAILS ITS CALLER. manage_requests.sh calls it after the answer is
# already written, and a mail server that is down must not make a decline look
# like it did not happen. Every failure here is a printed line and exit 0.
#
# THE ADDRESSES COME FROM THE SIDE FILE, AUTH_USER_META, which is where item
# 107 put them: name | e-mail | role | mailboxes. Nothing is derived from a
# username, because an account name is not an address and guessing one sends
# somebody else's decline to whoever owns that mailbox.
#
# THE SENDER IS A REAL NAME ON A REAL DOMAIN. noreply@<BASE_DOMAIN>, because
# DKIM signs per domain and example.com already answers dkim=pass from a real
# receiver (item 93). An invented domain like machine.server fails DKIM, SPF
# and DMARC at once, which is how a notification becomes junk nobody sees.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

usage() {
    echo "Usage: $0 <request-id> filed" >&2
    echo "       $0 <request-id> answered" >&2
    exit 1
}

ID="${1:-}"
EVENT="${2:-}"
if [ -z "$ID" ] || [ -z "$EVENT" ]; then usage; fi
case "$EVENT" in
    filed|answered) ;;
    *) print_error "'$EVENT' is not an event this sends mail about."; usage ;;
esac
case "$ID" in
    ''|*[!A-Za-z0-9._-]*) print_error "'$ID' is not a request."; exit 1 ;;
esac

if [ "$EUID" -ne 0 ]; then
    print_error "This reads the request store and the user side file, so it needs root."
    print_action "Run with: sudo $0 $ID $EVENT"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/var/lib/hosting-manager/config-repo/backup_config")"

conf_one() {
    local key="$1" def="$2" v
    v="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
         | head -1 | cut -d= -f2-)"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "${v:-$def}"
}

REQ_DIR="${REQ_DIR:-/var/lib/hosting-manager/requests}"
REQ_FILE="$REQ_DIR/$ID.json"
[ -f "$REQ_FILE" ] || { print_error "No request $ID."; exit 1; }

BASE_DOMAIN="$(conf_one BASE_DOMAIN '')"
META_FILE="$(conf_one AUTH_USER_META /etc/apache2/.htpasswd-progress.meta)"
ADMIN_USER="$(conf_one AUTH_ADMIN_USER admin)"

# Both the From and the Reply-To live in the config, so the drive swap changes
# one line rather than a string inside a script.
NOTIFY_FROM="$(conf_one NOTIFY_FROM "noreply@${BASE_DOMAIN}")"
NOTIFY_REPLY_TO="$(conf_one NOTIFY_REPLY_TO '')"
# Where the link in the mail points. The console's LAN port is not it: a mail is
# read from a phone as often as from the desk.
NOTIFY_CONSOLE_URL="$(conf_one NOTIFY_CONSOLE_URL "https://admin.${BASE_DOMAIN}")"
# Who hears about a request when no full access admin has an address yet. The
# certificate expiry warnings already go there, so it is an address somebody
# reads.
NOTIFY_FALLBACK="$(conf_one NOTIFY_FALLBACK "$(conf_one CERT_EMAIL '')")"
# Where a person looks a domain up by hand when this machine could not.
DOMAIN_CHECK_URL="$(conf_one DOMAIN_CHECK_URL 'https://domainr.com/%s')"
# Where it is registered once the answer is yes, asked of the DNS service. Admin
# side only. No provider, no line in the mail.
DNS_IFACE="$SCRIPT_DIR/dns.sh"
[ -f "$DNS_IFACE" ] || DNS_IFACE=/usr/local/lib/linuxbasics/hostings/scripts/dns.sh
DOMAIN_ORDER_URL="$(export SITES_CONF DNS_OPTIONAL=1
    . "$DNS_IFACE" >/dev/null 2>&1 && [ "$DNS_READY" = 1 ] && dns_register_url 2>/dev/null)" \
    || DOMAIN_ORDER_URL=""

SENDMAIL="$(command -v sendmail 2>/dev/null || true)"
[ -n "$SENDMAIL" ] || SENDMAIL=/usr/sbin/sendmail
if [ ! -x "$SENDMAIL" ]; then
    print_action "No sendmail on this machine, so nobody was told about $ID."
    print_info "Postfix provides it: sudo apt-get install -y postfix"
    exit 0
fi

# set +e around it deliberately: this script never fails its caller, so the
# exit code is read rather than allowed to kill the run.
set +e
SENT="$(python3 - "$REQ_FILE" "$EVENT" "$META_FILE" "$ADMIN_USER" "$NOTIFY_FROM" \
                 "$NOTIFY_REPLY_TO" "$NOTIFY_CONSOLE_URL" "$NOTIFY_FALLBACK" "$SENDMAIL" \
                 "$BASE_DOMAIN" "$DOMAIN_CHECK_URL" "$DOMAIN_ORDER_URL" <<'PY'
import json, subprocess, sys, time
from urllib.parse import quote
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

(req_path, event, meta_path, admin_user, sender,
 reply_to, console_url, fallback, sendmail, base_domain, domain_check_url,
 domain_order_url) = sys.argv[1:13]

with open(req_path, "r", encoding="utf-8") as fh:
    r = json.load(fh)

# name -> (e-mail, role). A name with no line here has no role and no address,
# which is the deny by default item 105 settled.
meta = {}
try:
    with open(meta_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "|" not in line:
                continue
            p = [x.strip() for x in line.split("|")]
            meta[p[0]] = (p[1] if len(p) > 1 else "",
                          p[2] if len(p) > 2 else "")
except OSError:
    pass


def address(name):
    return meta.get(name, ("", ""))[0].strip()


who = str(r.get("by", ""))
row = r.get("row") or {}
name = str(row.get("name", "")).strip()
kind = str(row.get("type", "")).strip() or "row"
state = str(r.get("state", ""))
link = console_url.rstrip("/") + "/#req-" + str(r.get("id", ""))

# WHAT WAS ASKED FOR, AS LABEL AND VALUE. The owner, 2026-09-11: a sentence makes
# him read it to find the three things that matter. A list does not.
#
#   Type:      Website
#   Domain:    brochure.example.com
#   Repo name: www_brochure
#
# The value is what is being looked for, so in the HTML part it is the bold
# half. The plain part carries the same pairs, because a reader whose client
# shows text only must not get less.
KINDS = {"app": "Application", "website": "Website", "mailbox": "E-mail",
         "proxy": "Forwarded", "panel": "Machine page"}

# The label a request field is read under. Only what a requester can ask for is
# here: a key nobody can send is a row that never renders.
LABELS = [
    ("path", "Path"),
    ("applicationOptionsOverwrite", "App settings"),
    ("authProtected", "Login"),
    ("repository", "Repository"),
    ("branch", "Source branch"),
    ("envs", "Environments"),
    ("repoMode", "Repository mode"),
    ("runtime", "Application type"),
    ("enabled", "Enabled"),
]


def hostname_of(sub, base):
    # The config's spelling turned into the address a person recognises: `=x.nl`
    # is a whole domain, `@` is the base itself, anything else is a label under
    # it. Sending the raw field would print "=example.com" at somebody.
    sub = str(sub or "").strip()
    if not sub or sub == "-":
        return ""
    if sub.startswith("="):
        return sub[1:]
    if sub == "@":
        return base
    return sub + "." + base if base else sub


def asked_pairs():
    # Who, in the block rather than only in the sentence above it. The owner,
    # 2026-09-11: the name is one of the values being scanned for, so it belongs
    # where the eye already is.
    # Read first: the Domain line below is suppressed when there is one.
    want_dom = str(row.get("domainRequest", "") or "").strip()
    out = [("Who", who or "?"),
           ("Type", KINDS.get(kind, kind or "?"))]
    # Why sits directly under Type rather than below the block. The owner,
    # 2026-09-11: the one line that explains the request belongs inside the part
    # being scanned, not after it.
    why = str(r.get("comment", "")).strip()
    if why:
        out.append(("Why", why))
    if kind == "mailbox":
        if name:
            out.append(("Address", name + "@"
                        + (hostname_of(row.get("subdomain"), base_domain) or base_domain)))
        # Said plainly, because only the owner can supply one and the mailbox
        # does not answer until they do.
        out.append(("Password", "not supplied"))
    else:
        # The domain request below already names the domain, so printing the
        # row's own one as well gave two Domain lines that can disagree. The
        # drawer suppresses it; this did not, which Outlook showed on
        # 2026-09-11.
        host = "" if want_dom else hostname_of(row.get("subdomain"), base_domain)
        if host:
            out.append(("Domain", host))
        if name:
            out.append(("Repo name", name))
    # A domain nobody owns yet, and the two separate answers about it. The tick
    # is the requester's claim, the check is this machine asking TransIP; the
    # person placing the order decides whether they agree, so both are shown
    # with their dates rather than merged into one verdict.
    if want_dom:
        out.append(("Domain requested", want_dom))
        # ONE LINE, NOT TWO. The owner, 2026-09-11: a domain that is not available
        # cannot be asked for at all now, so the request existing IS the answer
        # to "is it free". The date is what remains worth knowing, because an
        # answer from last month is not an answer.
        st = str(row.get("domainChecked", "") or "")
        when = int(row.get("domainCheckedAt") or 0)
        if when and st != "unknown":
            out.append(("Availability checked",
                        time.strftime("%d-%m-%Y %H:%M", time.localtime(when))))
        else:
            # The one case worth saying out loud: TransIP could not be reached,
            # so this one came through unchecked.
            out.append(("Availability checked", "could not check"))
        # A way to look it up by hand, which is the whole point when the answer
        # above is "could not check". The owner, 2026-09-11.
        #
        # %s is where the domain goes; a URL without one is used as it stands,
        # because TransIP's own checker cannot be prefilled and pasting the name
        # onto the end of it produces a 404.
        if domain_check_url:
            out.append(("Look it up",
                        domain_check_url.replace("%s", quote(want_dom, safe=""))
                        if "%s" in domain_check_url else domain_check_url))
        # And where it is REGISTERED, which is a different job: the URL comes
        # from the DNS service. Only on the mail an ADMIN reads.
        if domain_order_url and event == "filed":
            out.append(("Register it at",
                        domain_order_url.replace("%s", quote(want_dom, safe=""))
                        if "%s" in domain_order_url else domain_order_url))

    for key, label in LABELS:
        v = str(row.get(key, "") or "").strip()
        if v and v != "-":
            # A COMMA LIST IS READ AS ONE VALUE. The owner, 2026-09-11: the
            # environments go under each other. "live,test" is two answers
            # printed as one word, and the eye does not split it.
            if key == "envs" and "," in v:
                parts = [p.strip() for p in v.split(",") if p.strip()]
                out.append((label, parts))
            else:
                out.append((label, v))
    return out


def esc_html(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def pair_html(v):
    # A list goes one per line, and anything that IS a URL becomes one: the
    # look-it-up line is only useful if it can be clicked.
    if isinstance(v, list):
        return "<br>".join(esc_html(x) for x in v)
    s = str(v)
    if s.startswith("http://") or s.startswith("https://"):
        return '<a href="%s">%s</a>' % (esc_html(s), esc_html(s))
    return esc_html(s)

if event == "filed":
    # Every full access admin, because any of them can answer it. The admin
    # account is one whether or not the side file says so: it is the account
    # that can always reach the page.
    to = {address(n) for n, (_m, role) in meta.items() if role == "full"}
    if address(admin_user):
        to.add(address(admin_user))
    to = sorted(a for a in to if a)
    if not to and fallback:
        to = [fallback]
    # The kind in words, and the NAME in the sentence. "a new app" says almost
    # nothing: it does not say which one, and `app` is the config's spelling
    # rather than a word anybody uses. A mailbox is named by its address.
    SUBJECT_KINDS = {"app": "application", "website": "website", "mailbox": "mailbox",
             "proxy": "forwarded address", "panel": "machine page"}
    word = SUBJECT_KINDS.get(kind, kind)
    whole = (name + "@" + str(row.get("subdomain", "")).strip().lstrip("=")
             if (kind == "mailbox" and name) else name)
    if row.get("isNew") or not name:
        what = ("a new %s, %s" % (word, whole)) if whole else ("a new " + word)
    else:
        what = "changes to %s %s" % (word, whole)
    subject = "%s asked for %s" % (who or "somebody", what)
    lead = "%s is asking for:" % (who or "Somebody")
    pairs = asked_pairs()
    # Why is inside the block now, under Type, so there is nothing left to put
    # after it.
    tail = []
    close = ["Answer it here, with a reason either way:", link, "",
             "Nothing is served until it is approved."]
else:
    # The requester, and only the requester. A decline carries its reason, which
    # is the whole point of the feature.
    to = [address(who)] if address(who) else []
    verb = {"approved": "approved", "declined": "declined"}.get(state, state)
    subject = "Your request was %s" % verb
    lead = "Your request was %s by %s. You asked for:" % (
        verb, str(r.get("answered_by", "")) or "an admin")
    pairs = asked_pairs()
    tail = [("Reason", str(r.get("answer", "")).strip() or "(none given)")]
    close = ["See it here:", link]
    # A MAILBOX IS NOT USABLE UNTIL ITS OWNER SETS A PASSWORD, and nobody else
    # can set it for them. No password is ever carried in a request, so an
    # approved mailbox is a row with no account: add_dovecot.sh leaves it
    # unmade rather than making one anybody could try, and Postfix refuses mail
    # for it meanwhile, so the sender is told rather than it vanishing.
    #
    # Without this line the customer waits for an address that is waiting for
    # them.
    if state == "approved" and kind == "mailbox":
        close += [
            "",
            "One more step, and only you can do it: the address has no password",
            "yet, so it cannot receive mail. Open its row and set one:",
            console_url.rstrip("/") + "/",
        ]

if not to:
    sys.stderr.write("Nobody has an address for this. Set one in the Users tab.\n")
    sys.exit(1)

m = EmailMessage()
m["From"] = sender
m["To"] = ", ".join(to)
if reply_to:
    m["Reply-To"] = reply_to
# The subject goes through EmailMessage rather than a heredoc: a row name is
# validated nowhere in a request, and a newline in one would otherwise write its
# own headers.
m["Subject"] = subject
m["Date"] = formatdate(localtime=True)
m["Message-ID"] = make_msgid(domain=sender.partition("@")[2] or None)
# Never answer a holiday responder with another notification.
m["Auto-Submitted"] = "auto-generated"
# The pairs are padded so the values line up in a fixed-width client, which is
# the plain-text half of "make the value distinct".
width = max([len(k) for k, _v in pairs + tail] or [0]) + 1
# A blank line either side of the block, so the three lines that matter are an
# island rather than the middle of a paragraph. The owner, 2026-09-11: "I do not
# need to read the fluff".
text = [lead, "", ""]
# A value that is a LIST goes one per line, under its label, indented to where
# the values start. The owner, 2026-09-11, about the environments.
for k, v in pairs:
    if isinstance(v, list):
        text.append("%-*s %s" % (width, k + ":", v[0]))
        text += ["%-*s %s" % (width, "", x) for x in v[1:]]
    else:
        text.append("%-*s %s" % (width, k + ":", v))
text += ["", ""]
# Only when there IS a tail. Why moved into the block on 2026-09-11, which left
# this printing four blank lines in a row at somebody.
if tail:
    text += ["%s: %s" % (k, v) for k, v in tail]
    text += ["", ""]
text += close
m.set_content("\n".join(text) + "\n")

# The same thing again with the values in bold. A client that refuses HTML has
# lost nothing: it reads the part above.
rows_html = "".join(
    '<tr><td style="padding:.1rem .8rem .1rem 0;color:#555;vertical-align:top">%s</td>'
    '<td style="padding:.1rem 0"><strong>%s</strong></td></tr>'
    % (esc_html(k), pair_html(v))
    for k, v in pairs)
tail_html = "".join(
    "<p style='margin:.4rem 0'>%s: <strong>%s</strong></p>"
    % (esc_html(k), esc_html(v)) for k, v in tail)
close_html = "".join(
    ('<p style="margin:.4rem 0"><a href="%s">%s</a></p>' % (esc_html(c), esc_html(c)))
    if c.startswith("http") else
    ("<p style='margin:.4rem 0'>%s</p>" % esc_html(c)) if c else ""
    for c in close)
m.add_alternative(
    '<div style="font:14px/1.5 system-ui,sans-serif">'
    '<p style="margin:.4rem 0">%s</p>'
    '<table style="margin:1.2rem 0 1.4rem;border-collapse:collapse">%s</table>%s%s</div>'
    % (esc_html(lead), rows_html, tail_html, close_html), subtype="html")

p = subprocess.run([sendmail, "-t", "-oi"], input=m.as_bytes())
if p.returncode != 0:
    sys.stderr.write("sendmail exited %d\n" % p.returncode)
    sys.exit(1)
print(", ".join(to))
PY
)"
RC=$?
set -e

if [ "$RC" -eq 0 ] && [ -n "$SENT" ]; then
    print_success "Told $SENT about $ID."
    exit 0
fi
print_action "Nobody was told about $ID. The request itself is written and stands."
print_info "Run it by hand to see why: sudo $0 $ID $EVENT"
exit 0
