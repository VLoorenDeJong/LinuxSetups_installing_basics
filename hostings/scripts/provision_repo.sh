#!/usr/bin/env bash

# =============================================================================
# Authenticating git to GitHub goes through ONE file
#
# git_credential_github_app.sh reads the repository OWNER out of the URL git
# hands it and mints that installation's token. This script used to carry its
# own helper with a single owner-blind token, which is correct only while every
# repository has the same owner. Measured 2026-09-12: an org token gets
# "remote: Repository not found." for a personal-account repository, a 404 that
# names no cause.
#
# credential.useHttpPath is what makes the choice possible: without it git tells
# the helper the host only, and every github.com URL looks identical.
#
# THE INLINE FALLBACK STAYS, and it is deliberate. project-context.md principle
# 2b: one file talks to an outside service, and a caller MAY keep its own copy
# so a lone script on a bare machine still runs. This is that copy, and it is
# only ever the read path.
#
# "!bash <path>" rather than the path alone: the pipeline tree chmods every file
# in it to 644, so a helper named by path is not executable there.
# =============================================================================
CRED_HELPER=""
for _c in /usr/local/lib/linuxbasics/hostings/scripts/git_credential_github_app.sh \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git_credential_github_app.sh"; do
    [ -f "$_c" ] && { CRED_HELPER="$_c"; break; }
done
if [ -n "$CRED_HELPER" ]; then
    GIT_CRED="!bash '$CRED_HELPER'"
else
    GIT_CRED='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
fi
# A redraw needs a terminal. In a Jenkins log \r is not a carriage return, so
# every update lands as its own line and \033[K blanks it: seventeen units
# printed one line of text and sixteen empty ones. Silent there instead, since
# each of these loops already prints a summary when it finishes.
redraw() { [ -t 1 ] || return 0; printf "$@"; }
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
# Create the repository a row asks for, its branches, and its Jenkins job.
#
#   sudo ./provision_repo.sh              report what it would create, change
#                                         nothing. The default, deliberately.
#   sudo ./provision_repo.sh --create     actually create it
#   sudo ./provision_repo.sh --setup-key  install or replace the GitHub token
#
# A row asks for a repository by putting `new` in its Repository field. This
# script replaces that with the real URL once the repository exists, so the
# file describes what is there rather than what was wanted.
#
# WHAT DECIDES WHAT
#
#   RepoMode    private     private repository, default branch dev
#               portfolio   public, default branch main, main mirrors live
#               opensource  public, default branch main, main is the trunk
#
#   Envs        which branches exist. `-` means every environment in ENVS.
#               dev is always created: it is the trunk. main is created for
#               portfolio and opensource, because it is their default branch.
#
# THE TOKEN NEVER TOUCHES JENKINS, AND NEVER TOUCHES THE PAGE
#
# It is systemd-creds encrypted, 0600 root, in GITHUB_CRED_DIR. The same
# argument the config already makes for the TransIP key applies here and is
# stronger: Jenkins runs code out of git on this machine, so a token it can
# read turns a pull request into "create a repository as you". The hosting
# manager runs as hosting-manager and cannot read it either; it asks root to run this
# script, exactly like the other privileged commands.
#
# CREATING A REPOSITORY IS OUTWARD FACING, so nothing happens without --create.
# A run with no arguments reports and exits.
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
print_hint()    { printf "   %s\n" "$1"; }

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

# Watch-only spinner: shows the command is alive but never signals it. A push
# killed halfway leaves a repository half created, which is worse than slow.
#
# Silent when stdout is not a terminal, so a page capturing this output gets
# text rather than carriage returns.
show_spinner_watch_only() {
    local message="$1"
    shift
    if [ ! -t 1 ]; then "$@"; return $?; fi

    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    "$@" &
    local cmd_pid=$! tick=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        redraw '\r\033[K\033[34m%s %s\033[0m' "${frames[tick % 10]}" "$message"
        tick=$((tick + 1))
        sleep 0.2 || { printf "\n\033[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\033[0m\n"; break; }
    done
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    redraw '\r\033[K'
    return $exit_code
}

MODE="check"
STEP_ONLY=""
STEP_ROW=""
case "${1:-}" in
    --create)    MODE="create" ;;
    --reconcile) MODE="reconcile" ;;
    --setup-key) MODE="setupkey" ;;
    --check|"")  MODE="check" ;;
    # RUN ONE STEP OF THE CREATE, for a row whose repository already exists.
    #
    # The owner's decision 2026-09-03: one button press, and the operations
    # underneath separate so a scenario can change without breaking the others.
    # The step report says which one stopped; this is what does something about
    # it, without creating anything a second time.
    #
    # Only the repeatable steps are offered. Creating the repository and
    # pushing its branches are not among them: they have already happened by
    # definition if there is a step to re-run, and offering them would mean
    # offering to do them twice.
    --step)
        MODE="step"
        STEP_ONLY="${2:-}"
        STEP_ROW="${3:-}"
        case "$STEP_ONLY" in
            jenkins-folder|write-back|seed|deploy-jobs|first-deploy) ;;
            *)
                print_error "Unknown step: ${STEP_ONLY:-(none)}"
                print_action "One of: jenkins-folder, write-back, seed, deploy-jobs, first-deploy"
                exit 1 ;;
        esac
        if [ -z "$STEP_ROW" ]; then
            print_error "--step needs a row name: $0 --step $STEP_ONLY <row>"
            exit 1
        fi
        ;;
    *)
        print_error "Unknown argument: $1"
        print_action "Use --create, --reconcile, --setup-key, --step, --check, or no argument at all."
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

# The console runs the installed copy at /usr/local/sbin, where ../.. is /usr:
# not a repository and with no /etc/hostings in it. That made the provision
# button fail with "Config not found: /usr/backup_config/hostings.conf", and
# it would have failed a second time on the origin lookup below, which reads
# REPO_ROOT as a git repository to learn the GitHub account.
#
# Both fall back to the manager's clone, the same one promote_certificate.sh
# uses. Guarded separately, because SITES_CONF can be set by hand to somewhere
# that is not in a repository at all.
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/etc/hostings")"

GITHUB_CRED_DIR="/etc/github-api"
GITHUB_CRED_NAME="ghapi"
GITHUB_CRED_FILE="${GITHUB_CRED_DIR}/${GITHUB_CRED_NAME}.cred"
GITHUB_API="https://api.github.com"
JENKINS_HOME="/var/lib/jenkins"

# -----------------------------------------------------------------------------
# Config readers. Duplicated rather than sourced, so this script still runs on a
# machine that has only this file copied to it.
# -----------------------------------------------------------------------------
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

trim() { echo "$1" | xargs; }

# -----------------------------------------------------------------------------
# The token
# -----------------------------------------------------------------------------
# Never printed, never written in plaintext, and never passed as an argument:
# an argument is visible in `ps` to every user on the machine.
setup_key() {
    print_header "Install the GitHub token"

    echo "Create a token at https://github.com/settings/tokens"
    echo ""
    echo "It needs to create repositories and push to them. A classic token"
    echo "with the 'repo' scope does; a fine-grained token needs repository"
    echo "creation for your account, which GitHub words differently from time"
    echo "to time, so read the permission list rather than trusting this line."
    echo ""
    echo "The token is NOT stored in plaintext: it is encrypted to this host"
    echo "with systemd-creds, so a copy taken off this machine is worthless."
    echo ""

    install -d -m 0700 -o root -g root "$GITHUB_CRED_DIR"

    local plain
    plain="$(mktemp)"
    chmod 600 "$plain"

    # Read from the terminal, one character at a time, with a mask. `read -s`
    # shows nothing at all, so a paste that failed looks exactly like one that
    # worked, and the first anyone learns of it is a token that does not work.
    printf "Paste the token, then press Enter: "
    local token="" char
    while IFS= read -rsn1 char < /dev/tty; do
        [ -z "$char" ] && break
        if [ "$char" = $'\177' ]; then
            [ -n "$token" ] && { token="${token%?}"; printf '\b \b'; }
            continue
        fi
        token="${token}${char}"
        printf '*'
    done
    printf "\n"

    if [ -z "$token" ]; then
        rm -f "$plain"
        print_error "Nothing was pasted, so nothing was written."
        exit 1
    fi

    printf '%s' "$token" > "$plain"
    unset token

    rm -f "$GITHUB_CRED_FILE"
    if ! systemd-creds encrypt --name="$GITHUB_CRED_NAME" "$plain" "$GITHUB_CRED_FILE" 2>/dev/null; then
        rm -f "$plain"
        print_error "systemd-creds could not encrypt the token."
        exit 1
    fi
    rm -f "$plain"
    chmod 600 "$GITHUB_CRED_FILE"
    chown root:root "$GITHUB_CRED_FILE"

    print_success "Token installed at $GITHUB_CRED_FILE, encrypted to this host."
    print_status "Check it with: sudo $0"
}

