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
# Replace one hostname's TEST certificate with a real one.
#
#   promote_certificate.sh example.org
#
# This is the only thing in the setup that spends a production issuance on
# purpose, one hostname at a time. add_site_certificates.sh issues staging
# certificates for everything while MACHINE_IS_LIVE = no; this promotes one of
# them once you have opened it and it works.
#
# ONE HOSTNAME, NEVER A SET. Let's Encrypt allows 50 certificates per registered
# domain per week. A machine with eighteen hostnames under one domain gets two
# complete runs in a week, so promoting the whole lot to fix one row is the
# expensive mistake this shape prevents.
#
# TWO REFUSALS, BOTH BEFORE ANYTHING IS SPENT
#
#   1. The hostname must look like a hostname. This runs through sudo from a web
#      form, so an unchecked argument reaches certbot's command line.
#   2. A staging certificate must already exist for it. That proves the whole
#      challenge has succeeded here at least once, against the server whose
#      limits do not matter.
#
# Rolling back is add_site_certificates.sh, which reissues from staging.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

# --- Inline utility functions (always defined, no sourcing required) ---
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[1m=== %s ===\033[0m\n" "$1"; }

usage() {
    echo "Usage: $0 <hostname> [--check]" >&2
    echo "" >&2
    echo "  hostname   one name that already holds a staging certificate" >&2
    echo "  --check    say whether it could be promoted, request nothing" >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  SITES_CONF      override the config location" >&2
    exit 1
}

HOST=""
CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check)   CHECK_ONLY=1; shift ;;
        -h|--help) usage ;;
        -*)        print_error "Unknown option: $1"; usage ;;
        *)         [ -n "$HOST" ] && { print_error "Only one hostname at a time."; usage; }
                   HOST="$1"; shift ;;
    esac
done
[ -z "$HOST" ] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "")"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
# The installed copy lives in /usr/local/sbin, where the repo is not above it.
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/etc/hostings")"

LE_LIVE="/etc/letsencrypt/live"
CHALLENGE_HOOK="/usr/local/sbin/transip_dns_challenge.sh"

conf_get() {
    local key="$1" default="$2" value
    value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    # tr -d '\r': xargs does not strip a carriage return, and a value is the
    # last thing on its line, so a CRLF config leaves one inside every value.
    value="$(echo "$value" | tr -d '\r' | sed 's/#.*//' | xargs)"
    echo "${value:-$default}"
}

print_header "Promote $HOST to a real certificate"

# 1. A hostname, not an argument list. Letters, digits, dots and hyphens only,
#    and no label may start or end with a hyphen.
if ! printf '%s' "$HOST" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'; then
    print_error "'$HOST' is not a hostname."
    exit 1
fi

# 2. A staging certificate must exist, which is the proof the challenge works
#    for this name on this machine.
if [ ! -r "$LE_LIVE/$HOST/cert.pem" ]; then
    print_error "No certificate at $LE_LIVE/$HOST, so there is nothing to promote."
    print_action "Run add_site_certificates.sh first: it issues the test one."
    exit 1
fi

if ! openssl x509 -issuer -noout -in "$LE_LIVE/$HOST/cert.pem" 2>/dev/null | grep -q "(STAGING)"; then
    print_success "$HOST already holds a real certificate. Nothing to do."
    exit 0
fi

CERT_EMAIL="${CERT_EMAIL:-$(conf_get CERT_EMAIL "")}"
if [ -z "$CERT_EMAIL" ]; then
    print_error "No CERT_EMAIL in $SITES_CONF, so Let's Encrypt has nowhere to warn you."
    exit 1
fi

if [ ! -x "$CHALLENGE_HOOK" ]; then
    print_error "The DNS-01 hook is missing: $CHALLENGE_HOOK"
    print_action "Run add_site_certificates.sh once: it installs the hook."
    exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    print_success "$HOST holds a test certificate and could be promoted."
    print_status "Promote it with: $0 $HOST"
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    print_error "certbot writes into /etc/letsencrypt, so this needs sudo."
    exit 1
fi

print_info "This spends one real issuance. 50 per registered domain per 7 days."
print_status "Requesting..."

LOG="$(mktemp)"
# --force-renewal is required: certbot would otherwise see a certificate that is
# nowhere near expiry and keep it, staging issuer and all.
if certbot certonly \
        --manual \
        --preferred-challenges dns \
        --manual-auth-hook    "$CHALLENGE_HOOK --add" \
        --manual-cleanup-hook "$CHALLENGE_HOOK --delete" \
        --non-interactive \
        --agree-tos \
        --email "$CERT_EMAIL" \
        --cert-name "$HOST" \
        --force-renewal \
        --deploy-hook "systemctl reload apache2" \
        -d "$HOST" >"$LOG" 2>&1; then
    rm -f "$LOG"
else
    print_error "certbot failed, so $HOST still holds its test certificate."
    print_info "Last 20 lines:"
    tail -n 20 "$LOG"
    print_action "Full log: $LOG"
    exit 1
fi

if openssl x509 -issuer -noout -in "$LE_LIVE/$HOST/cert.pem" 2>/dev/null | grep -q "(STAGING)"; then
    print_error "$HOST still has a staging certificate after a successful run."
    print_action "Nothing was rolled back. Look at: certbot certificates"
    exit 1
fi

print_success "$HOST now holds a real certificate, and Apache has been reloaded."
