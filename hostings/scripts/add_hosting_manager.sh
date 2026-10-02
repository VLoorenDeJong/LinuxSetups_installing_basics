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
# The hosting manager: edit hostings.conf from a browser instead of VS Code.
#
# Three parts, and the split between them is the whole design:
#
#   the page        PHP under Apache, as hosting-manager in its own PHP-FPM
#                   pool, never as www-data. Holds no credential
#                   and can push nothing. Writes a candidate file and calls
#                   four fixed commands.
#   the publisher   publish_hostings.sh, run through sudo with NO arguments.
#                   Validates, commits, pushes. It does NOT apply: that is
#                   trigger_apply.sh, on its own button, by decision.
#   the checker     check_hostings.sh, read-only, writes the drift report.
#   the triggers    trigger_apply.sh and trigger_update.sh, which ask Jenkins
#                   to run a job that already exists.
#   the clone       a checkout of this repo that only the publisher can write,
#                   pushing with Jenkins' key, which the page cannot read.
#
# WHY A SEPARATE CLONE
#
# Not the Jenkins workspace: Jenkins force-checks-out on every build and would
# throw the commit away. Not the user's home clone either, because the page
# would then be able to reach a directory a person edits by hand.
#
# WHICH KEY IT PUSHES WITH: GIT_PUSH_KEY
#
# It reused Jenkins' key from 2026-08-08, decided over a key of its own: a
# separate key could be revoked without stopping Jenkins, at the cost of one
# more key to create, add and remember.
#
# That reuse was implicit, and deleting the jenkins key on 2026-09-04 broke
# every console save at once. All four publishing scripts fell through to
# /var/lib/hosting-manager/.ssh/id_ed25519, a real file GitHub has never
# accepted, and reported it as GitHub being unreachable.
#
# GIT_PUSH_KEY in hostings.conf names it now, so the choice is visible, is the
# same in every script, and no script carries an account name.
#
# The page reads none of them. The publisher runs as root and the page as
# neither.
#
# THE GRANT IS ONE LITERAL COMMAND
#
# The page may run exactly `/usr/local/sbin/publish_hostings.sh` and nothing
# else. No wildcard, so there is no argument list to smuggle anything into. If
# the page is compromised, the worst it can do is publish a config that has to
# pass validation first.
#
# WHERE IT IS REACHED, AND WHY THAT IS NOT A HOSTNAME
#
# the `console` machine page, on the local subnet, with a login in front. No public
# hostname, no DNS record, no certificate. It edits the file that decides what
# this machine serves, so the internet has no business reaching it; away from
# home the path is Tailscale.
#
# Usage:
#   sudo bash add_hosting_manager.sh              install it
#   sudo bash add_hosting_manager.sh --check      report what would change
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

# =============================================================================
# Clear away the previous name
#
# This was called the console until 2026-08-09, and every path carried that
# word. Leaving the old vhost behind is not untidy, it is fatal: two files
# holding `Listen 10001` make Apache refuse to start, and the machine loses
# every site rather than just this page.
#
# Removed by this script rather than by hand, because a machine flashed from
# this branch tomorrow must end up in the same state as one upgraded today.
# =============================================================================
retire_the_console() {
    local old_vhost="/etc/apache2/sites-available/console-lan.conf"
    if [ -f "$old_vhost" ]; then
        a2dissite console-lan >/dev/null 2>&1 || true
        rm -f "$old_vhost"
        print_status "Removed the old console-lan vhost, which also held Listen 10001."
    fi
    [ -f /etc/sudoers.d/020_console-publish ] && rm -f /etc/sudoers.d/020_console-publish
    [ -d /var/www/console ] && rm -rf /var/www/console
}

MODE="apply"
case "${1:-}" in
    --check) MODE="check" ;;
    "")      ;;
    *)
        print_error "Unknown argument: $1"
        print_action "Use --check, or no argument at all."
        exit 1
        ;;
esac

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 ${1:-}"
    exit 1
fi

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

conf_get() {
    local key="$1" default="$2" value
    [ -f "$SITES_CONF" ] || { echo "$default"; return; }
    value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
    # tr -d '\r': xargs does not strip a carriage return, and a value is the
    # last thing on its line, so a CRLF config leaves one inside every value.
    value="$(echo "$value" | tr -d '\r' | sed 's/#.*//' | xargs)"
    echo "${value:-$default}"
}