read_token() {
    [ -f "$GITHUB_CRED_FILE" ] || return 1
    systemd-creds decrypt --name="$GITHUB_CRED_NAME" "$GITHUB_CRED_FILE" - 2>/dev/null
}

# The account the repositories belong to, taken from this clone's own remote
# rather than configured: a machine built from a fork provisions into that fork.
github_owner() {
    local url
    url="$(git -C "$(readlink -f /etc/hostings)" remote get-url origin 2>/dev/null || true)"
    case "$url" in
        git@*:*)   echo "$url" | sed -E 's#^[^:]+:([^/]+)/.*$#\1#' ;;
        https://*) echo "$url" | sed -E 's#^https://[^/]+/([^/]+)/.*$#\1#' ;;
        *)         echo "" ;;
    esac
}

if [ "$MODE" = "setupkey" ]; then
    setup_key
    exit 0
fi

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
print_header "Provision repositories"

ERRORS=()
WARNINGS=()
err()  { ERRORS+=("$1"); }
warn() { WARNINGS+=("$1"); }

[ -f "$SITES_CONF" ] || { print_error "Config not found: $SITES_CONF"; exit 1; }

for tool in git curl python3 systemd-creds; do
    command -v "$tool" >/dev/null 2>&1 || err "$tool is not installed"
done

OWNER="$(github_owner)"

# WHERE NEW REPOSITORIES ARE MADE, which is not where the old ones live.
#
# A GitHub App cannot create a repository under a personal account, only inside
# an organisation, which is the entire reason a PAT was still on this machine.
# Creating in the org removes that credential rather than renewing it.
# See .claude/docs/github-org-decisions.md, decision 2.
#
# Unset means the old behaviour: create under OWNER with the PAT.
CREATE_ORG="$(conf_get GITHUB_ORG "")"

# WHO PUSHES: the GitHub App, as root, over HTTPS. GIT_PUSH_KEY is for the first
# clone of a machine only, the owner 2026-09-13. Root because minting reads the
# root-only App key.
APP_RUN_USER="$(conf_get APP_RUN_USER jenkins)"
[ -z "$APP_RUN_USER" ] && APP_RUN_USER="jenkins"

# Checked before anything is created, not discovered at the push.
#
# A run that dies at the push leaves a repository on GitHub that exists, has no
# commits, and has to be reconciled rather than created next time.
# Can the App mint a token right now? Asked rather than assumed: the key can be
# present and the installation revoked, and the two look identical on disk.
#
# The same three paths the token minter is looked for further down, and for the
# same reason: the installed copy runs from /usr/local/sbin, where it has no
# siblings, so a bare $SCRIPT_DIR lookup finds nothing and reports "no App".
app_token_available() {
    local sh
    for sh in "$SCRIPT_DIR/github_app_token.sh" \
              "/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh" \
              "/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"; do
        [ -f "$sh" ] || continue
        [ -n "$(SITES_CONF="$SITES_CONF" bash "$sh" 2>/dev/null)" ] && return 0
    done
    return 1
}

require_push_identity() {
    if app_token_available; then
        print_info "Pushing as the GitHub App."
        return 0
    fi
    print_error "No GitHub App token could be minted, so nothing could be pushed."
    print_action "Nothing was created. Check the App: sudo bash ${SCRIPT_DIR}/add_github_app.sh --test-only"
    exit 1
}
[ -n "$OWNER" ] || err "Could not read the GitHub account from $REPO_ROOT's origin remote"

# EITHER credential will do, and the App is the one that should be there.
#
# This used to demand the PAT file unconditionally, while the code below prefers
# the App and falls back to the PAT only when the mint fails. So the machine
# refused to run on exactly the configuration that is wanted: the App installed,
# the PAT deleted. Found 2026-09-04, the moment the PAT was removed.
#
# The PAT is no longer needed for anything measured on 2026-09-04:
#   create in the org   the App does it, 201
#   create personally   only a PAT can, and GITHUB_ORG makes that unreachable
#   transfer            NEITHER can. 403 for both, it is a browser or classic-PAT act
if [ ! -f "$GITHUB_CRED_FILE" ] && ! app_token_available; then
    err "No GitHub credential: no App token, and no PAT at $GITHUB_CRED_FILE"
    err "  Install the App: sudo bash ${SCRIPT_DIR}/add_github_app.sh"
    err "  Or a token:      sudo bash $0 --setup-key"
fi

ALL_ENVS=()
while IFS= read -r e; do [ -n "$e" ] && ALL_ENVS+=("$e"); done < <(
    conf_get ENVS "live" | tr ',' '\n' | while IFS= read -r x; do trim "$x"; done
)

# Rows asking to be created. `new` is the marker, and it is deliberately a word
# rather than an empty field: empty means "deployed by hand", which is a real
# answer that must not start creating things.
WANTED=()
while IFS='|' read -r type name port path sub ds opts auth repo branch rowenvs users mode runtime _rest; do
    type="$(trim "$type")"; name="$(trim "$name")"; repo="$(trim "$repo")"
    rowenvs="$(trim "$rowenvs")"; mode="$(trim "$mode")"

    [ "$(echo "$repo" | tr '[:upper:]' '[:lower:]')" = "new" ] || continue

    case "$type" in
        app|website) ;;
        *) err "$name is a '$type' row, which has no repository to create"; continue ;;
    esac

    [ -n "$name" ] || { err "A row asks for a repository but has no name"; continue; }

    case "$(echo "$mode" | tr '[:upper:]' '[:lower:]')" in
        ""|-|private) mode="private" ;;
        portfolio)    mode="portfolio" ;;
        opensource)   mode="opensource" ;;
        *) err "$name: RepoMode '$mode' is not private, portfolio or opensource"; continue ;;
    esac

    # The TYPE rides along, because the seed step downstream picks a different
    # script for an application than for a website and the row is long gone by
    # then. Fifth field, appended, so nothing that reads the first four moves.
    WANTED+=("${name}|${rowenvs}|${mode}|$(trim "$branch")|${type}")
done < <(conf_rows)

# Rows whose repository already exists. RepoMode and Envs can change after
# creation, and a mode that cannot be changed afterwards is a mode nobody dares
# choose, so these are compared and reported like any other drift.
EXISTING_ROWS=()
while IFS='|' read -r type name port path sub ds opts auth repo branch rowenvs users mode runtime _rest; do
    type="$(trim "$type")"; name="$(trim "$name")"; repo="$(trim "$repo")"
    rowenvs="$(trim "$rowenvs")"; mode="$(trim "$mode")"

    case "$type" in app|website) ;; *) continue ;; esac
    case "$repo" in
        ""|-|new) continue ;;
        *github.com*) ;;
        *) warn "$name: Repository '$repo' is not a github.com URL, so it is not managed here"; continue ;;
    esac

    case "$(echo "$mode" | tr '[:upper:]' '[:lower:]')" in
        ""|-|private) mode="private" ;;
        portfolio)    mode="portfolio" ;;
        opensource)   mode="opensource" ;;
        *) continue ;;
    esac

    # owner/name out of either URL form, so the row keeps whichever it holds.
    slug="$(echo "$repo" | sed -E 's#^git@[^:]+:##; s#^https://[^/]+/##; s#\.git$##')"
    EXISTING_ROWS+=("${name}|${rowenvs}|${mode}|${slug}|$(trim "$branch")")
done < <(conf_rows)

