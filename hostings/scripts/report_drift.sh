#!/bin/bash
# =============================================================================
# What does the config say should exist, and what is actually on the machine?
#
# One question, one script. Split out of maintain_services.sh on 2026-08-16.
# It reads and reports; it never writes, deletes or restarts anything, so it is
# safe to run at any moment on any machine.
#
#   ADD      the config says this should exist, the machine has no such thing
#   OK       machine matches config
#   ORPHAN   on the machine, carries our generated header, no longer in config
#
# An UPDATE is deliberately not detected. The generators compare content
# themselves and leave an unchanged file alone, so they are the honest answer to
# "would this change", and duplicating that comparison would mean two places to
# keep in step.
#
# Anything a human wrote is invisible here by definition: only files carrying
# "from /etc/hostings/hostings.conf" can ever be called an orphan. That rule is
# what keeps a year of hand-written vhosts safe from whatever consumes this.
#
# Usage:
#   ./report_drift.sh                     print the report
#   DRIFT_OUT=/tmp/drift ./report_drift.sh   also write it machine-readable
#
# DRIFT_OUT gets one line per item, "KIND WHAT NAME", no colour and no totals,
# for a caller that has to act on the list rather than read it.
#
# Exits 0 whether or not there is drift. Drift is a fact, not a failure.
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
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
DRIFT_OUT="${DRIFT_OUT:-}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Config not found: $SITES_CONF"
    exit 1
fi

