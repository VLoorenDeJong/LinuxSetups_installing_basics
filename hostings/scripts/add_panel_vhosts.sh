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
# Serve a machine page, from one line of config.
#
# A machine page is a tool for whoever runs this box: the console, Jenkins,
# webmin, webmail. They are not sites. They have no hostname, no certificate
# and no environments, and they are reachable from the local network only.
#
#     PANEL = <id> | <port> | <name> | <serves> | <target> | <login>
#
# WHY THIS SCRIPT EXISTS
#
# The first three pages were each served by their own installer: the console by
# add_hosting_manager.sh, Jenkins by add_jenkins.sh, webmin by webmin itself.
# Three pages, three unrelated shapes, so nobody wrote the fourth thing, and
# adding webmail meant writing a fourth installer for what is a folder of PHP.
#
# The last three fields are that fourth thing. `serves` says which shape this
# page is, and the script picks the vhost to match:
#
#     folder   files on this machine          target is a path
#     service  something already listening    target is host:port
#     itself   the page serves its own port   target is unused
#
# `itself` is what the three existing pages are, and is the default when the
# fields are absent. This script reports them and writes nothing, so the pages
# whose installers already work are untouched by it.
#
# ADDING A NEW KIND
#
# Write `vhost_for_<kind>` and add the name to PANEL_KINDS. Nothing else
# branches on the kind: the dispatch resolves the function by name, and a kind
# with no function fails pre-flight rather than halfway through a write.
#
# THE LOGIN IS ON BY DEFAULT
#
# `login` is yes unless it says no. A machine page is a tool for the operator,
# and a page reachable on the LAN with no login is one that anyone on the
# network can use. A page with a good login of its own may say no.
#
# Safe to re-run: an unchanged vhost is left alone, a page that has left the
# config is reported and removed with --prune, and Apache is only reloaded
# after configtest passes.
# =============================================================================
#
# Usage:
#   sudo bash add_panel_vhosts.sh            write what is missing or wrong
#   sudo bash add_panel_vhosts.sh --check    report, change nothing
#   sudo bash add_panel_vhosts.sh --prune    also remove pages that have gone
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

MODE="apply"
PRUNE=0

# RENDER_ONLY=1: build every vhost as a real run would and write them to
# RENDER_OUT instead of to Apache, so report_drift.sh can ask this script what
# it WOULD write rather than reimplementing the comparison itself.
RENDER_ONLY="${RENDER_ONLY:-0}"
RENDER_OUT="${RENDER_OUT:-}"

usage() {
    echo "Usage: sudo bash add_panel_vhosts.sh [--check] [--prune] [--debug]"
    echo ""
    echo "  --check   report what would change, write nothing"
    echo "  --prune   remove the vhost and close the port of a page that has"
    echo "            left the config. Without it they are only reported."
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --check)     MODE="check" ;;
        --prune)     PRUNE=1 ;;
        -h|--help)   usage ;;
        *)           print_error "Unknown option: $arg"; usage ;;
    esac
done

[ "$RENDER_ONLY" = "1" ] && MODE="check"

if [ "$MODE" = "apply" ] && [ "$EUID" -ne 0 ]; then
    print_error "This writes Apache config and firewall rules, so it needs root."
    print_action "Run: sudo bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

AVAILABLE_DIR="/etc/apache2/sites-available"
PANEL_PREFIX="panel-"

# A setting, read the same way every other script reads one: the last
# uncommented assignment wins, and a trailing comment is not part of the value.
conf_get() {
    local key="$1" default="${2:-}" value
    [ -f "$SITES_CONF" ] || { echo "$default"; return; }
    # tr -d '\r' before anything else: a value is the last thing on its line, so
    # a CRLF file leaves the carriage return inside it and every path built from
    # it points at a file that does not exist. xargs does not strip it.
    value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
             | tr -d '\r' | tail -1 | cut -d= -f2- | sed 's/#.*//' | xargs)"
    [ -z "$value" ] && value="$default"
    echo "$value"
}

# The kinds this script knows how to serve. A kind in the config that is not
# here, or one here with no vhost_for_ function, is caught by pre-flight.
PANEL_KINDS=(folder service itself)

