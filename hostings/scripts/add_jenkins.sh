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
# Install Jenkins LTS and bind it to localhost only.
#
# Jenkins is the server's deploy pipeline: push to a branch, Jenkins builds,
# tests and deploys into running_csharp_projects, then restarts the Kestrel
# unit. Chosen over GitHub Actions on purpose. Actions is lighter and its
# builds run on someone else's hardware, but the orchestration stays GitHub's,
# so a pricing change stops deploys. This runs on hardware we own.
#
# Two deliberate choices:
#
#   Localhost only. Jenkins is a web app that runs arbitrary shell. It listens
#   on loopback and is reached solely through the Apache vhost, which is
#   where TLS and any access control live. Exposing 8080 directly would mean
#   an unauthenticated setup wizard on the open internet for as long as it
#   takes you to finish it.
#
#   The setup wizard is left ON. It is the thing that forces an admin password
#   to exist. Disabling it for a smoother install would leave the instance
#   open, and this script must never be the reason that happens.
#
# Safe to re-run: an already-installed Jenkins is left alone apart from the
# listen-address override being re-checked.
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

# Progress dots for kill-safe operations only. apt-get install is NOT wrapped
# in this: killing dpkg mid-write corrupts package state.
show_progress() {
    local message="$1"
    local command="$2"
    local interval="${3:-3}"
    local timeout="${4:-300}"

    echo -e "\e[34m${message}\e[0m"

    eval "$command" &
    local cmd_pid=$!
    local start_time
    start_time=$(date +%s)

    while kill -0 $cmd_pid 2>/dev/null; do
        echo -n "."
        sleep $interval || { printf "\n\e[31m❌ Progress loop aborted, sleep failed\e[0m\n"; break; }
        local current_time
        current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
            printf "\n\e[31m❌ Command timed out after %d seconds\e[0m\n" "$timeout"
            kill -TERM $cmd_pid 2>/dev/null || true
            sleep 2
            kill -KILL $cmd_pid 2>/dev/null || true
            return 1
        fi
    done

    wait $cmd_pid
    local exit_code=$?
    echo
    return $exit_code
}

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_TICK=0

# One frame, then 0.2s. Separate from the wrapper below so a polling loop can
# keep the indicator moving while the command it polls with is itself blocking.
spin_tick() {
    printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[SPIN_TICK % 10]}" "$1"
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Watch-only spinner: shows the command is alive but never signals it. A
# systemctl start or restart killed halfway leaves the unit half-transitioned,
# and the next run then reports a state nobody asked for.
show_spinner_watch_only() {
    local message="$1"
    shift
    "$@" &
    local cmd_pid=$!
    while kill -0 "$cmd_pid" 2>/dev/null; do
        spin_tick "$message" || break
    done
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    printf '\r\033[K'
    return $exit_code
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

# Config reader, duplicated verbatim rather than sourced, so this script stays
# runnable on its own on a machine that has only this file copied to it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

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

# Duplicated from add_auth_users.sh, per the convention that each script stays
# runnable alone. One asterisk per character, as they arrive.
read_secret() {
    local prompt="$1" out="" ch
    printf '%s' "$prompt" > /dev/tty
    while IFS= read -rsn1 ch < /dev/tty; do
        case "$ch" in
            "")             break ;;
            $'\177'|$'\b')  [ -n "$out" ] && { out="${out%?}"; printf '\b \b' > /dev/tty; } ;;
            *)              out="$out$ch"; printf '*' > /dev/tty ;;
        esac
    done
    printf '\n' > /dev/tty
    SECRET="$out"
}

