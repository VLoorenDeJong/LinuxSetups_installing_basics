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
# A copy of this repository that root runs and the deploy account cannot write.
#
#   sudo bash add_pipeline_scripts.sh           create or refresh it
#   sudo bash add_pipeline_scripts.sh --check   report, change nothing
#
# WHY THIS EXISTS
#
# The pipeline ran its scripts out of Jenkins' own workspace, and the sudoers
# grants named them by RELATIVE path because that is what the Jenkinsfiles
# typed. sudo matches the command as typed, so it resolved inside a directory
# the jenkins account owns. Jenkins could edit deploy_app.sh and then run it
# through sudo: arbitrary root, from an account that only needed to be able to
# start a build.
#
# So the scripts sudo runs now live here, owned by root, mode 0755, and the
# jenkins account cannot write a byte of it. The grants name absolute paths
# under this directory and nothing else.
#
# WHERE THE CONTENT COMES FROM, AND WHY THAT IS STILL SAFE
#
# From GitHub, by a git pull run as root. NOT from the workspace: copying out
# of the workspace would reintroduce exactly the hole this closes, one step
# further back. Whoever can push to this repository can still change what root
# runs, and that is both unavoidable and already true of every install script
# on the machine.
#
# WHAT STAYS IN THE WORKSPACE
#
# Everything else. The pipeline still checks the repo out to read a Jenkinsfile
# and to run things that need no privilege at all. Only the sudo path moved.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_hint()    { printf "   %s\n" "$1"; }

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

CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) echo "Usage: sudo $0 [--check]" >&2; exit 1 ;;
        *) print_error "Unknown argument '$1'"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This installs a root-owned tree, so it needs sudo."
    print_hint "run with: sudo $0 $*"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIPELINE_ROOT="${PIPELINE_ROOT:-/usr/local/lib/linuxbasics}"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }

print_header "Pipeline scripts"

# =============================================================================
# Pre-flight
# =============================================================================
ERRORS=()
command -v git >/dev/null 2>&1 || ERRORS+=("git is not installed.")

GIT_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
GIT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$GIT_URL" ]    || ERRORS+=("Could not read the git remote of $REPO_ROOT.")
[ -n "$GIT_BRANCH" ] || ERRORS+=("Could not read the current branch of $REPO_ROOT.")

# HTTPS with a GitHub App token, not ssh. root has no key on this machine and
# giving it one is a second thing to rotate; the App already exists, its tokens
# last an hour, and nothing has to be stored.
case "$GIT_URL" in
    git@*:*)
        GIT_URL="https://github.com/$(printf '%s' "$GIT_URL" | sed -E 's#^[^:]+:##')"
        ;;
esac

# THIS SCRIPT KEEPS ITS OWN COPY, DELIBERATELY, and it is the one place in the
# clone layer that does. 2026-09-12: six other scripts moved onto repo_git in
# repo_host.sh, and this one cannot, because its JOB is to create the tree that
# holds repo_host.sh. A bootstrap that depends on what it installs has nothing
# to run on a machine where the tree is absent, broken, or mid-upgrade, which
# are the three cases this script exists for.
#
# Same shape as the first-clone SSH key item 91 settled: a genuine chicken and
# egg, written down once so nobody has to rediscover it.
#
# What that costs is honest and small: if repo_git changes, this copy has to be
# changed with it. credential.useHttpPath is the part that must not be dropped.
#
# Authentication goes through ONE file, git_credential_github_app.sh, and the
# reason is measured rather than tidy. This used to mint a single token here,
# with no owner named, and hand it to every remote including line 205's
# submodule update. The submodules have two different owners:
#
#   the config repository                     <org>      (org)      private
#   a private submodule                      <owner>  (personal) private
#   the config repository_installing_basics   <owner>  (personal) public
#
# So the org token got "remote: Repository not found." for a private submodule, which is
# a 404 for the WRONG INSTALLATION and not a missing repository. The pipeline
# tree could not be refreshed and every Jenkins job died at its checkout.
#
# credential.useHttpPath is what makes it possible to choose: without it git
# tells the helper the host only, and every github.com URL looks the same.
#
# See .claude/docs/handoff-jenkins-submodule-token.md.
CRED_HELPER=""
for _c in "$SCRIPT_DIR/git_credential_github_app.sh" \
          "$PIPELINE_ROOT/hostings/scripts/git_credential_github_app.sh"; do
    [ -f "$_c" ] && { CRED_HELPER="$_c"; break; }
done
[ -n "$CRED_HELPER" ] || ERRORS+=("git_credential_github_app.sh was not found beside $0.")

# The token never reaches the URL or the argument list: anything on this machine
# can read /proc/<pid>/cmdline while the clone runs, and a token written into a
# URL ends up in .git/config. The helper writes it to stdout, over a pipe.
#
# GIT_CONFIG_PARAMETERS carries -c settings into child git processes, which is
# how the helper reaches the per-submodule fetches line 205 starts.
#
# "!bash <path>" rather than the path alone, because this script chmods every
# file in the tree to 644 further down. A helper named by path must be
# executable; one behind "!" is a shell command and does not care.
git_with_token() {
    SITES_CONF="$(conf_active "/etc/hostings")" \
    git -c credential.helper= \
        -c credential.helper="!bash '$CRED_HELPER'" \
        -c credential.useHttpPath=true \
        "$@"
}

if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