# Pages switched off, by id. Read once: it is a settings line, not a field on
# the PANEL line. Spaces are stripped so the comma test below is exact.
PANELS_OFF_LIST="$(conf_get PANELS_OFF '')"
PANELS_OFF_LIST="${PANELS_OFF_LIST// /}"
[ "$PANELS_OFF_LIST" = "-" ] && PANELS_OFF_LIST=""

# What each kind is called on screen and on the page. The config keeps the
# short word; nothing an operator reads has to.
kind_label() {
    case "$1" in
        folder)  echo "a folder on this machine" ;;
        service) echo "a service already running here" ;;
        itself)  echo "its own port, served by its own installer" ;;
        *)       echo "$1" ;;
    esac
}

# =============================================================================
# The rows
#
# PANEL lines hold pipes, so read as service rows they parse as nonsense. They
# are read here and only here, by their leading `PANEL =`.
# =============================================================================
panel_lines() {
    [ -f "$SITES_CONF" ] || return 0
    sed -n 's/^[[:space:]]*PANEL[[:space:]]*=//p' "$SITES_CONF"
}

# One row into six variables. Missing trailing fields take their defaults,
# which is what keeps the three-field lines that predate this script working.
read_panel() {
    local line="$1"
    # The carriage return of a CRLF file survives on the LAST field only, where
    # nothing else strips it: every other field is followed by a `|`. It made a
    # page whose login said `yes` come out as $'yes\r' and be served with no
    # login at all, silently. This config is edited from Windows, so it is a
    # normal state for the file to be in, not a corruption.
    line="${line//$'\r'/}"
    P_ID=""; P_PORT=""; P_NAME=""; P_KIND=""; P_TARGET=""; P_LOGIN=""; P_USERS=""
    IFS='|' read -r P_ID P_PORT P_NAME P_KIND P_TARGET P_LOGIN P_USERS <<< "$line"
    P_ID="$(echo "${P_ID:-}"     | sed 's/#.*//' | xargs)"
    P_PORT="$(echo "${P_PORT:-}" | sed 's/#.*//' | xargs)"
    P_NAME="$(echo "${P_NAME:-}" | xargs)"
    P_KIND="$(echo "${P_KIND:-}" | sed 's/#.*//' | xargs)"
    P_TARGET="$(echo "${P_TARGET:-}" | sed 's/#.*//' | xargs)"
    P_LOGIN="$(echo "${P_LOGIN:-}"   | sed 's/#.*//' | xargs)"

    [ "$P_PORT" = "-" ]   && P_PORT=""
    [ "$P_KIND" = "-" ]   && P_KIND=""
    [ "$P_TARGET" = "-" ] && P_TARGET=""
    [ "$P_LOGIN" = "-" ]  && P_LOGIN=""
    P_USERS="$(echo "${P_USERS:-}" | sed 's/#.*//' | xargs)"
    [ "$P_USERS" = "-" ]  && P_USERS=""

    # A page that does not say what it serves is one whose own installer serves
    # it. That is what every page was before this script existed.
    [ -z "$P_KIND" ] && P_KIND="itself"
    P_KIND="${P_KIND,,}"

    # Fails closed. A machine page is an operator's tool, and one published on
    # the LAN with no login is usable by anyone on the network.
    [ -z "$P_LOGIN" ] && P_LOGIN="yes"
    P_LOGIN="${P_LOGIN,,}"

    # Switched off, from the PANELS_OFF list rather than from this line. The id
    # is the one thing about a page that never changes, and the last field on
    # this line is exactly what a carriage return once corrupted.
    P_ENABLED="yes"
    case ",${PANELS_OFF_LIST}," in
        *",${P_ID},"*) P_ENABLED="no" ;;
    esac
}

# =============================================================================
# The firewall
#
# Field comparison, not a regex over the text: `grep "$port.*$cidr"` matches
# port 1000 inside a line about 10001, and the dots in a CIDR are metacharacters
# rather than the literals they look like.
# =============================================================================
ufw_allows() {
    local port="$1" cidr="$2"
    ufw status 2>/dev/null | awk -v p="$port" -v c="$cidr" '
        $1 == p "/tcp" && $0 ~ c { found = 1 }
        END { exit found ? 0 : 1 }'
}

lan_cidr() {
    local cidr
    cidr="$(conf_get LAN_CIDR "")"
    [ -n "$cidr" ] && { echo "$cidr"; return; }
    # Derived from the interface holding the default route, so a machine that
    # has never been told its own subnet still scopes the rule to it.
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}' | while read -r dev; do
        ip -4 -o addr show dev "$dev" 2>/dev/null \
            | awk '{print $4; exit}' \
            | sed 's#\.[0-9]*/#.0/#'
    done
}