# A machine page is `PANEL = id | port | name`. Looked up by id, which never
# changes; the name is the console's to rename.
#
# Three answers, not two, because emptying a port is destructive: it removes the
# vhost and closes the port. Only a line that EXISTS and says `-` or nothing may
# mean that. A missing line, or one too short to have a port field, prints
# MISSING so the caller refuses instead of quietly applying the off path.
panel_port() {
    local id="$1" line
    [ -f "$SITES_CONF" ] || { echo "MISSING"; return; }
    line="$(sed -n 's/^[[:space:]]*PANEL[[:space:]]*=//p' "$SITES_CONF" \
        | awk -F'|' -v want="$id" '
            { first = $1; gsub(/^[ \t]+|[ \t]+$/, "", first)
              if (first == want) { print NF "|" $2; exit } }')"
    [ -z "$line" ] && { echo "MISSING"; return; }
    [ "${line%%|*}" -lt 3 ] && { echo "MISSING"; return; }
    # Same trailing-comment handling conf_get does, so the two agree.
    line="$(echo "${line#*|}" | sed 's/#.*//' | xargs)"
    [ "$line" = "-" ] && line=""
    echo "$line"
}

# Is this exact port already allowed from this exact subnet?
#
# Field comparison, not a regex over the text. `grep "$port.*$cidr"` matched
# port 1000 inside a line about 10001 and reported it open, and the dots and
# slash in a CIDR are regex metacharacters rather than the literals they look
# like. Either way round the answer is wrong and the port never gets opened.
ufw_allows() {
    local port="$1" cidr="$2"
    ufw status 2>/dev/null | awk -v p="$port" -v c="$cidr" '
        { to = $1; from = $NF
          sub(/\/tcp$/, "", to); sub(/\/udp$/, "", to)
          if (to == p && from == c) { found = 1 } }
        END { exit !found }'
}

MANAGER_HOME="/var/lib/hosting-manager"
WEB_ROOT="/var/www/hosting-manager"
PUBLISHER="/usr/local/sbin/publish_hostings.sh"
UPDATER="/usr/local/sbin/trigger_update.sh"
REBOOTER="/usr/local/sbin/reboot_machine.sh"
APPLIER="/usr/local/sbin/trigger_apply.sh"
CHECKER="/usr/local/sbin/check_hostings.sh"
PROVISIONER="/usr/local/sbin/provision_repo.sh"
DOMAINS="/usr/local/sbin/fetch_domains.sh"
JOBSTATUS="/usr/local/sbin/jenkins_job_status.sh"
JOBLOG="/usr/local/sbin/jenkins_job_log.sh"
SITEJOB="/usr/local/sbin/trigger_site_job.sh"
DEPLOYEDSHA="/usr/local/sbin/deployed_commit.sh"
AUTHUSERS="/usr/local/sbin/manage_auth_users.sh"
REQUESTS="/usr/local/sbin/manage_requests.sh"
# Called BY manage_requests.sh and never by the page, so it gets no sudoers
# entry: the notifier is already running as root by the time it is reached.
NOTIFIER="/usr/local/sbin/notify_request.sh"
# Read only, and the page calls it for a customer filling in a domain request,
# so it does get a sudoers line: the API key it reads is root's.
CHECKDOMAIN="/usr/local/sbin/check_domain_available.sh"
READSETTINGS="/usr/local/sbin/read_appsettings.sh"
PROMOTE="/usr/local/sbin/promote_certificate.sh"
MAILSET="/usr/local/sbin/app_mail_settings.sh"
SVCCTL="/usr/local/sbin/app_service_control.sh"
FASTAPPLY="/usr/local/sbin/apply_config_only.sh"
GOLIVE="/usr/local/sbin/go_live.sh"
PUBSMB="/usr/local/sbin/publish_smb.sh"
# The repair half of the publisher: fast-forward, validate, reload. No push.
RELOADSMB="/usr/local/sbin/reload_samba.sh"
LISTDIRS="/usr/local/sbin/list_folders.sh"
LISTREPOS="/usr/local/sbin/list_repo_names.sh"
LISTPROJECTS="/usr/local/sbin/list_startup_projects.sh"
# The branches in one repository, for the drawer's Source branch dropdown.
LISTBRANCHES="/usr/local/sbin/list_repo_branches.sh"
MANAGEREPO="/usr/local/sbin/manage_repo.sh"
SHAREACL="/usr/local/sbin/set_share_access.sh"
MANAGEMAIL="/usr/local/sbin/manage_mail.sh"
MAILPW="/usr/local/sbin/set_mail_password.sh"
# Read only: it reports what to type into Outlook, from what Dovecot and Postfix
# are actually doing. A customer setting up their own phone is exactly who asks.
MAILCLIENT="/usr/local/sbin/mail_client_settings.sh"
# Shares a person's 1Password entry and mails them the link, and writes the
# second factor's recovery codes into it. Only those two verbs are granted: the
# password verbs are called by root scripts, never by the page.
PERSONENTRY="/usr/local/sbin/person_entry.sh"
# Read only: the console audit trail from the journal, for the Audit tab.
READAUDIT="/usr/local/sbin/read_audit.sh"
# No .sh: it is the command the code page and the SSH banner tell you to type.
OTP="/usr/local/sbin/console_otp"
OTP_MOTD="/etc/update-motd.d/61-console-otp"
SUDOERS="/etc/sudoers.d/020_hosting-manager"

# THE PAGE'S OWN ACCOUNT, item 146. The page ran as www-data, which every PHP
# site and Roundcube run as too, and www-data held the grant below. So a bug in
# any of them could make any account a full console admin.
PAGE_USER="hosting-manager"
PHP_FPM_VER="$(ls -d /etc/php/*/fpm 2>/dev/null | sort -V | tail -1 | cut -d/ -f4)"
POOL_FILE="/etc/php/${PHP_FPM_VER}/fpm/pool.d/${PAGE_USER}.conf"
POOL_SOCKET="/run/php/${PAGE_USER}.sock"
SRC_DIR="$REPO_ROOT/hostings/console"
SRC_PAGE="$SRC_DIR/index.php"

# The styles and scripts that index.php loads beside itself. Listed rather than
# globbed, so a file left behind in the checkout is never published, and a file
# added to the page without being added here fails pre-flight instead of
# reaching the browser as a 404 and a blank table.
SRC_ASSETS=(style.css i18n.js cells.js drawer.js chrome.js apply.js smb.js bulk.js users.js requests.js audit.js boot.js second_factor.php recovery_cli.php forgot.php)
SRC_PUBLISHER="$SCRIPT_DIR/publish_hostings.sh"
SRC_UPDATER="$SCRIPT_DIR/trigger_update.sh"
SRC_REBOOTER="$SCRIPT_DIR/reboot_machine.sh"
SRC_APPLIER="$SCRIPT_DIR/trigger_apply.sh"
SRC_CHECKER="$SCRIPT_DIR/check_hostings.sh"
SRC_PROVISIONER="$SCRIPT_DIR/provision_repo.sh"
SRC_DOMAINS="$SCRIPT_DIR/fetch_domains.sh"
SRC_JOBSTATUS="$SCRIPT_DIR/jenkins_job_status.sh"
SRC_JOBLOG="$SCRIPT_DIR/jenkins_job_log.sh"
SRC_SITEJOB="$SCRIPT_DIR/trigger_site_job.sh"
SRC_DEPLOYEDSHA="$SCRIPT_DIR/deployed_commit.sh"
SRC_AUTHUSERS="$SCRIPT_DIR/manage_auth_users.sh"
SRC_REQUESTS="$SCRIPT_DIR/manage_requests.sh"
SRC_NOTIFIER="$SCRIPT_DIR/notify_request.sh"
SRC_CHECKDOMAIN="$SCRIPT_DIR/check_domain_available.sh"
SRC_READSETTINGS="$SCRIPT_DIR/read_appsettings.sh"
SRC_PROMOTE="$SCRIPT_DIR/promote_certificate.sh"
SRC_MAILSET="$SCRIPT_DIR/app_mail_settings.sh"
SRC_SVCCTL="$SCRIPT_DIR/app_service_control.sh"
SRC_FASTAPPLY="$SCRIPT_DIR/apply_config_only.sh"
SRC_GOLIVE="$SCRIPT_DIR/go_live.sh"
SRC_PUBSMB="$SCRIPT_DIR/publish_smb.sh"
SRC_RELOADSMB="$SCRIPT_DIR/reload_samba.sh"
SRC_LISTDIRS="$SCRIPT_DIR/list_folders.sh"
SRC_LISTREPOS="$SCRIPT_DIR/list_repo_names.sh"
SRC_LISTPROJECTS="$SCRIPT_DIR/list_startup_projects.sh"
SRC_LISTBRANCHES="$SCRIPT_DIR/list_repo_branches.sh"
SRC_MANAGEREPO="$SCRIPT_DIR/manage_repo.sh"
SRC_SHAREACL="$SCRIPT_DIR/set_share_access.sh"
SRC_MANAGEMAIL="$SCRIPT_DIR/manage_mail.sh"
SRC_MAILPW="$SCRIPT_DIR/set_mail_password.sh"
SRC_MAILCLIENT="$SCRIPT_DIR/mail_client_settings.sh"
SRC_PERSONENTRY="$SCRIPT_DIR/person_entry.sh"
SRC_READAUDIT="$SCRIPT_DIR/read_audit.sh"
SRC_OTP="$SCRIPT_DIR/console_otp.sh"

LAN_PORT="$(panel_port console)"
VHOST_NAME="hosting-manager"
VHOST="/etc/apache2/sites-available/${VHOST_NAME}.conf"
AUTH_FILE="$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)"
ADMIN_USER="$(conf_get AUTH_ADMIN_USER admin)"

# WHO MAY REACH THIS PAGE AT ALL: the names that hold a role, and nobody else.
# The owner, 2026-09-10.
#
# Not `valid-user`. Every account in the password file exists for something
# else too, a protected vhost, a LAN preview, an SMB share, and none of that
# should be a console login. Those vhosts keep their own AuthUsers lists and
# are untouched by this: it is only the console that narrows.
#
# Read from the SOURCE copy, not the installed one: on a fresh machine nothing
# is in /usr/local/sbin yet, and this file is written before that copy is made.
#
# The list is rebuilt on every run, so giving somebody a role and re-running is
# what lets them in. index.php refuses a roleless account as well, for the
# window between a role being taken away and this file being rewritten.
ROLE_HOLDERS="$(SITES_CONF="$SITES_CONF" bash "$SRC_AUTHUSERS" --role-holders 2>/dev/null || true)"
[ -z "$ROLE_HOLDERS" ] && ROLE_HOLDERS="$ADMIN_USER"
AUTH_ROOT="$(conf_get AUTH_WEB_ROOT /var/www/auth)"
SESSION_KEY="$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)"
LOGIN_PAGE="login.html"


print_header "Hosting manager"
print_status "Config: /etc/hostings"
print_status "Page:   $WEB_ROOT"
print_status "Port:   ${LAN_PORT:-none, so the page is installed but nothing serves it}"
print_status "Mode:   $MODE"

# =============================================================================
# Pre-flight
# =============================================================================
ERRORS=()

[ -f "$SRC_PAGE" ]      || ERRORS+=("The page is missing: $SRC_PAGE")

for A in "${SRC_ASSETS[@]}"; do
    [ -f "$SRC_DIR/$A" ] || ERRORS+=("The page loads $A and it is missing: $SRC_DIR/$A")
done

# A PHP error here reaches the machine as a blank white page with nothing said
# about why. Nothing checked this until 2026-08-16: tools/check_console_js.sh
# parses the page's JavaScript and says so itself, but cannot see the PHP.
if command -v php >/dev/null 2>&1; then
    for PHP_SRC in "$SRC_PAGE" "$SRC_DIR/second_factor.php" "$SRC_DIR/recovery_cli.php" "$SRC_DIR/forgot.php"; do
        [ -f "$PHP_SRC" ] || continue
        if ! PHP_LINT="$(php -l "$PHP_SRC" 2>&1)"; then
            ERRORS+=("$(basename "$PHP_SRC") does not parse, so the page would serve a blank screen:")
            ERRORS+=("  $(echo "$PHP_LINT" | head -3 | tr '\n' ' ')")
        fi
    done
fi
[ -f "$SRC_PUBLISHER" ] || ERRORS+=("The publisher is missing: $SRC_PUBLISHER")
[ -f "$SRC_OTP" ]       || ERRORS+=("The second factor break-glass is missing: $SRC_OTP")
[ -f "$SRC_UPDATER" ]   || ERRORS+=("The update trigger is missing: $SRC_UPDATER")
[ -f "$SRC_REBOOTER" ]  || ERRORS+=("The reboot trigger is missing: $SRC_REBOOTER")
[ -f "$SRC_APPLIER" ]   || ERRORS+=("The apply trigger is missing: $SRC_APPLIER")
[ -f "$SRC_CHECKER" ]   || ERRORS+=("The check runner is missing: $SRC_CHECKER")
[ -f "$SRC_PROVISIONER" ] || ERRORS+=("The provisioner is missing: $SRC_PROVISIONER")
[ -f "$SRC_PERSONENTRY" ] || ERRORS+=("The 1Password entry script is missing: $SRC_PERSONENTRY")
[ -d /etc/hostings ]    || ERRORS+=("No config directory at /etc/hostings. Run install_hostings.sh first.")

id www-data >/dev/null 2>&1    || ERRORS+=("There is no www-data user, so Apache is not installed")

if [ -z "$PHP_FPM_VER" ]; then
    ERRORS+=("PHP-FPM is not installed, and the page runs in a PHP-FPM pool of its own.")
    ERRORS+=("  Run it first: sudo bash LinuxBasics/install_scripts/add_php.sh")
fi

# A page with no PANEL line is not a page that is switched off. Emptying a port
# removes the vhost and closes it, so an absent or malformed line must stop the
# run rather than be read as an instruction to do that.
if [ "$LAN_PORT" = "MISSING" ]; then
    ERRORS+=("No usable 'PANEL = console | <port> | <name>' line in $SITES_CONF")
    ERRORS+=("  Add one, or set its port to '-' if the console really should be off.")
    LAN_PORT=""
fi

# Every page against every other, and against the rows. Two panels wanting one
# port used to surface as an Apache dump at apply time instead of a sentence
# here, and the console can now change these ports from a browser.
if [ -n "$LAN_PORT" ]; then
    if ! [ "$LAN_PORT" -ge 1024 ] 2>/dev/null; then
        ERRORS+=("The console's panel port must be a number of 1024 or above, not '$LAN_PORT'")
    fi
    while IFS='|' read -r other_id other_port; do
        [ "$other_id" = "console" ] && continue
        [ "$other_port" = "$LAN_PORT" ] && \
            ERRORS+=("The console's panel port is $LAN_PORT, which the '$other_id' page already holds")
    done < <(sed -n 's/^[[:space:]]*PANEL[[:space:]]*=//p' "$SITES_CONF" \
             | awk -F'|' 'NF >= 3 { gsub(/^[ \t]+|[ \t]+$/, "", $1)
                                    gsub(/^[ \t]+|[ \t]+$/, "", $2)
                                    print $1 "|" $2 }')

    if awk -F'|' -v p="$LAN_PORT" '
            /^[[:space:]]*#/ { next }
            NF > 1 { gsub(/^[ \t]+|[ \t]+$/, "", $1)
                     gsub(/^[ \t]+|[ \t]+$/, "", $3)
                     if ($1 ~ /^(app|proxy)$/ && $3 == p) found = 1 }
            END { exit !found }' "$SITES_CONF"; then
        ERRORS+=("The console's panel port is $LAN_PORT, which a row in $SITES_CONF already holds")
    fi

    if [ ! -f "$AUTH_FILE" ]; then
        ERRORS+=("No password file at $AUTH_FILE, so nobody could log in.")
        ERRORS+=("  Create it: sudo bash LinuxBasics/install_scripts/add_auth_users.sh --file $AUTH_FILE $ADMIN_USER")
    elif ! grep -q "^${ADMIN_USER}:" "$AUTH_FILE" 2>/dev/null; then
        ERRORS+=("$AUTH_FILE has no '$ADMIN_USER' entry, so the login would reject everyone.")
        ERRORS+=("  Add it: sudo htpasswd $AUTH_FILE $ADMIN_USER")
    fi
    if [ ! -f "$AUTH_ROOT/$LOGIN_PAGE" ] || [ ! -f "$SESSION_KEY" ]; then
        ERRORS+=("No login page at $AUTH_ROOT/$LOGIN_PAGE or no session key at $SESSION_KEY.")
        ERRORS+=("  Run add_app_vhosts.sh first: it installs both.")
    fi
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

if [ "$MODE" = "check" ]; then
    print_status "would create $MANAGER_HOME"
    print_status "would run the page as $PAGE_USER, in its own PHP pool at $POOL_FILE"
    print_status "would install the privileged commands and the sudo grant for $PAGE_USER"
    print_status "would install the page at $WEB_ROOT"
    print_status "would make recovery codes for any console account that has none, and keep them in 1Password"
    if [ -n "$LAN_PORT" ]; then
        print_status "would serve it on port $LAN_PORT, local subnet only, login in front"
    else
        print_status "The console's panel port is empty: would remove the vhost and close the port"
    fi
    print_status "--check, so nothing was written."
    exit 0
fi

# =============================================================================
# The page's own account and PHP pool
#
# In the www-data group only to READ what the page read before: the password
# file, the user metadata, the requests. Nothing www-data can write is trusted
# by this page, which is the direction that matters.
# =============================================================================
if ! id "$PAGE_USER" >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin "$PAGE_USER"
    print_success "Created the account $PAGE_USER"
fi
usermod -aG www-data "$PAGE_USER"

NEW_POOL="$(cat <<EOF
; Generated by add_hosting_manager.sh, rewritten on every run.
; The hosting manager page, and nothing else, runs in this pool.
[${PAGE_USER}]
user = ${PAGE_USER}
group = ${PAGE_USER}
listen = ${POOL_SOCKET}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 60s
EOF
)"