# -----------------------------------------------------------------------------
# Config readers. Duplicated verbatim rather than sourced, so this script stays
# runnable on its own on a machine that has only this file copied to it.
# -----------------------------------------------------------------------------
# Read once, in bash, rather than five forks per key. Same change as
# maintain_services.sh, and this is the script that made it worth making: it is
# 2.7 of the check's 4.5 seconds, and 312 of its processes.
declare -A _CONF_CACHE=()
_CONF_LOADED=0
_conf_load() {
    local line key value
    [ "$_CONF_LOADED" = "1" ] && return 0
    _CONF_LOADED=1
    [ -f "$SITES_CONF" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        [ -n "${_CONF_CACHE[$key]+set}" ] && continue
        # A CRLF config leaves a carriage return on the end of the value, and
        # the two trims below only remove whitespace.
        value="${BASH_REMATCH[2]//$'\r'/}"
        value="${value%%#*}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        _CONF_CACHE[$key]="$value"
    done < "$SITES_CONF"
}

# Filled at the top level, never first from in here.
#
# conf_get is always called as $(conf_get ...), and a command substitution is a
# subshell. A cache filled inside one dies with it, which is why the
# memoisation this replaces never once served a second caller: every call took
# the slow path and nobody noticed, because the slow path was only five forks.
# Loading in the parent means each subshell inherits an array already full.
conf_get() {
    local key="$1" default="$2" value
    _conf_load
    value="${_CONF_CACHE[$key]:-}"
    echo "${value:-$default}"
}

_conf_load

conf_rows() {
    # One awk pass. A bash read loop over the whole file cost 0.2s per call.
    # A SETTING line is skipped even when it holds pipes, as PANEL lines do.
    awk '{ sub(/#.*/, "") } /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next } /\|/' "$SITES_CONF"
}

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

# Pure bash throughout: this is called once per row per environment, and the
# two `echo | xargs` it used to hold were four forks every time.
row_in_env() {
    local list="$1" env="$2" e
    list="${list#"${list%%[![:space:]]*}"}"
    list="${list%"${list##*[![:space:]]}"}"
    [ -z "$list" ] || [ "$list" = "-" ] && return 0
    IFS=',' read -r -a _re <<< "$list"
    for e in "${_re[@]}"; do
        e="${e#"${e%%[![:space:]]*}"}"
        e="${e%"${e##*[![:space:]]}"}"
        [ "$e" = "$env" ] && return 0
    done
    return 1
}

IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS live)"
for i in "${!ALL_ENVS[@]}"; do ALL_ENVS[$i]="$(trim "${ALL_ENVS[$i]}")"; done
DEFAULT_ENV="${ALL_ENVS[0]}"

IFS=',' read -r -a PUBLISH_ENVS <<< "$(conf_get PUBLISH_ENVS "$(conf_get ENVS live)")"
for i in "${!PUBLISH_ENVS[@]}"; do PUBLISH_ENVS[$i]="$(trim "${PUBLISH_ENVS[$i]}")"; done

AVAILABLE_DIR="/etc/apache2/sites-available"
UNIT_DIR="/etc/systemd/system"
GENERATED_MARK="from /etc/hostings/hostings.conf"

# The four generator runs only read, and none needs another's answer, so they
# start together here and are collected where each is used. In sequence they
# were most of this script's time.
GEN_DIR="$(mktemp -d)"
trap 'rm -rf "$GEN_DIR"' EXIT
PREVIEW_SCRIPT="$SCRIPT_DIR/add_preview_vhosts.sh"
ADMIN_SCRIPT="$SCRIPT_DIR/add_admin_vhosts.sh"
if [ -f "$PREVIEW_SCRIPT" ]; then
    { LIST_VHOSTS=1 SITES_CONF="$SITES_CONF" bash "$PREVIEW_SCRIPT" >"$GEN_DIR/preview.list" 2>/dev/null || true; } &
fi
# admin.<domain> is the console, so a machine without one expects none.
if [ -f "$ADMIN_SCRIPT" ] && id -u hosting-manager >/dev/null 2>&1; then
    { SITES_CONF="$SITES_CONF" bash "$ADMIN_SCRIPT" --list >"$GEN_DIR/admin.list" 2>/dev/null || : >"$GEN_DIR/admin.list"; } &
fi
# A generator that predates RENDER_ONLY would IGNORE the variable and run a
# real write, so it is not started at all.
render_start() {
    local key="$1" script="$2"
    [ -f "$script" ] || return 0
    grep -q 'RENDER_ONLY' "$script" || return 0
    { RENDER_ONLY=1 RENDER_OUT="$GEN_DIR/$key.render" SITES_CONF="$SITES_CONF" \
        bash "$script" >/dev/null 2>&1 && : > "$GEN_DIR/$key.ok"; } &
}
render_start app "$SCRIPT_DIR/add_app_vhosts.sh"
render_start preview "$PREVIEW_SCRIPT"

# The hostnames a certificate would be requested for, asked of the generator
# rather than worked out again here. A checker that reimplemented that logic
# could drift from it and agree with neither it nor the vhost generator.
#
# REQUESTED_HOSTS_FILE is that same list, already computed by
# check_generators_agree.sh in the same run. Asking the generator again is a
# whole second pass over the config for an answer that is already known.
REQUESTED_HOSTS=""
if [ -n "${REQUESTED_HOSTS_FILE:-}" ] && [ -s "$REQUESTED_HOSTS_FILE" ]; then
    REQUESTED_HOSTS="$(sort -u "$REQUESTED_HOSTS_FILE")"
else
    CERT_SCRIPT="$SCRIPT_DIR/add_site_certificates.sh"
    if [ -f "$CERT_SCRIPT" ]; then
        # ONLY_ROWS cleared: this list decides which certificates are ORPHAN, and
        # --prune deletes those. A list narrowed to the changed rows would call
        # every other certificate an orphan.
        REQUESTED_HOSTS="$(LIST_HOSTS=1 ONLY_ROWS= SITES_CONF="$SITES_CONF" bash "$CERT_SCRIPT" 2>/dev/null | sort -u || true)"
    fi
fi

# =============================================================================
# What the config says should exist
# =============================================================================
declare -A EXPECTED_VHOST=()
declare -A EXPECTED_UNIT=()
declare -A UNIT_WANTED=()
declare -A EXPECTED_SECRET=()
declare -A EXPECTED_DOCROOT=()
declare -A EXPECTED_POOL=()

# Duplicated verbatim from add_app_vhosts.sh, which is the rule for this name.
site_account() {
    local n
    n="site_$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_' '_')"
    if [ ${#n} -gt 32 ]; then
        n="${n:0:23}_$(printf '%s' "$1" | md5sum | cut -c1-8)"
    fi
    printf '%s' "$n"
}

# The catch-all redirects to BASE_DOMAIN, so a machine without one has none.
[ -n "$(conf_get BASE_DOMAIN "")" ] && EXPECTED_VHOST["000-catchall.conf"]=1
DEPRECATED="$(conf_get DEPRECATED_DOMAINS "")"
if [ -n "$DEPRECATED" ]; then
    IFS=',' read -r -a dep_list <<< "$DEPRECATED"
    for d in "${dep_list[@]}"; do
        d="$(trim "$d")"
        [ -n "$d" ] && EXPECTED_VHOST["010-deprecated-${d}.conf"]=1
    done
fi

while IFS='|' read -r type name port path sub datasource options auth repo branch rowenvs authusers repomode runtime enabled owner; do
    type="$(trim "$type")"; name="$(trim "$name")"; sub="$(trim "$sub")"
    [ -z "$name" ] && continue

    if [ "$type" = "app" ]; then
        EXPECTED_SECRET["$name.env"]=1
        for e in "${ALL_ENVS[@]}"; do
            row_in_env "$rowenvs" "$e" || continue
            eu="${e^^}"
            suffix="$(conf_get "${eu}_UNIT_SUFFIX" "")"
            EXPECTED_UNIT["app-${name}${suffix}.service"]=1
            UNIT_WANTED["app-${name}${suffix}.service"]="$(printf '%s' "$enabled" | tr -d ' \r' | tr '[:upper:]' '[:lower:]')"
        done
    fi

    case "$type" in
        website|php|docroot)
            EXPECTED_POOL["$(site_account "$name")"]=1
            for e in "${ALL_ENVS[@]}"; do
                row_in_env "$rowenvs" "$e" || continue
                eu="${e^^}"
                web="$(conf_get "WEB_ROOT_${eu}" "")"
                p="$(trim "$path")"
                [ -n "$web" ] && [ -n "$p" ] && EXPECTED_DOCROOT["${web%/}/${p#/}"]=1
            done
            ;;
    esac

    [ "$type" = "mailbox" ] && continue
    [ -z "$sub" ] && continue
    for e in "${PUBLISH_ENVS[@]}"; do
        row_in_env "$rowenvs" "$e" || continue
        case "$type" in
            proxy) [ "$e" != "$DEFAULT_ENV" ] && continue ;;
        esac
        EXPECTED_VHOST["${name}-${e}.conf"]=1
    done
done < <(conf_rows)

# The previews, asked of the generator rather than worked out here. Which ones
# exist depends on the row's port, its environments and its AuthProtected, and a
# second implementation of those rules would drift from the first.
wait

PREVIEW_ASKED=0
if [ -f "$GEN_DIR/preview.list" ]; then
    while read -r b; do
        [ -n "$b" ] || continue
        EXPECTED_VHOST["$b"]=1
        PREVIEW_ASKED=1
    done < "$GEN_DIR/preview.list"
fi

# WEBMAIL AND ADMIN, the two sets of vhosts that come from DERIVED names rather
# than from rows, and both were wrong here in opposite directions.
#
#   webmail.<domain>  carried the generated header and was in nobody's expected
#                     list, so all three were reported ORPHAN on every run and
#                     --prune would have deleted a working webmail.
#   admin.<domain>    carried no header at all, so drift could not see it: a
#                     stale one would never have been reported.
#
# Both are asked of the script that writes them, exactly as the previews are: a
# second implementation of "which names exist" is a second implementation to
# drift apart.
if [ -d "$(conf_get WEBMAIL_ROOT /var/lib/roundcube/public_html)" ]; then
    while IFS='|' read -r _t _n _p _pa sub _rest; do
        _t="$(printf '%s' "${_t//$'\r'/}" | xargs)"
        [ "$_t" = "mailbox" ] || continue
        sub="$(printf '%s' "${sub//$'\r'/}" | xargs)"
        # conf_get, not a variable: BASE_DOMAIN is read further down in this
        # script and did not exist yet here, so a mailbox on the base domain
        # expected "020-webmail-.conf" and the real one stayed orphaned.
        { [ -z "$sub" ] || [ "$sub" = "-" ]; } && sub="$(conf_get BASE_DOMAIN "")"
        [ -n "$sub" ] || continue
        EXPECTED_VHOST["020-webmail-${sub}.conf"]=1
    done < <(conf_rows)
fi

if [ -f "$GEN_DIR/admin.list" ]; then
    while read -r _h; do
        [ -n "$_h" ] || continue
        EXPECTED_VHOST["admin-${_h}.conf"]=1
    done < "$GEN_DIR/admin.list"
fi

# =============================================================================
# What is on the machine
# =============================================================================
ADD=(); OK_LIST=(); ORPHAN=()

for f in "${!EXPECTED_VHOST[@]}"; do
    if [ ! -f "$AVAILABLE_DIR/$f" ]; then
        ADD+=("vhost   $f")
    else
        OK_LIST+=("vhost   $f")
    fi
done

for u in "${!EXPECTED_UNIT[@]}"; do
    if [ ! -f "$UNIT_DIR/$u" ]; then
        ADD+=("unit    $u")
    else
        OK_LIST+=("unit    $u")
    fi
done

# Orphans: ours by header, no longer wanted.
#
# preview-*.conf is judged only when the generator could be asked above. An
# empty answer means it could not run, and every preview would then look
# orphaned, which --prune would act on.
PREVIEW_SKIPPED=0
if [ -d "$AVAILABLE_DIR" ]; then
    for f in "$AVAILABLE_DIR"/*.conf; do
        [ -f "$f" ] || continue
        b="${f##*/}"
        if [ "$PREVIEW_ASKED" != "1" ]; then
            case "$b" in preview-*) PREVIEW_SKIPPED=$((PREVIEW_SKIPPED + 1)); continue ;; esac
        fi
        [ -n "${EXPECTED_VHOST[$b]:-}" ] && continue
        case "$b" in
            preview-*) ORPHAN+=("vhost   $b") ;;
            *) grep -qs "$GENERATED_MARK" "$f" && ORPHAN+=("vhost   $b") ;;
        esac
    done