if [ ${#WANTED[@]} -eq 0 ]; then
    print_status "No row asks for a repository."
    print_status "Put 'new' in a row's Repository field, then run this again."
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    print_info "Warnings, which do not stop the run:"
    for w in "${WARNINGS[@]}"; do print_info "  - $w"; done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed. Nothing was created."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

# -----------------------------------------------------------------------------
# What each row gets
# -----------------------------------------------------------------------------
branches_for() {
    local rowenvs="$1" mode="$2" rowbranch="${3:-}" out=("dev") e

    # THE ROW'S BRANCH IS THE SOURCE, NOT THE ANSWER. Changed 2026-09-09.
    #
    # It used to end the question: a row with a Branch set wanted dev and that
    # branch and nothing else, because the field OVERRODE the environment's
    # branch everywhere, and deriving live/test/accept then reported branches
    # missing from a repository that deploys perfectly well.
    #
    # The field means "where does this row's code come from" now, and the
    # environments still want a branch each. So it is ADDED to the list rather
    # than replacing it, and the create step below cuts the missing ones from
    # it. A repository that already has live/test/accept/skunkworks is
    # unaffected: nothing is missing, so nothing is created.
    if [ -n "$rowbranch" ] && [ "$rowbranch" != "-" ]; then
        out+=("$rowbranch")
    fi

    if [ -z "$rowenvs" ] || [ "$rowenvs" = "-" ]; then
        for e in "${ALL_ENVS[@]}"; do out+=("$e"); done
    else
        while IFS= read -r e; do
            e="$(trim "$e")"
            [ -n "$e" ] && out+=("$e")
        done < <(echo "$rowenvs" | tr ',' '\n')
    fi
    # skunk deploys from `skunkworks`, the one branch whose name is not its
    # environment. Every other environment's branch is its own name.
    local b final=()
    for b in "${out[@]}"; do
        [ "$b" = "skunk" ] && b="skunkworks"
        final+=("$b")
    done
    [ "$mode" != "private" ] && final+=("main")
    printf '%s\n' "${final[@]}" | awk '!seen[$0]++'
}

# Every branch name the config has ever named as an environment's, including
# environments dropped from ENVS. That is the point: a dropped environment keeps
# its <ENV>_BRANCH block, and its branch is exactly what the drift report has to
# still be able to name.
#
# The key must be <SOMETHING>_BRANCH and nothing else may be read as one: the
# report ends in a delete command, and a future DEFAULT_BRANCH key must not turn
# into an instruction to delete the branch everything is merged into.
ENV_BRANCH_NAMES=()
while IFS= read -r _k; do
    [ -z "$_k" ] && continue
    case "$_k" in
        ENV_BRANCH|BRANCH|DEFAULT_BRANCH) continue ;;
    esac
    _b="$(trim "$(conf_get "$_k" "")")"
    [ -n "$_b" ] && ENV_BRANCH_NAMES+=("$_b")
done < <(sed -n 's/^[[:space:]]*\([A-Z0-9_]\{1,\}_BRANCH\)[[:space:]]*=.*/\1/p' "$SITES_CONF" \
         | tr -d '\r' | awk '!seen[$0]++')

default_branch_for() { [ "$1" = "private" ] && echo "dev" || echo "main"; }
is_private_for()     { [ "$1" = "private" ] && echo "true" || echo "false"; }

print_status "Account:      $OWNER"
[ -n "$CREATE_ORG" ] && print_status "New repos in: $CREATE_ORG"
print_status "Environments: ${ALL_ENVS[*]}"
echo ""

for entry in ${WANTED+"${WANTED[@]}"}; do
    IFS="|" read -r name rowenvs mode rowbranch rowtype <<< "$entry"
    mapfile -t brs < <(branches_for "$rowenvs" "$mode" "$rowbranch")
    printf "  %-30s %-10s %s\n" "$name" "$mode" "$(printf '%s ' "${brs[@]}")"
    printf "  %-30s %-10s default branch %s, %s\n" "" "" \
        "$(default_branch_for "$mode")" \
        "$([ "$(is_private_for "$mode")" = "true" ] && echo private || echo PUBLIC)"
done

# THE APP FIRST, THE PERSONAL ACCESS TOKEN ONLY AS A FALLBACK.
#
# A PAT cannot renew itself. The one here died silently on 2026-08-18 and cost
# two days, because a dead token and a missing repository look identical from
# the outside. An installation token is minted fresh from a key that does not
# expire, so there is nothing to notice and nothing to remember.
#
# The fallback stays because an App cannot create a repository under a personal
# account: GitHub only allows that for an organisation. So creation still needs
# the PAT until these repositories live in one, and saying so here is cheaper
# than a 403 nobody can explain.
TOKEN=""

# The installed copy runs from /usr/local/sbin, alone, so the token minter is
# not beside it and every App mint failed silently into the PAT fallback. The
# pipeline tree is where the other privileged scripts read their siblings from.
TOKEN_SH="$SCRIPT_DIR/github_app_token.sh"
[ -f "$TOKEN_SH" ] || TOKEN_SH="/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"
[ -f "$TOKEN_SH" ] || TOKEN_SH="/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"
TOKEN_SOURCE=""
if [ -f "$TOKEN_SH" ]; then
    if TOKEN="$(SITES_CONF="$SITES_CONF" bash "$TOKEN_SH" 2>/dev/null)" \
       && [ -n "$TOKEN" ]; then
        TOKEN_SOURCE="the GitHub App"
    fi
fi

if [ -z "$TOKEN" ]; then
    TOKEN="$(read_token)" || {
        print_error "No GitHub App token and no personal access token."
        print_hint "install the App with: sudo bash $SCRIPT_DIR/add_github_app.sh"
        exit 1
    }
    TOKEN_SOURCE="a personal access token"
fi
print_info "Authenticating as ${TOKEN_SOURCE}."
[ -n "$TOKEN" ] || { print_error "The token file decrypted to nothing."; exit 1; }

# THE INTERFACE. Item 115: this file was the last caller carrying its own copy
# of the auth, the signing and the curl, and it was kept last on purpose
# because its token_for_path is the code github_api.sh was lifted FROM. Keeping
# the one correct caller unconverted gave a working reference to compare
# against; that comparison is done, so the copy goes.
#
# The owner still comes out of the path. That logic did not change, it moved:
# /repos/<owner>/... and /orgs/<owner> name their owner, so an org repository
# gets an org token and a personal one gets the personal token. The four
# functions that took an explicit token are gone with it, because handing one
# in was only ever a way of saying which owner was meant.
API_SH=""
for _c in /usr/local/lib/linuxbasics/hostings/scripts/github_api.sh \
          "$SCRIPT_DIR/github_api.sh"; do
    [ -f "$_c" ] && { API_SH="$_c"; break; }
done
[ -n "$API_SH" ] || { print_error "github_api.sh was not found beside $0 or in the pipeline tree."; exit 1; }

# THE VERBS come from repo_host.sh, which names no path and no HTTP code. Item
# 115 put this file on github_api.sh, the transport; this puts it on the
# interface above it. github_api.sh is still there, one layer down, under
# repo_host_github.sh.
# shellcheck source=/dev/null
# A SCRIPT INSTALLED TO /usr/local/sbin HAS NO SIBLINGS, which is the fault of
# 2026-09-02 that made every sibling lookup fail silently. The interfaces live
# in the pipeline tree, so look there when they are not beside this file.
_iface() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

. "$(_iface repo_host.sh)"

# ONE CALL STAYS ON THE TRANSPORT, and the reason sits with it further down:
# the create needs the response BODY and the HTTP code together, and its
# personal-account branch needs a PAT the interface does not carry and should
# not. A create that went through the verb on one path and around it on the
# other would be worse than either.
api_with_code() {
    SITES_CONF="$SITES_CONF" bash "$API_SH" --with-code "$1" "$2" ${3:+"$3"} 2>/dev/null \
        || printf '\n000'
}
json_field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1],"") or "")' "$1" 2>/dev/null || true; }

# Sets ORG_TOKEN rather than printing it. A function whose output is captured
# runs in a subshell, so an assignment inside it never reaches the caller: that
# is the conf_get cache bug of 2026-08-24, and it would have cost three GitHub
# round trips per row here.
ORG_TOKEN=""
org_token() {
    [ -n "$ORG_TOKEN" ] && return 0
    [ -f "$TOKEN_SH" ] || return 1
    ORG_TOKEN="$(SITES_CONF="$SITES_CONF" bash "$TOKEN_SH" "$CREATE_ORG" 2>/dev/null)" || return 1
    [ -n "$ORG_TOKEN" ]
}
json_names() { python3 -c 'import json,sys; print("\n".join(x.get("name","") for x in json.load(sys.stdin)))' 2>/dev/null || true; }
json_obj()   { python3 -c 'import json,sys; print(json.dumps(dict(zip(sys.argv[1::2], [True if v=="__true" else False if v=="__false" else v for v in sys.argv[2::2]]))))' "$@"; }