read_password_twice() {
    local label="$1" p1 p2
    while :; do
        read_secret "   Password for $label: " || return 1
        p1="$SECRET"
        if [ ${#p1} -lt 8 ]; then
            printf "   \033[33mAt least 8 characters. This one runs your machine.\033[0m\n" > /dev/tty
            continue
        fi
        read_secret "   Again: " || return 1
        p2="$SECRET"
        unset SECRET
        if [ "$p1" = "$p2" ]; then
            PASSWORD="$p1"
            unset p1 p2
            return 0
        fi
        printf "   \033[33mThey do not match. Try again.\033[0m\n" > /dev/tty
    done
}

print_header "Jenkins"

# -----------------------------------------------------------------------------
# Memory check. Jenkins is a JVM and idles around 600MB to 1GB once plugins are
# installed, on a box already running eight Kestrel processes, Apache, Samba
# and Webmin. Warn loudly rather than refuse: the operator may have swap, or
# may be installing before the apps.
# -----------------------------------------------------------------------------
TOTAL_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
print_status "Total RAM: ${TOTAL_MB} MB"

if [ "$TOTAL_MB" -lt 2048 ]; then
    print_error "Under 2GB of RAM. Jenkins will not run here alongside the web stack."
    print_action "Install it on another machine, or set JENKINS_FORCE_LOW_MEMORY=1 to try anyway."
    if [ "${JENKINS_FORCE_LOW_MEMORY:-0}" != "1" ]; then
        exit 1
    fi
    print_info "JENKINS_FORCE_LOW_MEMORY=1 set, continuing against advice."
elif [ "$TOTAL_MB" -lt 4096 ]; then
    print_info "Under 4GB of RAM. Jenkins will fit but the box will be tight."
    print_action "Watch for the OOM killer taking out Kestrel units: journalctl -k | grep -i oom"
fi

# Java is installed further down, AFTER the repository is added.
#
# Which versions Jenkins accepts is not a fact worth writing here: the package
# declares it, as an alternation of virtual java runtimes, and that declaration
# is correct for the exact version about to be installed. A number written in a
# comment is correct only until the next Jenkins release.

# -----------------------------------------------------------------------------
# Jenkins apt repository. debian-stable is the LTS line: quarterly releases
# with backported fixes. The weekly line ships a new version every week and is
# not something a machine you depend on should track.
# -----------------------------------------------------------------------------
KEYRING="/usr/share/keyrings/jenkins-keyring.asc"
SOURCES="/etc/apt/sources.list.d/jenkins.list"
REPO_BASE="https://pkg.jenkins.io/debian-stable"

# -----------------------------------------------------------------------------
# THE SIGNING KEY IS FETCHED BY NAME DISCOVERY, NOT BY A NAME WRITTEN HERE
#
# Jenkins names the key after the year it was issued and rotates it every three
# years, matching the expiry of their jar and MSI signing certificates. This
# script asked for jenkins.io-2023.key, which expired on 2026-03-26. Every
# install after that date got:
#
#   W: GPG error: ... NO_PUBKEY 7198F4B714ABFC68
#   E: The repository ... is not signed.
#
# A year in a filename is a timer on a script. So the newest jenkins.io-YYYY.key
# is discovered from the repository's own index, and the hardcoded name is only
# the fallback for when that cannot be read.
#
# AND IT IS RE-FETCHED, NOT KEPT
#
# The old code skipped the download whenever the file existed, so a machine that
# had ever installed Jenkins kept its expired key for ever and could not be
# fixed by re-running the installer. Fetching every time is one small file and
# removes that whole class of failure.
# -----------------------------------------------------------------------------
discover_key_url() {
    local newest
    newest="$(curl -fsSL --max-time 20 "$REPO_BASE/" 2>/dev/null \
        | grep -oE 'jenkins\.io-[0-9]{4}\.key' \
        | sort -u | sort -t- -k2 -n | tail -1)"
    if [ -n "$newest" ]; then
        echo "$REPO_BASE/$newest"
    else
        # Known good at the time of writing, valid to 2028-12-21.
        echo "$REPO_BASE/jenkins.io-2026.key"
    fi
}

print_status "Fetching the Jenkins signing key..."
KEY_URL="$(discover_key_url)"
print_status "Key: $KEY_URL"

KEY_TMP="$(mktemp)"
KEY_LOG="$(mktemp)"
if ! curl -fsSL --max-time 30 "$KEY_URL" -o "$KEY_TMP" 2>"$KEY_LOG"; then
    print_error "Could not download the Jenkins signing key from $KEY_URL"
    cat "$KEY_LOG"
    rm -f "$KEY_TMP" "$KEY_LOG"
    if [ -f "$KEYRING" ]; then
        print_info "Continuing with the key already on disk, which may be expired."
    else
        exit 1
    fi
else
    # Written only after it looks like a key. A proxy or a captive portal can
    # answer 200 with an HTML page, and installing that as a keyring turns a
    # clear network error into an unsigned-repository error somewhere else.
    if head -1 "$KEY_TMP" | grep -q 'BEGIN PGP PUBLIC KEY BLOCK'; then
        mv "$KEY_TMP" "$KEYRING"
        chmod 644 "$KEYRING"
        print_success "Signing key installed."
        if command -v gpg >/dev/null 2>&1; then
            gpg --show-keys "$KEYRING" 2>/dev/null | grep -E '^pub' | head -1 \
                | sed 's/^/   /' || true
        fi
    else
        print_error "What came back from $KEY_URL is not a PGP key."
        print_info "First line: $(head -1 "$KEY_TMP")"
        rm -f "$KEY_TMP"
        [ -f "$KEYRING" ] || exit 1
    fi
    rm -f "$KEY_LOG"
fi

REPO_LINE="deb [signed-by=${KEYRING}] https://pkg.jenkins.io/debian-stable binary/"

if [ ! -f "$SOURCES" ] || ! grep -qF "$REPO_LINE" "$SOURCES"; then
    print_status "Adding the Jenkins apt repository..."
    echo "$REPO_LINE" > "$SOURCES"
    print_success "Repository added."
else
    print_success "Jenkins repository already configured."
fi

# -----------------------------------------------------------------------------
# Jenkins itself
# -----------------------------------------------------------------------------
if dpkg -s jenkins >/dev/null 2>&1; then
    print_success "Jenkins is already installed."
else
    # Logged, never discarded. apt-get update fails for a dozen different
    # reasons and they are not guessable from the exit code: an expired key, a
    # repository with no package for this architecture, a proxy, or simply DNS.
    # Throwing the output away turned every one of those into the same
    # unanswerable question.
    JENKINS_APT_LOG="$(mktemp)"
    if ! show_progress "📦 Updating package lists" "apt-get update -o Acquire::Retries=2 >$JENKINS_APT_LOG 2>&1"; then
        print_error "Package list update failed. apt said:"
        echo ""
        # Only the lines that name a failure. A full apt update is 30 lines of
        # "Hit:" that bury the one line that matters.
        grep -iE '^(err|e:|w:|warning)|jenkins' "$JENKINS_APT_LOG" | tail -20 || tail -20 "$JENKINS_APT_LOG"
        echo ""
        print_error "Full log: $JENKINS_APT_LOG"
        print_action "Check it by hand with: sudo apt-get update"
        exit 1
    fi
    rm -f "$JENKINS_APT_LOG"

    # -------------------------------------------------------------------------
    # Java, asked of the package rather than written down here.
    #
    # The jenkins deb declares its runtime as an alternation of virtual
    # packages, currently:
    #
    #   Depends: java17-runtime-headless | java21-runtime-headless
    #
    # That declaration is correct for the exact version about to be installed,
    # which no comment in this file can claim. It used to say "17 or 21, pick
    # 17", and a number in a comment is right until the next release.
    #
    # The NEWEST accepted major is chosen: it is supported for longest, so a
    # Jenkins upgrade is least likely to strand the machine.
    #
    # Java is not backwards compatible in the way people expect. Bytecode is,
    # applications are not: 24 removed the Security Manager, and JPMS closed
    # internals that plugins reach for. Jenkins checks the version at startup
    # and refuses one it does not support, so "the newest JDK" is a way to end
    # up with a Jenkins that will not start.
    # -------------------------------------------------------------------------
    # The jenkins deb declares NO java dependency, so there is nothing to read.
    # Jenkins states its supported versions only when it refuses to start, which
    # is what the check after the start uses. Here: take the newest the distro
    # packages.
    AVAILABLE_JAVA="$(apt-cache pkgnames openjdk- 2>/dev/null \
        | grep -oE '^openjdk-[0-9]+-jre-headless$' \
        | grep -oE '[0-9]+' | sort -rnu)"

    JAVA_MAJOR="$(echo "$AVAILABLE_JAVA" | head -1)"

    if [ -z "$JAVA_MAJOR" ]; then
        print_error "No openjdk-*-jre-headless package is available."
        print_action "Check that the universe repository is enabled, then re-run."
        exit 1
    fi

    print_status "Installing the newest Java this distro has: $JAVA_MAJOR"
    JAVA_PKG="openjdk-${JAVA_MAJOR}-jre-headless"
    if dpkg -s "$JAVA_PKG" >/dev/null 2>&1; then
        print_success "$JAVA_PKG already installed."
    else
        print_status "Installing $JAVA_PKG..."
        # Not wrapped in show_progress: this is a dpkg transaction and must
        # never be killed by a timeout.
        #
        # fontconfig alongside it because Jenkins renders text for some plugins
        # and a headless JRE does not pull it in.
        if ! apt-get install -y -qq fontconfig "$JAVA_PKG"; then
            print_error "Could not install $JAVA_PKG"
            exit 1
        fi
        print_success "$JAVA_PKG installed."
    fi

    print_status "Installing Jenkins. This is slow on a Pi, do not interrupt it."
    # Deliberately not wrapped: a killed dpkg leaves package state broken
    if ! apt-get install -y jenkins; then
        print_error "Jenkins installation failed."
        print_action "Check: apt-get install -f, then re-run this script."
        exit 1
    fi
    print_success "Jenkins installed."

    # -------------------------------------------------------------------------
    # Plugins, from jenkins/plugins.txt, before the wizard is ever opened.
    #
    # The wizard's "install suggested plugins" takes about five minutes on a Pi
    # and installs four things this machine has no use for. On a machine that
    # gets reflashed repeatedly, that is the same five minutes and the same four
    # mistakes every time.
    #
    # The setup wizard is deliberately left ON. This only pre-fills the plugin
    # step; it does not skip the part that forces an admin password to exist.
    #
    # jenkins-plugin-cli ships with the container images, not with the deb, so
    # the tool is fetched when it is not already present. Dependencies are
    # resolved against the installed war, which is why the war path is passed:
    # a plugin list without dependency resolution installs plugins that then
    # refuse to load.
    # -------------------------------------------------------------------------
    PLUGIN_FILE="$REPO_ROOT/hostings/jenkins/plugins.txt"
    PLUGIN_DIR="/var/lib/jenkins/plugins"
    JENKINS_WAR="/usr/share/java/jenkins.war"

    if [ ! -f "$PLUGIN_FILE" ]; then
        print_info "No $PLUGIN_FILE, so no plugins were pre-installed."
        print_info "The setup wizard will ask instead."
    elif [ ! -f "$JENKINS_WAR" ]; then
        print_info "No $JENKINS_WAR, so plugin dependencies cannot be resolved. Skipping."
    else
        PLUGIN_CLI=""
        if command -v jenkins-plugin-cli >/dev/null 2>&1; then
            PLUGIN_CLI="jenkins-plugin-cli"
        else
            PLUGIN_JAR="/opt/jenkins-plugin-manager.jar"
            if [ ! -f "$PLUGIN_JAR" ]; then
                print_status "Fetching the plugin manager..."
                # GitHub pretty-prints its JSON, so the colon is followed by a
                # space. Requiring none matched nothing and the plugin step was
                # silently skipped on every install.
                #
                # The .sha256 asset sits next to the jar and also ends in a
                # quote, so anchor on the .jar closing quote.
                PM_URL="$(curl -fsSL --max-time 20 \
                    https://api.github.com/repos/jenkinsci/plugin-installation-manager-tool/releases/latest 2>/dev/null \
                    | grep -oE '"browser_download_url": *"[^"]*jenkins-plugin-manager-[^"]*\.jar"' \
                    | grep -oE 'https://[^"]*\.jar' | head -1)"
                if [ -n "$PM_URL" ]; then
                    curl -fsSL --max-time 120 "$PM_URL" -o "$PLUGIN_JAR" 2>/dev/null || rm -f "$PLUGIN_JAR"
                fi
            fi
            [ -f "$PLUGIN_JAR" ] && PLUGIN_CLI="java -jar $PLUGIN_JAR"
        fi

        if [ -z "$PLUGIN_CLI" ]; then
            print_info "Could not obtain the plugin manager, so plugins were not pre-installed."
            print_info "Not fatal: pick them in the setup wizard instead."
        else
            mkdir -p "$PLUGIN_DIR"
            print_status "Installing plugins from jenkins/plugins.txt..."
            PLUGIN_LOG="$(mktemp)"
            if $PLUGIN_CLI --war "$JENKINS_WAR" \
                           --plugin-file "$PLUGIN_FILE" \
                           --plugin-download-directory "$PLUGIN_DIR" \
                           >"$PLUGIN_LOG" 2>&1; then
                chown -R jenkins:jenkins "$PLUGIN_DIR"
                print_success "Plugins installed: $(ls "$PLUGIN_DIR" | grep -c '\.jpi$' || echo 0) files."
            else
                print_info "Plugin pre-install failed. The wizard will ask instead."
                tail -10 "$PLUGIN_LOG" 2>/dev/null || true
                print_action "Full log: $PLUGIN_LOG"
            fi
            rm -f "$PLUGIN_LOG"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Bind to localhost. A systemd drop-in, not an edit to the packaged unit file:
# the packaged unit is replaced on every Jenkins upgrade and any edit to it is
# silently lost, which would quietly re-expose port 8080.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# The admin account, asked for here instead of in the setup wizard.
#
# Asking during the install is the normal thing to do and it removes the one
# genuinely dangerous window in a Jenkins install: between the service starting
# and somebody finishing the wizard, the instance is open to whoever reaches it.
# On a LAN binding that window is real.
#
# THE ORDER IS LOAD BEARING. The account is created and the security realm set
# in the same init script, and the wizard is only marked complete at the end of
# it. A failure anywhere leaves the wizard in place rather than an open Jenkins.
# That is the whole reason this was not done sooner.
#
# The password reaches Jenkins through a file in init.groovy.d, which the jenkins
# user must be able to read, so it is on disk in plaintext for as long as it
# takes Jenkins to start. Mode 600, owned by jenkins, and deleted as soon as the
# port answers. Jenkins stores only a hash afterwards.
#
# Skipped entirely without a terminal, or when Jenkins already has a realm
# configured: this never touches an instance somebody has already set up.
# -----------------------------------------------------------------------------
INIT_DIR="/var/lib/jenkins/init.groovy.d"
INIT_FILE="$INIT_DIR/00-create-admin.groovy"
JENKINS_CONFIG="/var/lib/jenkins/config.xml"

if [ -f "$JENKINS_CONFIG" ] && grep -q "HudsonPrivateSecurityRealm" "$JENKINS_CONFIG" 2>/dev/null; then
    print_success "Jenkins already has an admin account, leaving it alone."
elif [ ! -r /dev/tty ]; then
    print_info "No terminal, so the admin account cannot be asked for."
    print_info "The setup wizard will ask instead, on first visit."
else
    # Defaults to the same name as the Apache admin, from hostings.conf, so one
    # person is one name everywhere rather than two accounts to keep straight.
    #
    # Reusing the PASSWORD too is a fair choice for a machine with one operator,
    # and this cannot check that you did: the Apache file holds a hash, so there
    # is nothing to compare against. It can only suggest it and say why.
    #
    # Reaching Jenkins through the vhost asks twice regardless: Apache first,
    # then Jenkins. Two locks on the same door, deliberately, because the Apache
    # one also guards everything else on the machine.
    DEFAULT_ADMIN="$(conf_get AUTH_ADMIN_USER admin)"

    echo ""
    print_status "Jenkins needs an administrator. This replaces the setup wizard."
    print_status "The same password as the Apache '$DEFAULT_ADMIN' login is fine,"
    print_status "and means one password instead of two."
    printf "   Username [%s]: " "$DEFAULT_ADMIN" > /dev/tty
    read -r JENKINS_ADMIN < /dev/tty || JENKINS_ADMIN=""
    JENKINS_ADMIN="$(echo "$JENKINS_ADMIN" | xargs)"
    [ -z "$JENKINS_ADMIN" ] && JENKINS_ADMIN="$DEFAULT_ADMIN"

    PASSWORD=""
    if read_password_twice "$JENKINS_ADMIN"; then
        mkdir -p "$INIT_DIR"

        # Written with a quoted heredoc so nothing here is expanded by the
        # shell, then the two values are substituted deliberately. The password
        # goes in single quotes with any quote escaped, so a password containing
        # a quote cannot break out into Groovy.
        ESCAPED_PASS="${PASSWORD//\\/\\\\}"
        ESCAPED_PASS="${ESCAPED_PASS//\'/\\\'}"

        cat > "$INIT_FILE" <<GROOVY
// Generated by add_jenkins.sh. Deleted as soon as Jenkins answers.
//
// Order matters: the account exists and the realm is set BEFORE the wizard is
// marked complete. If anything here throws, the wizard is still in place and
// the instance is not open.
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy
import jenkins.install.InstallState

def instance = Jenkins.get()

def realm = new HudsonPrivateSecurityRealm(false)
realm.createAccount('${JENKINS_ADMIN}', '${ESCAPED_PASS}')
instance.setSecurityRealm(realm)

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

instance.save()
instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
GROOVY

        unset PASSWORD ESCAPED_PASS
        chown -R jenkins:jenkins "$INIT_DIR"
        chmod 700 "$INIT_DIR"
        chmod 600 "$INIT_FILE"
        print_success "Administrator '$JENKINS_ADMIN' will be created on start."
    else
        print_info "No password given, so the setup wizard stays in place."
    fi
fi

# =============================================================================
# THE HOSTING MANAGER'S API TOKEN
#
# Apply and Update are POSTs to Jenkins, and Jenkins wants a credential. Left to
# a human that is five clicks in a UI, on a machine that may not be touched for
# a year, and the buttons are dead until somebody remembers them.
#
# So Jenkins mints it for itself at startup. The token never appears on a
# terminal, in scrollback or in a screenshot, which is more than can be said for
# one that was copied out of a browser by hand.
#
# The handoff goes through a file the jenkins user can write and root can read,
# because init.groovy.d runs as jenkins and /var/lib/hosting-manager is root's.
# It is collected and shredded further down, once Jenkins is answering.
#
# Only when there is no token already. A re-run must not pile up a second one.
# =============================================================================
TOKEN_FILE="/var/lib/hosting-manager/jenkins-token"
TOKEN_HANDOFF="/var/lib/jenkins/secrets/hosting-manager-token"
TOKEN_INIT="$INIT_DIR/10-hosting-manager-token.groovy"
TOKEN_ADMIN="$(conf_get AUTH_ADMIN_USER admin)"

if [ -s "$TOKEN_FILE" ]; then
    print_success "The hosting manager already has a Jenkins token, leaving it alone."
else
    mkdir -p "$INIT_DIR"

    # Which account to mint for, in order: the one named in hostings.conf, then
    # the only account there is. A machine with several accounts and none of
    # them named AUTH_ADMIN_USER is not guessable, so it says so rather than
    # picking one at random and handing it the machine.
    #
    # The candidates come from the SECURITY REALM, not from User.getAll(). The
    # latter also holds a record per git commit author seen in a build, so on a
    # machine that has ever run a job it is several people who cannot log in.
    cat > "$TOKEN_INIT" <<GROOVY
// Generated by add_jenkins.sh. Deleted as soon as the token has been collected.
import jenkins.model.Jenkins
import hudson.model.User
import hudson.security.HudsonPrivateSecurityRealm
import jenkins.security.ApiTokenProperty

def out = new File(Jenkins.get().getRootDir(), 'secrets/hosting-manager-token')

if (!out.exists()) {
    def realm = Jenkins.get().getSecurityRealm()
    def users = (realm instanceof HudsonPrivateSecurityRealm)
        ? realm.getAllUsers()
        : User.getAll().findAll { it.id != 'SYSTEM' && it.id != 'unknown' }

    def user = users.find { it.id == '${TOKEN_ADMIN}' } ?: (users.size() == 1 ? users[0] : null)

    if (user == null) {
        // The ids are printed because the previous version said only that it
        // could not decide, which took a journal dig to get past.
        println 'hosting-manager: cannot tell which account to mint a token for.'
        println 'hosting-manager: accounts that can log in: ' + users.collect { it.id }.join(', ')
        println 'hosting-manager: set AUTH_ADMIN_USER in hostings.conf to one of those.'
    } else {
        def store = user.getProperty(ApiTokenProperty.class).tokenStore

        // Any token this script minted before and failed to hand over. Without
        // this a failure between minting and writing leaves one behind that
        // nothing holds and nobody knows to revoke, once per attempt.
        store.getTokenListSortedByName()
             .findAll { it.getName() == 'hosting-manager' }
             .each { store.revokeToken(it.getUuid()) }

        // TokenUuidAndPlainValue holds two public final FIELDS and no getters,
        // so it is .tokenUuid and .plainValue. Both other spellings were tried
        // on the machine: .uuid is the wrong name, getPlainValue() the wrong
        // shape.
        def made = store.generateNewToken('hosting-manager')
        user.save()
        out.text = user.id + ':' + made.plainValue + '\n' + made.tokenUuid + '\n'
        out.setReadable(false, false)
        out.setWritable(false, false)
        out.setReadable(true, true)
        println 'hosting-manager: minted an API token for ' + user.id
    }
}
GROOVY

    chown -R jenkins:jenkins "$INIT_DIR"
    chmod 700 "$INIT_DIR"
    chmod 600 "$TOKEN_INIT"
    TOKEN_WANTED=1
    print_success "Jenkins will mint the hosting manager's token when it starts."
fi

# =============================================================================
# SSH ACCESS TO GIT, AND THE JOBS THEMSELVES
#
# Everything below replaces about twenty clicks in the Jenkins UI. Clicks are
# not reviewable, not versioned and not rememberable: setting this up by hand
# took four wrong turns on 2026-08-04, and none of them would have been
# reconstructable a year later.
#
#   - a redirect that ran as root instead of jenkins, so known_hosts was empty
#   - a host key that was therefore never trusted
#   - a pasted private key that failed with "error in libcrypto"
#   - a credential that stayed attached after being set to "- none -"
#
# The last one is the reason no credential is configured here at all. Jenkins
# runs git AS THE JENKINS USER, so a key in that user's ~/.ssh is used without
# Jenkins having to store, encrypt, unpack and re-write it. Every failure above
# lived in that copying.
# =============================================================================
JENKINS_HOME="/var/lib/jenkins"
JENKINS_SSH="$JENKINS_HOME/.ssh"

# NO KEY IS GENERATED ANY MORE. The checkout uses the App over HTTPS, and a key
# here is worse than the token in both directions that matter: an SSH key put on
# a GitHub ACCOUNT reaches every repository that account can reach and never
# expires, while an installation token is scoped to the installation and lives
# an hour. Anything that can run a Jenkins job can read this file.
#
# An existing key is LEFT ALONE rather than deleted. Deleting a credential on
# somebody's behalf is not this script's call, and a machine may still be using
# it for something nobody has looked at yet.
if [ -f "$JENKINS_SSH/id_ed25519" ]; then
    print_info "jenkins has an SSH key at $JENKINS_SSH/id_ed25519."
    print_info "  Nothing here needs it: the checkout uses the App over HTTPS."
    print_action "  Delete it, and remove its public half from GitHub, once you are sure."
fi

# THE insteadOf REWRITE, REMOVED. Found 2026-09-04, and it cost most of an hour.
#
# `git config --global url."git@github.com:".insteadOf https://github.com/` was
# set by hand on 2026-08-07 and never scripted, so nothing recorded it and
# nothing would have recreated it. It silently rewrote EVERY https remote back
# to SSH, one layer below anywhere you would look: the job config said https,
# the workspace config said https, the cache said https, and git still dialled
# git@ and failed with "Permission denied (publickey)".
#
# Removed here rather than only on the machine, so a box that has it is repaired
# by a run rather than by somebody remembering.
if [ -f "$JENKINS_HOME/.gitconfig" ] \
   && sudo -u jenkins git -C / config --global --get-regexp insteadOf >/dev/null 2>&1; then
    cp -a "$JENKINS_HOME/.gitconfig" "$JENKINS_HOME/.gitconfig.bak-$(date +%F)"
    sudo -u jenkins git -C / config --global --remove-section url."git@github.com:" 2>/dev/null || true
    print_success "Removed the git insteadOf rewrite that forced HTTPS back onto SSH."
fi

# JENKINS MUST NOT RECURSE INTO SUBMODULES ON FETCH, and this is not a way of
# hiding a problem. Measured 2026-09-12.
#
# git's default is fetch.recurseSubmodules=on-demand, so the moment a fetch
# brings a superproject commit whose gitlink MOVED, git fetches that submodule
# too. a private submodule is owned by the personal account and Jenkins' credential is
# the organisation's, so the fetch answered "remote: Repository not found."
# and the git plugin turned that into
#
#     ERROR: Error fetching remote repo 'origin'
#     ERROR: Maximum checkout retry attempts reached, aborting
#
# Builds 264 and 265 both died there, before a single pipeline step ran. Every
# job on the machine, not just the apply.
#
# JENKINS CANNOT MINT A TOKEN AT ALL: the App key is 0600 root, checked here,
# so an owner-aware credential helper is not available to it the way it is to
# root. And the workspace does not NEED the submodule: every step runs scripts
# from the root-owned tree, which gets its submodules properly through
# git_credential_github_app.sh, and the job's own submodule update is written
# to tolerate a skip.
#
# So the fetch that cannot succeed is the one being switched off, and the fetch
# that matters is unaffected.
if [ "$(sudo -u jenkins git -C / config --global --get fetch.recurseSubmodules 2>/dev/null)" != "no" ]; then
    sudo -u jenkins git -C / config --global fetch.recurseSubmodules no
    print_success "Jenkins' git no longer recurses into submodules on fetch."
    print_info "  A moved submodule pin used to abort every checkout: it cannot mint a token for another owner."
fi

# Host keys, written as root and then handed over. Doing the redirect under
# `sudo -u jenkins` writes as the CALLING user, which is how this ended up empty
# the first time and produced "No ED25519 host key is known for github.com".
GIT_HOST="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#^git@([^:]+):.*#\1#; s#^https://([^/]+)/.*#\1#')"
GIT_HOST="${GIT_HOST:-github.com}"

# Made here: the key generation that used to create it is gone.
install -d -m 700 -o jenkins -g jenkins "$JENKINS_SSH"
if ! grep -q "^$GIT_HOST " "$JENKINS_SSH/known_hosts" 2>/dev/null; then
    print_status "Trusting the host key for $GIT_HOST..."
    ssh-keyscan -t rsa,ecdsa,ed25519 "$GIT_HOST" 2>/dev/null >> "$JENKINS_SSH/known_hosts"
fi
chown -R jenkins:jenkins "$JENKINS_SSH"
chmod 700 "$JENKINS_SSH"
chmod 600 "$JENKINS_SSH/known_hosts" 2>/dev/null || true

# -----------------------------------------------------------------------------
# The jobs, written as config.xml rather than clicked.
#
# One job per hostings/jenkins/Jenkinsfile.<name>, so adding a pipeline to the repo adds
# a job to the machine. The SCM carries the App credential: see GIT_URL above.
JENKINS_GH_CRED="github-token"
#
# The remote and branch come from this checkout, so a machine built from a
# different fork or branch gets jobs pointing at its own, not at whatever was
# true when this was written.
# -----------------------------------------------------------------------------
GIT_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"

# HTTPS WITH THE APP CREDENTIAL, NOT SSH WITH A KEY. Reversed 2026-09-04.
#
# This used to rewrite an https remote INTO git@, so the checkout leant on
# /var/lib/jenkins/.ssh/id_ed25519. That key answers "Hi <owner>": it is an
# ACCOUNT key, so it carries write access to every repository the account can
# reach, it never expires, and anything that can run a Jenkins job can read it.
# An installation token is scoped to what the App was installed on and lives an
# hour.
#
# It was not spare, whatever it looked like. Every job reads its Jenkinsfile
# from this URL, so the key was load bearing for all of them.
case "$GIT_URL" in
    git@*) GIT_URL="https://${GIT_HOST}/$(echo "$GIT_URL" | sed -E 's#^git@[^:]+:##')" ;;