if [ -f "$POOL_FILE" ] && [ "$(cat "$POOL_FILE")" = "$NEW_POOL" ]; then
    print_success "PHP pool already correct: the page runs as $PAGE_USER."
else
    printf '%s\n' "$NEW_POOL" > "$POOL_FILE"
    if ! "php-fpm${PHP_FPM_VER}" -t >/dev/null 2>&1; then
        print_error "PHP-FPM rejected $POOL_FILE, so it was removed again:"
        "php-fpm${PHP_FPM_VER}" -t 2>&1 | tail -5
        rm -f "$POOL_FILE"
        exit 1
    fi
    systemctl reload "php${PHP_FPM_VER}-fpm"
    print_success "Wrote $POOL_FILE: the page runs as $PAGE_USER."
fi

# =============================================================================
# The manager's home
#
# 0755 root:root. The page has to TRAVERSE this directory: its candidate files
# live here. Setting 0750 only breaks the page.
# =============================================================================
retire_the_console

mkdir -p "$MANAGER_HOME"

# Brought up to date before the page shows it: a page showing an older config
# invites saving it over the newer one. The save refuses that anyway; this
# saves the round trip.
bash "$SCRIPT_DIR/publish_hostings.sh" --refresh \
    || print_info "Could not refresh the config directory, so the page may show an older config."