# -----------------------------------------------------------------------------
# Drift, for repositories that already exist
#
# Three things can disagree with the row after creation: whether it is private,
# which branch is default, and which branches exist. Reported for every mode
# because RepoMode is meant to be changeable, which it is not if changing it
# does nothing.
#
# Visibility is asymmetric on purpose. private -> public is applied by NOBODY
# here: it publishes every commit ever made, including anything deleted later,
# and that cannot be undone. The command is printed instead.
# -----------------------------------------------------------------------------
DRIFT_LINES=()
DRIFT_ACTIONS=()

collect_drift() {
    local name="$1" rowenvs="$2" mode="$3" slug="$4" rowbranch="${5:-}"
    local meta private_now default_now
    local owner="${slug%%/*}" repo="${slug#*/}" why detail rc
    repo_exists "$owner" "$repo"; rc=$?
    if [ "$rc" != "0" ]; then
        if [ "$rc" = "1" ]; then
            DRIFT_LINES+=("$name: ${slug} does not exist, or this token cannot see it.")
        else
            # The reason is a WORD, not an HTTP code: a caller reasoning about
            # 401 is a caller that knows it is talking to a web API.
            why="$(repo_exists "$owner" "$repo" | cut -f1)"
            detail="$(repo_exists "$owner" "$repo" | cut -f2)"
            case "$why" in
                denied)      DRIFT_LINES+=("$name: the host refused the token. It is expired or revoked. Reinstall it with --setup-key.") ;;
                forbidden)   DRIFT_LINES+=("$name: the host refused the token for ${slug}. It lacks the scope, or the rate limit is spent.") ;;
                unreachable) DRIFT_LINES+=("$name: ${slug} could not be reached at all.") ;;
                *)           DRIFT_LINES+=("$name: ${slug} cannot be read (${detail}).") ;;
            esac
        fi
        return 0
    fi

    case "$(repo_is_private "$owner" "$repo")" in
        yes) private_now=true ;;
        no)  private_now=false ;;
        *)   private_now="" ;;
    esac
    default_now="$(repo_default_branch "$owner" "$repo")"

    local private_want default_want
    private_want="$(is_private_for "$mode")"
    default_want="$(default_branch_for "$mode")"

    if [ "$private_now" != "$private_want" ]; then
        if [ "$private_want" = "false" ]; then
            DRIFT_LINES+=("$name: is private, RepoMode '$mode' wants it PUBLIC. Not done here, it cannot be undone:")
            DRIFT_LINES+=("    gh repo edit ${slug} --visibility public")
        else
            DRIFT_LINES+=("$name: is public, RepoMode '$mode' wants it private.")
            DRIFT_ACTIONS+=("private|${slug}|")
        fi
    fi

    local existing missing=() want
    existing="$(repo_branches "$owner" "$repo")"
    want="$(branches_for "$rowenvs" "$mode" "$rowbranch")"
    local b
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        printf '%s\n' "$existing" | grep -qx "$b" || missing+=("$b")
    done < <(printf '%s\n' "$want")

    if [ ${#missing[@]} -gt 0 ]; then
        DRIFT_LINES+=("$name: branches missing: ${missing[*]}")
        DRIFT_ACTIONS+=("branches|${slug}|${missing[*]}|${rowbranch}")
    fi

    # A branch that belonged to an environment this row no longer has. Reported,
    # never acted on: a branch is the only thing here that can hold work nobody
    # else has, and it cannot be rebuilt from the config like a vhost can.
    #
    # Only names from ENV_BRANCH_NAMES are considered, so a developer's own
    # branch is never mentioned.
    local surplus=()
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        printf '%s\n' "$existing" | grep -qx "$b" || continue
        printf '%s\n' "$want" | grep -qx "$b" && continue
        [ "$b" = "$default_now" ] && continue
        surplus+=("$b")
    done < <(printf '%s\n' "${ENV_BRANCH_NAMES[@]}")

    if [ ${#surplus[@]} -gt 0 ]; then
        DRIFT_LINES+=("$name: branches no environment uses: ${surplus[*]}")
        for b in "${surplus[@]}"; do
            DRIFT_LINES+=("    look first: git log origin/${default_now}..origin/${b}")
            DRIFT_LINES+=("    then, if it holds nothing: gh api -X DELETE repos/${slug}/git/refs/heads/${b}")
        done
    fi

    # Last, because creating the branch it wants has to happen first.
    if [ "$default_now" != "$default_want" ]; then
        DRIFT_LINES+=("$name: default branch is '$default_now', RepoMode '$mode' wants '$default_want'.")
        DRIFT_ACTIONS+=("default|${slug}|${default_want}")
    fi

    # main is surplus under RepoMode private, and this is the ONE moment it can
    # be deleted safely: dev is being made from it right now, so the two are the
    # same commit. A later run finds a main that has moved on its own and must
    # keep its hands off. Never extended to environment branches, which can hold
    # work nothing else has.
    if [ "$mode" = "private" ] && [ "$default_now" = "main" ] \
       && printf '%s\n' "${missing[@]}" | grep -qx "dev" \
       && printf '%s\n' "$existing" | grep -qx "main"; then
        DRIFT_LINES+=("$name: main is surplus under RepoMode private. It will be deleted, but only if it is the same commit as the dev made from it.")
        DRIFT_ACTIONS+=("prunemain|${slug}|")
    fi
}

# Called directly, never through the spinner: the spinner backgrounds what it
# wraps, and everything collected in a subshell is thrown away with it.
if [ ${#EXISTING_ROWS[@]} -gt 0 ]; then
    print_status "Reading ${#EXISTING_ROWS[@]} repository(ies) from GitHub..."
    for entry in "${EXISTING_ROWS[@]}"; do
        IFS='|' read -r name rowenvs mode slug rowbranch <<< "$entry"
        collect_drift "$name" "$rowenvs" "$mode" "$slug" "$rowbranch" || true
    done
fi

echo ""
if [ ${#DRIFT_LINES[@]} -eq 0 ]; then
    # "Every repository matches" is about the ones that EXIST. A row still
    # waiting to be created matched nothing, and saying it all matched read as
    # "nothing to do" while a repository was missing.
    if [ ${#WANTED[@]} -eq 0 ]; then
        print_success "Every repository already matches its row."
    else
        print_success "Every repository that exists already matches its row."
    fi
else
    print_info "Repositories that differ from their row:"
    for l in "${DRIFT_LINES[@]}"; do print_info "  $l"; done
fi

if [ ${#WANTED[@]} -gt 0 ]; then
    print_info "${#WANTED[@]} repository(ies) do not exist yet and would be created."
fi
if [ "$MODE" = "check" ]; then
    echo ""
    print_status "--check, so nothing was changed. --create makes what is missing and fixes what differs."
    exit 0
fi

# -----------------------------------------------------------------------------
# Fix what differs. Runs in both --create and --reconcile: a row whose mode
# changed is the same problem as a row whose repository does not exist yet.
# -----------------------------------------------------------------------------
# slug in, sha out. The verb takes owner and name separately, because an
# interface taking "owner/name" would be assuming the host has that shape.
ref_sha() {
    repo_branch_sha "${1%%/*}" "${1#*/}" "$2"
}

apply_drift() {
    # A FOURTH FIELD, `extra`, added 2026-09-09 for the branch source. This
    # function runs from DRIFT_ACTIONS alone and has never seen the row, so
    # anything the row decides has to travel in the action itself. Every other
    # kind leaves it empty.
    local kind slug arg extra
    for action in ${DRIFT_ACTIONS+"${DRIFT_ACTIONS[@]}"}; do
        IFS='|' read -r kind slug arg extra <<< "$action"
        case "$kind" in
            private)
                repo_set_private "${slug%%/*}" "${slug#*/}" yes
                print_success "${slug} is private again."
                ;;
            branches)
                # CUT FROM THE ROW'S SOURCE BRANCH when it names one, and from
                # the repository's default branch otherwise. Always the default
                # branch before 2026-09-09, which was right while the field
                # meant "pin every environment to this" and is wrong now that
                # it means "where this row's code comes from": a row on main in
                # a repository whose default is dev would have had its live
                # branch cut from dev.
                local head sha b
                head="$extra"
                if [ -z "$head" ] || [ "$head" = "-" ]; then
                    head="$(repo_default_branch "${slug%%/*}" "${slug#*/}")"
                fi
                sha="$(ref_sha "$slug" "$head")"
                if [ -z "$sha" ]; then
                    print_info "${slug}: could not read ${head}, so no branch was created."
                    continue
                fi
                for b in $arg; do
                    repo_create_branch "${slug%%/*}" "${slug#*/}" "$b" "$sha"
                    print_success "${slug}: branch ${b} created from ${head}."
                done
                ;;
            default)
                repo_set_default_branch "${slug%%/*}" "${slug#*/}" "$arg"
                print_success "${slug}: default branch is now ${arg}."
                ;;
            # Deleting a branch on GitHub closes any PR that targets it and
            # breaks a clone tracking it, so every one of these refuses rather
            # than guesses. The SHA comparison is the whole safety: equal means
            # dev holds everything main did, this second.
            prunemain)
                local now msha dsha code
                now="$(repo_default_branch "${slug%%/*}" "${slug#*/}")"
                if [ "$now" != "dev" ]; then
                    print_info "${slug}: default branch is still '${now}', so main was left alone."
                    continue
                fi
                msha="$(ref_sha "$slug" main)"
                dsha="$(ref_sha "$slug" dev)"
                if [ -z "$msha" ] || [ -z "$dsha" ]; then
                    print_info "${slug}: could not read both main and dev, so main was left alone."
                    continue
                fi
                if [ "$msha" != "$dsha" ]; then
                    print_info "${slug}: main and dev are different commits, so main was left alone."
                    print_action "  look first: git log origin/dev..origin/main"
                    continue
                fi
                if repo_delete_branch "${slug%%/*}" "${slug#*/}" main; then
                    print_success "${slug}: main deleted. It was the same commit as dev."
                else
                    print_info "${slug}: the host refused to delete main. Left alone."
                fi
                ;;
        esac
    done
}

if [ ${#DRIFT_ACTIONS[@]} -gt 0 ]; then
    print_header "Reconcile"
    apply_drift
fi

if [ "$MODE" = "reconcile" ]; then
    unset TOKEN
    exit 0
fi

# The Jenkins job. A MULTIBRANCH pipeline, not one job per branch: Jenkins
# discovers the branches itself, so adding accept later adds a job on its own
# rather than needing this script run again.
write_jenkins_job() {
    local name="$1" repo_url="$2" job_dir="${JENKINS_HOME}/jobs/$1"

    if [ -f "$job_dir/config.xml" ]; then
        print_success "Jenkins job '$name' already exists, left alone."
        return 0
    fi

    mkdir -p "$job_dir"
    cat > "$job_dir/config.xml" <<XML
<?xml version='1.1' encoding='UTF-8'?>
<org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject plugin="workflow-multibranch">
  <description>Generated by provision_repo.sh from hostings.conf</description>
  <properties/>
  <folderViews class="jenkins.branch.MultiBranchProjectViewHolder">
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
  </folderViews>
  <healthMetrics/>
  <sources class="jenkins.branch.MultiBranchProject\$BranchSourceList">
    <data>
      <jenkins.branch.BranchSource>
        <source class="jenkins.plugins.git.GitSCMSource" plugin="git">
          <id>${name}-source</id>
          <remote>${repo_url}</remote>
          <traits>
            <jenkins.plugins.git.traits.BranchDiscoveryTrait/>
          </traits>
        </source>
        <strategy class="jenkins.branch.DefaultBranchPropertyStrategy">
          <properties class="empty-list"/>
        </strategy>
      </jenkins.branch.BranchSource>
    </data>
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
  </sources>
  <factory class="org.jenkinsci.plugins.workflow.multibranch.WorkflowBranchProjectFactory">
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
    <scriptPath>Jenkinsfile</scriptPath>
  </factory>
</org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject>
XML
    chown -R jenkins:jenkins "$job_dir" 2>/dev/null || true
    print_success "Jenkins job '$name' written."
    return 0
}

# The Repository field, rewritten in place. Only the one row's ninth field is
# touched, and the file's alignment is left alone: a diff should show the URL
# arriving, not every row moving.
# The edit itself, on whatever $SITES_CONF currently points at. Split out so the
# pipeline tree and the console clone get the identical change from one piece of
# awk rather than one of them getting a copy of the other's whole file.
# NOT FOUND AND ALREADY CORRECT ARE DIFFERENT ANSWERS, and returning the same
# code for both is what made a rerun say "do it by hand" over a row that was
# perfectly written. Same shape as 488cf3c one function down, where "nothing to
# commit" was read as "nothing to push": no change is not a failure.
#
#   0  the row was found and the URL written
#   1  the row was found and already held this URL
#   2  no row of that name
_write_row_url() {
    local name="$1" url="$2" tmp rc
    tmp="$(mktemp)"
    awk -v want="$name" -v url="$url" '
        BEGIN { FS="|"; OFS="|"; found = 0 }
        /^[[:space:]]*(app|website|proxy|mailbox)[[:space:]]*\|/ {
            n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n)
            if (n == want) {
                found = 1
                pad = $9
                sub(/^[ \t]*/, "", pad); sub(/[ \t]*$/, "", pad)
                $9 = " " url " "
            }
        }
        { print }
        END { exit found ? 0 : 2 }
    ' "$SITES_CONF" > "$tmp"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        if cmp -s "$SITES_CONF" "$tmp"; then
            rc=1
        else
            cat "$tmp" > "$SITES_CONF"
        fi
    fi
    rm -f "$tmp"
    return "$rc"
}

write_back_url() {
    local name="$1" url="$2" _wrote=0
    _write_row_url "$name" "$url" || _wrote=$?
    case "$_wrote" in
        0) print_success "$name: Repository field now holds the URL." ;;
        1) print_status "$name: the row already holds this URL." ;;
        *) print_action "$name: could not find its row to write the URL back. Do it by hand." ;;
    esac
    # Published either way. The row may already carry the URL in the tree this
    # run reads while the console clone, which is what everything else pulls
    # from, still says `new`.
    publish_config "$name" "$url"
}
# THE WRITE-BACK HAS TO BE RECORDED, or it is not a fact, only a local edit.
#
# On 2026-09-02 a repository was created, its URL written into the config, and
# then lost on the next refresh: the row said `new` again and asked to create a
# repository that already existed. So the URL goes into the config directory
# between the same CONFIG_SAVE_HOOK pre and post a console save uses.
publish_config() {  # <row name> <url>
    local name="$1" conf hook
    conf="$(conf_active /etc/hostings)"
    hook="$(sed -n 's/^[[:space:]]*CONFIG_SAVE_HOOK[[:space:]]*=[[:space:]]*//p' "$conf" 2>/dev/null \
            | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')"
    [ "$hook" = "-" ] && hook=""
    if [ -n "$hook" ] && ! bash "$hook" pre; then
        print_action "  Set the row's Repository field from the console, or it will ask to create it again."
        print_error "$name: the config directory could not be refreshed, so the URL was not written."
        return 1
    fi
    # Always, not only when the paths differ: "pre" resets the clone, which
    # throws away the write write_back_url made before it.
    local saved="$SITES_CONF"
    SITES_CONF="$conf"
    _write_row_url "$name" "$2" || true
    SITES_CONF="$saved"
    if [ -z "$hook" ]; then
        print_success "$name: the URL is in $conf."
        return 0
    fi
    if bash "$hook" post "provision_repo.sh" "Provision $name: record its repository URL"; then
        print_success "$name: the URL is recorded, so a refresh cannot lose it."
        return 0
    fi
    print_action "  Save anything from the console to retry recording it."
    print_error "$name: the URL is in $conf, but recording it failed."
    return 1
}

CREATED=0

# =============================================================================
# The create, as steps that report themselves
# =============================================================================
#
# The owner's decision 2026-09-03: ONE button press, and the operations underneath
# are separate so a scenario can be changed without breaking the others.
#
# What was wrong: one press did six things and a failure named none of them.
# The operator got a red line and had to read the whole log to find out how far
# it got, which on 2026-09-02 cost an evening.
#
# The steps were already six discrete calls. What was missing is that nothing
# recorded WHICH ran, so this adds the recording rather than rewriting the
# chain: each step is named, its outcome is kept, and the run ends with a table
# and a machine-readable file the console can show.
#
# NOT Jenkins jobs, and that is a deliberate limit. The console calls this
# script directly, so making each step a Jenkins job would mean the create
# needs Jenkins to be up. This is the layer that either shape needs first: the
# steps are named and independently reportable now, and turning one into a job
# is a change to that step alone.
STEP_NAMES=()
STEP_STATES=()
STEP_NOTES=()
CREATE_ROW=""

# run_step <name> <command...>
#
# The exit code decides, never the output: add_postfix.sh spent its whole life
# treating a benign warning as a rejection because it read the text instead.
run_step() {
    local name="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    printf '%s\n' "$out"
    STEP_NAMES+=("$name")
    if [ "$rc" -eq 0 ]; then
        STEP_STATES+=("ok")
        STEP_NOTES+=("")
    else
        STEP_STATES+=("failed")
        # The last line the step printed, which is where these scripts put the
        # reason. The whole output is already on screen above.
        STEP_NOTES+=("$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | tail -n 1)")
    fi
    return $rc
}

step_skipped() {
    STEP_NAMES+=("$1")
    STEP_STATES+=("skipped")
    STEP_NOTES+=("${2:-}")
}

# For work that has already happened by the time it can be recorded, such as
# the repository existing: the API call is what proved it, not a later check.
step_ok() {
    STEP_NAMES+=("$1")
    STEP_STATES+=("ok")
    STEP_NOTES+=("${2:-}")
}

# Printed, and written where the console can read it. A create that failed
# halfway is exactly when nobody wants to scroll a log.
# The --step name for a recorded step, or empty when it cannot be rerun.
#
# Derived here rather than passed at every call site: ten call sites would each
# have to repeat it, and one forgotten argument is a button that reruns the
# wrong thing. Creating the repository and pushing its branches map to nothing
# on purpose, so the console offers no button for them: by the time there is a
# step to rerun they have already happened.
step_id_for() {
    case "$1" in
        "write the Jenkins folder")                 printf 'jenkins-folder' ;;
        "write the repository back into the row")   printf 'write-back' ;;
        "seed the placeholder page")                printf 'seed' ;;
        # The app half of the same step. Both map to `seed`, and the rerun
        # works out which script to call from the row, so the console's button
        # appears on a failed application seed as well as a website one.
        "seed the starter project")                 printf 'seed' ;;
        "write the deploy jobs")                    printf 'deploy-jobs' ;;
        "start the first deploy")                   printf 'first-deploy' ;;
        # No id on purpose, so no rerun button. Both are the apply's work, done
        # here only because an application's first deploy needs them and the
        # apply runs afterwards. Rerunning them alone from the console would
        # duplicate what Make it live already does.
        "write the service unit")                   printf '' ;;
        "grant the pipeline its restart")           printf '' ;;
        *)                                          printf '' ;;
    esac
}