esac
GIT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
# Detached at a pinned commit (a submodule): the jobs follow the branch that
# holds it. Only the Jenkinsfiles come from there; the scripts they run are the
# pinned runtime tree.
if [ "$GIT_BRANCH" = "HEAD" ]; then
    GIT_BRANCH="$(git -C "$REPO_ROOT" for-each-ref --contains HEAD --format='%(refname:lstrip=3)' refs/remotes/origin 2>/dev/null \
                  | grep -vx HEAD | head -1)"
fi

if [ -z "$GIT_URL" ] || [ -z "$GIT_BRANCH" ]; then
    print_action "Could not read the git remote or branch, so no jobs were created."
elif [ ! -d "$REPO_ROOT/hostings/jenkins" ]; then
    print_info "No hostings/jenkins/ folder in the repo, so there are no pipelines to install."
else
    # A folder holding grouped jobs. Written only when missing, so a folder
    # somebody has given a description or a view is left as they made it.
    write_folder_config() {
        local dir="$1" name="$2"

        # REPAIRED, not just created. A folder written before 2026-08-15 carries
        # a hand-written <folderViews> block, and a wrong back-reference in it
        # gives "An error occurred when retrieving jobs for this view" with an
        # empty page. Rewriting drops the block so Jenkins builds its own.
        if [ -f "$dir/config.xml" ]; then
            grep -q "<folderViews" "$dir/config.xml" || return 0
            print_info "Folder '$name' had a hand-written view, rewriting it."
        fi

        mkdir -p "$dir/jobs"
        cat > "$dir/config.xml" <<XML
<?xml version='1.1' encoding='UTF-8'?>
<com.cloudbees.hudson.plugins.folder.Folder plugin="cloudbees-folder">
  <actions/>
  <description>${name}</description>
  <properties/>
  <healthMetrics/>
  <icon class="com.cloudbees.hudson.plugins.folder.icons.StockFolderIcon"/>
</com.cloudbees.hudson.plugins.folder.Folder>
XML
        print_success "Folder '$name' written."
    }

    JOBS_MADE=0
    for jf in "$REPO_ROOT"/hostings/jenkins/Jenkinsfile.*; do
        [ -f "$jf" ] || continue
        job_name="$(basename "$jf" | sed 's/^Jenkinsfile\.//')"

        # A double dash in the filename puts the job in a folder:
        # Jenkinsfile.machine--apply-config becomes machine/apply-config. The
        # top level is then only folders, and every job sits under a name that
        # says what it is for.
        # NO DOUBLE DASH MEANS IT IS NOT A JOB OF ITS OWN. Those files are the
        # per-site templates: add_jenkins_site_jobs.sh instantiates them inside
        # each site's folder, where the pipeline reads its row from the folder
        # name. Creating them here as well would put a copy at the top level
        # that has no site and asks for one.
        case "$job_name" in
            *--*) : ;;
            *)
                print_status "$(basename "$jf") is a per-site template, so add_jenkins_site_jobs.sh owns it."
                continue
                ;;
        esac
        job_folder="${job_name%%--*}"
        job_name="${job_name#*--}"

        if [ -n "$job_folder" ]; then
            folder_dir="$JENKINS_HOME/jobs/$job_folder"
            job_dir="$folder_dir/jobs/$job_name"

            # MOVED, NOT RECREATED. These jobs existed at the top level before
            # they were grouped, and their builds live inside their directory:
            # recreating would leave the history behind under a name nothing
            # points at, and give a job that has never run. Same reasoning as the
            # 2026-08-11 rename, which moved directories for exactly this reason.
            #
            # The old name cannot be derived from the new one, so it is written
            # down. This is a one-time migration and the list only ever shrinks.
            former=""
            case "${job_folder}--${job_name}" in
                machine--check-config)              former="hosting-check" ;;
                machine--apply-config)              former="hosting-apply" ;;
                machine--request-all-certificates)  former="hosting-certificates" ;;
                machine--update-packages)           former="machine-update" ;;
                machine--update-dns)                former="dns-apex" ;;
            esac

            if [ -n "$former" ] && [ -f "$JENKINS_HOME/jobs/$former/config.xml" ] \
               && [ ! -d "$job_dir" ]; then
                mkdir -p "$folder_dir/jobs"
                write_folder_config "$folder_dir" "$job_folder"
                mv "$JENKINS_HOME/jobs/$former" "$job_dir"
                print_success "Job '$former' moved to $job_folder/$job_name, history kept."
                JOBS_MADE=$(( JOBS_MADE + 1 ))
            fi

            mkdir -p "$folder_dir/jobs"
            write_folder_config "$folder_dir" "$job_folder"
        else
            job_dir="$JENKINS_HOME/jobs/$job_name"
        fi

        # Never overwritten. A job somebody has since configured by hand is
        # theirs, and silently reverting it would be worse than not helping.
        #
        # One exception, and it is a repair rather than a change: a scriptPath
        # naming a Jenkinsfile that no longer exists. Renaming the jobs on
        # 2026-08-11 moved the directories, to keep the build history, and left
        # every config.xml pointing at the old filename. The job then starts and
        # fails with "Unable to find hostings/jenkins/Jenkinsfile.apply", which says
        # nothing about where the setting lives.
        if [ -f "$job_dir/config.xml" ]; then
            # SECOND REPAIR, same reasoning as the scriptPath one below: a job
            # written before 2026-09-04 clones its Jenkinsfile over SSH with
            # jenkins's ACCOUNT key, and a job is never rewritten, so changing
            # the template alone would leave all thirteen on the key forever.
            #
            # Both halves are needed and neither alone works: the url decides
            # the transport, the credentialsId decides who the token belongs
            # to. A job is only touched when it still names git@.
            #
            # WIDENED 2026-09-05 from "still names git@" to "does not match the
            # remote". Transferring this repository into the organisation left
            # nine jobs pointing at the old OWNER over HTTPS, which the narrower
            # test could not see: they were already https, just at a path the
            # App token no longer covers.
            #
            # Comparing against the remote catches a rename, a transfer and a
            # fork, where each of those would otherwise need its own special
            # case bolted on after it had already broken something.
            cur_url="$(sed -n 's|.*<url>\(.*\)</url>.*|\1|p' "$job_dir/config.xml" | head -n1)"
            if [ -n "$cur_url" ] && [ "$cur_url" != "$GIT_URL" ]; then
                sed -i "s|<url>${cur_url//|/\\|}</url>|<url>${GIT_URL//|/\\|}</url>|" "$job_dir/config.xml"
                grep -q "<credentialsId>" "$job_dir/config.xml" \
                    || sed -i "s|<url>${GIT_URL//|/\\|}</url>|<url>${GIT_URL//|/\\|}</url>\n          <credentialsId>${JENKINS_GH_CRED}</credentialsId>|" \
                        "$job_dir/config.xml"
                # JOBS_MADE drives the restart below, and a config.xml edited
                # under a running Jenkins is not read until then. Measured
                # 2026-09-05: POST /reload answered 302 and Jenkins kept the old
                # URL in memory; only a restart picked it up.
                JOBS_MADE=$(( JOBS_MADE + 1 ))
                print_success "Job '$job_name' repointed: ${cur_url} -> ${GIT_URL}"
            fi

            want="hostings/jenkins/$(basename "$jf")"
            have="$(sed -n 's|.*<scriptPath>\(.*\)</scriptPath>.*|\1|p' "$job_dir/config.xml" | head -n1)"

            if [ -n "$have" ] && [ "$have" != "$want" ] && [ ! -f "$REPO_ROOT/$have" ]; then
                sed -i "s|<scriptPath>${have}</scriptPath>|<scriptPath>${want}</scriptPath>|" \
                    "$job_dir/config.xml"
                JOBS_MADE=$(( JOBS_MADE + 1 ))
                print_success "Job '$job_name' pointed at a file that is gone, now $want."
            else
                print_success "Job '$job_name' already exists, left alone."
            fi
            continue
        fi

        # The job list shows the description, so it carries the pipeline's own
        # first line rather than the name of the script that generated it.
        job_desc="$(sed -n '2s#^//[ ]*##p' "$jf" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        [ -z "$job_desc" ] && job_desc="From hostings/jenkins/$(basename "$jf")"

        mkdir -p "$job_dir"
        cat > "$job_dir/config.xml" <<XML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>${job_desc}</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>${GIT_URL}</url>
          <credentialsId>${JENKINS_GH_CRED}</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/${GIT_BRANCH}</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>hostings/jenkins/$(basename "$jf")</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