chown -R root:root "$MANAGER_HOME"
chmod 0755 "$MANAGER_HOME"

# The page reads the config, so the directory must be readable by it.
chmod 0755 /etc/hostings
chmod 0644 "/etc/hostings/hostings.conf"
[ -f "/etc/hostings/hostings.test.conf" ] && chmod 0644 "/etc/hostings/hostings.test.conf"

# Where the page drops the edited file. Writable by the page, and nothing else
# in this directory is.
install -d -m 0755 -o root -g root "$MANAGER_HOME"
touch "${MANAGER_HOME}/hostings.conf.candidate"
chown "$PAGE_USER:$PAGE_USER" "${MANAGER_HOME}/hostings.conf.candidate"
chmod 0600 "${MANAGER_HOME}/hostings.conf.candidate"

# The hash of the file the page was shown, and the publisher refuses without it.
# It has to exist and be writable by the page BEFORE the page tries: the
# directory is 0755 root, so a page creating it from scratch cannot, and on
# 2026-08-10 that turned the stale-edit guard into a no-op and a save reverted
# a day of work.
touch "${MANAGER_HOME}/candidate.base"
chown "$PAGE_USER:$PAGE_USER" "${MANAGER_HOME}/candidate.base"
chmod 0600 "${MANAGER_HOME}/candidate.base"

# The same two files for smb.conf. Same reason, same ownership: the page writes
# them, the directory does not let it create them.
for f in smb.conf.candidate smb.candidate.base; do
    touch "${MANAGER_HOME}/${f}"
    chown "$PAGE_USER:$PAGE_USER" "${MANAGER_HOME}/${f}"
    chmod 0600 "${MANAGER_HOME}/${f}"
done

# What the last save did, written by the page and read back after the redirect.
# THE SAME TRAP AS candidate.base ABOVE, and it caught us again: the directory
# is 0755 root, the page cannot create files in it, the write is @-suppressed, so
# last-save.txt was never once created and every failure lost its reason. Found
# 2026-09-03 when a mailbox delete failed and the dialog had nothing to show.
touch "${MANAGER_HOME}/last-save.txt"
chown "$PAGE_USER:$PAGE_USER" "${MANAGER_HOME}/last-save.txt"
chmod 0600 "${MANAGER_HOME}/last-save.txt"

# One file per change in progress, so every open page can show that somebody
# else is saving or applying. Same trap again: the page cannot create it.
install -d -o "$PAGE_USER" -g "$PAGE_USER" -m 0700 "${MANAGER_HOME}/work"
chown -R "$PAGE_USER:$PAGE_USER" "${MANAGER_HOME}/work"

# The second factor's key, codes and recovery hashes. The page makes the key on
# first use; chown -R again because the root:root sweep above takes it back.
install -d -o "$PAGE_USER" -g "$PAGE_USER" -m 0700 "${MANAGER_HOME}/2fa"
chown -R "$PAGE_USER:$PAGE_USER" "${MANAGER_HOME}/2fa"

# The forgot-password links, one per account, and the hourly send count.
install -d -o "$PAGE_USER" -g "$PAGE_USER" -m 0700 "${MANAGER_HOME}/reset"
chown -R "$PAGE_USER:$PAGE_USER" "${MANAGER_HOME}/reset"

# =============================================================================
# The publisher, and the one grant that lets the page call it
# =============================================================================
install -m 0700 -o root -g root "$SRC_PUBLISHER" "$PUBLISHER"
print_success "Installed $PUBLISHER"