# =============================================================================
# The vhost bodies, one function per kind
#
# This is the whole interface. `vhost_for_<kind>` takes the row in P_* and
# prints a complete vhost. Adding a kind means adding a function and a name to
# PANEL_KINDS, and touching nothing else.
# =============================================================================

# Everything inside a vhost that puts the operator login in front of it. Empty
# when the row says no, so the same body serves both cases.
# Who may enter, admin always first. The admin is the master account and is
# appended to every generated vhost in this repo, so a page that names nobody
# still admits the operator, and a page that names people does not lock the
# operator out of their own machine.
#
# It was admin ALONE until 2026-08-28, which meant a machine page admitted one
# person while the Jenkins door beside it admitted everyone the row listed.
panel_require() {
    local out="$AUTH_ADMIN_USER" u
    for u in $(printf '%s' "$P_USERS" | tr ',' ' '); do
        [ -n "$u" ] || continue
        [ "$u" = "$AUTH_ADMIN_USER" ] && continue
        out="$out $u"
    done
    printf '%s' "$out"
}

auth_block() {
    # Only an explicit `no` removes the login. Asking for `yes` and getting
    # anything else is how a page went onto the LAN unauthenticated on
    # 2026-08-28: a stray carriage return made the value $'yes\r', which is not
    # `yes`, and the test was written the other way round.
    [ "$P_LOGIN" = "no" ] && return 0
    cat <<EOF
    Alias /${AUTH_LOGIN_PAGE} ${AUTH_WEB_ROOT}/${AUTH_LOGIN_PAGE}
    Alias /auth-assets ${AUTH_WEB_ROOT}
    <Directory ${AUTH_WEB_ROOT}>
        Require all granted
    </Directory>

    # ORDER IS LOAD BEARING: <Location> blocks merge in file order and the LAST
    # match wins, so the general <Location /> comes FIRST and the exceptions
    # after it. Reversed, the login page itself requires a login and loops.
    #
    # Its own cookie name, and no \`secure\`: this port is plain HTTP, and a
    # secure cookie is never sent back over it. Reusing the name \`session\`
    # would collide with the one :443 sets, because cookies ignore the port.
    <Location />
        AuthType form
        AuthName "Sign in"
        AuthFormProvider file
        AuthUserFile ${AUTH_USER_FILE}
        AuthFormLoginRequiredLocation /${AUTH_LOGIN_PAGE}
        # No KeptBodySize: see add_hosting_manager.sh, it segfaults Apache on a slow POST.
        Session On
        SessionCookieName session_http path=/;httponly
        SessionCryptoPassphraseFile ${AUTH_SESSION_KEY}
        Require user $(panel_require)
    </Location>

    <Location /${AUTH_LOGIN_PAGE}>
        AuthType None
        Require all granted
    </Location>

    <Location /auth-assets>
        AuthType None
        Require all granted
    </Location>

    <Location /do-login>
        SetHandler form-login-handler
        AuthType form
        AuthName "Sign in"
        AuthFormProvider file
        AuthUserFile ${AUTH_USER_FILE}
        AuthFormLoginRequiredLocation /${AUTH_LOGIN_PAGE}
        AuthFormLoginSuccessLocation /
        Session On
        SessionCookieName session_http path=/;httponly
        SessionCryptoPassphraseFile ${AUTH_SESSION_KEY}
        Require all granted
    </Location>

    <Location /logout>
        SetHandler form-logout-handler
        AuthType None
        AuthFormLogoutLocation /${AUTH_LOGIN_PAGE}
        Session On
        SessionCookieName session_http path=/;httponly
        SessionCryptoPassphraseFile ${AUTH_SESSION_KEY}
        Require all granted
    </Location>
EOF
}

vhost_for_folder() {
    # Roundcube runs in its own pool, written by add_roundcube.sh. Item 146.
    local php_block=""
    case "$P_TARGET" in
        /var/lib/roundcube*|/usr/share/roundcube*)
            php_block='
        <FilesMatch "\.php$">
            SetHandler "proxy:unix:/run/php/roundcube.sock|fcgi://roundcube"
        </FilesMatch>' ;;
    esac
    cat <<EOF