XML
        JOBS_MADE=$(( JOBS_MADE + 1 ))
        print_success "Job '$job_name' created."
    done

    chown -R jenkins:jenkins "$JENKINS_HOME/jobs" 2>/dev/null || true

    # Jenkins reads jobs at startup, so newly written ones need a reload.
    if [ "$JOBS_MADE" -gt 0 ] && systemctl is-active --quiet jenkins; then
        show_spinner_watch_only "Restarting Jenkins so it picks up the new jobs" \
            systemctl restart jenkins
        print_success "Jenkins restarted."
    fi
fi

OVERRIDE_DIR="/etc/systemd/system/jenkins.service.d"
OVERRIDE_FILE="$OVERRIDE_DIR/override.conf"

# -----------------------------------------------------------------------------
# JENKINS_LISTEN in hostings.conf decides who can reach port 8080 directly.
#
#   loopback  (default)  127.0.0.1 only. Reached through the Apache vhost, which
#                        is where TLS and the login live.
#   lan                  every interface, and 8080 opened to the local subnet
#                        only. Convenient while setting a machine up, because
#                        http://<ip>:8080 works from any browser in the house.
#
# `lan` is a real loosening and it is worth being honest about what it gives up.
# Jenkins runs arbitrary shell by design, so it IS the machine. On loopback the
# Apache login stands in front of it; on the LAN, anything on your network
# reaches the Jenkins login directly, and during the first minutes of a fresh
# install that login is an unauthenticated setup wizard.
#
# The firewall rule is scoped to the local subnet rather than opened to the
# world, so a port forward on the router is still needed to expose it outside,
# and that is nobody's accident.
# -----------------------------------------------------------------------------
JENKINS_LISTEN="$(conf_get JENKINS_LISTEN loopback)"