fi
for f in "$UNIT_DIR"/app-*.service; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    [ -n "${EXPECTED_UNIT[$b]:-}" ] && continue
    grep -qs "$GENERATED_MARK" "$f" && ORPHAN+=("unit    $b")
done

# =============================================================================
# MACHINE PAGES. Invisible to the scan above, and that was a real blind spot.
#
# add_panel_vhosts.sh writes panel-<id>.conf with its OWN header, "Generated by
# add_panel_vhosts.sh", not the GENERATED_MARK the scan greps for. So a stale
# machine page vhost was never reported: Apache served it, the drift report
# said nothing differed, and the only thing that would ever remove it was
# somebody running add_panel_vhosts.sh --prune by hand.
#
# Reported as its own kind, `panel`, rather than as `vhost`. prune_orphans.sh
# does not know that kind and says so and leaves it alone, which is correct:
# the panel script prunes its own, and the apply already runs it with --prune
# BEFORE the general prune. This closes the reporting gap without moving the
# ownership of the file.
# =============================================================================
declare -A EXPECTED_PANEL=()
while IFS='|' read -r p_id _rest; do
    p_id="$(printf '%s' "${p_id#*=}" | tr -d '\r' | xargs)"
    [ -n "$p_id" ] && EXPECTED_PANEL["panel-${p_id}.conf"]=1
done < <(grep -E '^[[:space:]]*PANEL[[:space:]]*=' "$SITES_CONF" 2>/dev/null || true)

if [ -d "$AVAILABLE_DIR" ]; then
    for f in "$AVAILABLE_DIR"/panel-*.conf; do
        [ -f "$f" ] || continue
        b="${f##*/}"
        [ -n "${EXPECTED_PANEL[$b]:-}" ] && continue
        ORPHAN+=("panel   $b")
    done
fi

# The other direction: a PANEL line with a kind gets a vhost, and a new one
# must show as something to add, or Make it live never appears for it.
while IFS='|' read -r p_id _p_port _p_label p_kind _rest; do
    p_id="$(printf '%s' "${p_id#*=}" | tr -d '\r' | xargs)"
    p_kind="$(printf '%s' "$p_kind" | tr -d '\r' | xargs)"
    [ -n "$p_id" ] && [ -n "$p_kind" ] || continue
    # A dash is `itself`: the page's own installer owns its vhost.
    case "$p_kind" in -|itself) continue ;; esac
    case ",$(conf_get PANELS_OFF "" | tr -d ' ')," in *",${p_id},"*) continue ;; esac
    [ -f "$AVAILABLE_DIR/panel-${p_id}.conf" ] || ADD+=("panel   panel-${p_id}.conf")