report_steps() {
    [ ${#STEP_NAMES[@]} -eq 0 ] && return 0
    echo ""
    print_header "What the create did"
    local i mark
    for i in "${!STEP_NAMES[@]}"; do
        case "${STEP_STATES[$i]}" in
            ok)      mark="\033[32m  ok     \033[0m" ;;
            failed)  mark="\033[31m  FAILED \033[0m" ;;
            *)       mark="\033[34m  skipped\033[0m" ;;
        esac
        printf "%b%s\n" "$mark" " ${STEP_NAMES[$i]}"
        [ -n "${STEP_NOTES[$i]}" ] && printf "\033[36m           %s\033[0m\n" "${STEP_NOTES[$i]}"
    done

    local f="/var/lib/hosting-manager/last-create.json" tmp
    [ -d /var/lib/hosting-manager ] || return 0
    tmp="$(mktemp)"
    {
        printf '{"row":"%s","when":"%s","steps":[' \
            "${CREATE_ROW//\"/}" "$(date -Is)"
        for i in "${!STEP_NAMES[@]}"; do
            [ "$i" -gt 0 ] && printf ','
            printf '{"name":"%s","id":"%s","state":"%s","note":"%s"}' \
                "${STEP_NAMES[$i]//\"/}" "$(step_id_for "${STEP_NAMES[$i]}")" \
                "${STEP_STATES[$i]}" \
                "$(printf '%s' "${STEP_NOTES[$i]}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        done
        printf ']}\n'
    } > "$tmp"
    install -m 0644 -o root -g root "$tmp" "$f" 2>/dev/null || true
    rm -f "$tmp"
}