print_info "Source: ${GIT_URL} (${GIT_BRANCH})"
print_info "Target: ${PIPELINE_ROOT}, root owned"

if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -d "$PIPELINE_ROOT/.git" ]; then
        cur="$(git -C "$PIPELINE_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        print_info "Already installed, at ${cur}."
    else
        print_action "Not installed. Create it: sudo $0"
    fi
    exit 0
fi

# =============================================================================
# The tree
#
# A clone rather than a copy, so refreshing it is a pull from GitHub and never
# a read of anything the deploy account can write.
#
# ONE REFRESH AT A TIME. A push starts about eleven Jenkins jobs, and two of
# them run this script: Jenkinsfile.machine--apply-config and
# Jenkinsfile.app-1-build-and-deploy. Several processes then fetch and
# `reset --hard` the SAME tree, one loses git's index.lock, and the loser
# printed "Could not refresh" over a tree the winner had just brought fully up
# to date. Measured 2026-09-12: three concurrent runs, one failure, two
# successes, and the tree correct afterwards.
#
# A step that reports failure while the work succeeded is the same false
# reading as items 110 and 95, only the other way round, so it is serialised
# rather than explained in a comment.
# =============================================================================
REFRESH_LOCK="/var/lock/hostings-pipeline-refresh.lock"

if [ -d "$PIPELINE_ROOT/.git" ]; then
    spinner_start "Refreshing ${PIPELINE_ROOT}..."
    # The reason git gives is kept, not swallowed: "could not read Username"
    # and "Unable to create index.lock" are different faults with different
    # fixes, and the old message could not tell them apart.
    refresh_err="$( { flock 9
        git_with_token -C "$PIPELINE_ROOT" fetch -q origin "$GIT_BRANCH" \
        && git -C "$PIPELINE_ROOT" reset -q --hard "origin/${GIT_BRANCH}"
      } 9>"$REFRESH_LOCK" 2>&1 )" && refresh_ok=1 || refresh_ok=0
    if [ "$refresh_ok" = "1" ]; then
        spinner_stop
        print_success "Refreshed to $(git -C "$PIPELINE_ROOT" rev-parse --short HEAD)."
    else
        spinner_stop
        print_error "Could not refresh ${PIPELINE_ROOT} from ${GIT_URL}."
        [ -n "$refresh_err" ] && print_error "git said: $(printf '%s' "$refresh_err" | tail -n 3)"
        print_hint "check the App token: sudo bash hostings/scripts/add_pipeline_scripts.sh --check"
        exit 1
    fi
else
    spinner_start "Cloning into ${PIPELINE_ROOT}..."
    rm -rf "$PIPELINE_ROOT"
    if git_with_token clone -q --branch "$GIT_BRANCH" "$GIT_URL" "$PIPELINE_ROOT" 2>/dev/null; then
        spinner_stop
        print_success "Cloned at $(git -C "$PIPELINE_ROOT" rev-parse --short HEAD)."
    else
        spinner_stop
        print_error "Could not clone ${GIT_URL} into ${PIPELINE_ROOT}."
        print_hint "the GitHub App token is how root authenticates here."
        print_hint "check it with: sudo bash hostings/scripts/add_github_app.sh --test-only"
        exit 1
    fi
fi

# This script sets the modes here itself, further down, so git must not report
# its own chmod as a local change. Without this the chmod pass dirtied three
# LinuxBasics files and every later run refused to check the submodule out.
git -C "$PIPELINE_ROOT" config core.fileMode false
git -C "$PIPELINE_ROOT" submodule foreach --recursive \
    'git config core.fileMode false' >/dev/null 2>&1 || true

# The submodule carries scripts the pipeline runs, so it has to be here too.
# --force, because this tree is a mirror of the branch and never a place to
# edit: anything local in it is something to discard, not something to keep.
if ! git_with_token -C "$PIPELINE_ROOT" submodule update --init --recursive --force >/dev/null 2>&1; then
    print_action "Submodules did not initialise. LinuxBasics scripts will be missing."
    git_with_token -C "$PIPELINE_ROOT" submodule update --init --recursive --force 2>&1 | tail -5
fi

# =============================================================================
# Ownership is the whole point
# =============================================================================
chown -R root:root "$PIPELINE_ROOT"
find "$PIPELINE_ROOT" -type d -exec chmod 755 {} +
find "$PIPELINE_ROOT" -type f -exec chmod 644 {} +
find "$PIPELINE_ROOT" -type f -name '*.sh' -exec chmod 755 {} +

CI_USER="$(sed -n 's/^[[:space:]]*APP_RUN_USER[[:space:]]*=//p' "$(conf_active "/etc/hostings")" 2>/dev/null | head -1 | tr -d ' ')"
CI_USER="${CI_USER:-jenkins}"

if id "$CI_USER" >/dev/null 2>&1; then
    if sudo -n -u "$CI_USER" test -w "$PIPELINE_ROOT/hostings/scripts/deploy_app.sh" 2>/dev/null; then
        print_error "${CI_USER} can still write the scripts root runs. The whole point is lost."
        exit 1
    fi
    print_success "${CI_USER} cannot write anything under ${PIPELINE_ROOT}."
fi

echo ""
print_success "Pipeline scripts installed."
print_info "The sudoers grants and the Jenkinsfiles both name paths under here."
print_action "Refresh it after every change to this repo: sudo $0"