done < <(grep -E '^[[:space:]]*PANEL[[:space:]]*=' "$SITES_CONF" 2>/dev/null || true)

# =============================================================================
# JENKINS FOLDERS. The other blind spot, and the more expensive one.
#
# A deleted row leaves its jobs behind: the apply prunes vhosts, units,
# certificates and document roots, and nothing in it touches Jenkins. Measured
# twice on 2026-09-04, with pngtest and blazortest: drift said "Nothing
# differs" while the row's folder was still in /var/lib/jenkins/jobs.
#
# Same treatment: reported as `jenkins`, not pruned here.
# add_jenkins_site_jobs.sh --prune owns those, deletes through the API so
# Jenkins forgets the job rather than writing a skeleton back, and item 50 is
# the whole story of why doing it any other way is wrong.
#
# Only folders carrying the generated mark, and only when the jobs directory is
# readable: a machine with no Jenkins reports nothing rather than everything.
# =============================================================================
declare -A EXPECTED_JOBFOLDER=()
while IFS='|' read -r j_type j_name _rest; do
    j_type="$(printf '%s' "$j_type" | tr -d '\r' | xargs)"
    j_name="$(printf '%s' "$j_name" | tr -d '\r' | xargs)"
    # add_jenkins_site_jobs.sh makes a folder for rows that deploy something.
    # A mailbox has no unit and no vhost and gets none, which that script says
    # out loud on every run.
    case "$j_type" in app|website|php|docroot) ;; *) continue ;; esac
    [ -n "$j_name" ] && EXPECTED_JOBFOLDER["$j_name"]=1
done < <(conf_rows)