# The port comes from the jenkins row, which already decides where the vhost
# proxies. One source, so changing it there moves both.
JENKINS_PORT="$(grep -v '^[[:space:]]*#' "$SITES_CONF" 2>/dev/null | grep '|' \
    | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$3); if ($2=="jenkins") print $3}' | head -1)"
JENKINS_PORT="${JENKINS_PORT:-8080}"

# Jenkins runs unprivileged and cannot bind below 1024.
if [ "$JENKINS_PORT" -lt 1024 ] 2>/dev/null; then
    print_error "Port $JENKINS_PORT is privileged, and Jenkins runs as the jenkins user."
    print_action "Use 1024 or above in the jenkins row of $SITES_CONF"
    exit 1
fi

case "$JENKINS_LISTEN" in
    lan|LAN|all)
        LISTEN_ADDRESS="0.0.0.0"
        JENKINS_LISTEN="lan"
        ;;
    *)
        LISTEN_ADDRESS="127.0.0.1"
        JENKINS_LISTEN="loopback"
        ;;
esac

NEW_OVERRIDE="$(cat <<EOF
# Generated by add_jenkins.sh
#
# Jenkins runs arbitrary shell by design, so where it listens is a security
# decision, not a convenience one. Set JENKINS_LISTEN in hostings.conf, never
# here: this file is rewritten on every run.
#
# A drop-in rather than an edit to the packaged unit, because the packaged unit
# is overwritten on every Jenkins upgrade and the edit would be silently lost.
[Service]
Environment="JENKINS_LISTEN_ADDRESS=${LISTEN_ADDRESS}"
Environment="JENKINS_PORT=${JENKINS_PORT}"

# The packaged 90s start timeout is shorter than a real startup here. Jenkins
# resumes in-flight pipeline builds before it reports ready, so after a reboot
# that interrupted a build it needs about 105s, systemd kills it at 90, and it
# restarts forever at 100% CPU with nothing able to run.
TimeoutStartSec=600

EOF
)"

mkdir -p "$OVERRIDE_DIR"

if [ -f "$OVERRIDE_FILE" ] && [ "$(cat "$OVERRIDE_FILE")" = "$NEW_OVERRIDE" ]; then
    print_success "Listen address override already in place."
