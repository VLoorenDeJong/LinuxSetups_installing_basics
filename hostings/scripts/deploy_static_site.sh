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
# Deploy a static or PHP website from a checkout into its live document root.
#
#   ./deploy_static_site.sh <site-name> <source-dir>
#   ./deploy_static_site.sh example_org ./
#
# Called by a Jenkinsfile after `checkout scm`, but it is a normal script and
# running it by hand is the expected way to learn it and to recover when a
# pipeline breaks.
#
# NO SUDO, ON PURPOSE
#
# deploy_app.sh needs root because it runs `systemctl restart`. A website has no
# service to restart, so this script only writes files and needs no privilege
# beyond ownership of the target directory, which add_app_vhosts.sh sets:
#
#   jenkins:site_<row>, 2750, so the row's own PHP account and Apache read it
#   and no other site's account can enter it (item 146)
#
# Jenkins writes, Apache reads, nothing runs as root. A smaller blast radius
# than a sudoers rule, and one fewer file to maintain.
#
# WHAT MAKES IT SAFE TO RUN ON A LIVE SITE
#
#   1. Nothing touches the live folder until the source has been checked. An
#      empty or wrong directory is refused before any copy starts.
#   2. --delete-after, so removals happen at the end rather than partway
#      through. A failure leaves the old files in place rather than a site with
#      its stylesheets deleted and its pages not yet replaced.
#   3. .git is never copied. The repository, its history and its remote URLs
#      must not be downloadable from the web root.
#   4. The result is verified after the copy, not assumed.
#
# Rollback is re-running the previous build: the repository holds every version.
# =============================================================================

# --- Inline utility functions (always defined, no sourcing required) ---
print_status() {
    printf "\033[34m🔧 %s\033[0m\n" "$1"
}

print_success() {
    printf "\033[32m✅ %s\033[0m\n" "$1"
}

print_warning() {
    printf "\033[33m⚠️ %s\033[0m\n" "$1"
}

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

usage() {
    echo "Usage: $0 <site-name> <source-dir> [env]" >&2
    echo "" >&2
    echo "  site-name   a website row name from the config, e.g. example_org" >&2
    echo "  source-dir  the checkout to publish, usually . in a Jenkins workspace" >&2
    echo "  env         an environment from ENVS. Defaults to the first, the live one." >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  SITES_CONF     override the config location" >&2
    echo "  HEALTH_URL     URL to check after deploying, default none" >&2
    echo "  EXTRA_EXCLUDES space separated rsync excludes, added to the defaults" >&2
    echo "  DRY_RUN=1      show what would change, copy nothing" >&2
    exit 1
}

SITE_NAME="$1"
SOURCE_DIR="$2"
ENV_NAME="${3:-}"
[ -z "$SITE_NAME" ] && usage
[ -z "$SOURCE_DIR" ] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Config not found: $SITES_CONF"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    print_error "Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

# -----------------------------------------------------------------------------
# Config readers. Duplicated verbatim rather than sourced, so this script stays
# runnable on its own on a machine that has only this file copied to it.
# -----------------------------------------------------------------------------
# Memoised: this is called once per key per row per environment, and each
# uncached call forks four processes. Without the cache a pre-flight on a
# ten row config spends most of its time in fork rather than doing anything.
declare -A _CONF_CACHE=()
conf_get() {
    local key="$1" default="$2" value
    if [ -n "${_CONF_CACHE[$key]+set}" ]; then
        value="${_CONF_CACHE[$key]}"
    else
        value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
        # tr -d '\r': xargs does not strip a carriage return, and a value is
        # the last thing on its line, so a CRLF config leaves one in it.
        value="$(echo "$value" | tr -d '\r' | sed 's/#.*//' | xargs)"
        _CONF_CACHE[$key]="$value"
    fi
    echo "${value:-$default}"
}

conf_rows() {
    # One awk pass. A bash read loop over the whole file cost 0.2s per call.
    # A SETTING line is skipped even when it holds pipes, as PANEL lines do.
    awk '{ sub(/#.*/, "") } /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next } /\|/' "$SITES_CONF"
}

# A field holding a single dash means empty. `| | |` cannot be counted by eye.
trim() {
    # Pure bash: no echo, no xargs. This is called once per field per row per
    # environment, and each fork costs more than the work it does.
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

# -----------------------------------------------------------------------------
# Find the row and check it is the right kind
# -----------------------------------------------------------------------------
FOUND=0
while IFS='|' read -r type name port path sub datasource options auth repo branch rowenvs authusers repomode runtime enabled owner; do
    [ "$(trim "$name")" = "$SITE_NAME" ] || continue
    TYPE="$(trim "$type")"
    REL_ROOT="$(trim "$path")"
    SUBDOMAIN="$(trim "$sub")"
    SITE_REPO="$(trim "$repo")"
    ROW_ENVS="$(trim "$rowenvs")"
    ROW_BRANCH="$(trim "$branch")"
    FOUND=1
    break
done < <(conf_rows)

if [ "$FOUND" -ne 1 ]; then
    print_error "No row named '$SITE_NAME' in $SITES_CONF"
    exit 1
fi

# -----------------------------------------------------------------------------
# Which environment. Defaults to the first in ENVS, the live one, so a two
# argument call still deploys to production exactly as before.
# -----------------------------------------------------------------------------
IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS live)"
for i in "${!ALL_ENVS[@]}"; do ALL_ENVS[$i]="$(trim "${ALL_ENVS[$i]}")"; done
[ -z "$ENV_NAME" ] && ENV_NAME="${ALL_ENVS[0]}"