# -----------------------------------------------------------------------------
# ONE STEP, FOR ONE ROW THAT ALREADY HAS ITS REPOSITORY.
#
# The step report says which part of a create stopped. This is what does
# something about it: rerun that part alone, rather than pressing the whole
# create again and asking GitHub to make a repository that is already there.
#
# The repository URL comes from the row, so a step can only run once the row
# actually names one. That is the same condition as "the create got past step
# one", which is the only situation any of these steps make sense in.
# -----------------------------------------------------------------------------
if [ "$MODE" = "step" ]; then
    _row_repo=""
    while IFS='|' read -r type name port path sub ds opts auth repo _rest; do
        name="$(trim "$name")"; repo="$(trim "$repo")"
        [ "$name" = "$STEP_ROW" ] || continue
        _row_repo="$repo"
        break
    done < <(conf_rows)

    if [ -z "$_row_repo" ]; then
        print_error "'$STEP_ROW' is not a row in $SITES_CONF."
        exit 1
    fi
    case "$_row_repo" in
        ""|-|new)
            print_error "'$STEP_ROW' has no repository yet, so there is no step to rerun."
            print_action "Run --create first: it is step one that makes the repository."
            exit 1 ;;
    esac

    CREATE_ROW="$STEP_ROW"
    print_header "Rerun one step: $STEP_ONLY"
    print_status "Row:        $STEP_ROW"
    print_status "Repository: $_row_repo"

    _rc=0
    case "$STEP_ONLY" in
        jenkins-folder)
            run_step "write the Jenkins folder" write_jenkins_job "$STEP_ROW" "$_row_repo" || _rc=1 ;;
        write-back)
            run_step "write the repository back into the row" \
                write_back_url "$STEP_ROW" "$_row_repo" || _rc=1 ;;
        seed)
            # Swapped by row type, exactly as the create path does it. Read
            # from the config here rather than carried in, because a rerun
            # starts with nothing but a row name.
            _step_type="$(conf_rows | awk -F'|' -v n="$STEP_ROW" \
                '{gsub(/^[ \t]+|[ \t]+$/,"",$1); gsub(/^[ \t]+|[ \t]+$/,"",$2)}
                 $2==n {print $1; exit}')"
            if [ "$_step_type" = "app" ]; then
                _seed_name="seed_app_project.sh"; _seed_label="seed the starter project"
            else
                _seed_name="seed_site_index.sh";  _seed_label="seed the placeholder page"
            fi
            _seed="$SCRIPT_DIR/$_seed_name"
            [ -f "$_seed" ] || _seed="/usr/local/lib/linuxbasics/hostings/scripts/$_seed_name"
            [ -f "$_seed" ] || _seed="/usr/local/lib/linuxbasics/hostings/scripts/$_seed_name"
            if [ -f "$_seed" ]; then
                run_step "$_seed_label" \
                    env SITES_CONF="$SITES_CONF" bash "$_seed" --push --only-row "$STEP_ROW" || _rc=1
            else
                print_error "$_seed_name not found."; _rc=1
            fi ;;
        deploy-jobs)
            _jobs="$SCRIPT_DIR/add_jenkins_site_jobs.sh"
            [ -f "$_jobs" ] || _jobs="/usr/local/lib/linuxbasics/hostings/scripts/add_jenkins_site_jobs.sh"
            if [ -f "$_jobs" ]; then
                run_step "write the deploy jobs" env SITES_CONF="$SITES_CONF" bash "$_jobs" || _rc=1
            else
                print_error "add_jenkins_site_jobs.sh not found."; _rc=1
            fi ;;
        first-deploy)
            _first="$SCRIPT_DIR/trigger_first_deploys.sh"
            [ -f "$_first" ] || _first="/usr/local/lib/linuxbasics/hostings/scripts/trigger_first_deploys.sh"
            if [ -f "$_first" ]; then
                run_step "start the first deploy" env SITES_CONF="$SITES_CONF" bash "$_first" || _rc=1
            else
                print_error "trigger_first_deploys.sh not found."; _rc=1
            fi ;;
    esac

    report_steps
    exit "$_rc"
