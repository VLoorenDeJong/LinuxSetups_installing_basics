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
# Everything that makes this machine the live one, except the drive swap.
#
# THIS SCRIPT DOES NOT DECIDE ANYTHING. The cutover is physical and stays
# physical: you swap the drive and boot. This repo is explicit that no script
# may decide a machine is live, because swapping a drive is deliberate and
# reversible and a script taking over is neither.
#
#   1. promote every staging certificate to a real one, over DNS-01
#   2. flip MACHINE_IS_LIVE to yes
#   3. write the apex A/AAAA record
#   4. publish the mail records: DKIM, SPF, DMARC and the MX
#   5. re-run the apply, so everything gated on step 2 takes effect
#   6. report what only a human can do: the PTR and the router
#
# RUN IT BEFORE THE SWAP, NOT AFTER.
#
# The first version required the domain to already reach this machine, which is
# a circle: it made the whole list wait until after the swap, so the drive would
# go in and THEN four certificates would be fetched while the site was down.
#
# The order that avoids that is this one. Certificates come first and never need
# the machine to be reachable, because the challenge is DNS-01 through the
# TransIP API and never touches this box. The address record then propagates
# while the drive is being changed, so the new machine is already there when
# traffic arrives, and the downtime is the swap itself and nothing else.
#
# Where the domain currently points is REPORTED, never a blocker.
#
# --check looks for blockers and writes nothing. It is the first button in the
# console; the second one does the four steps.
# =============================================================================
#
# Usage:
#   sudo bash go_live.sh --check     look for blockers, change nothing
#   sudo bash go_live.sh             do it, then swap the drive
#

export DEBIAN_FRONTEND=noninteractive

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPIN_PID=""
spinner_start() {
    [ "${DEBUG_MODE:-0}" = "1" ] && return 0
    local message="$1"
    (
        local i=0
        while true; do
            printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[i % 10]}" "$message"
            i=$((i + 1))
            sleep 0.2
        done
    ) &
    _SPIN_PID=$!
}
spinner_stop() {
    [ -n "$_SPIN_PID" ] || return 0
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf '\r\033[K'
}
trap spinner_stop EXIT

MODE="apply"
for arg in "$@"; do
    case "$arg" in
        --check)   MODE="check" ;;
        -h|--help) echo "Usage: sudo bash go_live.sh [--check]"; exit 0 ;;
        *)         print_error "Unknown option: $arg"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This reads certificates and rewrites the config, so it needs root."
    print_action "Run: sudo bash $0 ${MODE/apply/}"
    exit 1
fi

# Installed to /usr/local/sbin so the console may sudo it, and run from a
# checkout when a person runs it by hand. Two homes, so the repo cannot be found
# by walking up from the script: from /usr/local/sbin that lands on /usr, which
# is where the first run looked for hostings.conf and found nothing.
#
# The pipeline tree is the answer the rest of the fleet already uses: it is
# root-owned, refreshed from GitHub, and holds both the config and the scripts
# this one drives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="/usr/local/lib/linuxbasics"

if [ -f "/etc/hostings/hostings.conf" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
elif [ -d "$PIPELINE_ROOT/hostings/scripts" ]; then
    REPO_ROOT="$PIPELINE_ROOT"
    SCRIPT_DIR="$PIPELINE_ROOT/hostings/scripts"
else
    print_error "No script tree at $PIPELINE_ROOT and none beside this script."
    print_action "Install it: sudo bash add_pipeline_scripts.sh"
    exit 1
fi

. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
LE_LIVE="/etc/letsencrypt/live"

# Where the console reads the rehearsal's verdict. One file, two facts: whether
# it passed, and when. The page never runs the check itself.
REPORT_DIR="/run/hosting-status"
REPORT="$REPORT_DIR/go-live-check.json"

conf_get() {
    local key="$1" default="${2:-}" value
    [ -f "$SITES_CONF" ] || { echo "$default"; return; }
    value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
             | tr -d '\r' | tail -1 | cut -d= -f2- | sed 's/#.*//' | xargs)"
    [ -z "$value" ] && value="$default"
    echo "$value"
}

is_yes() { case "${1,,}" in y|yes|true|1) return 0 ;; *) return 1 ;; esac; }

BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"
MACHINE_IS_LIVE="$(conf_get MACHINE_IS_LIVE no)"

print_header "Go live"
print_status "Config: $SITES_CONF"
print_status "Mode:   $MODE"
print_status "Domain: ${BASE_DOMAIN:-unset}"