ENV_KNOWN=0
for e in "${ALL_ENVS[@]}"; do
    [ "$e" = "$ENV_NAME" ] && ENV_KNOWN=1
done
if [ "$ENV_KNOWN" -ne 1 ]; then
    print_error "'$ENV_NAME' is not in ENVS."
    print_info "Known environments: $(conf_get ENVS live)"
    exit 1
fi

# A row can be limited to certain environments. Deploying to one it does not
# exist in would create a document root no vhost points at, so it is refused
# rather than silently producing a directory nobody serves.
if [ -n "$ROW_ENVS" ]; then
    IN_ENV=0
    IFS=',' read -r -a ROW_ENV_LIST <<< "$ROW_ENVS"
    for e in "${ROW_ENV_LIST[@]}"; do
        [ "$(echo "$e" | xargs)" = "$ENV_NAME" ] && IN_ENV=1
    done
    if [ "$IN_ENV" -ne 1 ]; then
        print_error "'$SITE_NAME' does not exist in the '$ENV_NAME' environment."
        print_info "Its Envs field lists: $ROW_ENVS"
        exit 1
    fi
fi

ENV_UPPER="$(echo "$ENV_NAME" | tr '[:lower:]' '[:upper:]')"
WEB_ROOT="$(conf_get "WEB_ROOT_${ENV_UPPER}" "")"
if [ -z "$WEB_ROOT" ]; then
    print_error "No WEB_ROOT_${ENV_UPPER} in $SITES_CONF"
    exit 1
fi

# The row holds a folder name relative to the environment's web root. That is
# what lets one row serve every environment from its own directory.
DOC_ROOT="${WEB_ROOT%/}/${REL_ROOT#/}"

# The branch this environment deploys from, unless the row overrides it. The
# demo instance is the reason the override exists.
DEPLOY_BRANCH="${ROW_BRANCH:-$(conf_get "${ENV_UPPER}_BRANCH" "$ENV_NAME")}"

case "$TYPE" in
    website|php|docroot) ;;
    *)
        print_error "'$SITE_NAME' is a '$TYPE' row, not a website."
        print_info "app rows are deployed with deploy_app.sh instead."
        exit 1
        ;;
esac

if [ -z "$DOC_ROOT" ]; then
    print_error "Row '$SITE_NAME' has no document root."
    exit 1
fi

print_header "Deploying $SITE_NAME ($ENV_NAME)"
print_status "From: $SOURCE_DIR"
print_status "To:   $DOC_ROOT"
print_status "Env:  $ENV_NAME (branch $DEPLOY_BRANCH)"
[ -n "$SITE_REPO" ] && print_status "Repo: $SITE_REPO"

# -----------------------------------------------------------------------------
# Refuse before touching anything.
#
# An empty source with --delete would erase a live website, which is the same
# failure deploy_app.sh guards against with its own empty-publish check.
# -----------------------------------------------------------------------------
if [ -z "$(ls -A "$SOURCE_DIR" 2>/dev/null | grep -v '^\.git$')" ]; then
    print_error "$SOURCE_DIR is empty apart from .git, refusing to deploy."
    print_info "An empty source would delete the live site."
    exit 1
fi

# A website has an entry point. Its absence usually means the checkout is a
# subdirectory deeper or shallower than expected, which is worth catching before
# the copy rather than after.
INDEX_FOUND=0
for f in index.html index.htm index.php index.shtml default.html; do
    [ -f "$SOURCE_DIR/$f" ] && INDEX_FOUND=1 && break
done
if [ "$INDEX_FOUND" -ne 1 ]; then
    print_info "No index file found at the top of $SOURCE_DIR"
    print_info "Deploying anyway, but check the source is the site root."
fi

if [ ! -d "$DOC_ROOT" ]; then
    print_status "Creating $DOC_ROOT"
    mkdir -p "$DOC_ROOT" 2>/dev/null || {
        print_error "Cannot create $DOC_ROOT"
        print_action "Let add_app_vhosts.sh create it with the right owner and group:"
        print_action "  sudo bash hostings/scripts/add_app_vhosts.sh"
        exit 1
    }
fi

if [ ! -w "$DOC_ROOT" ]; then
    print_error "$DOC_ROOT is not writable by $(id -un)."
    print_action "This script deliberately does not use sudo. Let add_app_vhosts.sh set ownership:"
    print_action "  sudo bash hostings/scripts/add_app_vhosts.sh"
    exit 1
fi