fi
# ASKED ONCE, NOT PER ROW. Without this, a run on a machine where the App is
# not installed on the org gets as far as the push identity check and only then
# refuses, once per row, with no single line saying what is actually missing.
#
# Not wrapped in the spinner: it backgrounds the command, so ORG_TOKEN would be
# set in a subshell and lost, which is the trap org_token itself avoids.
if [ -n "$CREATE_ORG" ] && [ -n "${WANTED+set}" ] && [ ${#WANTED[@]} -gt 0 ]; then
    if org_token; then
        print_success "The App is installed on ${CREATE_ORG} and can create there."
    else
        print_error "The App is NOT installed on ${CREATE_ORG}, so nothing can be created there."
        print_action "Install it: https://github.com/settings/apps -> your App -> Install App -> ${CREATE_ORG}"
    fi
fi

# Before the first repository is made, not at the push that follows it.
[ -n "${WANTED+set}" ] && [ ${#WANTED[@]} -gt 0 ] && require_push_identity

for entry in ${WANTED+"${WANTED[@]}"}; do
    IFS="|" read -r name rowenvs mode rowbranch rowtype <<< "$entry"
    mapfile -t brs < <(branches_for "$rowenvs" "$mode" "$rowbranch")
    private="$(is_private_for "$mode")"
    default_branch="$(default_branch_for "$mode")"

    print_header "$name"

    # WHERE THIS ONE GOES. The org when there is one, the account the repository
    # tree came from otherwise.
    target_owner="${CREATE_ORG:-$OWNER}"

    create_token="$TOKEN"
    if [ -n "$CREATE_ORG" ]; then
        if ! org_token; then
            print_error "The App is not installed on ${CREATE_ORG}, or no App is configured."
            print_action "Install it: https://github.com/settings/apps -> your App -> Install App -> ${CREATE_ORG}"
            print_info "Nothing was created for this row."
            continue
        fi
        create_token="$ORG_TOKEN"
    fi

    # THE NAME IS CHECKED AGAINST BOTH OWNERS, and a clash on either stops it.
    #
    # GitHub allows the same name under two owners, so the second check is a
    # house rule. It exists because a transfer leaves a redirect behind: making
    # a repository with the name of one that moved away silently breaks the old
    # links. See .claude/docs/github-org-decisions.md, decision 6.
    clash=""
    unreadable_owner=""
    unreadable_code=""
    seen=""
    for own in "$target_owner" "$OWNER"; do
        [ -n "$own" ] || continue
        [ "$own" = "$seen" ] && continue
        seen="$own"
        # repo_exists answers three ways on purpose: absent and unreadable look
        # identical from here, and creating on top of the second is how a live
        # repository gets a duplicate.
        set +e
        repo_exists "$own" "$name"; look=$?
        set -e
        case "$look" in
            1) : ;;                         # free, which is what we want
            0) clash="$own"; break ;;
            *) unreadable_owner="$own"
               unreadable_code="$(repo_exists "$own" "$name" | cut -f2)"
               break ;;
        esac
    done

    if [ -n "$clash" ]; then
        print_info "${clash}/${name} already exists on GitHub, so nothing was created."
        print_action "Put its URL in the row by hand, or delete the repository first."
        continue
    fi
    if [ -n "$unreadable_owner" ]; then
        print_error "${unreadable_owner}/${name} could not be checked: GitHub answered HTTP ${unreadable_code}."
        case "$unreadable_code" in
            401) print_action "The token is expired or revoked. Reinstall it with --setup-key." ;;
            403) print_info "The token lacks the scope, or the rate limit is spent." ;;
            000) print_info "No response from ${GITHUB_API} at all." ;;
        esac
        print_info "Nothing was created for this row."
        continue
    fi

    body="$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"private":sys.argv[2]=="true","auto_init":False,"description":sys.argv[3]}))' \
            "$name" "$private" "Generated for $name on $(hostname)")"

    # CREATION IS THE CALL THE APP MAY ONLY MAKE IN AN ORGANISATION. That is
    # the whole reason a PAT was still on this machine; with GITHUB_ORG set,
    # the App does it and the PAT has no job left.
    create_path="/orgs/${CREATE_ORG}/repos"
    if [ -z "$CREATE_ORG" ]; then
        create_path="/user/repos"
        if [ "$TOKEN_SOURCE" = "the GitHub App" ]; then
            if create_token="$(read_token)" && [ -n "$create_token" ]; then
                print_info "Creating as the personal access token: an App cannot create under a personal account."
            else
                print_error "No personal access token, and a GitHub App cannot create a repository under a personal account."
                print_action "Set GITHUB_ORG in $SITES_CONF so the App can create, or put a token at $GITHUB_CRED_FILE"
                print_info "Nothing was created for this row."
                continue
            fi
        fi
    fi

    # THE ONE CALL THAT DOES NOT GO THROUGH github_api.sh, and it is not an
    # oversight. Creating under a PERSONAL account needs the personal access
    # token, which the interface does not carry and should not: it authenticates
    # as the App, deliberately, and an App cannot create there at all. With
    # GITHUB_ORG set this branch is never taken.
    if [ "$create_path" = "/user/repos" ] && [ -n "$create_token" ]; then
        created="$(curl -s -w '\n%{http_code}' -X POST \
            -H "Authorization: Bearer ${create_token}" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/json" \
            -d "$body" "${GITHUB_API}${create_path}")" || created=$'\n000'
    else
        created="$(api_with_code POST "$create_path" "$body")"
    fi
    create_code="$(printf '%s' "$created" | tail -n1)"
    ssh_url="$(printf '%s' "$created" | sed '$d' | json_field ssh_url)"

    # THE ROW GETS THE HTTPS URL, NOT THE SSH ONE.
    #
    # Whatever goes in the Repository field is what Jenkins clones with, and
    # Jenkins authenticates as the GitHub App over HTTPS since its own SSH key
    # was deleted on 2026-09-04. An ssh_url therefore produced a row that looked
    # perfect and a deploy that died at
    #
    #   ERROR: Error cloning remote repo 'origin'
    #
    # after the Jenkinsfile had already been fetched successfully, which makes
    # it read as a problem with the new repository rather than with its URL.
    #
    # The first push below uses it too, as the App, since 2026-09-13.
    row_url="$(printf '%s' "$created" | sed '$d' | json_field clone_url)"
    [ -z "$row_url" ] && row_url="$(repo_https_url "$ssh_url" 2>/dev/null || true)"

    if [ -z "$row_url" ]; then
        print_error "GitHub did not create ${target_owner}/${name}: HTTP ${create_code}."
        # The body says why, and nothing else does. A 403 here is almost always
        # the App being used for a call only a PAT may make.
        print_info "  $(printf '%s' "$created" | sed '$d' | json_field message)"
        continue
    fi
    print_success "Created ${target_owner}/${name} ($([ "$private" = "true" ] && echo private || echo PUBLIC))"

    # The first commit, made here rather than by auto_init, so every branch
    # starts from one commit.
    #
    # NO Jenkinsfile. It used to seed one, and that copy is why the wvr
    # repository carries a pipeline that always deploys live and reads a path
    # the deploy account cannot enter. Since 2026-08-23 the pipelines live in
    # the config repository, one job per environment, so a site repository holds content
    # and nothing else.
    #
    # As root, pushing as the GitHub App.
    work="$(mktemp -d)"
    (
        cd "$work"
        git init -q -b dev
        tee README.md >/dev/null <<MD
# ${name}

Created by provision_repo.sh on $(hostname).

Branches follow the DTAP table in /etc/hostings/hostings.conf:
dev is the trunk, and promotion is merging into test, accept or live.
MD
        git add -A
        git -c user.email="${APP_RUN_USER}@$(hostname)" \
            -c user.name="provision_repo.sh" \
            commit -q -m "Initial commit, generated"
        git remote add origin "$row_url"
        for b in "${brs[@]}"; do
            git branch -f "$b" dev >/dev/null 2>&1 || true
        done
        repo_git push -q origin "${brs[@]}"
    )
    rm -rf "$work"
    print_success "Pushed: ${brs[*]}"

    repo_set_default_branch "$target_owner" "$name" "$default_branch"
    print_success "Default branch: $default_branch"

    CREATE_ROW="$name"
    step_ok "create the repository" "${target_owner}/${name}"
    step_ok "push its branches" "${brs[*]}"

    run_step "write the Jenkins folder" write_jenkins_job "$name" "$row_url" || true
    run_step "write the repository back into the row" write_back_url "$name" "$row_url" || true

    # A page, on the same press. Without it a new site's repository holds a
    # README and nothing else, so every environment deploys perfectly and shows
    # nothing, and a working pipeline is indistinguishable from a broken one.
    #
    # AFTER write_back_url, not before: the seeder skips a row whose Repository
    # field still says `new`, and that field is what was just rewritten.
    #
    # Never fatal. The repository exists and its branches are pushed by this
    # point, so a failure here is a missing placeholder, not a failed creation.
    # THE SEED IS SWAPPED BY ROW TYPE, and that is the whole point of the two
    # scripts having the same flags.
    #
    # A website is proved by a page appearing. An application is not: a marker
    # index.html in an app repository leaves the build stage with no .csproj to
    # find, and the first thing that says so is a red Jenkins job.
    if [ "$rowtype" = "app" ]; then
        _seed_name="seed_app_project.sh"
        _seed_label="seed the starter project"
        _seed_miss="$name: the repository is there, but its starter project was not written."
    else
        _seed_name="seed_site_index.sh"
        _seed_label="seed the placeholder page"
        _seed_miss="$name: the repository is there, but its placeholder page was not written."
    fi

    SEED_SH="$SCRIPT_DIR/$_seed_name"
    [ -f "$SEED_SH" ] || SEED_SH="/usr/local/lib/linuxbasics/hostings/scripts/$_seed_name"
    [ -f "$SEED_SH" ] || SEED_SH="/usr/local/lib/linuxbasics/hostings/scripts/$_seed_name"
    if [ -f "$SEED_SH" ]; then
        run_step "$_seed_label" \
            env SITES_CONF="$SITES_CONF" bash "$SEED_SH" --push --only-row "$name" \
            || print_action "$_seed_miss"
    else
        step_skipped "$_seed_label" "$_seed_name not found"
    fi

    CREATED=$(( CREATED + 1 ))