else
    printf '%s\n' "$NEW_OVERRIDE" > "$OVERRIDE_FILE"
    chmod 644 "$OVERRIDE_FILE"
    print_success "Bound Jenkins to ${LISTEN_ADDRESS}:${JENKINS_PORT} (JENKINS_LISTEN = $JENKINS_LISTEN)."
    show_spinner_watch_only "Reloading systemd" systemctl daemon-reload
    if systemctl is-active --quiet jenkins; then
        show_spinner_watch_only "Restarting Jenkins on the new address" \
            systemctl restart jenkins
        print_success "Jenkins restarted on ${LISTEN_ADDRESS}:${JENKINS_PORT}."
    fi
fi

# -----------------------------------------------------------------------------
# The firewall follows the listen address, in both directions.
#
# Opening the port without changing the binding does nothing, and changing the
# binding without the port leaves a service that answers only itself: either
# half on its own is a confusing afternoon.
#
# Scoped to the local subnet rather than opened to the world. Reaching it from
# outside then still needs a port forward on the router, which nobody does by
# accident.
# -----------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [ "$JENKINS_LISTEN" = "lan" ]; then
        LAN_CIDR="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1 \
            | sed -E 's/\.[0-9]+$/.0\/24/')"
        if [ -n "$LAN_CIDR" ]; then
            if ufw status | grep -q "$JENKINS_PORT.*$LAN_CIDR"; then
                print_success "Port $JENKINS_PORT already open to $LAN_CIDR."
            else
                ufw allow from "$LAN_CIDR" to any port '"$JENKINS_PORT"' proto tcp >/dev/null 2>&1
                print_success "Opened $JENKINS_PORT to $LAN_CIDR only."
            fi
        else
            print_action "Could not work out the local subnet, so port $JENKINS_PORT was not opened."
            print_action "Open it by hand: sudo ufw allow from 192.168.0.0/16 to any port '"$JENKINS_PORT"' proto tcp"
        fi
    else
        # Closed again when switched back, so flipping the config in either
        # direction leaves the machine matching what it says.
        if ufw status | grep -q "^$JENKINS_PORT"; then
            ufw delete allow $JENKINS_PORT/tcp >/dev/null 2>&1 || true
            print_status "Closed port $JENKINS_PORT: Jenkins listens on loopback only."
        fi
    fi
fi

# -----------------------------------------------------------------------------
# The `jenkins` machine page: an Apache port on the local subnet that proxies to Jenkins,
# so http://<ip>:<port> works from a browser in the house with no DNS and no
# certificate. Jenkins itself stays on loopback, so the login is always in front
# of it, including during the setup wizard.
#
# Empty or `-` removes the vhost and closes the port, so the machine matches
# this file in both directions.
# -----------------------------------------------------------------------------
JENKINS_LAN_PORT="$(panel_port jenkins)"

LAN_VHOST_NAME="jenkins-lan"
LAN_VHOST="/etc/apache2/sites-available/${LAN_VHOST_NAME}.conf"

# A page with no PANEL line is not a page that is switched off. Emptying a port
# removes the vhost and closes it, so an absent or malformed line stops the run
# rather than being read as an instruction to do that.
if [ "$JENKINS_LAN_PORT" = "MISSING" ]; then
    print_error "No usable 'PANEL = jenkins | <port> | <name>' line in $SITES_CONF"
    print_action "Add one, or set its port to '-' if the LAN door really should be off."
    exit 1
fi

# PANELS_OFF closes this door as it does every other page's. The live config
# sets it at Go live, so Jenkins is then only its proxy row's name, behind 2FA.
case ",$(conf_get PANELS_OFF '' | tr -d ' ')," in
    *,jenkins,*) JENKINS_LAN_PORT="" ;;
esac

if [ -n "$JENKINS_LAN_PORT" ]; then
    if ! [ "$JENKINS_LAN_PORT" -ge 1024 ] 2>/dev/null; then
        print_error "The jenkins panel port must be a number of 1024 or above, not '$JENKINS_LAN_PORT'."
        print_action "Fix it in $SITES_CONF"
        exit 1
    fi
    if [ "$JENKINS_LAN_PORT" = "$JENKINS_PORT" ]; then
        print_error "The jenkins panel port is $JENKINS_LAN_PORT, which Jenkins already holds."
        print_action "Give Apache a different port in $SITES_CONF"
        exit 1
    fi
    # Against every other page, not just against Jenkins itself. Nothing checked
    # this against the console or webmin, and the console can now change them.
    while IFS='|' read -r other_id other_port; do
        [ "$other_id" = "jenkins" ] && continue
        if [ "$other_port" = "$JENKINS_LAN_PORT" ]; then
            print_error "The jenkins panel port is $JENKINS_LAN_PORT, which the '$other_id' page already holds."
            print_action "Give one of them a different port in $SITES_CONF"
            exit 1
        fi
    done < <(sed -n 's/^[[:space:]]*PANEL[[:space:]]*=//p' "$SITES_CONF" \
             | awk -F'|' 'NF >= 3 { gsub(/^[ \t]+|[ \t]+$/, "", $1)
                                    gsub(/^[ \t]+|[ \t]+$/, "", $2)
                                    print $1 "|" $2 }')
    if [ "$JENKINS_LISTEN" = "lan" ]; then
        print_info "JENKINS_LISTEN = lan already puts Jenkins on the LAN unauthenticated."
        print_action "Set it to loopback, or the proxy's login is not in front of anything."
    fi
fi

LAN_WEB_ROOT="$(conf_get AUTH_WEB_ROOT /var/www/auth)"
LAN_SESSION_KEY="$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)"
LAN_LOGIN_PAGE="login.html"

if [ -n "$JENKINS_LAN_PORT" ] && ! command -v a2ensite >/dev/null 2>&1; then
    print_info "Apache is not installed, so the jenkins panel port was not applied."
    print_action "Run add_apache_webserver.sh, then this script again."
elif [ -n "$JENKINS_LAN_PORT" ] && { [ ! -f "$LAN_WEB_ROOT/$LAN_LOGIN_PAGE" ] || [ ! -f "$LAN_SESSION_KEY" ]; }; then
    # On a fresh install add_app_vhosts.sh, which installs both, runs after this
    # script; install_hostings.sh runs this script again once it has.
    print_warning "No login page or session key yet, so the jenkins panel port was not applied."
    print_action "Run add_app_vhosts.sh, then this script again."
elif [ -n "$JENKINS_LAN_PORT" ]; then
    LAN_AUTH_FILE="$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)"
    LAN_ADMIN_USER="$(conf_get AUTH_ADMIN_USER admin)"

    # The jenkins row's AuthUsers, with the admin always appended: same rule the
    # vhost script follows, so both doors admit the same people.
    LAN_REQUIRE="Require user"
    for lan_user in $(grep -v '^[[:space:]]*#' "$SITES_CONF" 2>/dev/null | grep '|' \
        | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$12); if ($2=="jenkins") print $12}' \
        | head -1 | tr ',' ' '); do
        [ "$lan_user" = "-" ] && continue
        LAN_REQUIRE="$LAN_REQUIRE $lan_user"
    done
    LAN_REQUIRE="$LAN_REQUIRE $LAN_ADMIN_USER"

    if [ ! -f "$LAN_AUTH_FILE" ]; then
        print_error "No password file at $LAN_AUTH_FILE, so nobody could log in."
        print_action "Create it: sudo bash LinuxBasics/install_scripts/add_auth_users.sh --file $LAN_AUTH_FILE $LAN_ADMIN_USER"
        exit 1
    fi

    if ! grep -q "^${LAN_ADMIN_USER}:" "$LAN_AUTH_FILE" 2>/dev/null; then
        print_error "$LAN_AUTH_FILE has no '$LAN_ADMIN_USER' entry, so the login would reject everyone."
        print_action "Add it: sudo htpasswd $LAN_AUTH_FILE $LAN_ADMIN_USER"
        exit 1
    fi

    LAN_WEB_ROOT="$(conf_get AUTH_WEB_ROOT /var/www/auth)"
    LAN_SESSION_KEY="$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)"
    LAN_LOGIN_PAGE="login.html"

    if [ ! -f "$LAN_WEB_ROOT/$LAN_LOGIN_PAGE" ]; then
        print_error "No login page at $LAN_WEB_ROOT/$LAN_LOGIN_PAGE."
        print_action "Run add_app_vhosts.sh first: it installs the login page and the session key."
        exit 1
    fi

    if [ ! -f "$LAN_SESSION_KEY" ]; then
        print_error "No session key at $LAN_SESSION_KEY, so no session cookie can be encrypted."
        print_action "Create it: openssl rand -base64 32 | sudo tee $LAN_SESSION_KEY && sudo chmod 600 $LAN_SESSION_KEY"
        exit 1
    fi

    NEW_LAN_VHOST="$(cat <<EOF
# Generated by add_jenkins.sh, rewritten on every run.
# Set the jenkins PANEL line in hostings.conf, never here.
Listen ${JENKINS_LAN_PORT}