JENKINS_JOBS_DIR="${JENKINS_JOBS_DIR:-/var/lib/jenkins/jobs}"
if [ -d "$JENKINS_JOBS_DIR" ] && [ -r "$JENKINS_JOBS_DIR" ]; then
    for d in "$JENKINS_JOBS_DIR"/*/; do
        [ -d "$d" ] || continue
        b="$(basename "$d")"
        # The three folders the installers own, which no row asks for.
        case "$b" in csharp|jenkins|machine) continue ;; esac
        [ -n "${EXPECTED_JOBFOLDER[$b]:-}" ] && continue
        ORPHAN+=("jenkins $b")
    done
fi


# A secrets file whose app row is gone. It is generated per app row by
# add_app_secrets.sh and holds nothing else, so nothing a human keeps elsewhere
# is at stake; an inert template left behind would still name a row that does
# not exist, which is what made this invisible.
SECRETS_DIR="${SECRETS_DIR:-/etc/app-secrets}"
if [ -d "$SECRETS_DIR" ]; then
    for f in "$SECRETS_DIR"/*.env; do
        [ -f "$f" ] || continue
        b="${f##*/}"
        [ -n "${EXPECTED_SECRET[$b]:-}" ] && continue
        ORPHAN+=("secrets $b")
    done
fi
# A certificate lineage no row asks for any more. certbot names a lineage after
# the first -d, so the name is usually the hostname, and /etc/letsencrypt/renewal
# holds one .conf per lineage. Deleting one costs an issuance to undo, so every
# doubtful case is left alone rather than reported:
#
#   - an empty REQUESTED_HOSTS means the generator could not be asked, and every
#     lineage would then look orphaned;
#   - example.com-0001 is certbot's name for a SECOND lineage of a hostname that
#     is still wanted, so the -NNNN suffix is stripped before comparing;
#   - a vhost nobody generated can still point at a lineage. Those carry no
#     GENERATED_MARK and are invisible to the scan above, so they are searched
#     for the certificate directory. Only those: a GENERATED vhost naming the
#     lineage is often the very one being pruned alongside it.
#
# Collected in one pass rather than per lineage. Asking "does any hand-written
# vhost name this certificate" once per lineage meant re-reading every vhost on
# the machine every time: 22 lineages against 28 files is 600 greps to answer
# what one pass answers.
declare -A CERT_IN_USE=()
if [ -d "$AVAILABLE_DIR" ]; then
    for v in "$AVAILABLE_DIR"/*.conf; do
        [ -f "$v" ] || continue
        grep -qs "$GENERATED_MARK" "$v" && continue
        while IFS= read -r used; do
            [ -n "$used" ] && CERT_IN_USE["$used"]=1
        done < <(sed -n 's|.*/etc/letsencrypt/live/\([^/]*\)/.*|\1|p' "$v")
    done
fi

CERT_WARNING=""
if [ -d /etc/letsencrypt/renewal ]; then
    if [ -z "$REQUESTED_HOSTS" ]; then
        CERT_WARNING="the certificate hostname list is empty, so no certificate was checked for orphans"
    else
        # Hashed once. Two greps down a list per lineage was two forks and a
        # linear scan each time, for a question asked 22 times.
        declare -A WANTED_HOST=()
        while IFS= read -r h; do
            [ -n "$h" ] && WANTED_HOST["$h"]=1
        done <<< "$REQUESTED_HOSTS"

        for f in /etc/letsencrypt/renewal/*.conf; do
            [ -f "$f" ] || continue
            lineage="${f##*/}"
            lineage="${lineage%.conf}"
            [ -n "${WANTED_HOST[$lineage]:-}" ] && continue
            # example.com-0001 is certbot's name for a second lineage of a
            # hostname that is still wanted.
            base="${lineage%-[0-9][0-9][0-9][0-9]}"
            [ -n "${WANTED_HOST[$base]:-}" ] && continue
            [ -n "${CERT_IN_USE[$lineage]:-}" ] && continue
            ORPHAN+=("cert    $lineage")

            # THE OTHER HALF OF THE SAME LEFTOVER, and reporting only the
            # certificate hid it. A lineage no row asks for can still be named
            # by a service whose config is not derived from rows: Dovecot and
            # Postfix are pointed at mail.<domain>, which is requested per
            # MAILBOX row, so deleting the last mailbox leaves both configs
            # naming a certificate nothing wants.
            #
            # Named rather than silenced. prune_orphans.sh:246 already refuses
            # to delete such a lineage, so without this line the report says
            # "orphan" while the prune says "still in use" and neither says the
            # config is what needs closing.
            #
            # Apache is not scanned here: its vhosts ARE derived from rows and
            # are already reported as orphan vhosts in their own right.
            while IFS= read -r _cfg; do
                [ -n "$_cfg" ] && ORPHAN+=("mailconf $_cfg still names $lineage")
            done < <(grep -RlF "/etc/letsencrypt/live/${lineage}/" \
                        /etc/dovecot /etc/postfix 2>/dev/null | sort -u | head -5)
        done
    fi