install -m 0700 -o root -g root "$SRC_UPDATER" "$UPDATER"
print_success "Installed $UPDATER"

install -m 0700 -o root -g root "$SRC_REBOOTER" "$REBOOTER"
print_success "Installed $REBOOTER"

install -m 0700 -o root -g root "$SRC_APPLIER" "$APPLIER"
print_success "Installed $APPLIER"

install -m 0700 -o root -g root "$SRC_CHECKER" "$CHECKER"
print_success "Installed $CHECKER"

install -m 0700 -o root -g root "$SRC_PROVISIONER" "$PROVISIONER"
print_success "Installed $PROVISIONER"

install -m 0700 -o root -g root "$SRC_DOMAINS" "$DOMAINS"
print_success "Installed $DOMAINS"

install -m 0700 -o root -g root "$SRC_JOBSTATUS" "$JOBSTATUS"
print_success "Installed $JOBSTATUS"

install -m 0700 -o root -g root "$SRC_JOBLOG" "$JOBLOG"
print_success "Installed $JOBLOG"

install -m 0700 -o root -g root "$SRC_SITEJOB" "$SITEJOB"
print_success "Installed $SITEJOB"
install -m 0700 -o root -g root "$SRC_DEPLOYEDSHA" "$DEPLOYEDSHA"
print_success "Installed $DEPLOYEDSHA"
install -m 0700 -o root -g root "$SRC_AUTHUSERS" "$AUTHUSERS"
print_success "Installed $AUTHUSERS"
install -m 0700 -o root -g root "$SRC_REQUESTS" "$REQUESTS"
print_success "Installed $REQUESTS"
install -m 0700 -o root -g root "$SRC_NOTIFIER" "$NOTIFIER"
print_success "Installed $NOTIFIER"
install -m 0700 -o root -g root "$SRC_CHECKDOMAIN" "$CHECKDOMAIN"
print_success "Installed $CHECKDOMAIN"
install -m 0700 -o root -g root "$SRC_READSETTINGS" "$READSETTINGS"
print_success "Installed $READSETTINGS"

install -m 0700 -o root -g root "$SRC_PROMOTE" "$PROMOTE"
print_success "Installed $PROMOTE"

install -m 0700 -o root -g root "$SRC_MAILSET" "$MAILSET"
print_success "Installed $MAILSET"

install -m 0700 -o root -g root "$SRC_SVCCTL" "$SVCCTL"
print_success "Installed $SVCCTL"

install -m 0700 -o root -g root "$SRC_FASTAPPLY" "$FASTAPPLY"
print_success "Installed $FASTAPPLY"

install -m 0700 -o root -g root "$SRC_GOLIVE" "$GOLIVE"
print_success "Installed $GOLIVE"

install -m 0700 -o root -g root "$SRC_PUBSMB" "$PUBSMB"
install -m 0700 -o root -g root "$SRC_RELOADSMB" "$RELOADSMB"
print_success "Installed $RELOADSMB"
print_success "Installed $PUBSMB"

install -m 0700 -o root -g root "$SRC_LISTDIRS" "$LISTDIRS"
print_success "Installed $LISTDIRS"

install -m 0700 -o root -g root "$SRC_LISTREPOS" "$LISTREPOS"
print_success "Installed $LISTREPOS"
install -m 0700 -o root -g root "$SRC_LISTPROJECTS" "$LISTPROJECTS"
install -m 0700 -o root -g root "$SRC_LISTBRANCHES" "$LISTBRANCHES"
print_success "Installed $LISTPROJECTS"

install -m 0700 -o root -g root "$SRC_MANAGEREPO" "$MANAGEREPO"
print_success "Installed $MANAGEREPO"

install -m 0700 -o root -g root "$SRC_SHAREACL" "$SHAREACL"
print_success "Installed $SHAREACL"

install -m 0700 -o root -g root "$SRC_MANAGEMAIL" "$MANAGEMAIL"
print_success "Installed $MANAGEMAIL"

install -m 0700 -o root -g root "$SRC_MAILPW" "$MAILPW"
print_success "Installed $MAILPW"

install -m 0700 -o root -g root "$SRC_MAILCLIENT" "$MAILCLIENT"
print_success "Installed $MAILCLIENT"

install -m 0700 -o root -g root "$SRC_PERSONENTRY" "$PERSONENTRY"
print_success "Installed $PERSONENTRY"
install -m 0700 -o root -g root "$SRC_READAUDIT" "$READAUDIT"
print_success "Installed $READAUDIT"

# Root only and NOT in the sudoers grant below: it mints a console login, so
# only a sudo user over SSH may run it, never the page or the manageserver menu.
install -m 0700 -o root -g root "$SRC_OTP" "$OTP"
print_success "Installed $OTP"

# Written where you look while locked out: every SSH login prints it.
printf '%s\n' '#!/bin/sh' \
    "printf '\\n  Console locked out? sudo console_otp <user> prints a sign-in code.\\n\\n'" \
    > "$OTP_MOTD"
chmod 0755 "$OTP_MOTD"
print_success "Installed $OTP_MOTD"

# /etc/samba/smb.conf is a symlink to the config directory's smb.conf, so the
# file the console saves is the file Samba reads.
SMB_LINK="/etc/samba/smb.conf"
SMB_TARGET="/etc/hostings/smb/smb.conf"
if [ -f "$SMB_TARGET" ]; then
    if [ "$(readlink -f "$SMB_LINK" 2>/dev/null)" = "$SMB_TARGET" ]; then
        print_success "Samba already reads $SMB_TARGET"
    elif [ -L "$SMB_LINK" ] || [ ! -e "$SMB_LINK" ]; then
        ln -sfn "$SMB_TARGET" "$SMB_LINK"
        print_success "Samba now reads $SMB_TARGET"
    else
        # A real file, not a link. Someone put it there on purpose, or the
        # package did; replacing it silently would throw away a hand edit.
        print_action "$SMB_LINK is a real file, so it was left alone."
        print_info "The console publishes to $SMB_TARGET, which Samba is not reading."
    fi
else
    print_info "No $SMB_TARGET in this clone, so the Samba symlink was left as it is."
fi