done

unset TOKEN

if [ "$CREATED" -gt 0 ]; then
    # The deploy jobs, then Jenkins, then the first run. Without these two a
    # console create ended with a repository holding a page and nothing that
    # ever copies it to the document root: the multibranch folder written above
    # is not what deploys a site, add_jenkins_site_jobs.sh writes deploy-<env>
    # and trigger_first_deploys.sh is the only thing that runs them once. Both
    # lived in start_install.sh alone, so only a fresh flash got them.
    #
    # Never fatal. The repository and its branches exist by here, so a failure
    # is a site that has not been published yet, not a failed creation.
    sibling() {
        local n="$1"
        for c in "$SCRIPT_DIR/$n" \
                 "/usr/local/lib/linuxbasics/hostings/scripts/$n" \
                 "/usr/local/lib/linuxbasics/hostings/scripts/$n"; do
            [ -f "$c" ] && { printf '%s' "$c"; return 0; }
        done
        return 1
    }

    if JOBS_SH="$(sibling add_jenkins_site_jobs.sh)"; then
        run_step "write the deploy jobs" env SITES_CONF="$SITES_CONF" bash "$JOBS_SH" \
            || print_action "The deploy jobs were not written. Run $JOBS_SH by hand."
    else
        step_skipped "write the deploy jobs" "add_jenkins_site_jobs.sh not found"
        print_action "add_jenkins_site_jobs.sh not found, so no deploy job was written."
    fi

    # add_jenkins_site_jobs.sh above already reloaded, and a reload is not
    # instant: Jenkins re-reads every config.xml and answers 503 until it is
    # done. A second POST straight after therefore FAILS, which is why one run
    # printed "Jenkins reloaded" and "Could not reload Jenkins" in that order.
    # Measured 2026-09-03: two reloads back to back give 302 then 503.
    #
    # So this waits for the reload that already happened rather than asking for
    # another one. Triggering a build while Jenkins is mid-reload is worse than
    # slow: the queue item is created against jobs that are then re-read, and it
    # sits on "Waiting for next available executor" with both executors idle.
    if systemctl is-active --quiet jenkins; then
        _url="${JENKINS_URL:-http://127.0.0.1:11002}"
        _tok="${TOKEN_FILE:-/var/lib/hosting-manager/jenkins-token}"
        _ready=0
        for _i in $(seq 1 60); do
            if curl -fsS -o /dev/null --max-time 5 \
                    -u "$(head -n1 "$_tok" 2>/dev/null)" "${_url}/api/json?tree=mode" 2>/dev/null; then
                _ready=1; break
            fi
            sleep 2
        done
        if [ "$_ready" -eq 1 ]; then
            step_ok "wait for Jenkins to come back"
            print_success "Jenkins is back after the reload and sees the new jobs."
        else
            step_skipped "wait for Jenkins to come back" "no answer within two minutes"
            print_action "Jenkins did not answer within two minutes of the reload."
            print_action "  The jobs are on disk. Reload it from Manage Jenkins."
        fi
    else
        step_skipped "wait for Jenkins to come back" "jenkins is not running"
    fi

    # AN APPLICATION NEEDS ITS UNIT BEFORE ITS FIRST DEPLOY.
    #
    # A website's deploy copies files into a document root and Apache serves
    # them whether or not the vhost has been written yet, so triggering before
    # the apply costs nothing. An application's deploy ENDS by restarting its
    # unit, and the unit is written by add_app_services.sh during the apply.
    # Trigger first and the build publishes correctly and then dies with
    # "Unit app-<name>.service not found", reported as a failed deploy of a
    # perfectly good build.
    #
    # Measured on blazortest, 2026-09-04: build 3 published the files and
    # failed at the restart, and the unit appeared only when the apply ran.
    #
    # Writing the unit here rather than reordering the apply, because the apply
    # is a Jenkins job the console starts afterwards and this script cannot
    # wait for it.
    if [ "$rowtype" = "app" ]; then
        if SERVICES_SH="$(sibling add_app_services.sh)"; then
            run_step "write the service unit" \
                env SITES_CONF="$SITES_CONF" bash "$SERVICES_SH" \
                || print_action "$name: the unit was not written, so its first deploy will fail at the restart."
        else
            step_skipped "write the service unit" "add_app_services.sh not found"
        fi
        # The unit is useless to a pipeline it may not restart, and that file
        # is written per row.
        if PERMS_SH="$(sibling add_jenkins_deploy_permissions.sh)"; then
            run_step "grant the pipeline its restart" \
                env SITES_CONF="$SITES_CONF" bash "$PERMS_SH" \
                || print_action "$name: the deploy account may not restart the unit yet."
        else
            step_skipped "grant the pipeline its restart" "add_jenkins_deploy_permissions.sh not found"
        fi
    fi

    if FIRST_SH="$(sibling trigger_first_deploys.sh)"; then
        run_step "start the first deploy" env SITES_CONF="$SITES_CONF" bash "$FIRST_SH" \
            || print_action "The first deploy did not start. Run $FIRST_SH by hand."
    else
        step_skipped "start the first deploy" "trigger_first_deploys.sh not found"
        print_action "trigger_first_deploys.sh not found, so nothing published the new site."
    fi

    # The Repositories tab and the name-clash check read a cached list, so a
    # repository created here has to invalidate it or the page keeps offering
    # its name as free.
    rm -f /var/lib/hosting-manager/repo-names.json 2>/dev/null || true

    report_steps

    echo ""
    print_success "$CREATED repository(ies) created."
    print_action "hostings.conf changed. Commit and push it, or the next run creates them again:"
    print_action "  cd $REPO_ROOT && git add /etc/hostings/hostings.conf && git commit && git push"
fi