fi

# A website's PHP pool and account, left when its row went. Only the vhost
# generator prunes these, and an apply that only deletes rows never runs it.
PHP_POOL_DIR="$(ls -d /etc/php/*/fpm/pool.d 2>/dev/null | sort -V | tail -1)"
for f in ${PHP_POOL_DIR:+"$PHP_POOL_DIR"/site_*.conf}; do
    [ -f "$f" ] || continue
    b="$(basename "$f" .conf)"
    [ -n "${EXPECTED_POOL[$b]:-}" ] && continue
    grep -qs "$GENERATED_MARK" "$f" && ORPHAN+=("pool    $b")
done

# A document root no row asks for any more. There is no generated mark to go on:
# a directory carries no header, so the only evidence is that it sits directly
# inside a WEB_ROOT this config defines. That is why whatever prunes one MOVES
# it aside rather than deleting it, unlike a vhost or a unit.
declare -A SEEN_WEB_ROOT=()
for e in "${ALL_ENVS[@]}"; do
    eu="${e^^}"
    web="$(conf_get "WEB_ROOT_${eu}" "")"
    [ -z "$web" ] && continue
    [ -n "${SEEN_WEB_ROOT[$web]:-}" ] && continue
    SEEN_WEB_ROOT["$web"]=1
    [ -d "$web" ] || continue
    for d in "$web"/*/; do
        [ -d "$d" ] || continue
        d="${d%/}"
        [ -n "${EXPECTED_DOCROOT[$d]:-}" ] && continue
        ORPHAN+=("docroot $d")
    done
done

# -----------------------------------------------------------------------------
# Mail: addresses the machine accepts that no row claims
#
# This report skipped mailbox rows entirely, so on 2026-09-02 it said "nothing
# differs" while Postfix accepted mail for six addresses the config had never
# heard of, and five of them could not be read by anyone because their Dovecot
# lines were gone too. A delivery map that outlives its config is not a
# cosmetic difference: mail arrives and lands where nothing is looking.
#
# The MAILDIR IS NOT REPORTED. Removing an address deliberately leaves the
# messages on disk, forwarded or retired, so a maildir without a row is the
# expected end state of a soft delete rather than drift. What is drift is the
# machine still ACCEPTING or AUTHENTICATING an address nothing claims.
# -----------------------------------------------------------------------------
MAIL_BASE="$(conf_get BASE_DOMAIN "")"
declare -A EXPECTED_ADDR=()
while IFS='|' read -r type local _p _path dom _rest; do
    [ "$(trim "$type")" = "mailbox" ] || continue
    # trim() turns a bare '-' into an empty string, which for a mailbox row's
    # domain means the base domain, exactly as the file reads it.
    l="$(trim "$local")"; d="$(trim "$dom")"
    [ -z "$l" ] && continue
    [ -z "$d" ] && d="$MAIL_BASE"
    [ -n "$d" ] && EXPECTED_ADDR["${l}@${d}"]=1
done < <(grep -E '^[[:space:]]*mailbox[[:space:]]*\|' "$SITES_CONF" 2>/dev/null || true)

mail_orphans_in() {
    local file="$1" what="$2" a
    [ -f "$file" ] || return 0
    while read -r a _; do
        [ -n "$a" ] || continue
        case "$a" in \#*) continue ;; esac
        [ -n "${EXPECTED_ADDR[$a]:-}" ] && continue
        ORPHAN+=("mail    $what $a")
    done < "$file"
}

mail_orphans_in /etc/postfix/virtual_mailbox_map delivery
mail_orphans_in /etc/postfix/sender_login_map    sender
mail_orphans_in /etc/postfix/virtual_forwards    forward

if [ -f /etc/dovecot/users ]; then
    while IFS=: read -r a _rest; do
        [ -n "$a" ] || continue
        case "$a" in \#*) continue ;; esac
        [ -n "${EXPECTED_ADDR[$a]:-}" ] && continue
        ORPHAN+=("mail    login $a")
    done < /etc/dovecot/users
fi

# THE OTHER DIRECTION, and it was missing entirely. Everything above asks "does
# the machine serve something no row claims". Nothing asked "does a row claim
# something the machine does not serve", so a mailbox added from the console
# reported SUCCESS and did nothing at all.
#
# Measured 2026-09-06: three mailboxes were created from the website drawer, the
# console showed "Mailboxes 3", apply-config build 196 went SUCCESS, and
# /etc/dovecot/users was EMPTY. maintain_services.sh never calls add_dovecot.sh
# or add_postfix.sh: the mail scripts run at install time only.
#
# Reported rather than fixed here, because the fix is a decision about how a
# password reaches a mailbox the pipeline creates, and a silent nothing is the
# part that has to stop today.
declare -A HAVE_LOGIN=()
declare -A HAVE_DELIVERY=()
if [ -f /etc/dovecot/users ]; then
    while IFS=: read -r a _rest; do
        [ -n "$a" ] && HAVE_LOGIN["$a"]=1
    done < /etc/dovecot/users
fi
if [ -f /etc/postfix/virtual_mailbox_map ]; then
    while read -r a _rest; do
        [ -n "$a" ] && HAVE_DELIVERY["$a"]=1
    done < /etc/postfix/virtual_mailbox_map
fi
# "mail login <addr>" said WHAT was missing and nothing about how to get it,
# and this is the one drift item no button can fix: add_dovecot.sh refuses to
# create an account without a password, on purpose, so Fix drift and Make it
# live both leave it exactly as it was. The owner pressed both on 2026-09-09 and
# then asked what the line meant.
#
# So the line carries the fix. It is the only place a person reads this.
for a in "${!EXPECTED_ADDR[@]}"; do
    [ -n "${HAVE_LOGIN[$a]:-}" ] || ADD+=("mail    login $a  <- no password yet, set it from its row in the console")
    [ -n "${HAVE_DELIVERY[$a]:-}" ] || ADD+=("mail    delivery $a")
done

# A mail domain with no DKIM key signs nothing, and the only place that said so
# was go_live.sh, which is a button most people never press. The key is per
# DOMAIN, not per address, so it is checked once per distinct domain.
DKIM_DIR="$(conf_get MAIL_DKIM_DIR /var/lib/rspamd/dkim)"
DKIM_SELECTOR="$(conf_get MAIL_DKIM_SELECTOR mail)"
declare -A SEEN_MAIL_DOMAIN=()
for a in "${!EXPECTED_ADDR[@]}"; do
    d="${a#*@}"
    [ -n "${SEEN_MAIL_DOMAIN[$d]:-}" ] && continue
    SEEN_MAIL_DOMAIN["$d"]=1
    [ -f "${DKIM_DIR}/${d}.${DKIM_SELECTOR}.key" ] || \
        ADD+=("mail    dkim $d  <- outgoing mail is not signed, Make it live creates the key")
done

# =============================================================================
# UPDATE: what exists but would be REWRITTEN
#
# Everything above answers "does it exist". That is not the same question as
# "would applying change anything", and the difference had a cost: flipping a
# login said "Nothing differs" and Apply then rewrote the vhost. Reported by
# The owner on 2026-08-25 and closed here on 2026-08-26.
#
# The generators answer it, in RENDER_ONLY mode, because they are the only
# things that know what a vhost should contain. A comparison written here would
# be a second implementation of that, and it would drift from both.
#
# Skipped when the generators are not beside this script, so a copy of this file
# on its own still runs and simply reports one question less.
# =============================================================================
UPDATE=()
UPDATE_CHECKED=0

# Collected from render_start near the top. A generator that did not start or
# did not finish leaves no .ok file, and reports nothing.
render_updates() {
    local key="$1"
    [ -f "$GEN_DIR/$key.ok" ] || return 0
    UPDATE_CHECKED=1
    [ -f "$GEN_DIR/$key.render" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] && UPDATE+=("${line#UPDATE }")
    done < "$GEN_DIR/$key.render"
}

render_updates app
render_updates preview

# The unit file existing says nothing about whether it runs. The apply stops a
# disabled row's unit, so an enabled or running one here is a stop that never
# happened.
for u in "${!UNIT_WANTED[@]}"; do
    [ -f "$UNIT_DIR/$u" ] || continue
    state="$(systemctl is-enabled "$u" 2>/dev/null || true)"
    if [ "${UNIT_WANTED[$u]}" = "no" ] && [ "$state" = "enabled" ]; then
        UPDATE+=("unit    $u  <- the row is disabled but the unit still starts")
    elif [ "${UNIT_WANTED[$u]}" = "no" ] \
         && case "$(systemctl is-active "$u" 2>/dev/null)" in
                active|activating|reloading) true ;; *) false ;; esac; then
        UPDATE+=("unit    $u  <- the row is disabled but the unit is running")
    elif [ "${UNIT_WANTED[$u]}" != "no" ] && [ "$state" = "disabled" ]; then
        UPDATE+=("unit    $u  <- the row is enabled but the unit is switched off")
    fi
done


# -----------------------------------------------------------------------------
# The vault against the machine
#
# Asked of person_entry.sh rather than worked out here, for the same reason the
# vhost questions are asked of their generators: it owns the entry naming and
# the domain-owner rule, and a second copy would drift from it.
#
# Skipped without a sound when person_entry.sh is not beside this script or the
# store is not set up. This report runs on machines that have no vault.
#
# It is the one check that READS SECRETS, so it runs only as root and its
# output carries states, never values.
# -----------------------------------------------------------------------------
PERSON_ENTRY="$SCRIPT_DIR/person_entry.sh"
[ -f "$PERSON_ENTRY" ] || PERSON_ENTRY=/usr/local/sbin/person_entry.sh
if [ -f "$PERSON_ENTRY" ] && [ "${EUID:-$(id -u)}" -eq 0 ] && [ "${DRIFT_SKIP_VAULT:-0}" != "1" ]; then
    while IFS=$'\t' read -r st who _owner note; do
        [ -n "$st" ] || continue
        case "$st" in
            OK)       OK_LIST+=("vault   mailbox $who") ;;
            MISSING)  ADD+=("vault   mailbox $who  <- $note") ;;
            WRONG)    UPDATE+=("vault   mailbox $who  <- $note, set it again from its row") ;;
            MOVED)    UPDATE+=("vault   mailbox $who  <- $note") ;;
            STALE)    ORPHAN+=("vault   mailbox $who  <- $note") ;;
            NOBOX)    ORPHAN+=("vault   mailbox $who  <- $note") ;;
            NOOWNER)  OK_LIST+=("vault   mailbox $who  ($note)") ;;
            UNKNOWN)  print_info "Vault: $note" ;;
        esac
    done < <(SITES_CONF="$SITES_CONF" bash "$PERSON_ENTRY" --audit 2>/dev/null || true)
fi
# =============================================================================
# Report
# =============================================================================
# Only what differs is printed. Forty-odd OK lines are the same fact as their
# count, and burying two orphans in them is how a report stops being read.
# DRIFT_VERBOSE=1 prints them, and DRIFT_OUT always holds every line.
print_header "Drift"
for x in "${ADD[@]:-}";     do [ -n "$x" ] && printf "\033[32mADD      %s\033[0m\n" "$x"; done
if [ "${DRIFT_VERBOSE:-0}" = "1" ]; then
    for x in "${OK_LIST[@]:-}"; do [ -n "$x" ] && printf "\033[34mOK       %s\033[0m\n" "$x"; done
fi
for x in "${UPDATE[@]:-}";  do [ -n "$x" ] && printf "\033[33mUPDATE   %s\033[0m\n" "$x"; done
for x in "${ORPHAN[@]:-}";  do [ -n "$x" ] && printf "\033[31mORPHAN   %s\033[0m\n" "$x"; done
if [ ${#ADD[@]} -eq 0 ] && [ ${#ORPHAN[@]} -eq 0 ] && [ ${#UPDATE[@]} -eq 0 ]; then
    print_success "Nothing differs."
fi

echo ""
[ "$PREVIEW_SKIPPED" -gt 0 ] && print_info "$PREVIEW_SKIPPED preview vhost(s) not checked here. Run add_preview_vhosts.sh to add or remove one."
[ -n "$CERT_WARNING" ] && print_info "$CERT_WARNING"
print_status "$(( ${#ADD[@]} )) to add, $(( ${#UPDATE[@]} )) to rewrite, $(( ${#OK_LIST[@]} )) already present, $(( ${#ORPHAN[@]} )) orphaned."
[ "${DRIFT_VERBOSE:-0}" = "1" ] || print_status "DRIFT_VERBOSE=1 lists the ones already present."
[ "$UPDATE_CHECKED" = "1" ] || print_status "The generators were not beside this script, so nothing was checked for content."

if [ -n "$DRIFT_OUT" ]; then
    : > "$DRIFT_OUT"
    for x in "${ADD[@]:-}";     do [ -n "$x" ] && printf 'ADD %s\n'    "$x" >> "$DRIFT_OUT"; done
    for x in "${OK_LIST[@]:-}"; do [ -n "$x" ] && printf 'OK %s\n'     "$x" >> "$DRIFT_OUT"; done
    for x in "${UPDATE[@]:-}";  do [ -n "$x" ] && printf 'UPDATE %s\n' "$x" >> "$DRIFT_OUT"; done
    for x in "${ORPHAN[@]:-}";  do [ -n "$x" ] && printf 'ORPHAN %s\n' "$x" >> "$DRIFT_OUT"; done
fi

exit 0