# -----------------------------------------------------------------------------
# Copy.
#
# .git is excluded because a repository under the web root means the full source
# and history are downloadable. That is not a theoretical concern: scanners
# probe /.git/config as a matter of routine.
# -----------------------------------------------------------------------------
EXCLUDES=(--exclude '.git' --exclude '.gitignore' --exclude '.gitattributes'
          --exclude '.github' --exclude 'Jenkinsfile' --exclude 'README.md')

if [ -n "${EXTRA_EXCLUDES:-}" ]; then
    for e in $EXTRA_EXCLUDES; do
        EXCLUDES+=(--exclude "$e")
    done
fi

# -rlt, not -a: no -p, -g or -o. The site's group comes from the setgid folder
# add_app_vhosts.sh made, and the top folder's 2750 is never touched, because
# that mode is what keeps every other site's account out.
# --safe-links drops a link pointing out of the site, which Apache would
# otherwise serve from wherever it leads.
RSYNC_FLAGS=(-rlt --safe-links --delete-after --human-readable)
if [ "${DRY_RUN:-0}" = "1" ]; then
    RSYNC_FLAGS+=(--dry-run --itemize-changes)
    print_info "DRY_RUN=1, nothing will be copied."
fi

print_status "Excluding: .git .gitignore .gitattributes .github Jenkinsfile README.md ${EXTRA_EXCLUDES:-}"
print_status "Syncing..."

if ! rsync "${RSYNC_FLAGS[@]}" "${EXCLUDES[@]}" "${SOURCE_DIR%/}/" "${DOC_ROOT%/}/"; then
    print_error "rsync failed. The live site still holds the previous content."
    print_info "--delete-after means removals happen last, so a failure part way"
    print_info "through leaves the old files rather than a half-deleted site."
    exit 1
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
    print_success "Dry run complete, nothing changed."
    exit 0
fi

print_success "Files in place."

# -----------------------------------------------------------------------------
# Verify rather than assume
# -----------------------------------------------------------------------------
if [ -z "$(ls -A "$DOC_ROOT" 2>/dev/null)" ]; then
    print_error "$DOC_ROOT is empty after the copy. Something went wrong."
    exit 1
fi

if [ -d "$DOC_ROOT/.git" ]; then
    print_error "$DOC_ROOT/.git exists, so the repository is inside the web root."
    print_action "Remove it: rm -rf $DOC_ROOT/.git"
    exit 1
fi

# Default to the row's own hostname, so the check needs no configuration
HEALTH_URL="${HEALTH_URL:-}"
if [ -z "$HEALTH_URL" ] && [ -n "$SUBDOMAIN" ]; then
    BASE_DOMAIN="$(sed -n 's/^[[:space:]]*BASE_DOMAIN[[:space:]]*=//p' "$SITES_CONF" | head -n1 | sed 's/#.*//' | xargs)"
    case "$SUBDOMAIN" in
        @)  HEALTH_URL="https://${BASE_DOMAIN}/" ;;
        =*) HEALTH_URL="https://${SUBDOMAIN#=}/" ;;
        *)  HEALTH_URL="https://${SUBDOMAIN}.${BASE_DOMAIN}/" ;;
    esac
fi

if [ -n "$HEALTH_URL" ] && command -v curl >/dev/null 2>&1; then
    print_status "Checking $HEALTH_URL"
    CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$HEALTH_URL" || echo 000)"
    case "$CODE" in
        2*|3*) print_success "Site answered $CODE." ;;
        401)   print_success "Site answered 401, which is correct for a protected site." ;;
        *)
            # A hostname cannot reach this machine until the drive swap: public
            # DNS still points at the old one. Failing the deploy for that says
            # the deploy went wrong when the files are in place and correct, and
            # it is unfixable until the swap, so every deploy of a new site
            # would be red forever.
            #
            # MACHINE_IS_LIVE is the config's own word for which of the two this
            # is, and it already decides staging certificates for the same
            # reason. The check still runs and still reports; it just stops
            # being a verdict on the deploy.
            MACHINE_IS_LIVE="$(sed -n 's/^[[:space:]]*MACHINE_IS_LIVE[[:space:]]*=//p' "$SITES_CONF" \
                | head -n1 | sed 's/#.*//' | xargs)"
            case "${MACHINE_IS_LIVE,,}" in
                y|yes|true|1)
                    print_error "Site answered $CODE."
                    print_action "Files are deployed but the site is not serving them."
                    print_action "Check: sudo apache2ctl -S, and the vhost for $SITE_NAME."
                    exit 1
                    ;;
                *)
                    print_info "Site answered $CODE, and MACHINE_IS_LIVE is no."
                    print_info "   Expected: the name still points at the machine this one replaces."
                    print_info "   The files ARE in place. Check them by IP with a preview port,"
                    print_info "   which is what PREVIEW_ROWS in hostings.conf is for."
                    ;;
            esac
            ;;
    esac
else
    print_info "No health check performed, so the deploy is unverified."
fi

print_success "$SITE_NAME deployed."