# =============================================================================
# The checks. Every one of them runs in both modes: --check stops after them,
# a real run refuses on any failure before writing anything.
# =============================================================================
FAILED=()
NOTES=()

# 1. The config is readable and names a domain.
if [ ! -f "$SITES_CONF" ]; then
    FAILED+=("No config at $SITES_CONF")
elif [ -z "$BASE_DOMAIN" ]; then
    FAILED+=("BASE_DOMAIN is not set in $SITES_CONF")
fi

# 2. Where the domain currently points. REPORTED, NEVER A BLOCKER.
#
# It was a blocker in the first version, and that was wrong. The swap happens
# AFTER these actions, deliberately: writing the address record first lets DNS
# propagate while the drive is being changed, so the new machine is already
# there when traffic arrives. Requiring the machine to be live before going
# live is a circle, and it would have bought exactly the downtime this ordering
# exists to avoid.
#
# Still worth saying out loud, because it tells the operator which side of the
# swap they are on.
# Through public_ip.sh, which is where the provider list lives now. This line
# used to name api.ipify.org and had no fallback at all, so one provider
# having a bad day made a live machine report that it could not be confirmed.
# A SCRIPT INSTALLED TO /usr/local/sbin HAS NO SIBLINGS, which is the fault of
# 2026-09-02 that made every sibling lookup fail silently. The interfaces live
# in the pipeline tree, so look there when they are not beside this file.
_iface() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

. "$(_iface public_ip.sh)"
PUBLIC_IP="$(public_ip4 || true)"
if [ -z "$BASE_DOMAIN" ]; then
    : # already reported above; without a domain there is nothing to ask
elif [ -z "$PUBLIC_IP" ]; then
    FAILED+=("Could not find this machine's public address, so it cannot be confirmed live")
else
    print_status "Public address: $PUBLIC_IP"
    # A token only this machine can serve, fetched over the public name. If the
    # old machine is still answering, it does not have this file.
    TOKEN="golive-$(date +%s)-$$"
    TOKEN_DIR="/var/www/certbot/.well-known/acme-challenge"
    if [ -d "$(dirname "$TOKEN_DIR")" ] || mkdir -p "$TOKEN_DIR" 2>/dev/null; then
        mkdir -p "$TOKEN_DIR" 2>/dev/null || true
        echo "$TOKEN" > "$TOKEN_DIR/$TOKEN" 2>/dev/null || true
        spinner_start "Asking $BASE_DOMAIN whether it is this machine..."
        ANSWER="$(curl -s -m 10 "http://${BASE_DOMAIN}/.well-known/acme-challenge/${TOKEN}" 2>/dev/null || true)"
        spinner_stop
        rm -f "$TOKEN_DIR/$TOKEN" 2>/dev/null || true
        if [ "$ANSWER" = "$TOKEN" ]; then
            print_success "$BASE_DOMAIN already reaches THIS machine."
            REACHES_HERE=yes
        else
            print_info "$BASE_DOMAIN still reaches the machine being replaced."
            print_info "That is expected before the swap and does not block anything."
            REACHES_HERE=no
        fi
    else
        print_info "No webroot at $TOKEN_DIR, so where the domain points was not checked."
        REACHES_HERE=unknown
    fi
fi

