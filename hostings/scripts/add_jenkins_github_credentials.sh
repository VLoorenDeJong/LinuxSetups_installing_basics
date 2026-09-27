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
# Teach Jenkins to authenticate as the GitHub App, and to check webhook
# signatures.
#
#   sudo bash add_jenkins_github_credentials.sh
#   sudo bash add_jenkins_github_credentials.sh --secret-only
#   sudo bash add_jenkins_github_credentials.sh --secret-only --ask
#                       ask for the webhook secret even when the vault has one
#
# Two things, and they are separate:
#
#   1. A GitHub App credential, so Jenkins mints its OWN tokens. Not a token
#      pasted in: those live one hour, and one pasted here would have to be
#      replaced every hour by somebody. Jenkins holds the App's key instead and
#      asks GitHub for a token whenever it needs one.
#
#   2. The webhook shared secret, so a hook that did not come from GitHub is
#      rejected. Without it Jenkins accepts any POST that reaches the endpoint.
#      The firewall already admits only GitHub's ranges, so this is the second
#      lock rather than the only one.
#
# JENKINS WANTS THE KEY IN PKCS#8 AND GITHUB GIVES PKCS#1. That is the
# difference between "BEGIN RSA PRIVATE KEY" and "BEGIN PRIVATE KEY", and
# Jenkins fails with an unhelpful error rather than saying so. Converted here.
#
# THE VALUES GO THROUGH THE SCRIPT CONSOLE, base64 encoded. A credential's
# on-disk form is encrypted with a key only Jenkins holds, so there is no file
# to write: the object has to be built inside the JVM. The request is a POST
# over loopback, so the payload is in the body and not in any access log.
#
# Safe to re-run: an existing credential is replaced with the same values, and
# nothing else in Jenkins is touched.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
# How to explain an ask without drowning it.
#
#   yellow   the ask. One line, and the only yellow on screen.
#   plain    the explanation. Most of it, in the terminal's own colour,
#            because most of it is optional reading.
#   cyan     inside that explanation, the parts to actually find: a URL, a
#            button to click, the shape of the number being looked for.
#
# The version before this put the whole explanation in yellow. Ten yellow lines
# where nine are "here is how to find it if you do not already know" buries the
# one line that is a question.
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'     # cyan: the bit to look for
NC=$'\033[0m'      # back to the terminal's own colour

# EVERY ESCAPE IN THIS SCRIPT LIVES IN THIS BLOCK, so there is one place to get
# right rather than a handful scattered through the file. Inline ones are how a
# search and replace left a colour code printing itself instead of applying.
prompt_ask()    { printf "\n   \033[33m%s\033[0m %s" "$1" "${2:-}"; }
prompt_got()    { printf "   \033[32m✅ %s\033[0m\n" "$1"; }

# The busy indicator every other script in this fleet uses, copied exactly.
# A Jenkins script console call is several seconds of silence otherwise.
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

print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }


SECRET_ONLY=0
ASK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --secret-only) SECRET_ONLY=1; shift ;;
        --ask)         ASK=1; shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--secret-only] [--ask]" >&2
            exit 1 ;;
        *) print_error "Unknown argument '$1'"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script reads the App key and Jenkins' token, so it needs sudo."
    print_action "Run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    # A CRLF config leaves a carriage return on the end of every value, and
    # none of the trimming below removes it.
    v="${v//$'\r'/}"
    v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

APP_ID="$(conf_get GITHUB_APP_ID "")"
KEY_FILE="$(conf_get GITHUB_APP_KEY_FILE /etc/github-app/app.pem)"
APP_CRED_ID="$(conf_get GITHUB_APP_CREDENTIAL_ID github-token)"

# Which installation Jenkins mints its tokens from. An App installed on one
# account needs no answer; installed on two, the plugin refuses to guess and
# every clone fails. The owner that matters is whoever holds THIS repository,
# because every job reads its Jenkinsfile from here before it reads anything
# else.
CRED_OWNER="$(conf_get GITHUB_CREDENTIAL_OWNER "")"
if [ -z "$CRED_OWNER" ]; then
    CRED_OWNER="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null \
        | sed -E 's#^git@[^:]+:##; s#^https://[^/]+/##; s#/.*$##')"
fi
SECRET_CRED_ID="github-webhook-secret"

TOKEN_FILE="/var/lib/hosting-manager/jenkins-token"
JENKINS_PORT="$(grep -v '^[[:space:]]*#' "$SITES_CONF" 2>/dev/null | grep '|' \
    | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$3); if ($2=="jenkins") print $3}' | head -1)"
