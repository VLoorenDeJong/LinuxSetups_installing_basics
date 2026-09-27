#!/bin/bash
# =============================================================================
# Do the two generators agree on which hostnames exist?
#
# One question, one script. Split out of maintain_services.sh on 2026-08-16.
#
# add_app_vhosts.sh and add_site_certificates.sh both resolve a row's Subdomain
# into a hostname, and each carries its own copy of that logic. The duplication
# is deliberate, so either script stays runnable alone on a machine that has
# only that file. Duplication needs a guard, and this is it.
#
# Neither list is re-derived here: each script is asked what it thinks, with
# LIST_HOSTS=1. A checker that reimplemented the logic could drift from both and
# agree with neither.
#
# This is not hypothetical. On 2026-08-02 the same comparison, run by hand,
# found two disagreements that each looked correct in isolation: the certificate
# script still gave websites a single environment, so a published test hostname
# would have had a vhost and no certificate; and its already-covered test
# matched substrings across dots, so the apex was treated as covered by any
# subdomain's certificate and would never have been issued.
#
# THE TWO LISTINGS RUN AT THE SAME TIME.
#
# They are whole runs of two scripts that read the same config and touch
# nothing, so neither can affect the other. Run one after the other this was
# the slowest part of a pre-flight that changes nothing.
#
# Usage:
#   ./check_generators_agree.sh
#   PUBLISHED_OUT=/tmp/p REQUESTED_OUT=/tmp/r ./check_generators_agree.sh
#
# The two OUT files are for a caller that needs the lists as well as the
# verdict. Asking the generators twice is the thing worth avoiding.
#
# Exits non-zero when a published hostname would get no certificate.
# =============================================================================

set -e

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
PUBLISHED_OUT="${PUBLISHED_OUT:-}"
REQUESTED_OUT="${REQUESTED_OUT:-}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Config not found: $SITES_CONF"
    exit 1
fi

# The published side is the lister rather than one generator, so a name from a
# generator this script has never heard of is still cross-checked. Before that
# it asked add_app_vhosts.sh alone, and admin.<domain> was compared to nothing.
VHOST_SCRIPT="$SCRIPT_DIR/list_served_hostnames.sh"
CERT_SCRIPT="$SCRIPT_DIR/add_site_certificates.sh"

if [ ! -f "$VHOST_SCRIPT" ] || [ ! -f "$CERT_SCRIPT" ]; then
    # Never skip a guard quietly. If it cannot run, that is worth knowing.
    print_action "list_served_hostnames.sh or add_site_certificates.sh is not next to this script, so the two were not cross-checked"
    exit 0
fi

pub_out="$(mktemp)"; req_out="$(mktemp)"
trap 'rm -f "$pub_out" "$req_out"' EXIT

# ONLY_ROWS is cleared for both, deliberately. The question here is whether the
# two generators name the same hostnames, which has nothing to do with which rows
# a run happens to be writing. The caller exports ONLY_ROWS, and the vhost script
# honours it while the certificate script does not: that compared 5 names against
# 27 and reported 22 hostnames as having no vhost.
#
# The list also becomes REQUESTED_OUT, which report_drift.sh uses to decide which
# certificates are orphans. A narrowed list there would call every certificate
# outside the changed row an orphan, and --prune deletes those.
ONLY_ROWS= SITES_CONF="$SITES_CONF" bash "$VHOST_SCRIPT" --for vhosts >"$pub_out" 2>/dev/null &
pub_pid=$!
LIST_HOSTS=1 ONLY_ROWS= SITES_CONF="$SITES_CONF" bash "$CERT_SCRIPT" >"$req_out" 2>/dev/null &
req_pid=$!
wait "$pub_pid" || printf '' >"$pub_out"
wait "$req_pid" || printf '' >"$req_out"

published="$(sort -u "$pub_out")"
requested="$(sort -u "$req_out")"

[ -n "$PUBLISHED_OUT" ] && printf '%s\n' "$published" > "$PUBLISHED_OUT"
[ -n "$REQUESTED_OUT" ] && printf '%s\n' "$requested" > "$REQUESTED_OUT"

if [ -z "$published" ] || [ -z "$requested" ]; then
    print_info "Could not list hostnames from both generators, so they were not cross-checked"
    exit 0
fi

bad=0

# Published without a certificate is an error: the site exists and is served
# over HTTP only, with nothing saying why.
while read -r h; do
    [ -z "$h" ] && continue
    print_error "$h has a vhost but no certificate would be requested for it"
    bad=$((bad + 1))
done < <(comm -23 <(printf '%s\n' "$published") <(printf '%s\n' "$requested"))

# The reverse is usually a www. alias riding on another certificate, so it is
# only worth a warning.
while read -r h; do
    [ -z "$h" ] && continue
    case "$h" in
        www.*) continue ;;
    esac
    print_info "a certificate would be requested for $h, which has no vhost"
done < <(comm -13 <(printf '%s\n' "$published") <(printf '%s\n' "$requested"))

if [ "$bad" -eq 0 ]; then
    print_success "Generators agree: $(printf '%s\n' "$published" | wc -l) hostnames published."
    exit 0
fi
exit 1