<VirtualHost *:${JENKINS_LAN_PORT}>
    ProxyPreserveHost On
    AllowEncodedSlashes NoDecode

    # These must appear before the ProxyPass below, or the login page is proxied
    # to Jenkins instead of being served from disk.
    ProxyPass /${LAN_LOGIN_PAGE} !
    ProxyPass /do-login     !
    ProxyPass /logout       !
    ProxyPass /auth-assets  !

    ProxyPass        / http://127.0.0.1:${JENKINS_PORT}/ nocanon
    ProxyPassReverse / http://127.0.0.1:${JENKINS_PORT}/

    Alias /${LAN_LOGIN_PAGE} ${LAN_WEB_ROOT}/${LAN_LOGIN_PAGE}
    Alias /auth-assets ${LAN_WEB_ROOT}
    <Directory ${LAN_WEB_ROOT}>
        Require all granted
    </Directory>

    # ORDER IS LOAD BEARING: <Location> blocks merge in file order and the LAST
    # match wins, so the general <Location /> must come FIRST and the exceptions
    # after it. Reversed, the login page itself requires a login and loops.
    #
    # Its own cookie name, and no \`secure\`: this port is plain HTTP, and a
    # secure cookie is never sent back over it. Reusing the name \`session\` would
    # collide with the one :443 sets, because cookies ignore the port.
    <Location />
        AuthType form
        AuthName "Sign in"
        AuthFormProvider file
        AuthUserFile ${LAN_AUTH_FILE}
        AuthFormLoginRequiredLocation /${LAN_LOGIN_PAGE}
        # No KeptBodySize: see add_hosting_manager.sh, it segfaults Apache on a slow POST.
        Session On
        SessionCookieName session_http path=/;httponly
        SessionCryptoPassphraseFile ${LAN_SESSION_KEY}
        ${LAN_REQUIRE}
    </Location>

    <Location /${LAN_LOGIN_PAGE}>
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
        AuthUserFile ${LAN_AUTH_FILE}
        AuthFormLoginRequiredLocation /${LAN_LOGIN_PAGE}
        AuthFormLoginSuccessLocation /
        Session On
        SessionCookieName session_http path=/;httponly
        SessionCryptoPassphraseFile ${LAN_SESSION_KEY}
        Require all granted
    </Location>

    <Location /logout>
        SetHandler form-logout-handler
        AuthType None
        AuthFormLogoutLocation /${LAN_LOGIN_PAGE}
        Session On
        SessionCookieName session_http path=/;httponly
        SessionCryptoPassphraseFile ${LAN_SESSION_KEY}
        Require all granted
    </Location>

    ErrorLog  \${APACHE_LOG_DIR}/${LAN_VHOST_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${LAN_VHOST_NAME}-access.log combined
</VirtualHost>
EOF
)"

    for lan_mod in proxy proxy_http auth_form authn_file authz_user \
                   session session_cookie session_crypto request; do
        a2enmod "$lan_mod" >/dev/null 2>&1 || true
    done

    # Read before overwriting: the vhost is the only record of which port was
    # open, and moving the door to a new one otherwise leaves the old firewall
    # rule behind with nothing answering on it.
    PREV_LAN_PORT="$([ -f "$LAN_VHOST" ] && awk '/^Listen /{print $2; exit}' "$LAN_VHOST" || true)"

    if [ -f "$LAN_VHOST" ] && [ "$(cat "$LAN_VHOST")" = "$NEW_LAN_VHOST" ]; then
        print_success "LAN proxy vhost already correct on port $JENKINS_LAN_PORT."
    else
        printf '%s\n' "$NEW_LAN_VHOST" > "$LAN_VHOST"
        chmod 644 "$LAN_VHOST"
        a2ensite "$LAN_VHOST_NAME" >/dev/null 2>&1
        if apache2ctl configtest >/dev/null 2>&1; then
            systemctl reload apache2
            print_success "Jenkins reachable at http://<this machine>:${JENKINS_LAN_PORT}, sign-in page in front."
        else
            print_error "Apache rejected the LAN proxy vhost, so it was not loaded:"
            apache2ctl configtest 2>&1 | tail -10
            a2dissite "$LAN_VHOST_NAME" >/dev/null 2>&1
            exit 1
        fi
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        LAN_CIDR="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1 \
            | sed -E 's/\.[0-9]+$/.0\/24/')"
        if [ -z "$LAN_CIDR" ]; then
            print_action "Could not work out the local subnet, so port $JENKINS_LAN_PORT was not opened."
            print_action "Open it by hand: sudo ufw allow from 192.168.0.0/16 to any port $JENKINS_LAN_PORT proto tcp"
        else
            # The door moved. Close the one it used to answer on, or it stays
            # open to the subnet with nothing behind it.
            if [ -n "$PREV_LAN_PORT" ] && [ "$PREV_LAN_PORT" != "$JENKINS_LAN_PORT" ]; then
                ufw delete allow from "$LAN_CIDR" to any port "$PREV_LAN_PORT" proto tcp >/dev/null 2>&1 || true
                print_success "Closed $PREV_LAN_PORT, which this door no longer uses."
            fi
            if ufw_allows "$JENKINS_LAN_PORT" "$LAN_CIDR"; then
                print_success "Port $JENKINS_LAN_PORT already open to $LAN_CIDR."
            else
                ufw allow from "$LAN_CIDR" to any port "$JENKINS_LAN_PORT" proto tcp >/dev/null 2>&1
                print_success "Opened $JENKINS_LAN_PORT to $LAN_CIDR only."
            fi
        fi
    fi
elif [ -f "$LAN_VHOST" ]; then
    LAN_OLD_PORT="$(awk '/^Listen /{print $2; exit}' "$LAN_VHOST")"
    a2dissite "$LAN_VHOST_NAME" >/dev/null 2>&1 || true
    rm -f "$LAN_VHOST"
    systemctl reload apache2 2>/dev/null || true
    # Deleted the way it was added: a rule scoped to a subnet does not match
    # `delete allow <port>/tcp`.
    if [ -n "$LAN_OLD_PORT" ] && command -v ufw >/dev/null 2>&1; then
        LAN_CIDR="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1 \
            | sed -E 's/\.[0-9]+$/.0\/24/')"
        [ -n "$LAN_CIDR" ] && ufw delete allow from "$LAN_CIDR" to any port "$LAN_OLD_PORT" proto tcp >/dev/null 2>&1 || true
    fi
    print_status "The jenkins panel port is empty: removed the LAN proxy and closed port ${LAN_OLD_PORT:-it}."
fi

if ! systemctl is-enabled --quiet jenkins; then
    systemctl enable jenkins >/dev/null 2>&1
    print_success "Jenkins enabled at boot."
fi

# init.groovy.d is read at startup and nowhere else. On a machine where Jenkins
# is already running and no new job was created, nothing restarts it, so a
# freshly written init script is shredded further down having never run once.
if [ "${TOKEN_WANTED:-0}" = "1" ] && systemctl is-active --quiet jenkins; then
    show_spinner_watch_only "Restarting Jenkins so it mints the token" \
        systemctl restart jenkins
    print_success "Jenkins restarted."
fi

if ! systemctl is-active --quiet jenkins; then
    # Clear the start-limit counter first.
    #
    # A unit that failed five times in ten seconds is refused by systemd until
    # the counter is reset, and it says "Start request repeated too quickly"
    # rather than anything about the original fault. So after fixing the actual
    # cause, the next start still fails, with a message pointing at the wrong
    # thing entirely.
    #
    # That is exactly what happened here: Jenkins crash-looped on Java 17, Java
    # 21 was installed to fix it, and the restart was refused with a message
    # about restart frequency.
    #
    # Safe when nothing is wrong: on a unit that is not failed it does nothing.
    systemctl reset-failed jenkins >/dev/null 2>&1 || true

    print_status "Starting Jenkins. First start takes a minute or two on a Pi."
    show_spinner_watch_only "Starting Jenkins" systemctl start jenkins || true
fi

# Jenkins names its supported Java versions only when it refuses to start. That
# message is the only authoritative source, so it is read rather than guessed.
if ! systemctl is-active --quiet jenkins; then
    WANTED="$(journalctl -u jenkins -n 40 --no-pager 2>/dev/null \
        | grep -oE 'Supported Java versions are: \[[0-9, ]+\]' \
        | grep -oE '[0-9]+' | sort -rnu)"

    if [ -n "$WANTED" ]; then
        print_action "Jenkins refused the installed Java. It accepts: $(echo "$WANTED" | tr '\n' ' ')"
        for v in $WANTED; do
            if apt-cache pkgnames "openjdk-${v}-jre-headless" 2>/dev/null \
                | grep -qx "openjdk-${v}-jre-headless"; then
                print_status "Installing openjdk-${v}-jre-headless..."
                if apt-get install -y -qq "openjdk-${v}-jre-headless"; then
                    systemctl reset-failed jenkins >/dev/null 2>&1 || true
                    show_spinner_watch_only "Starting Jenkins on Java $v" \
                        systemctl start jenkins || true
                fi
                break
            fi
            print_status "Java $v is accepted but not packaged here."
        done
    fi
fi