JENKINS_PORT="${JENKINS_PORT:-11002}"
JENKINS_URL="http://127.0.0.1:${JENKINS_PORT}"

print_header "Jenkins and the GitHub App"

ERRORS=()
[ -s "$TOKEN_FILE" ] || ERRORS+=("No Jenkins API token at $TOKEN_FILE. Run add_hosting_manager.sh first.")
if ! ss -lnt 2>/dev/null | grep -q ":${JENKINS_PORT}\b"; then
    ERRORS+=("Nothing is listening on ${JENKINS_URL}, so Jenkins is not running.")
fi
if [ "$SECRET_ONLY" -ne 1 ]; then
    [ -z "$APP_ID" ] && ERRORS+=("No GITHUB_APP_ID in $SITES_CONF. Run add_github_app.sh first.")
    [ -s "$KEY_FILE" ] || ERRORS+=("No App key at $KEY_FILE. Run add_github_app.sh first.")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

AUTH="$(head -n1 "$TOKEN_FILE")"

# Token and script go in on stdin and a config fd, never argv: the scripts
# carry the App key and the webhook secret, and argv is readable in `ps`.
run_groovy() {
    printf '%s' "$1" | curl -fsS --max-time 60 \
        -K <(printf 'user = "%s"\n' "$AUTH") \
        --data-urlencode "script@-" \
        "${JENKINS_URL}/scriptText" 2>&1
}

# =============================================================================
# 1. The GitHub App credential
# =============================================================================
# install_app_cred <credential id> <app id> <key file> <owner>
install_app_cred() {
    local APP_CRED_ID="$1" APP_ID="$2" KEY_FILE="$3" CRED_OWNER="$4" PK8 KEY_B64 APP_GROOVY OUT SEEN
    PK8="$(mktemp)"; chmod 600 "$PK8"

    if ! openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt \
            -in "$KEY_FILE" -out "$PK8" 2>/dev/null; then
        rm -f "$PK8"
        print_error "Could not convert the App key to PKCS#8."
        print_action "Check it with: sudo openssl rsa -in $KEY_FILE -noout -check"
        exit 1
    fi
    print_success "Key converted to PKCS#8, the only format Jenkins accepts."

    # base64, so no quoting or newline in a PEM can break the Groovy.
    KEY_B64="$(base64 -w0 < "$PK8")"
    rm -f "$PK8"

    spinner_start "Installing the App credential as ${APP_CRED_ID}..."

    APP_GROOVY="import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
import org.jenkinsci.plugins.github_branch_source.GitHubAppCredentials
import hudson.util.Secret

def credId = '${APP_CRED_ID}'
def appId  = '${APP_ID}'
def owner  = '${CRED_OWNER}'
def keyPem = new String(java.util.Base64.decoder.decode('${KEY_B64}'), 'UTF-8')

def store  = SystemCredentialsProvider.getInstance().getStore()
def domain = Domain.global()

def cred = new GitHubAppCredentials(
    CredentialsScope.GLOBAL, credId,
    'GitHub App: mints its own tokens, nothing to expire',
    appId, Secret.fromString(keyPem))

// Which installation to mint from. setOwner is the old field and newer
// github-branch-source ignores it silently, so the strategy object is tried
// first and setOwner is only the fallback for an older plugin.
def ownerSet = 'none'
if (owner) {
    def pkg = 'org.jenkinsci.plugins.github_branch_source.app_credentials'
    def cl  = jenkins.model.Jenkins.instance.pluginManager.uberClassLoader
    try {
        def k = cl.loadClass(pkg + '.AccessSpecifiedRepositories')
        cred.setRepositoryAccessStrategy(k.newInstance(owner, []))
        ownerSet = 'strategy'
    } catch (ignored) {
        cred.setOwner(owner)
        ownerSet = 'setOwner'
    }
}

def existing = store.getCredentials(domain).find { it.id == credId }
if (existing != null) {
    store.updateCredentials(domain, existing, cred)
    println 'REPLACED ' + credId
} else {
    store.addCredentials(domain, cred)
    println 'ADDED ' + credId
}

// Read it back. Reporting the owner from what was SENT is how this script
// claimed an installation it had not set: setOwner is silently ignored now.
def saved = store.getCredentials(domain).find { it.id == credId }
def strat = saved.getRepositoryAccessStrategy()
def seen  = saved.getOwner()
if (strat != null) {
    try { seen = strat.getOwner() } catch (ignored) { seen = strat.toString() }
}
println 'OWNER ' + (seen ?: 'null') + ' via ' + ownerSet"

    OUT="$(run_groovy "$APP_GROOVY")" || true
    spinner_stop
    if printf '%s' "$OUT" | grep -qE 'ADDED|REPLACED'; then
        print_success "Credential '${APP_CRED_ID}' is now a GitHub App credential."
        print_status "   Jenkins mints its own tokens from it. Nothing expires."
        SEEN="$(printf '%s' "$OUT" | sed -n 's/^OWNER \([^ ]*\) via .*/\1/p' | head -n1)"
        if [ -z "$CRED_OWNER" ]; then
            print_error "No owner could be worked out, so clones fail if the App"
            print_error "is installed on more than one account. Set GITHUB_CREDENTIAL_OWNER."
        elif [ "$SEEN" = "$CRED_OWNER" ]; then
            print_success "   Installation: ${CRED_OWNER}, read back from Jenkins."
            print_status "   Repositories under any other owner cannot be cloned with it."
        else
            print_error "Asked for installation '${CRED_OWNER}', Jenkins reports '${SEEN}'."
            print_error "Every clone will fail while the App is on more than one account."
            exit 1
        fi
    else
        print_error "Jenkins did not install the credential:"
        printf '%s\n' "$OUT" | tail -8
        exit 1
    fi
}

