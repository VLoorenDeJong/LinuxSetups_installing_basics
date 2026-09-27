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
# The one door GitHub is allowed through, so a push can start a build.
#
# Jenkins listens on loopback and its LAN door on 10002 is scoped to the local
# subnet, so nothing outside the house can reach it. A webhook needs the
# opposite: GitHub's servers have to get in. This opens the narrowest hole that
# still works.
#
# THREE THINGS STAND IN FRONT OF IT, AND ALL THREE MATTER
#
#   1. Only ONE path is proxied. /github-webhook/ reaches Jenkins; every other
#      URL lands on an empty document root and is refused. The Jenkins UI is
#      not reachable through this door at all.
#   2. Only GitHub's published webhook source ranges get past the firewall.
#      Fetched from api.github.com/meta on every run, because they change.
#   3. HTTPS with a real certificate, so the payload is not readable in flight.
#
# A shared secret is the fourth, and it is NOT set up here: it has to be typed
# into both GitHub and the Jenkins GitHub plugin, and half of it is a web form.
# Until it exists, 1 and 2 are what protect this.
#
# WHY NOT 443
#
# Port 80 and 443 forward to the OLD machine until the drive swap, and 8443
# would sit inside the 8000 live band where a row could later be given the same
# number. 10003 is in the management band beside the other doors: Webmin 10000,
# the console 10001, the Jenkins LAN door 10002.
#
# Safe to re-run: the vhost is rewritten only when it changes, the firewall
# rules are reconciled against GitHub's current list, and Apache is only
# reloaded after configtest passes.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

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

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    print_action "Override with: sudo env SITES_CONF=/path/to/hostings.conf $0"
    exit 1
fi
# -----------------------------------------------------------------------------
# Config readers. Duplicated verbatim into every script that reads this file
# rather than sourced, so each one stays runnable on its own on a machine that
# has only that script copied to it.
# -----------------------------------------------------------------------------
# Memoised: this is called once per key per row per environment, and each
# uncached call forks four processes. Without the cache a pre-flight on a
# ten row config spends most of its time in fork rather than doing anything.
declare -A _CONF_CACHE=()

# Assigns into a caller variable instead of printing, because `$(conf_get ...)`
# is a fork even when the cache answers. Measured 2026-08-17: 1638 clones in one
# LIST_HOSTS run, at 4.3ms each on this machine.
_conf_get() {
    local -n __out="$1"
    # Locals prefixed: a caller passing a target named like one of them would be
    # writing into this function's scope instead of its own.
    local __ck="$2" __cd="$3" __cv
    if [ -n "${_CONF_CACHE[$__ck]+set}" ]; then
        __cv="${_CONF_CACHE[$__ck]}"
    else
        __cv="$(sed -n "s/^[[:space:]]*${__ck}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
        # A CRLF config leaves a carriage return on the end of the value, and
        # _trim only removes whitespace.
        __cv="${__cv//$'\r'/}"
        _trim __cv "${__cv%%#*}"
        _CONF_CACHE[$__ck]="$__cv"
    fi
    __out="${__cv:-$__cd}"
}

conf_get() {
    local _v
    _conf_get _v "$1" "$2"
    echo "$_v"
}

# One clean row per line. A settings line has no pipe and would otherwise parse
# as a row whose type is the whole line.
conf_rows() {
    # One awk pass. A bash read loop over the whole file cost 0.2s per call.
    # A SETTING line is skipped even when it holds pipes, as PANEL lines do.
    awk '{ sub(/#.*/, "") } /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next } /\|/' "$SITES_CONF"
}

# Does this row exist in this environment?
#
# The Envs field is empty for almost everything, meaning all of them. It exists
# because a test environment proves a build runs, which needs one instance of an
# application rather than one per customer: the four progress tenants are live
# only, and a single row covers test.
row_in_env() {
    local list="$1" env="$2" e
    _trim list "$list"
    [ -z "$list" ] && return 0
    IFS=',' read -r -a _re <<< "$list"
    for e in ${_re+"${_re[@]}"}; do
        _trim e "$e"
        [ "$e" = "$env" ] && return 0
    done
    return 1
}