# Generated by add_panel_vhosts.sh, rewritten on every run.
# Set the '${P_ID}' PANEL line in hostings.conf, never here.
Listen ${P_PORT}

<VirtualHost *:${P_PORT}>
    DocumentRoot ${P_TARGET}

    <Directory ${P_TARGET}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted${php_block}
    </Directory>

$(auth_block)
    ErrorLog  \${APACHE_LOG_DIR}/${PANEL_PREFIX}${P_ID}-error.log
    CustomLog \${APACHE_LOG_DIR}/${PANEL_PREFIX}${P_ID}-access.log combined
</VirtualHost>
EOF
}

vhost_for_service() {
    cat <<EOF
# Generated by add_panel_vhosts.sh, rewritten on every run.
# Set the '${P_ID}' PANEL line in hostings.conf, never here.
Listen ${P_PORT}

<VirtualHost *:${P_PORT}>
    ProxyPreserveHost On
    AllowEncodedSlashes NoDecode

    # These must come before the ProxyPass below, or the login page is proxied
    # to the service instead of being served from disk.
    ProxyPass /${AUTH_LOGIN_PAGE} !
    ProxyPass /do-login     !
    ProxyPass /logout       !
    ProxyPass /auth-assets  !

    # upgrade=websocket: pages like Zigbee2MQTT live on a websocket (Apache 2.4.47+).
    ProxyPass        / http://${P_TARGET}/ nocanon upgrade=websocket
    ProxyPassReverse / http://${P_TARGET}/

$(auth_block)
    ErrorLog  \${APACHE_LOG_DIR}/${PANEL_PREFIX}${P_ID}-error.log
    CustomLog \${APACHE_LOG_DIR}/${PANEL_PREFIX}${P_ID}-access.log combined
</VirtualHost>
EOF
}

# Nothing to write: the page's own installer owns its vhost, or the page is not
# behind Apache at all. Here so the dispatch has an implementation for every
# kind rather than a special case around it.
vhost_for_itself() {
    return 0
}

# =============================================================================
# Reading the config
# =============================================================================
print_header "Machine pages"
print_status "Config: $SITES_CONF"
print_status "Mode:   $MODE$([ "$PRUNE" = 1 ] && echo ", pruning")"

AUTH_USER_FILE="$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)"
AUTH_SESSION_KEY="$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)"
AUTH_WEB_ROOT="$(conf_get AUTH_WEB_ROOT /var/www/auth)"
AUTH_ADMIN_USER="$(conf_get AUTH_ADMIN_USER admin)"
AUTH_LOGIN_PAGE="login.html"

LAN_CIDR="$(lan_cidr)"

# =============================================================================
# Pre-flight
#
# Everything that could stop the run, collected and reported together, before
# the first write.
# =============================================================================
ERRORS=()
SERVED_IDS=()
SERVED_PORTS=()
NEEDS_LOGIN=0

if [ ! -f "$SITES_CONF" ]; then
    print_error "No config at $SITES_CONF"
    print_action "Run this from the repository, or set SITES_CONF."
    exit 1
fi