if [ "$SECRET_ONLY" -ne 1 ]; then
    install_app_cred "$APP_CRED_ID" "$APP_ID" "$KEY_FILE" "$CRED_OWNER"

    # One more credential per owner the Apps are installed on, github-token-<owner>,
    # because a Jenkins App credential reaches one owner only: a site under any
    # other owner failed with "Repository not found". The Jenkinsfiles pick the
    # one matching the site's repository. On a TEST machine the owners in
    # GITHUB_ADMIN_TARGETS get the write App, like github_app_token.sh.
    ADMIN_TARGETS="$(conf_get GITHUB_ADMIN_TARGETS "")"
    for o in $(SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/github_app_token.sh" --owners 2>/dev/null); do
        case " $ADMIN_TARGETS " in
            *" $o "*) install_app_cred "github-token-$o" "$(conf_get GITHUB_ADMIN_APP_ID "")"                           "$(conf_get GITHUB_ADMIN_APP_KEY_FILE /etc/github-app/admin-app.pem)" "$o" ;;
            *)        install_app_cred "github-token-$o" "$APP_ID" "$KEY_FILE" "$o" ;;
        esac
    done
fi

# =============================================================================
# 2. The webhook shared secret
# =============================================================================
spinner_start "Checking Jenkins for a webhook secret..."
EXISTS="$(run_groovy "import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
def f = SystemCredentialsProvider.getInstance().getStore().getCredentials(Domain.global()).find { it.id == '${SECRET_CRED_ID}' }
println f == null ? 'NO' : 'YES'")" || true
spinner_stop

# THE VAULT ANSWERS FIRST, THEN THE KEYBOARD, AND THE KEYBOARD NEVER SKIPS.
#
# A script that silently leaves an existing value alone is a script you cannot
# use to fix a wrong one, so without a vault copy it asks every time and an
# empty answer keeps what is installed. --ask asks even when the vault has one.
HAVE_SECRET=0
printf '%s' "$EXISTS" | grep -q 'YES' && HAVE_SECRET=1