TMP_SUDOERS="$(mktemp)"
{
    echo "# Generated by add_hosting_manager.sh. Do not edit by hand."
    echo "#"
    echo "# Eight literal commands, no wildcard. Each takes its input from a"
    echo "# fixed path instead of an argument, so there is no argument list for"
    echo "# a compromised page to smuggle anything into. The two provisioner"
    echo "# entries are the two spellings it may be called with, written out in"
    echo "# full: a wildcard would let the page choose the rest of the line."
    echo "#"
    echo "# publish  writes the branch. Validates first, and applies nothing."
    echo "# check    read-only. Writes the drift report the page displays."
    echo "# apply    the one that changes the machine, and the only one that"
    echo "#          does. Separate from publish on purpose."
    echo "# update   operating system updates, through the Jenkins job."
    echo "# domains  read-only, and the token it mints from the DNS key is"
    echo "#          read_only too, so it cannot alter a record. Lists the"
    echo "#          account's domains for the mailbox drawer to offer."
    echo "# status   read-only. Two booleans per job, so the page can grey out"
    echo "#          a button while the job behind it is still running."
    echo "#"
    echo "# provision   creates the repositories rows ask for, and --create is"
    echo "#             a separate entry so the page can also run the reporting"
    echo "#             form, which changes nothing."
    echo "#"
    echo "# The triggers exist because the Jenkins token is 0600 root and the"
    echo "# page is ${PAGE_USER}. Root reads the token; the page never holds one."
    echo "# The GitHub token is the same arrangement, in /etc/github-api."
    # trigger_site_job.sh takes a row and an action, so it is the one entry here
    # with a wildcard. What that permits is bounded by the script itself: it
    # accepts four action names and refuses any row not in the published config.
    # promote_certificate.sh is the other wildcard, and it is the only entry that
    # can spend a real Let's Encrypt issuance. What that permits is bounded by
    # the script: one hostname, which must already hold a staging certificate and
    # must be ticked as checked by a person.
    # app_mail_settings.sh is the only entry that writes a root-owned file the
    # page cannot otherwise touch. What it will write is bounded by the script:
    # the row must be an app row in the published config, both values must be
    # email addresses, and every KEY is fixed in the script rather than taken
    # from the caller. The page chooses two values and never a key.
    # app_service_control.sh is the only entry that talks to systemd. What it
    # permits is bounded by the script: three verbs, none of which edit,
    # enable, disable or mask anything, and a unit name BUILT from an app row
    # in the published config rather than taken from the caller.
    # apply_config_only.sh writes vhosts and preview ports and nothing else:
    # no repository, no certificate, no unit, no prune. It takes no arguments,
    # so there is nothing for the page to steer.
    #
    # publish_smb.sh takes no arguments either, and reads its candidate from a
    # fixed path. It validates with testparm twice and reloads rather than
    # restarts, so a bad share cannot take smbd down and a good one does not
    # drop an open connection.
    #
    # Two grants here take a caller-chosen argument, because a folder picker is
    # a walk and a permission is set on a path. Each answers that itself rather
    # than trusting the input: the path is resolved with readlink -f and refused
    # unless it lands inside /srv, /var/www, /mnt, /media or a home.
    #
    # list_folders.sh reports directory NAMES only, never files, never contents.
    #
    # set_share_access.sh adds two refusals of its own: it never touches
    # "other", and it refuses a folder owned by a system account. A share
    # pointed at the Dovecot mail store on 2026-08-26 would otherwise have
    # opened the DKIM signing keys to anyone on the LAN.
    #
    # manage_mail.sh forwards, restores or deletes one mailbox, chosen in the
    # console's delete dialog. Four verbs, each takes a local part and a domain.
    # What it permits is bounded by the script: it refuses contact@ (the forward
    # target) and the dkim key directory, rebuilds the maildir path from parts
    # and readlink -f-checks it stays under Dovecot's mail root, and purge
    # refuses a maildir not owned by vmail. It never creates a mailbox: that
    # needs a password and is not on offer to the page.
    #
    # set_mail_password.sh sets the DEFAULT password of one mailbox that already
    # has a maildir, so the page cannot invent an account the config does not
    # claim. The password arrives on stdin and never as an argument, because ps
    # shows arguments to every account on the machine. It refuses dkim, refuses
    # anything under eight characters, and rebuilds and re-checks the maildir
    # path the same way manage_mail.sh does.
    echo "${PAGE_USER} ALL=(root) NOPASSWD: ${PUBLISHER}, ${CHECKER}, ${APPLIER}, ${UPDATER}, ${REBOOTER} \"\", ${PROVISIONER}, ${PROVISIONER} --create, ${PROVISIONER} --step *, ${DOMAINS}, ${JOBSTATUS}, ${JOBSTATUS} --history *, ${JOBSTATUS} --stages *, ${JOBLOG} *, ${SITEJOB} *, ${DEPLOYEDSHA} *, ${AUTHUSERS} --list, ${AUTHUSERS} --add *, ${AUTHUSERS} --password *, ${AUTHUSERS} --self-password *, ${AUTHUSERS} --disable *, ${AUTHUSERS} --enable *, ${AUTHUSERS} --delete *, ${AUTHUSERS} --meta *, ${AUTHUSERS} --role-of *, ${AUTHUSERS} --email-of *, ${AUTHUSERS} --role-holders, ${REQUESTS} --list, ${REQUESTS} --add *, ${REQUESTS} --get *, ${REQUESTS} --approve *, ${REQUESTS} --decline *, ${REQUESTS} --seen *, ${REQUESTS} --withdraw *, ${CHECKDOMAIN} *, ${PROMOTE} *, ${MAILSET} --read *, ${MAILSET} --write *, ${SVCCTL} *, ${FASTAPPLY}, ${GOLIVE}, ${GOLIVE} --check, ${PUBSMB}, ${RELOADSMB}, ${LISTDIRS}, ${LISTDIRS} *, ${LISTREPOS}, ${LISTPROJECTS} *, ${LISTBRANCHES} *, ${READSETTINGS} *, ${MANAGEREPO} --archive *, ${MANAGEREPO} --delete *, ${SHAREACL} --check *, ${SHAREACL} --set *, ${MANAGEMAIL} --check *, ${MANAGEMAIL} --forward *, ${MANAGEMAIL} --retire *, ${MANAGEMAIL} --unforward *, ${MANAGEMAIL} --purge *, ${MAILPW} --check *, ${MAILPW} --set *, ${MAILCLIENT} *, ${PERSONENTRY} --share *, ${PERSONENTRY} --share-mailbox *, ${PERSONENTRY} --recovery *, ${READAUDIT}"
} > "$TMP_SUDOERS"

if ! visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
    print_error "The generated sudoers file is invalid, so nothing was installed."
    visudo -cf "$TMP_SUDOERS" || true
    rm -f "$TMP_SUDOERS"
    exit 1
fi
install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS"
rm -f "$TMP_SUDOERS"
print_success "Installed $SUDOERS"

# =============================================================================
# The page
# =============================================================================
install -d -m 0755 -o root -g root "$WEB_ROOT"
install -m 0644 -o root -g root "$SRC_PAGE" "$WEB_ROOT/index.php"
print_success "Installed $WEB_ROOT/index.php"

for A in "${SRC_ASSETS[@]}"; do
    install -m 0644 -o root -g root "$SRC_DIR/$A" "$WEB_ROOT/$A"
done
print_success "Installed ${#SRC_ASSETS[@]} styles and scripts beside it"