# 3. What the promotion would cost, counted rather than guessed.
STAGING=()
if [ -d "$LE_LIVE" ]; then
    for d in "$LE_LIVE"/*/; do
        [ -r "$d/cert.pem" ] || continue
        if openssl x509 -issuer -noout -in "$d/cert.pem" 2>/dev/null | grep -q "(STAGING)"; then
            STAGING+=("$(basename "$d")")
        fi
    done
fi
print_status "Staging certificates to promote: ${#STAGING[@]}"

# 4. The scripts this one drives have to be beside it.
for s in promote_certificate.sh update_dns_apex.sh maintain_services.sh add_mail_dns_records.sh \
         add_github_app.sh add_jenkins_github_credentials.sh; do
    [ -f "$SCRIPT_DIR/$s" ] || FAILED+=("$s is not next to this script, so its step cannot run")
done

# 5. The things the two writing steps actually need. These ARE blockers: a run
# that gets halfway and then finds no API key has already spent certificates.
CERT_EMAIL="$(conf_get CERT_EMAIL "")"
[ -n "$CERT_EMAIL" ] || FAILED+=("No CERT_EMAIL in $SITES_CONF, and Let's Encrypt needs somewhere to warn you")

# /etc/dns-api is the house value, in hostings.conf and in every other script
# that reads it. An older default here named a path under /etc, which is harmless
# while the config sets the key and wrong the moment it does not.
DNS_CRED_DIR="$(conf_get DNS_CRED_DIR /etc/dns-api)"
if [ ! -d "$DNS_CRED_DIR" ]; then
    FAILED+=("No credential directory at $DNS_CRED_DIR, so neither certificates nor DNS can be written")
    FAILED+=("  Install the key: sudo bash $SCRIPT_DIR/add_transip_key.sh")
fi

# 6. The mail step, asked of the script that owns it rather than reimplemented.
# It refuses on a missing key, a missing tool or a bad TTL, and all of that has
# to surface BEFORE certificates are spent and the switch is flipped.
if [ -f "$SCRIPT_DIR/add_mail_dns_records.sh" ]; then
    if ! SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/add_mail_dns_records.sh" --check \
         >/tmp/golive-maildns.log 2>&1; then
        FAILED+=("The mail records step would fail. Its own reason:")
        while IFS= read -r line; do FAILED+=("  $line"); done \
            < <(grep -e '^❌' /tmp/golive-maildns.log | sed 's/^❌[[:space:]]*//' | head -5)
        FAILED+=("  Run it yourself: sudo bash $SCRIPT_DIR/add_mail_dns_records.sh --check")
    fi
fi

# The same path promote_certificate.sh and add_site_certificates.sh both name.
# Guessing a different filename here made the check report a missing hook that
# was sitting there the whole time.
CHALLENGE_HOOK="/usr/local/sbin/transip_dns_challenge.sh"
if [ ! -x "$CHALLENGE_HOOK" ]; then
    FAILED+=("The DNS-01 hook is missing, so no certificate can be promoted")
    FAILED+=("  Run add_site_certificates.sh once: it installs the hook.")
fi

command -v certbot >/dev/null 2>&1 || FAILED+=("certbot is not installed, so no certificate can be promoted")

# 5. Already done is not a failure, it is an answer.
if is_yes "$MACHINE_IS_LIVE"; then
    NOTES+=("MACHINE_IS_LIVE is already yes, so step 1 is a no-op")
elif [ -f "/etc/hostings/hostings.test.conf" ]; then
    NOTES+=("Step 2 switches to the LIVE vaults. Right after it, move every item from the four TEST vaults (the OP_VAULT* names in hostings.test.conf) to the live vault of the same kind")
fi

