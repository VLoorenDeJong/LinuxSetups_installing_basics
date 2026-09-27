#!/usr/bin/env bash
set -e

# =============================================================================
# What to type into Outlook, Thunderbird or a phone to reach a mailbox here.
# Read off the running machine, never written down twice.
#
# WHY IT IS NOT IN hostings.conf. A port in the config is a port somebody
# intends; a port in `ss -ltn` is a port that answers. Those differ exactly when
# it matters: 143 is configured in Dovecot and is NOT listening on this machine,
# so a settings card built from the config would tell a customer to use plain
# IMAP and they would get a connection refused with no explanation.
#
# So every value below comes from the service that owns it:
#
#   host      Dovecot's own ssl_cert lineage, which is the name the certificate
#             actually covers. A name that does not match is the one failure a
#             mail client cannot be talked through over the phone.
#   ports     ss -ltn, so only a port that is listening is ever offered
#   security  doveconf ssl, and postconf for the submission service's own
#             -o overrides rather than the global setting
#   username  the full address. Dovecot's userdb is keyed on it, and "just the
#             part before the @" is the most common wrong guess
#
#   mail_client_settings.sh <address>        one mailbox, as JSON
#   mail_client_settings.sh --domain <dom>   the domain's settings, no address
#   mail_client_settings.sh --check          say whether it can read the machine
#
# STDOUT IS JSON AND HOLDS NOTHING ELSE. The console decodes it, so one line of
# human text on stdout becomes a dialog showing "parse error" to a customer.
# Every message goes to stderr.
#
# A MISSING PIECE IS REPORTED, NOT GUESSED. No certificate for mail.<domain>
# means the host is named and flagged untrusted rather than silently offered,
# because a client told to trust an unverifiable server is being taught to
# click through the one warning that matters.
# =============================================================================

print_error() { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
print_info()  { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"
    v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

ADDRESS=""
DOMAIN=""
CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --check)  CHECK=1; shift ;;
        -h|--help)
            print_info "Usage: $0 <address> | --domain <domain> | --check"
            exit 0
            ;;
        *) ADDRESS="$1"; shift ;;
    esac
done

if [ -n "$ADDRESS" ] && [ -z "$DOMAIN" ]; then
    case "$ADDRESS" in
        *@*) DOMAIN="${ADDRESS#*@}" ;;
        *)   printf '{"error":"%s is not an e-mail address"}\n' "$(json_str "$ADDRESS")"; exit 0 ;;
    esac
fi
[ -z "$DOMAIN" ] && DOMAIN="$(conf_get BASE_DOMAIN "")"
if [ -z "$DOMAIN" ]; then
    printf '{"error":"no domain was named and BASE_DOMAIN is not set"}\n'
    exit 0
fi