# A file that used to be loaded and is not any more keeps being served, and the
# next person reading the folder cannot tell which half is live.
for OLD in "$WEB_ROOT"/*.js "$WEB_ROOT"/*.css; do
    [ -e "$OLD" ] || continue
    KEEP=no
    for A in "${SRC_ASSETS[@]}"; do
        [ "$(basename "$OLD")" = "$A" ] && KEEP=yes
    done
    if [ "$KEEP" = no ]; then
        rm -f "$OLD"
        print_status "Removed $(basename "$OLD"), which the page no longer loads."
    fi
done

# =============================================================================
# Recovery codes for every account that has none
#
# The owner, 2026-09-20: made now and at creation, never at the moment somebody is
# locked out. The console covers accounts made through it; this covers the ones
# that already existed and the admin the installer itself makes.
#
# --ensure is the whole reason this is safe to re-run: an account that already
# has a set keeps it, so a re-install never voids working codes.
#
# It runs as the page user because the 2fa directory is 0700 theirs, and pipes
# the codes into person_entry.sh, which needs root. Codes never touch argv.
# =============================================================================
RECOVERY_CLI="$WEB_ROOT/recovery_cli.php"

# The reason a step failed, minus anything shaped like a code. person_entry.sh
# does not echo them, but a provider error that quotes what it was sent would,
# and this output goes to a terminal and a Jenkins log.
recovery_log_tail() {
    [ -s "$RECOVERY_LOG" ] || return 0
    tail -3 "$RECOVERY_LOG" \
        | sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<code>/g'
}
if command -v php >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -x "$PERSONENTRY" ]; then
    # `-d` turns on set -x, and a trace of this loop would print ten working
    # second factors per account into the terminal and the scrollback. Off for
    # the loop, back on after, so --debug still traces everything else.
    RECOVERY_XTRACE=off
    case "$-" in *x*) RECOVERY_XTRACE=on; set +x ;; esac

    RECOVERY_SEEN=0
    RECOVERY_MADE=0
    RECOVERY_NOVAULT=""
    RECOVERY_NOCODES=""
    RECOVERY_LOG="$(mktemp)"
    print_status "Giving any console account with no recovery codes a set of ten..."

    while read -r RUSER; do
        [ -n "$RUSER" ] || continue
        RECOVERY_SEEN=$((RECOVERY_SEEN + 1))
        # --ensure prints nothing when the account already has a set, so an
        # empty result and a failure have to be told apart by the exit code.
        if ! RCODES="$(sudo -u "$PAGE_USER" php "$RECOVERY_CLI" --ensure "$RUSER" 2>>"$RECOVERY_LOG")"; then
            RECOVERY_NOCODES="$RECOVERY_NOCODES $RUSER"
            continue
        fi
        [ -n "$RCODES" ] || continue
        RECOVERY_MADE=$((RECOVERY_MADE + 1))
        # SITES_CONF goes with it, as every other call site does: without it
        # person_entry.sh falls back to the machine's own clone and reads a
        # different hostings.conf, so the vault settings would not be the ones
        # this install is being run from.
        if ! printf '%s\n' "$RCODES" \
             | SITES_CONF="$SITES_CONF" "$PERSONENTRY" --recovery "$RUSER" >>"$RECOVERY_LOG" 2>&1; then
            RECOVERY_NOVAULT="$RECOVERY_NOVAULT $RUSER"
        fi
    done <<< "$("$AUTHUSERS" --list 2>>"$RECOVERY_LOG" | jq -r '.users[].name // empty' 2>/dev/null)"
    unset RCODES

    # Not `[ ] && set -x`: under set -e a false test there ends the install.
    if [ "$RECOVERY_XTRACE" = on ]; then set -x; fi

    # Nobody listed is a broken $AUTHUSERS, not a machine that is all covered.
    # Reporting that as success is the failure this distinguishes.
    if [ "$RECOVERY_SEEN" -eq 0 ]; then
        print_error "No console account could be listed, so no recovery codes were made."
        recovery_log_tail
    elif [ "$RECOVERY_MADE" -eq 0 ] && [ -z "$RECOVERY_NOCODES" ]; then
        print_success "All $RECOVERY_SEEN console account(s) already have recovery codes."
    else
        print_success "Made recovery codes for $RECOVERY_MADE of $RECOVERY_SEEN account(s)."
    fi

    if [ -n "$RECOVERY_NOCODES" ]; then
        print_error "Codes could not be written for:$RECOVERY_NOCODES"
        recovery_log_tail
    fi
    if [ -n "$RECOVERY_NOVAULT" ]; then
        print_action "Put these people's codes in 1Password by hand:$RECOVERY_NOVAULT"
        print_info   "The codes exist on this machine. Open the key icon as each of them to make a set that lands in the vault."
        recovery_log_tail
    fi
    rm -f "$RECOVERY_LOG"
else
    print_error "No php, no jq, or no $PERSONENTRY, so recovery codes were not made."
fi

# =============================================================================
# The LAN door
#
# The same shape as the Jenkins machine page, and for the same reason: no
# hostname means no certificate, so this is plain HTTP and the firewall scopes
# it to the local subnet.
#
# Its own cookie name, and no `secure`: a secure cookie is never sent back over
# plain HTTP, and reusing `session` would collide with the one :443 sets,
# because cookies ignore the port.
# =============================================================================
if [ -n "$LAN_PORT" ]; then
    NEW_VHOST="$(cat <<EOF
# Generated by add_hosting_manager.sh, rewritten on every run.
# Set the console's PANEL line in hostings.conf, never here.
Listen ${LAN_PORT}

<VirtualHost *:${LAN_PORT}>
    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
        # The page's own pool. Without it the machine-wide pool runs the page as
        # www-data, which holds no grant, and every button fails.
        <FilesMatch "\.php\$">
            SetHandler "proxy:unix:${POOL_SOCKET}|fcgi://${PAGE_USER}"
        </FilesMatch>
    </Directory>

    Alias /${LOGIN_PAGE} ${AUTH_ROOT}/${LOGIN_PAGE}
    Alias /auth-assets ${AUTH_ROOT}
    <Directory ${AUTH_ROOT}>
        Require all granted
    </Directory>

    # ORDER IS LOAD BEARING: <Location> blocks merge in file order and the LAST
    # match wins, so the general <Location /> comes FIRST and the exceptions
    # after it. Reversed, the login page itself requires a login and loops.
    <Location />
        AuthType form
        AuthName "Sign in"
        AuthFormProvider file
        AuthUserFile ${AUTH_FILE}
        AuthFormLoginRequiredLocation /${LOGIN_PAGE}
        # NO KeptBodySize. With it set, a POST whose body arrives in slow
        # pieces (a phone, a VPN) segfaults Apache 2.4.58; without it a 68 KB
        # config still reaches PHP whole. Measured 2026-09-23.
        Session On
        SessionCookieName manager_http path=/;httponly;SameSite=Strict
        SessionMaxAge 7200
        SessionCryptoPassphraseFile ${SESSION_KEY}
        # ONLY THE NAMES THAT HOLD A ROLE. Item 105, the owner 2026-09-10.
        #
        # It was "Require user ${ADMIN_USER}", then briefly "valid-user", and
        # neither was right: the first let nobody but the operator in, and the
        # second made every password on this machine a console login, when most
        # accounts exist for a protected vhost, a preview or a share.
        #
        # Those vhosts keep their own AuthUsers lists. Only this door narrows.
        #
        # A name that gets past this is still not trusted: what it sees is
        # decided inside index.php by its role and by each row's Owner, and
        # every write it may not do is refused there. The page's hiding is a
        # courtesy, never the control.
        Require user ${ROLE_HOLDERS}
    </Location>

    <Location /${LOGIN_PAGE}>
        AuthType None
        Require all granted
    </Location>

    <Location /auth-assets>
        AuthType None
        Require all granted
    </Location>

    # Forgot password: whoever needs it cannot sign in. The one-time token in
    # its link is what guards it (forgot.php).
    <Location /forgot.php>
        AuthType None
        Require all granted
    </Location>

    <Location /do-login>
        SetHandler form-login-handler
        AuthType form
        AuthName "Sign in"
        AuthFormProvider file
        AuthUserFile ${AUTH_FILE}
        AuthFormLoginRequiredLocation /${LOGIN_PAGE}
        AuthFormLoginSuccessLocation /
        Session On
        SessionCookieName manager_http path=/;httponly;SameSite=Strict
        SessionMaxAge 7200
        SessionCryptoPassphraseFile ${SESSION_KEY}
        Require all granted
    </Location>

    <Location /logout>
        SetHandler form-logout-handler
        AuthType None
        AuthFormLogoutLocation /${LOGIN_PAGE}
        Session On
        SessionCookieName manager_http path=/;httponly;SameSite=Strict
        SessionMaxAge 7200
        SessionCryptoPassphraseFile ${SESSION_KEY}
        Require all granted
    </Location>

    ErrorLog  \${APACHE_LOG_DIR}/${VHOST_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${VHOST_NAME}-access.log combined
</VirtualHost>
EOF
)"

    for mod in proxy_fcgi auth_form authn_file authz_user session session_cookie \
               session_crypto request; do
        a2enmod "$mod" >/dev/null 2>&1 || true
    done

    # Read before overwriting: the vhost is the only record of which port was
    # open, and moving the page to a new one otherwise leaves the old firewall
    # rule behind with nothing answering on it.
    PREV_PORT="$([ -f "$VHOST" ] && awk '/^Listen /{print $2; exit}' "$VHOST" || true)"

    if [ -f "$VHOST" ] && [ "$(cat "$VHOST")" = "$NEW_VHOST" ]; then
        print_success "LAN vhost already correct on port $LAN_PORT."
    else
        printf '%s\n' "$NEW_VHOST" > "$VHOST"
        chmod 644 "$VHOST"
        a2ensite "$VHOST_NAME" >/dev/null 2>&1
        if apache2ctl configtest >/dev/null 2>&1; then
            systemctl reload apache2
            print_success "Serving on port $LAN_PORT, sign-in page in front."
        else
            print_error "Apache rejected the manager vhost, so it was not loaded:"
            apache2ctl configtest 2>&1 | tail -10
            a2dissite "$VHOST_NAME" >/dev/null 2>&1
            exit 1
        fi
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        LAN_CIDR="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1 \
            | sed -E 's/\.[0-9]+$/.0\/24/')"
        if [ -z "$LAN_CIDR" ]; then
            print_action "Could not work out the local subnet, so port $LAN_PORT was not opened."
            print_action "Open it by hand: sudo ufw allow from 192.168.0.0/16 to any port $LAN_PORT proto tcp"
        else
            # The page moved. Close the door it used to answer on, or it stays
            # open to the subnet with nothing behind it.
            if [ -n "$PREV_PORT" ] && [ "$PREV_PORT" != "$LAN_PORT" ]; then
                ufw delete allow from "$LAN_CIDR" to any port "$PREV_PORT" proto tcp >/dev/null 2>&1 || true
                print_success "Closed $PREV_PORT, which this page no longer uses."
            fi
            if ufw_allows "$LAN_PORT" "$LAN_CIDR"; then
                print_success "Port $LAN_PORT already open to $LAN_CIDR."
            else
                ufw allow from "$LAN_CIDR" to any port "$LAN_PORT" proto tcp >/dev/null 2>&1
                print_success "Opened $LAN_PORT to $LAN_CIDR only."
            fi
        fi
    fi
elif [ -f "$VHOST" ]; then
    OLD_PORT="$(awk '/^Listen /{print $2; exit}' "$VHOST")"
    a2dissite "$VHOST_NAME" >/dev/null 2>&1 || true
    rm -f "$VHOST"
    systemctl reload apache2 2>/dev/null || true
    # Deleted the way it was added: a rule scoped to a subnet does not match
    # `delete allow <port>/tcp`.
    if [ -n "$OLD_PORT" ] && command -v ufw >/dev/null 2>&1; then
        LAN_CIDR="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1 \
            | sed -E 's/\.[0-9]+$/.0\/24/')"
        [ -n "$LAN_CIDR" ] && ufw delete allow from "$LAN_CIDR" to any port "$OLD_PORT" proto tcp >/dev/null 2>&1 || true
    fi
    print_status "The console's panel port is empty: removed the vhost and closed port ${OLD_PORT:-it}."
fi

# =============================================================================
# Say what is left, because two things cannot be automated from here
# =============================================================================
echo ""
print_success "Hosting manager installed."
echo ""

# A dead publish path is a failed install, not a note at the bottom of a green
# one. Items 29 and 59 are both "printed a red line and exited 0".
EXIT_RC=0

if id -u jenkins >/dev/null 2>&1 && [ ! -f "${MANAGER_HOME}/jenkins-token" ]; then
    print_action "1. A Jenkins token, so Apply and Update can start their jobs:"
    print_action "   In Jenkins: your user -> Security -> API token -> Add new token"
    print_action "   Then, replacing the parts in angle brackets:"
    print_action "     sudo install -m 600 -o root -g root /dev/null ${MANAGER_HOME}/jenkins-token"
    print_action "     echo '<jenkins-user>:<token>' | sudo tee ${MANAGER_HOME}/jenkins-token"
    print_info "   Save and Re-check work without it. Apply and Update do not:"
    print_info "   press Build on the job in Jenkins instead."
fi

echo ""
if [ -n "$LAN_PORT" ]; then
    print_success "Open it at http://$(hostname -I | awk '{print $1}'):${LAN_PORT}, and sign in as ${ADMIN_USER}."
else
    print_action "2. PANEL = console has no port in $SITES_CONF, so nothing serves the page."
fi

# 3 means installed but unable to publish: the page will render and every save
# will fail at the push. Jenkins must see that as a failure.
exit "$EXIT_RC"