while IFS= read -r line; do
    [ -n "$line" ] || continue
    read_panel "$line"
    [ -n "$P_ID" ] || continue

    # Switched off, so it is not served and must not claim its id or its port.
    # Leaving it in SERVED_IDS was the whole bug: its vhost was then never an
    # orphan, so --prune left the page up while the console said it was off.
    if [ "$P_ENABLED" = "no" ]; then
        continue
    fi

    # Every kind must have an implementation. This is the interface check, and
    # it fails here rather than halfway through writing Apache config.
    if ! printf '%s\n' "${PANEL_KINDS[@]}" | grep -qx "$P_KIND"; then
        ERRORS+=("Page '$P_ID' says it serves '$P_KIND', which is not one of: ${PANEL_KINDS[*]}")
        continue
    fi
    if ! declare -F "vhost_for_$P_KIND" >/dev/null; then
        ERRORS+=("Page '$P_ID' is kind '$P_KIND' and no vhost_for_$P_KIND exists in this script.")
        continue
    fi

    [ "$P_KIND" = "itself" ] && continue

    if [ -z "$P_PORT" ]; then
        ERRORS+=("Page '$P_ID' serves $(kind_label "$P_KIND") but has no port.")
        continue
    fi
    if ! [ "$P_PORT" -ge 1024 ] 2>/dev/null; then
        ERRORS+=("Page '$P_ID' has port '$P_PORT'. It must be a number of 1024 or above.")
        continue
    fi
    if [ -z "$P_TARGET" ]; then
        ERRORS+=("Page '$P_ID' serves $(kind_label "$P_KIND") but names no target.")
        continue
    fi

    case "$P_KIND" in
        folder)
            [ -d "$P_TARGET" ] || \
                ERRORS+=("Page '$P_ID' serves the folder $P_TARGET, which does not exist.")
            ;;
        service)
            case "$P_TARGET" in
                *:*) : ;;
                *)   ERRORS+=("Page '$P_ID' proxies to '$P_TARGET'. It needs a host and a port, like 127.0.0.1:8080.") ;;
            esac
            ;;
    esac

    # Said out loud rather than guessed at. A value nobody meant now fails the
    # run instead of quietly picking one of the two answers.
    case "$P_LOGIN" in
        yes|no) : ;;
        *)      ERRORS+=("Page '$P_ID' says login is '$P_LOGIN'. It has to be yes or no.") ;;
    esac

    # Against every OTHER vhost on this machine, not only against the other
    # PANEL rows. Apache refuses to start with two Listen directives on one
    # port, so a page pointed at a port another vhost already holds took the
    # whole server down until its vhost was disabled by hand. That happened on
    # 2026-08-28: webmail was given 10003, which is the GitHub webhook door.
    if [ -d /etc/apache2/sites-enabled ]; then
        while IFS= read -r other_vhost; do
            [ -n "$other_vhost" ] || continue
            # Its own file is not a conflict with itself: this script rewrites
            # that one, and a re-run must not report the port it already uses.
            [ "$(basename "$other_vhost")" = "${PANEL_PREFIX}${P_ID}.conf" ] && continue
            ERRORS+=("Page '$P_ID' wants port $P_PORT, which $(basename "$other_vhost" .conf) already listens on.")
            ERRORS+=("  Apache refuses to start with two listeners on one port. Give the page a different one.")
        done < <(grep -l "^[[:space:]]*Listen[[:space:]]\+${P_PORT}[[:space:]]*\$" \
                 /etc/apache2/sites-enabled/*.conf 2>/dev/null)
    fi

    [ "$P_LOGIN" = "no" ] || NEEDS_LOGIN=1

    SERVED_IDS+=("$P_ID")
    SERVED_PORTS+=("$P_PORT")
done < <(panel_lines)

# Two pages on one port is two Listen directives Apache refuses to start with,
# so it is caught here rather than at reload.
_i=0
while [ "$_i" -lt "${#SERVED_PORTS[@]}" ]; do
    _j=$((_i + 1))
    while [ "$_j" -lt "${#SERVED_PORTS[@]}" ]; do
        if [ "${SERVED_PORTS[$_i]}" = "${SERVED_PORTS[$_j]}" ]; then
            ERRORS+=("Pages '${SERVED_IDS[$_i]}' and '${SERVED_IDS[$_j]}' both want port ${SERVED_PORTS[$_i]}.")
        fi
        _j=$((_j + 1))
    done
    _i=$((_i + 1))
done

if [ "$NEEDS_LOGIN" = "1" ]; then
    if [ ! -f "$AUTH_USER_FILE" ]; then
        ERRORS+=("No password file at $AUTH_USER_FILE, so nobody could log in.")
        ERRORS+=("  Create it: sudo bash LinuxBasics/install_scripts/add_auth_users.sh --file $AUTH_USER_FILE $AUTH_ADMIN_USER")
    elif ! grep -q "^${AUTH_ADMIN_USER}:" "$AUTH_USER_FILE" 2>/dev/null; then
        ERRORS+=("$AUTH_USER_FILE has no '$AUTH_ADMIN_USER' entry, so the login would reject everyone.")
        ERRORS+=("  Add it: sudo htpasswd $AUTH_USER_FILE $AUTH_ADMIN_USER")
    fi
    if [ ! -f "$AUTH_WEB_ROOT/$AUTH_LOGIN_PAGE" ]; then
        ERRORS+=("No login page at $AUTH_WEB_ROOT/$AUTH_LOGIN_PAGE.")
        ERRORS+=("  Run add_app_vhosts.sh first: it installs the login page and the session key.")
    fi
    if [ ! -f "$AUTH_SESSION_KEY" ]; then
        ERRORS+=("No session key at $AUTH_SESSION_KEY, so no session cookie can be encrypted.")
        ERRORS+=("  Create it: openssl rand -base64 32 | sudo tee $AUTH_SESSION_KEY && sudo chmod 600 $AUTH_SESSION_KEY")
    fi
fi

if [ "$RENDER_ONLY" != "1" ] && [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

if [ "$MODE" != "check" ] && ! command -v a2ensite >/dev/null 2>&1; then
    print_error "Apache is not installed, so no machine page can be served."
    print_action "Run add_apache_webserver.sh, then this script again."
    exit 1
fi

# =============================================================================
# What each page needs
# =============================================================================
ADDED=()
UPDATED=()
UNCHANGED=()
SELF_SERVED=()
SWITCHED_OFF=()
# What this run enabled, so a refused configtest can put the machine back rather
# than leaving Apache unable to reload for anything at all.
WROTE_SITES=()
CHANGED=0

if [ "$RENDER_ONLY" = "1" ] && [ -n "$RENDER_OUT" ]; then
    : > "$RENDER_OUT"
fi

while IFS= read -r line; do
    [ -n "$line" ] || continue
    read_panel "$line"
    [ -n "$P_ID" ] || continue

    # Switched off: treat it exactly as a page that has left the config. The
    # prune below takes its vhost away and closes its port, and the PANEL line
    # keeps the port so switching it back on needs no retyping.
    if [ "$P_ENABLED" = "no" ]; then
        SWITCHED_OFF+=("$P_ID${P_PORT:+ was on $P_PORT}")
        continue
    fi

    if [ "$P_KIND" = "itself" ]; then
        SELF_SERVED+=("$P_ID${P_PORT:+ on $P_PORT}")
        continue
    fi

    printf '%s\n' "${PANEL_KINDS[@]}" | grep -qx "$P_KIND" || continue

    vhost_file="$AVAILABLE_DIR/${PANEL_PREFIX}${P_ID}.conf"
    new_vhost="$("vhost_for_$P_KIND")"

    if [ "$RENDER_ONLY" = "1" ]; then
        if [ -n "$RENDER_OUT" ]; then
            printf '=== %s\n%s\n' "$vhost_file" "$new_vhost" >> "$RENDER_OUT"
        fi
        continue
    fi

    if [ -f "$vhost_file" ] && [ "$(cat "$vhost_file")" = "$new_vhost" ]; then
        UNCHANGED+=("$P_ID")
        continue
    fi

    CHANGED=1
    if [ -f "$vhost_file" ]; then
        UPDATED+=("$P_ID ($P_KIND, port $P_PORT)")
    else
        ADDED+=("$P_ID ($P_KIND, port $P_PORT)")
    fi

    [ "$MODE" = "check" ] && continue

    # Read before overwriting: the vhost is the only record of which port was
    # open, so moving a page to a new one otherwise leaves the old firewall rule
    # behind with nothing answering on it.
    prev_port="$([ -f "$vhost_file" ] && awk '/^Listen /{print $2; exit}' "$vhost_file" || true)"

    printf '%s\n' "$new_vhost" > "$vhost_file"
    chmod 644 "$vhost_file"
    a2ensite "${PANEL_PREFIX}${P_ID}" >/dev/null 2>&1 || true
    WROTE_SITES+=("${PANEL_PREFIX}${P_ID}")
    print_success "Wrote $vhost_file: $P_ID serves $(kind_label "$P_KIND") on port $P_PORT"

    if [ -n "$prev_port" ] && [ "$prev_port" != "$P_PORT" ] && [ -n "$LAN_CIDR" ]; then
        ufw delete allow from "$LAN_CIDR" to any port "$prev_port" proto tcp >/dev/null 2>&1 || true
        print_status "Closed port $prev_port, which '$P_ID' used to answer on."
    fi

    if [ -n "$LAN_CIDR" ] && ! ufw_allows "$P_PORT" "$LAN_CIDR"; then
        ufw allow from "$LAN_CIDR" to any port "$P_PORT" proto tcp >/dev/null 2>&1 || true
        print_success "Opened port $P_PORT to $LAN_CIDR."
    fi
done < <(panel_lines)

if [ "$RENDER_ONLY" = "1" ]; then
    exit 0
fi

# =============================================================================
# Pages that have gone
# =============================================================================
ORPHANS=()
for f in "$AVAILABLE_DIR/${PANEL_PREFIX}"*.conf; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .conf)"
    id="${base#$PANEL_PREFIX}"
    keep=0
    for served in ${SERVED_IDS+"${SERVED_IDS[@]}"}; do
        [ "$served" = "$id" ] && keep=1
    done
    [ "$keep" = "1" ] && continue
    ORPHANS+=("$id")

    [ "$PRUNE" = "1" ] || continue
    [ "$MODE" = "check" ] && continue

    gone_port="$(awk '/^Listen /{print $2; exit}' "$f" || true)"
    a2dissite "$base" >/dev/null 2>&1 || true
    rm -f "$f"
    CHANGED=1
    print_success "Removed the '$id' page: $f"
    if [ -n "$gone_port" ] && [ -n "$LAN_CIDR" ]; then
        ufw delete allow from "$LAN_CIDR" to any port "$gone_port" proto tcp >/dev/null 2>&1 || true
        print_status "Closed port $gone_port."
    fi
done

# =============================================================================
# Apply
# =============================================================================
if [ "$MODE" != "check" ] && [ "$CHANGED" = "1" ]; then
    if ! apache2ctl configtest >/tmp/panel-configtest.log 2>&1; then
        print_error "Apache refused the new config."
        tail -20 /tmp/panel-configtest.log >&2

        # Put it back. Leaving a refused vhost enabled does not just fail this
        # run: it fails the NEXT reload by anything at all, including certbot,
        # so one bad page takes every site down at the next renewal. Found the
        # hard way on 2026-08-28.
        for site in ${WROTE_SITES+"${WROTE_SITES[@]}"}; do
            a2dissite "$site" >/dev/null 2>&1 || true
            print_status "Disabled $site again, so Apache can still reload."
        done
        if apache2ctl configtest >/dev/null 2>&1; then
            systemctl reload apache2 >/dev/null 2>&1 || true
            print_success "Apache is back to the config it had before this run."
        else
            print_error "Apache STILL refuses its config, so something else is wrong too."
            print_action "Read it: sudo apache2ctl configtest"
        fi
        print_action "The full output is in /tmp/panel-configtest.log"
        exit 1
    fi
    for mod in proxy proxy_http auth_form authn_file authz_user \
               session session_cookie session_crypto request; do
        a2enmod "$mod" >/dev/null 2>&1 || true
    done
    spinner_start "Reloading Apache..."
    systemctl reload apache2 >/tmp/panel-reload.log 2>&1 || true
    spinner_stop
    print_success "Apache reloaded, so the pages below are answering now."
fi

# =============================================================================
# What it did
# =============================================================================
echo ""
for p in ${ADDED+"${ADDED[@]}"};     do print_success "Added   $p"; done
for p in ${UPDATED+"${UPDATED[@]}"}; do print_success "Updated $p"; done
[ ${#UNCHANGED[@]} -gt 0 ] && print_info "${#UNCHANGED[@]} page(s) already correct: ${UNCHANGED[*]}"
[ ${#SELF_SERVED[@]} -gt 0 ] && print_info "${#SELF_SERVED[@]} page(s) served by their own installer: ${SELF_SERVED[*]}"
[ ${#SWITCHED_OFF[@]} -gt 0 ] && print_info "${#SWITCHED_OFF[@]} page(s) switched off in PANELS_OFF: ${SWITCHED_OFF[*]}"

if [ ${#ORPHANS[@]} -gt 0 ] && [ "$PRUNE" != "1" ]; then
    for o in "${ORPHANS[@]}"; do
        print_action "The '$o' page has left the config, and its vhost is still here."
    done
    print_action "Remove them with: sudo bash $0 --prune"
fi

if [ "$MODE" = "check" ]; then
    if [ "$CHANGED" = "1" ]; then
        print_action "Nothing was written. Run without --check to apply."
    else
        print_success "Every machine page already matches the config."
    fi
fi

if [ -z "$LAN_CIDR" ]; then
    print_action "No LAN_CIDR in $SITES_CONF and none could be derived, so no firewall port was opened."
    print_action "Set LAN_CIDR = 192.168.1.0/24 and run this again."
fi

echo ""
print_success "Machine pages done."