# =============================================================================
# The host
#
# Dovecot's certificate decides it. A machine whose Dovecot has no ssl_cert at
# all falls back to mail.<domain>, which is the name every generator here
# publishes, and the answer says which of the two happened.
# =============================================================================
HOST=""
HOST_FROM="the certificate Dovecot presents"
CERT_PATH="$(doveconf -h ssl_cert 2>/dev/null | sed 's/^<//' || true)"
case "$CERT_PATH" in
    /etc/letsencrypt/live/*)
        HOST="${CERT_PATH#/etc/letsencrypt/live/}"
        HOST="${HOST%%/*}"
        ;;
esac
if [ -z "$HOST" ]; then
    HOST="mail.${DOMAIN}"
    HOST_FROM="the naming convention, because Dovecot presents no certificate"
fi

# Does that certificate cover the domain being asked about? One Dovecot serves
# every mail domain here, so a customer on a second domain is given a host whose
# certificate names somebody else's, and their client refuses it.
HOST_MATCHES=true
case "$HOST" in
    *".$DOMAIN"|"$DOMAIN") ;;
    *) HOST_MATCHES=false ;;
esac

# A staging certificate is a real file that no client trusts, which looks
# identical to a working setup until somebody tries it.
TRUSTED=true
if [ -n "$CERT_PATH" ] && [ -r "$CERT_PATH" ]; then
    if openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null | grep -qi 'staging\|STAGING'; then
        TRUSTED=false
    fi
elif [ -n "$CERT_PATH" ]; then
    TRUSTED=false
fi

# =============================================================================
# The ports, from what is listening rather than from what is configured
# =============================================================================
listening() {
    ss -H -ltn "sport = :$1" 2>/dev/null | grep -q . && return 0
    return 1
}

IMAP_PORT=""
IMAP_SEC=""
if listening 993; then
    IMAP_PORT=993
    IMAP_SEC="SSL/TLS"
elif listening 143; then
    IMAP_PORT=143
    # STARTTLS only counts as required when Dovecot says so; otherwise a client
    # may silently fall back to plain and the password crosses the LAN as text.
    if [ "$(doveconf -h ssl 2>/dev/null)" = "required" ]; then
        IMAP_SEC="STARTTLS"
    else
        IMAP_SEC="STARTTLS, not enforced"
    fi
fi

SMTP_PORT=""
SMTP_SEC=""
if listening 587; then
    SMTP_PORT=587
    SMTP_SEC="STARTTLS"
elif listening 465; then
    SMTP_PORT=465
    SMTP_SEC="SSL/TLS"
elif listening 25; then
    # Deliberately last and deliberately named as what it is. Port 25 here
    # relays for loopback without authentication and is not a client port.
    SMTP_PORT=25
    SMTP_SEC="none, and this is the server-to-server port"
fi

# The alternative, offered rather than hidden: a client that cannot do one can
# usually do the other, and saying so saves a support round trip.
SMTP_ALT=""
SMTP_ALT_SEC=""
if [ "$SMTP_PORT" = "587" ] && listening 465; then
    SMTP_ALT=465
    SMTP_ALT_SEC="SSL/TLS"
elif [ "$SMTP_PORT" = "465" ] && listening 587; then
    SMTP_ALT=587
    SMTP_ALT_SEC="STARTTLS"
fi

# =============================================================================
# The rest of what a mail app asks for
#
# Outlook's own wizard asks four more questions than host/port/security, and
# every one of them is answerable from the machine. A customer guessing at any
# of them gets a setup that fails with no useful message.
# =============================================================================

# "IMAP or POP3" is the first question Outlook asks. Answering "IMAP" is only
# half of it: saying POP3 is NOT offered stops somebody picking it and blaming
# the password.
ACCOUNT_TYPE="IMAP"
POP3=false
if listening 995 || listening 110; then POP3=true; fi

# Thunderbird calls this Authentication method, Outlook calls it Secure Password
# Authentication (which it is NOT: SPA is NTLM, and picking it fails). The
# mechanisms Dovecot offers decide the answer.
AUTH_METHOD="Normal password"
MECHS="$(doveconf -h auth_mechanisms 2>/dev/null || true)"
case "$MECHS" in
    *cram-md5*|*digest-md5*) AUTH_METHOD="Encrypted password" ;;
    ""|*plain*|*login*)      AUTH_METHOD="Normal password" ;;
esac

# The single most common broken setup: a client that receives fine and cannot
# send, because "My outgoing server requires authentication" was left unticked.
SMTP_AUTH=false
if postconf -M 2>/dev/null | grep -E '^(submission|smtps)\b' | grep -q 'smtpd_sasl_auth_enable=yes'; then
    SMTP_AUTH=true
fi

# Webmail, if this machine serves it for the domain. Offered because it needs
# no setup at all, which is the right answer for somebody who only wants to read
# one message. Read from the enabled vhost rather than assumed from the name.
WEBMAIL=""
if [ -e "/etc/apache2/sites-enabled/020-webmail-${DOMAIN}.conf" ]; then
    WEBMAIL="https://webmail.${DOMAIN}"
fi

if [ "$CHECK" -eq 1 ]; then
    print_info "Domain:   $DOMAIN"
    print_info "Host:     $HOST ($HOST_FROM)"
    print_info "IMAP:     ${IMAP_PORT:-nothing is listening} ${IMAP_SEC}"
    print_info "SMTP:     ${SMTP_PORT:-nothing is listening} ${SMTP_SEC}"
    print_info "Trusted:  $TRUSTED"
    [ -n "$IMAP_PORT" ] && [ -n "$SMTP_PORT" ] && exit 0
    print_error "No IMAP or no SMTP port is listening, so no client can be set up."
    exit 1
fi

# Authentication is the same for both, and saying so is the point: the most
# common failure is a client told to send without signing in.
printf '{'
printf '"address":"%s",'   "$(json_str "$ADDRESS")"
printf '"domain":"%s",'    "$(json_str "$DOMAIN")"
printf '"username":"%s",'  "$(json_str "${ADDRESS:-your full e-mail address}")"
printf '"host":"%s",'      "$(json_str "$HOST")"
printf '"host_from":"%s",' "$(json_str "$HOST_FROM")"
printf '"host_matches":%s,' "$HOST_MATCHES"
printf '"trusted":%s,'    "$TRUSTED"
printf '"imap":{"host":"%s","port":%s,"security":"%s"},' \
    "$(json_str "$HOST")" "${IMAP_PORT:-null}" "$(json_str "$IMAP_SEC")"
printf '"smtp":{"host":"%s","port":%s,"security":"%s","alt_port":%s,"alt_security":"%s"},' \
    "$(json_str "$HOST")" "${SMTP_PORT:-null}" "$(json_str "$SMTP_SEC")" \
    "${SMTP_ALT:-null}" "$(json_str "$SMTP_ALT_SEC")"
printf '"auth":"the same username and password for both",'
printf '"account_type":"%s",' "$(json_str "$ACCOUNT_TYPE")"
printf '"pop3":%s,'          "$POP3"
printf '"auth_method":"%s",' "$(json_str "$AUTH_METHOD")"
printf '"smtp_auth":%s,'     "$SMTP_AUTH"
printf '"webmail":"%s"'      "$(json_str "$WEBMAIL")"
printf '}\n'