# One place that decides what counts as yes. Accepts y, yes, true and 1 in any
# case; everything else, including empty and a dash, is no. Written once rather
# than as a case pattern at each site, because a value accepted in one script
# and rejected in another is the kind of inconsistency nobody finds quickly.
is_yes() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "${v,,}" in
        y|yes|true|1) return 0 ;;
        *)            return 1 ;;
    esac
}

# A field holding a single dash means empty. Written that way because a row of
# `| | |` cannot be counted by eye, and a miscounted row silently puts a value
# in the wrong column: that is how AuthProtected once landed in the options
# field and would have been parsed as a setting.
trim() {
    # Pure bash: no echo, no xargs. This is called once per field per row per
    # environment, and each fork costs more than the work it does.
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

# The same thing, assigning rather than printing. `$(trim "$x")` still forks for
# the substitution, which is the whole cost in the row loop.
# The locals are named __t and __tv rather than anything readable, because a
# nameref pointing at a caller variable of the same name resolves to the local
# and the value is written to a scope that dies on return.
_trim() {
    local -n __t="$1"
    local __tv="$2"
    __tv="${__tv#"${__tv%%[![:space:]]*}"}"
    __tv="${__tv%"${__tv##*[![:space:]]}"}"
    [ "$__tv" = "-" ] && __tv=""
    __t="$__tv"
}


WEBHOOK_HOST="$(conf_get WEBHOOK_HOST "")"
WEBHOOK_PORT="$(conf_get WEBHOOK_PORT "")"

# The port comes from the jenkins row, the same way add_jenkins.sh reads it.
# One source, so moving it there moves the door with it.
JENKINS_PORT="$(grep -v '^[[:space:]]*#' "$SITES_CONF" 2>/dev/null | grep '|' \
    | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$3); if ($2=="jenkins") print $3}' | head -1)"
JENKINS_PORT="${JENKINS_PORT:-11002}"


AVAILABLE_DIR="/etc/apache2/sites-available"
VHOST_NAME="jenkins-webhook"
VHOST="${AVAILABLE_DIR}/${VHOST_NAME}.conf"
VOID_ROOT="/var/www/webhook-void"
LE_DIR="/etc/letsencrypt/live"
SSL_OPTIONS_FILE="/etc/apache2/conf-available/ssl-options.conf"
GITHUB_META="https://api.github.com/meta"
RANGE_STATE="/var/lib/jenkins-webhook/github-hook-ranges"

# =============================================================================
# Pre-flight. Nothing is written until every one of these passes.
# =============================================================================
print_header "Webhook door"
ERRORS=()

[ -z "$WEBHOOK_HOST" ] && ERRORS+=("No WEBHOOK_HOST in $SITES_CONF. It is the name GitHub will post to.")
[ -z "$WEBHOOK_PORT" ] && ERRORS+=("No WEBHOOK_PORT in $SITES_CONF. Use a number in the 10000 management band.")

if [ -n "$WEBHOOK_PORT" ] && ! [[ "$WEBHOOK_PORT" =~ ^[0-9]+$ ]]; then
    ERRORS+=("WEBHOOK_PORT '$WEBHOOK_PORT' is not a number.")
fi

# The environment bands are 5000 to 8999 and a row could later be given any
# number in them. A door that quietly took one would collide with a real site.
if [[ "$WEBHOOK_PORT" =~ ^[0-9]+$ ]] && [ "$WEBHOOK_PORT" -ge 5000 ] && [ "$WEBHOOK_PORT" -le 8999 ]; then
    ERRORS+=("WEBHOOK_PORT $WEBHOOK_PORT is inside the 5000-8999 environment bands, where rows live. Use the 10000 management band.")
fi

# Against the rows too, because check_config.sh does not know about this port.
if [[ "$WEBHOOK_PORT" =~ ^[0-9]+$ ]]; then
    while IFS='|' read -r type name port rest; do
        _trim port "$port"
        [ "$port" = "$WEBHOOK_PORT" ] && ERRORS+=("WEBHOOK_PORT $WEBHOOK_PORT is already the Port of row '$(trim "$name")'.")
    done < <(conf_rows)
fi

if [ -n "$WEBHOOK_HOST" ] && [ ! -f "${LE_DIR}/${WEBHOOK_HOST}/fullchain.pem" ]; then
    ERRORS+=("No certificate for ${WEBHOOK_HOST}. GitHub will not post to a name it cannot verify.")
    ERRORS+=("   Issue one first: sudo bash hostings/scripts/add_site_certificates.sh")
fi

if ! ss -lnt 2>/dev/null | grep -q ":${JENKINS_PORT}\b"; then
    ERRORS+=("Nothing is listening on 127.0.0.1:${JENKINS_PORT}, so Jenkins is not running.")
    ERRORS+=("   Start it: sudo systemctl start jenkins")
fi

if [ ! -f "$SSL_OPTIONS_FILE" ]; then
    ERRORS+=("No $SSL_OPTIONS_FILE. Run add_app_vhosts.sh once: it owns that file.")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

print_status "Name: https://${WEBHOOK_HOST}:${WEBHOOK_PORT}/github-webhook/"
print_status "Path: only /github-webhook/ reaches Jenkins on 127.0.0.1:${JENKINS_PORT}"

# =============================================================================
# The firewall allowlist
#
# Reconciled rather than added to: GitHub retires ranges, and a rule left behind
# is a hole nobody remembers opening. The previous list is kept on disk because
# a UFW rule cannot be asked what it was for.
# =============================================================================
refresh_allowlist() {
    local fetched new old cidr
    fetched="$(curl -fsS --max-time 15 "$GITHUB_META" 2>/dev/null \
        | tr ',' '\n' | sed -n '/"hooks"/,/\]/p' \
        | grep -oE '[0-9a-fA-F:.]+/[0-9]+' | sort -u)"

    if [ -z "$fetched" ]; then
        print_info "Could not fetch GitHub's ranges from $GITHUB_META."
        if [ -s "$RANGE_STATE" ]; then
            print_info "Keeping the ${WEBHOOK_PORT} rules already in place, unchanged."
            return 0
        fi
        print_error "No previous list either, so the door would be open to everyone."
        print_error "Refusing to open port ${WEBHOOK_PORT}."
        return 1
    fi

    mkdir -p "$(dirname "$RANGE_STATE")"
    old="$([ -f "$RANGE_STATE" ] && cat "$RANGE_STATE" || true)"

    # Gone from GitHub's list: close it.
    for cidr in $old; do
        if ! printf '%s\n' "$fetched" | grep -qxF "$cidr"; then
            ufw delete allow from "$cidr" to any port "$WEBHOOK_PORT" proto tcp >/dev/null 2>&1 || true
            print_success "Closed ${WEBHOOK_PORT} to ${cidr}, which GitHub no longer uses."
        fi
    done

    new=0
    for cidr in $fetched; do
        if ufw status 2>/dev/null | grep -q "^${WEBHOOK_PORT}/tcp.*${cidr}"; then
            continue
        fi
        ufw allow from "$cidr" to any port "$WEBHOOK_PORT" proto tcp >/dev/null 2>&1
        new=$((new + 1))
    done

    printf '%s\n' "$fetched" > "$RANGE_STATE"
    chmod 600 "$RANGE_STATE"

    if [ "$new" -gt 0 ]; then
        print_success "Opened ${WEBHOOK_PORT} to ${new} GitHub range(s), and to nobody else."
    else
        print_status "Firewall already matches GitHub's current list."
    fi
    return 0
}

# =============================================================================
# The vhost
# =============================================================================
mkdir -p "$VOID_ROOT"
chmod 755 "$VOID_ROOT"

for mod in ssl proxy proxy_http headers rewrite; do
    a2enmod "$mod" >/dev/null 2>&1 || true
done

NEW_VHOST="$(cat <<EOF
# Generated by add_jenkins_webhook_door.sh, rewritten on every run.
# Set WEBHOOK_HOST and WEBHOOK_PORT in hostings.conf, never here.
#
# The only way in from the internet. One path is proxied; everything else lands
# on an empty document root that refuses. The Jenkins UI is NOT reachable here.
Listen ${WEBHOOK_PORT}

<VirtualHost *:${WEBHOOK_PORT}>
    ServerName ${WEBHOOK_HOST}

    SSLEngine on
    SSLCertificateFile ${LE_DIR}/${WEBHOOK_HOST}/fullchain.pem
    SSLCertificateKeyFile ${LE_DIR}/${WEBHOOK_HOST}/privkey.pem
    Include ${SSL_OPTIONS_FILE}

    # Nothing to serve. Any URL that is not proxied below ends up here and is
    # refused, rather than reaching Jenkins or listing a directory.
    DocumentRoot ${VOID_ROOT}
    <Directory ${VOID_ROOT}>
        Options -Indexes
        AllowOverride None
        Require all denied
    </Directory>

    # THE ONE PATH. nocanon keeps Jenkins' own URL parsing intact.
    ProxyPreserveHost On
    ProxyPass        /github-webhook/ http://127.0.0.1:${JENKINS_PORT}/github-webhook/ nocanon
    ProxyPassReverse /github-webhook/ http://127.0.0.1:${JENKINS_PORT}/github-webhook/

    <Location /github-webhook/>
        Require all granted
    </Location>

    # A payload is JSON and small. A body far past that is not a push event.
    LimitRequestBody 5242880

    ErrorLog  \${APACHE_LOG_DIR}/${VHOST_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${VHOST_NAME}-access.log combined
</VirtualHost>
EOF
)"

PREV_PORT="$([ -f "$VHOST" ] && awk '/^Listen /{print $2; exit}' "$VHOST" || true)"

if [ -f "$VHOST" ] && [ "$(cat "$VHOST")" = "$NEW_VHOST" ]; then
    print_success "Door already correct on port ${WEBHOOK_PORT}."
else
    printf '%s\n' "$NEW_VHOST" > "$VHOST"
    chmod 644 "$VHOST"
    a2ensite "$VHOST_NAME" >/dev/null 2>&1
    if apache2ctl configtest >/dev/null 2>&1; then
        systemctl reload apache2
        print_success "Door open on ${WEBHOOK_PORT}, one path only."
    else
        print_error "Apache rejected the webhook vhost, so it was not loaded:"
        apache2ctl configtest 2>&1 | tail -20
        a2dissite "$VHOST_NAME" >/dev/null 2>&1
        systemctl reload apache2 2>/dev/null || true
        exit 1
    fi
fi

# The door moved: close the port it used to answer on.
if [ -n "$PREV_PORT" ] && [ "$PREV_PORT" != "$WEBHOOK_PORT" ] && command -v ufw >/dev/null 2>&1; then
    for cidr in $([ -f "$RANGE_STATE" ] && cat "$RANGE_STATE" || true); do
        ufw delete allow from "$cidr" to any port "$PREV_PORT" proto tcp >/dev/null 2>&1 || true
    done
    print_success "Closed ${PREV_PORT}, which this door no longer uses."
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    refresh_allowlist || exit 1
else
    print_info "UFW is not active, so the port is open to anyone who can route to it."
fi

echo ""
print_success "Webhook door installed."
echo ""
print_status "Point the GitHub webhook at:"
echo "   https://${WEBHOOK_HOST}:${WEBHOOK_PORT}/github-webhook/"
echo ""
print_info "No shared secret is configured yet. The path limit and the GitHub"
print_info "   range allowlist are what protect this door until one is set, in"
print_action "   both GitHub and Manage Jenkins -> GitHub -> Advanced."