# Wait for the port rather than guessing at a sleep duration. The probe runs in
# the background so the elapsed counter keeps moving while curl is blocking:
# two minutes of a frozen line is indistinguishable from a hung install.
print_status "Waiting for Jenkins to answer on 127.0.0.1:${JENKINS_PORT}..."
WAIT_START=$(date +%s)
WAIT_LIMIT=120
while true; do
    curl -fsS --max-time 2 "http://127.0.0.1:${JENKINS_PORT}/login" >/dev/null 2>&1 &
    probe_pid=$!
    probe_ok=0
    while kill -0 "$probe_pid" 2>/dev/null; do
        spin_tick "Waiting for Jenkins, $(( $(date +%s) - WAIT_START ))s of ${WAIT_LIMIT}s"
    done
    wait "$probe_pid" && probe_ok=1

    [ "$probe_ok" = "1" ] && break
    [ $(( $(date +%s) - WAIT_START )) -ge "$WAIT_LIMIT" ] && break

    for _ in 1 2 3 4 5; do
        spin_tick "Waiting for Jenkins, $(( $(date +%s) - WAIT_START ))s of ${WAIT_LIMIT}s"
    done
done
printf '\r\033[K'

if ! curl -fsS --max-time 5 http://127.0.0.1:${JENKINS_PORT}/login >/dev/null 2>&1; then
    print_error "Jenkins is not answering on 127.0.0.1:${JENKINS_PORT} after two minutes."
    print_action "Logs: sudo journalctl -u jenkins -n 40 --no-pager"
    if [ -f "$INIT_FILE" ]; then
        print_info "The admin init script still holds a plaintext password: $INIT_FILE"
        print_action "Delete it once you have sorted the start failure."
    fi
    exit 1
fi

# Jenkins has read it, created the account and stored a hash. The plaintext has
# no further purpose, so it does not get to survive the install.
if [ -f "$INIT_FILE" ]; then
    shred -u "$INIT_FILE" 2>/dev/null || rm -f "$INIT_FILE"
    print_success "Admin created. The init script and its plaintext password are gone."
fi

# -----------------------------------------------------------------------------
# Collect the token Jenkins minted for itself, and install the rotation.
#
# Nothing is printed of it. A token that reaches a terminal is in the scrollback
# and usually in a screenshot as well, which is exactly how the one on
# 2026-08-11 ended up in a chat log.
# -----------------------------------------------------------------------------
if [ -f "$TOKEN_INIT" ] && [ ! -s "$TOKEN_HANDOFF" ]; then
    print_action "Jenkins did not mint a token, so Apply and Update will not work yet."

    # Printed here rather than pointed at: the reason is already in the journal,
    # and sending someone to grep for it is one round trip for text we have.
    TOKEN_LOG="$(journalctl -u jenkins --since "-5 min" --no-pager 2>/dev/null \
        | grep -oE 'hosting-manager: .*' | tail -n 5)"
    if [ -n "$TOKEN_LOG" ]; then
        printf '%s\n' "$TOKEN_LOG" | while IFS= read -r l; do print_action "  $l"; done
    else
        print_info "  Nothing in the journal. The init script may not have run:"
        print_action "  sudo journalctl -u jenkins -n 60 --no-pager | grep -i groovy"
    fi
fi

if [ -s "$TOKEN_HANDOFF" ]; then
    mkdir -p "$(dirname "$TOKEN_FILE")"
    install -m 600 -o root -g root "$TOKEN_HANDOFF" "$TOKEN_FILE"
    shred -u "$TOKEN_HANDOFF" 2>/dev/null || rm -f "$TOKEN_HANDOFF"
    print_success "The hosting manager has a Jenkins token. Apply and Update work."
fi

if [ -f "$TOKEN_INIT" ]; then
    shred -u "$TOKEN_INIT" 2>/dev/null || rm -f "$TOKEN_INIT"
fi

# The token does not expire, so rotation is not about expiry: it is about a copy
# that escaped going stale on its own rather than waiting to be remembered.
ROTATOR="/usr/local/sbin/rotate_jenkins_token.sh"
if [ -f "$SCRIPT_DIR/rotate_jenkins_token.sh" ]; then
    install -m 700 -o root -g root "$SCRIPT_DIR/rotate_jenkins_token.sh" "$ROTATOR"

    ROTATE_SERVICE="/etc/systemd/system/jenkins-token-rotate.service"
    ROTATE_TIMER="/etc/systemd/system/jenkins-token-rotate.timer"

    NEW_ROTATE_SERVICE="$(cat <<EOF
# Generated by add_jenkins.sh
# Do not edit by hand: the next run overwrites it.
[Unit]
Description=Replace the hosting manager's Jenkins API token with a fresh one
After=jenkins.service
Requires=jenkins.service

[Service]
Type=oneshot
ExecStart=${ROTATOR}
EOF
)"

    NEW_ROTATE_TIMER="$(cat <<EOF
# Generated by add_jenkins.sh
# Do not edit by hand: the next run overwrites it.
[Unit]
Description=Rotate the hosting manager's Jenkins token monthly

[Timer]
OnCalendar=monthly
# A machine that was off for a year rotates once on the next boot, rather than
# not at all.
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
)"

    ROTATE_CHANGED=0
    for pair in "$ROTATE_SERVICE|$NEW_ROTATE_SERVICE" "$ROTATE_TIMER|$NEW_ROTATE_TIMER"; do
        unit_path="${pair%%|*}"
        unit_body="${pair#*|}"
        if [ -f "$unit_path" ] && [ "$(cat "$unit_path")" = "$unit_body" ]; then
            continue
        fi
        printf '%s\n' "$unit_body" > "$unit_path"
        chmod 644 "$unit_path"
        ROTATE_CHANGED=1
    done

    if [ "$ROTATE_CHANGED" -eq 1 ]; then
        systemctl daemon-reload
    fi
    systemctl enable --now jenkins-token-rotate.timer >/dev/null 2>&1 \
        && print_success "The token rotates monthly. Next: systemctl list-timers jenkins-token-rotate.timer" \
        || print_action "Could not enable jenkins-token-rotate.timer. Check: systemctl status jenkins-token-rotate.timer"
fi

# THE "ADD THIS KEY TO GITHUB" STEP IS GONE, and with it the only manual step
# this script had. Jenkins clones with the App over HTTPS, and
# add_jenkins_github_credentials.sh installs that credential from the App key,
# so a fresh machine needs nothing pasted into GitHub.
#
# Worth keeping, because it is the shape of what went wrong: the removed text
# told the operator to add a DEPLOY key with write access OFF, and warned in so
# many words that an account key "would give Jenkins write access to everything
# you own". The key that was actually on this machine answered
# "Hi <owner>", so it had been added as an ACCOUNT key. The instruction
# was right and it was not followed, which is an argument for having no manual
# step rather than a better worded one.

print_success "Jenkins is up on 127.0.0.1:${JENKINS_PORT}."

# -----------------------------------------------------------------------------
# Confirm it is not listening anywhere else. The whole security model rests on
# this one fact, so it is verified rather than assumed.
# -----------------------------------------------------------------------------
if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep -q "0.0.0.0:${JENKINS_PORT}\|\[::\]:${JENKINS_PORT}"; then
        print_error "Jenkins is listening on all interfaces, not just loopback."
        print_action "Port $JENKINS_PORT is exposed. Check $OVERRIDE_FILE and restart jenkins."
        exit 1
    fi
    print_success "Verified: port $JENKINS_PORT is bound to loopback only."
fi

SECRET="/var/lib/jenkins/secrets/initialAdminPassword"
echo ""
print_header "Next steps, by hand"
if [ -f "$SECRET" ]; then
    print_info "The setup wizard has not been completed yet."
    print_status "Unlock password:  sudo cat $SECRET"
else
    print_success "Setup wizard already completed, no unlock password needed."
fi
# ASKED, NOT ASSUMED. This block told the operator to add a proxy row on every
# run, including the machines that had had one for weeks, which is how a step
# that is already done gets done twice or read as a failure. Same fault as
# add_hosting_manager.sh's "this uses Jenkins' key", fixed the same day.
if grep -qE '^[[:space:]]*proxy[[:space:]]*\|[[:space:]]*jenkins[[:space:]]*\|' "$SITES_CONF" 2>/dev/null; then
    print_success "A proxy row for jenkins is already in $(basename "$SITES_CONF"), so a vhost is managed for it."
    print_info "If it is not serving, that is add_app_vhosts.sh's job, not this script's."
else
    print_status "Jenkins is not reachable from a browser until it has a vhost."
    print_status "Add a proxy row to /etc/hostings/hostings.conf:"
    print_status "    proxy | jenkins | ${JENKINS_PORT} | | jenkins.<your-domain>"
    print_status "then run add_app_vhosts.sh and add_site_certificates.sh."
    print_status "A proxy row means: reverse proxy this port, but do not manage a"
    print_status "systemd unit for it. Jenkins ships its own."
    print_status "Until then, tunnel in:  ssh -L ${JENKINS_PORT}:127.0.0.1:${JENKINS_PORT} <user>@<host>"
fi

print_success "Jenkins installed."