FROM_VAULT=0
WEBHOOK_SECRET=""
if [ -f "$SCRIPT_DIR/secret_ask.sh" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/secret_ask.sh" || true
fi
if [ "$ASK" -ne 1 ] && command -v secret_ask >/dev/null 2>&1 \
   && WEBHOOK_SECRET="$(secret_ask github-webhook-secret \
                            --label "the GitHub App webhook secret" --no-ask)" \
   && [ -n "$WEBHOOK_SECRET" ]; then
    FROM_VAULT=1
    print_info "Changed it on GitHub since? Rerun with --ask to replace the vault's copy."
else
    WEBHOOK_SECRET=""
fi

if [ "$FROM_VAULT" -ne 1 ]; then
    [ "$HAVE_SECRET" -eq 1 ] && print_info "A webhook secret is already installed. Answering replaces it."

    echo ""
    print_action "NEEDED: the GitHub App webhook secret"
    print_hint   "it must match GitHub character for character. Nothing checks"
    print_hint   "that: a wrong one shows up later as every hook rejected."
    print_hint   "asked twice and compared, because a secret being SET cannot"
    print_hint   "be checked against anything."
    print_hint   "if you do not have it already:"
    print_hint   "  go to ${HL}https://github.com/settings/apps${NC}"
    print_hint   "  click your App, then ${HL}Webhook secret${NC}"
    print_hint   "  not sure what you set? generate a new one and paste the same"
    print_hint   "  value into both. Nothing depends on the old value."
    if [ "$HAVE_SECRET" -eq 1 ]; then
        print_hint "empty keeps the one already installed."
    else
        print_hint "empty skips it, and the door stays protected by the GitHub"
        print_hint "IP allowlist alone."
    fi

    # One asterisk per character, so a paste that landed and one that did not
    # look different.
    read_secret() {
        local -n __out="$1"
        local prompt="$2" value="" ch
        prompt_ask "$prompt"
        while IFS= read -rsn1 ch; do
            case "$ch" in
                "")            break ;;
                $'\177'|$'\b') [ -n "$value" ] && { value="${value%?}"; printf '\b \b'; } ;;
                *)             value="$value$ch"; printf '*' ;;
            esac
        done < /dev/tty 2>/dev/null || true
        echo ""
        __out="$value"
    }

    while true; do
        read_secret WEBHOOK_SECRET "Webhook secret:"
        [ -z "$WEBHOOK_SECRET" ] && break

        read_secret SECOND "Type it again:"
        if [ "$WEBHOOK_SECRET" = "$SECOND" ]; then
            unset SECOND
            break
        fi
        unset SECOND
        print_error "   Those two do not match. Nothing was saved."
        print_action "   Paste it rather than typing it, or generate a new one on"
        print_action "   the App's page and use that."
        WEBHOOK_SECRET=""
    done

    if [ -z "$WEBHOOK_SECRET" ]; then
        echo ""
        if [ "$HAVE_SECRET" -eq 1 ]; then
            print_status "Left the secret that was already installed."
        else
            print_info "Skipped. Jenkins will accept any POST that reaches the webhook"
            print_info "   endpoint, and only the firewall is stopping one."
            print_action "   Set it later with: sudo $0 --secret-only"
        fi
        exit 0
    fi
fi

if [ "$FROM_VAULT" -ne 1 ]; then
    MASKED="${WEBHOOK_SECRET:0:2}$(printf '%*s' $(( ${#WEBHOOK_SECRET} - 2 )) '' | tr ' ' '*')"
    prompt_got "got it: ${MASKED} (${#WEBHOOK_SECRET} characters)"
    unset MASKED
fi

SECRET_B64="$(printf '%s' "$WEBHOOK_SECRET" | base64 -w0)"
unset WEBHOOK_SECRET

SECRET_GROOVY="import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import org.jenkinsci.plugins.github.config.GitHubPluginConfig
import org.jenkinsci.plugins.github.config.HookSecretConfig
import hudson.util.Secret
import jenkins.model.Jenkins

def credId = '${SECRET_CRED_ID}'
def value  = new String(java.util.Base64.decoder.decode('${SECRET_B64}'), 'UTF-8')

def store  = SystemCredentialsProvider.getInstance().getStore()
def domain = Domain.global()

def cred = new StringCredentialsImpl(
    CredentialsScope.GLOBAL, credId,
    'Shared secret GitHub signs webhooks with',
    Secret.fromString(value))

def existing = store.getCredentials(domain).find { it.id == credId }
if (existing != null) { store.updateCredentials(domain, existing, cred) }
else { store.addCredentials(domain, cred) }

def cfg = Jenkins.get().getDescriptorByType(GitHubPluginConfig.class)
cfg.setHookSecretConfigs([new HookSecretConfig(credId)])
cfg.save()
println 'SECRET SET'"

spinner_start "Installing the webhook secret in Jenkins..."
OUT="$(run_groovy "$SECRET_GROOVY")" || true
spinner_stop
if printf '%s' "$OUT" | grep -q 'SECRET SET'; then
    print_success "Webhook secret installed and wired into the GitHub plugin."
    print_status "   Jenkins now rejects a hook that GitHub did not sign."
    # Stored only once Jenkins took it, so the vault never holds a typo.
    if [ "$FROM_VAULT" -ne 1 ] && command -v secret_save >/dev/null 2>&1; then
        printf '%s' "$SECRET_B64" | base64 -d | secret_save github-webhook-secret
    fi
else
    print_error "Jenkins did not accept the secret:"
    printf '%s\n' "$OUT" | tail -8
    exit 1
fi

echo ""
print_success "Jenkins is using the GitHub App."