# =============================================================================
# The verdict, and the file the console reads
# =============================================================================
PASSED=true
[ ${#FAILED[@]} -gt 0 ] && PASSED=false

# The fingerprint of the config this verdict was reached against. The console
# recomputes it and hides the go-live button when it no longer matches, so an
# edit made after the check invalidates the check rather than riding along with
# a pass that was true about a different config.
FINGERPRINT="$(sha256sum "$SITES_CONF" 2>/dev/null | cut -c1-16)"

mkdir -p "$REPORT_DIR" 2>/dev/null || true
{
    printf '{"checked":%s,"checkedText":"%s","passed":%s,"staging":%s,"fingerprint":"%s","reasons":[' \
        "$(date +%s)" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$PASSED" "${#STAGING[@]}" "$FINGERPRINT"
    sep=""
    for f in ${FAILED+"${FAILED[@]}"}; do
        printf '%s"%s"' "$sep" "$(printf '%s' "$f" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        sep=","
    done
    printf ']}\n'
} > "$REPORT" 2>/dev/null || true
chmod 644 "$REPORT" 2>/dev/null || true

echo ""
for n in ${NOTES+"${NOTES[@]}"}; do print_info "$n"; done

if [ "$PASSED" != "true" ]; then
    print_error "Not ready to go live:"
    for f in "${FAILED[@]}"; do print_error "  $f"; done
    echo ""
    print_action "Nothing was changed. Fix the above and run the test again."
    exit 1
fi

print_success "No blockers. Everything the go-live steps need is in place."

if [ "$MODE" = "check" ]; then
    echo ""
    print_status "What the go-live button would do, in order:"
    print_status "  1. promote ${#STAGING[@]} staging certificate(s) to real ones, over DNS-01"
    print_status "  2. MACHINE_IS_LIVE = yes in $SITES_CONF"
    print_status "  3. write the apex A/AAAA record for $BASE_DOMAIN"
    print_status "  4. publish the mail records: DKIM, SPF, DMARC and the MX"
    print_status "  5. re-run maintain_services.sh --apply"
    echo ""
    if [ "${REACHES_HERE:-unknown}" = "no" ]; then
        print_action "Run it BEFORE swapping the drive. The address record propagates while"
        print_action "you change the disk, so the new machine is already there when traffic"
        print_action "arrives. That ordering is what keeps the downtime to the swap itself."
    fi
    print_action "--check, so nothing was written."
    exit 0
fi

# =============================================================================
# 1. Real certificates
# =============================================================================
print_header "1. Certificates"
PROMOTED=0
CERT_FAILED=()
for host in ${STAGING+"${STAGING[@]}"}; do
    spinner_start "Promoting $host..."
    if bash "$SCRIPT_DIR/promote_certificate.sh" "$host" >/tmp/golive-cert.log 2>&1; then
        spinner_stop
        print_success "$host now holds a real certificate."
        PROMOTED=$((PROMOTED + 1))
    else
        spinner_stop
        print_error "$host could not be promoted, so it keeps its test certificate."
        tail -5 /tmp/golive-cert.log >&2
        CERT_FAILED+=("$host")
    fi
done
[ ${#STAGING[@]} -eq 0 ] && print_success "Nothing to promote."

# =============================================================================
# 2. The switch
# =============================================================================
print_header "2. MACHINE_IS_LIVE"
if is_yes "$MACHINE_IS_LIVE"; then
    print_success "Already yes."
elif [ -f "/etc/hostings/hostings.test.conf" ]; then
    # The test file becomes the live one, committed by the publisher, which
    # owns the App push. Then the pipeline tree takes that commit, so steps 3
    # to 5 read the live config and the live vault.
    PUBLISHER=/usr/local/sbin/publish_hostings.sh
    [ -x "$PUBLISHER" ] || PUBLISHER="$SCRIPT_DIR/publish_hostings.sh"
    bash "$PUBLISHER" --go-live || exit 1
    if ! bash "$(_iface add_pipeline_scripts.sh)" >/tmp/golive-refresh.log 2>&1; then
        print_error "Live config pushed, but $PIPELINE_ROOT did not take it:"
        tail -n 10 /tmp/golive-refresh.log >&2
        print_action "Run: sudo bash $PIPELINE_ROOT/hostings/scripts/add_pipeline_scripts.sh, then this again."
        exit 1
    fi
    REPO_ROOT="$PIPELINE_ROOT"
    SCRIPT_DIR="$PIPELINE_ROOT/hostings/scripts"
    SITES_CONF="$(conf_active "/etc/hostings")"
    if is_yes "$(conf_get MACHINE_IS_LIVE no)"; then
        print_success "MACHINE_IS_LIVE = yes, in $SITES_CONF"
    else
        print_error "The flip did not take. $SITES_CONF still says no."
        exit 1
    fi
    print_action "The live vaults are in force now. In 1Password, move every item from the four"
    print_action "TEST vaults (the OP_VAULT* names in hostings.test.conf)"
    print_action "to the live vault of the same kind. The API keys vault is shared: leave it."
elif [ "$REPO_ROOT" = "$PIPELINE_ROOT" ]; then
    # The pipeline tree is a checkout that add_pipeline_scripts.sh resets from
    # GitHub. A flip written here survives until the next refresh and then
    # silently reverts, which is worse than not flipping at all: every later run
    # would report live while the config says no.
    print_error "Running from $PIPELINE_ROOT, which is reset from GitHub on every refresh."
    print_action "Flip it where it is kept instead, then run this again:"
    print_action "  1. In the console, set MACHINE_IS_LIVE = yes and press Make it live."
    print_action "  2. Or edit hostings.conf in the repository, commit and push."
    exit 1
else
    sed -i 's/^\([[:space:]]*MACHINE_IS_LIVE[[:space:]]*=[[:space:]]*\).*/\1yes/' "$SITES_CONF"
    if is_yes "$(conf_get MACHINE_IS_LIVE no)"; then
        print_success "MACHINE_IS_LIVE = yes"
    else
        print_error "The flip did not take. $SITES_CONF still says no."
        print_action "Set it by hand, then run this again."
        exit 1
    fi
fi

# =============================================================================
# 2b. The live GitHub App
#
# The test machine ran on two TEST Apps, and Jenkins keeps whatever credentials
# it was last given, so both are switched here. A fresh drive has no live key
# yet: add_github_app.sh fetches it from the vault and then does Jenkins too.
# =============================================================================
print_header "2b. GitHub App"
if [ -s "$(conf_get GITHUB_APP_KEY_FILE /etc/github-app/app.pem)" ]; then
    GH_SETUP="$(_iface add_jenkins_github_credentials.sh)"
else
    GH_SETUP="$(_iface add_github_app.sh)"
fi
if SITES_CONF="$SITES_CONF" bash "$GH_SETUP" </dev/null >/tmp/golive-github.log 2>&1; then
    print_success "Scripts and Jenkins use the live GitHub App."
else
    print_error "Switching to the live GitHub App failed:"
    tail -n 10 /tmp/golive-github.log >&2
    print_action "Run: sudo bash $SCRIPT_DIR/add_github_app.sh"
    GITHUB_FAILED=1
fi

# =============================================================================
# 3. The address record
#
# One at a time, and a failure is reported rather than fatal: nineteen names
# should not be abandoned because the third one had a DNS hiccup.
# =============================================================================
print_header "3. DNS"
if bash "$SCRIPT_DIR/update_dns_apex.sh"; then
    print_success "Apex record written."
else
    print_error "The apex record was not written."
    print_action "Run it on its own to see why: sudo bash $SCRIPT_DIR/update_dns_apex.sh"
fi

# =============================================================================
# 4. The mail records
#
# After step 2, so MACHINE_IS_LIVE is already yes and the script will write the
# MX, SPF and DMARC records it refuses to touch on a machine that is not live.
# Reported and never fatal: a mail record that did not land does not stop a
# machine from serving, and the script only writes what still differs on a
# re-run.
# =============================================================================
print_header "4. Mail records"
# SITES_CONF is passed down rather than left to the child's own default. Item 19
# documents this script being run as `sudo SITES_CONF=... bash go_live.sh`, and
# a child reading a different config would see MACHINE_IS_LIVE = no, write DKIM
# alone and exit 0, under a parent reporting all four records written.
if SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/add_mail_dns_records.sh"; then
    # Says only what was actually checked. The child validates DKIM against the
    # nameservers and does not read MX, SPF or DMARC back.
    print_success "Mail records written. DKIM validated; MX, SPF and DMARC were not read back."
else
    print_error "The mail records were not all written."
    print_action "Run it on its own to see why: sudo bash $SCRIPT_DIR/add_mail_dns_records.sh"
    MAIL_DNS_FAILED=1
fi

# =============================================================================
# 5. Apply, so everything gated on the switch takes effect
# =============================================================================
print_header "5. Apply"
if bash "$SCRIPT_DIR/maintain_services.sh" --apply; then
    print_success "Applied."
else
    print_error "The apply did not finish. The machine may be part way changed."
    print_action "Run the check job to see where it stands: maintain_services.sh --check"
    APPLY_FAILED=1
fi

# =============================================================================
# What is left, and it is not this machine's to do
# =============================================================================
print_header "Still needs a human"
print_action "1. rDNS: ask the ISP to point the PTR for $PUBLIC_IP at mail.$BASE_DOMAIN"
print_info   "   The only one of the four mail checks a machine cannot do for itself."
print_action "2. Router: check the port forwards point at this machine's new address."
[ ${#CERT_FAILED[@]} -gt 0 ] && print_action "3. Retry these certificates: ${CERT_FAILED[*]}"
[ "${MAIL_DNS_FAILED:-0}" = "1" ] && print_action "4. Retry the mail records: sudo bash $SCRIPT_DIR/add_mail_dns_records.sh"

# =============================================================================
# The verdict, and it has to be able to say no.
#
# This exited 0 with a green "This machine is live" after failed certificates, a
# failed mail step and a failed apply. The console reads the exit code, so a
# part-done cutover was indistinguishable from a finished one.
# =============================================================================
PROBLEMS=$(( ${#CERT_FAILED[@]} + ${MAIL_DNS_FAILED:-0} + ${APPLY_FAILED:-0} + ${GITHUB_FAILED:-0} ))

echo ""
if [ "$PROBLEMS" -gt 0 ]; then
    print_error "Go live finished with $PROBLEMS failed step(s). $PROMOTED certificate(s) promoted."
    print_action "The list above says which. Re-running only redoes what is still wrong."
    exit 1
fi

print_success "This machine is live. $PROMOTED certificate(s) promoted."
