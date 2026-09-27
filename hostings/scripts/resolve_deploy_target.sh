#!/usr/bin/env bash
set -e

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

# =============================================================================
# Answer "which branch and which repository" for one row in one environment.
#
#   resolve_deploy_target.sh example_org test   ->  test|https://github.com/...
#
# One line, pipe separated, so a pipeline can read it without parsing the
# config itself. Either field may be empty; the caller decides whether that is
# fatal, because a row with no repository is a real state for a site that is
# not in git yet.
#
# THIS EXISTS SO THE LOOKUP CAN BE TESTED. It was shell embedded in a Groovy
# string, where a quoting mistake shows up as a failed build rather than as a
# wrong answer, and where nobody can run it to see what it says.
#
# THE BRANCH IS NOT THE ENVIRONMENT. skunkworks is the branch of the skunk
# environment, and reading one as the other is the bug this file exists to keep
# fixed: a deploy that took the branch name would have published skunkworks
# content to an environment that does not exist.
# =============================================================================

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

ROW="${1:-}"
ENV_NAME="${2:-}"

if [ "$ROW" = "--envs" ]; then
    MODE="envs"
    ROW="$ENV_NAME"
    ENV_NAME=""
else
    MODE="target"
fi

if [ -z "$ROW" ] || { [ "$MODE" = "target" ] && [ -z "$ENV_NAME" ]; }; then
    echo "Usage: $0 <row> <environment>" >&2
    echo "       $0 --envs <row>          the environments the row is in" >&2
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
    exit 1
fi

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

# The environments this row exists in, one line, space separated. A blank Envs
# field means every environment, which is the same reading add_jenkins_site_jobs.sh
# and the console use.
if [ "$MODE" = "envs" ]; then
    ALL_ENVS="$(sed -n 's/^[[:space:]]*ENVS[[:space:]]*=//p' "$SITES_CONF" | head -1)"
    ALL_ENVS="$(trim "${ALL_ENVS%%#*}")"
    ROWENVS="$(grep -v '^[[:space:]]*#' "$SITES_CONF" | grep '|' \
        | awk -F'|' -v n="$ROW" '{ gsub(/ /, "", $2); if ($2 == n) { print $11; exit } }')"
    ROWENVS="$(trim "$ROWENVS")"
    [ -n "$ROWENVS" ] || ROWENVS="$ALL_ENVS"
    printf '%s\n' "$ROWENVS" | tr ',' ' ' | tr -s ' '
    exit 0
fi

ENV_UPPER="$(printf '%s' "$ENV_NAME" | tr '[:lower:]' '[:upper:]')"

BRANCH="$(sed -n "s/^[[:space:]]*${ENV_UPPER}_BRANCH[[:space:]]*=//p" "$SITES_CONF" | head -1)"
BRANCH="$(trim "${BRANCH%%#*}")"

# The ninth field is the repository. Read by number rather than by name because
# that is how every other script here reads a row, and a mismatch between two
# readers is the kind of thing nobody finds quickly.
REPO="$(grep -v '^[[:space:]]*#' "$SITES_CONF" | grep '|' \
    | awk -F'|' -v n="$ROW" '{ gsub(/ /, "", $2); if ($2 == n) { print $9; exit } }')"
REPO="$(trim "$REPO")"

# THE ENVIRONMENT'S BRANCH IF THE REPOSITORY HAS IT, THE ROW'S IF NOT.
#
# WHY THE ROW HAS ONE. A site under DTAP has a branch per environment, so the
# environment names the branch and nothing needs writing down. A portfolio
# repository is not laid out that way: `main` is its only branch, and five rows
# deploy that same `main` into five different environments. Reading LIVE_BRANCH
# there sends the clone at a branch that has never existed.
#
# It USED TO WIN OUTRIGHT: a row with a Branch set deployed that branch in every
# environment, whatever the repository held. Changed 2026-09-09 with the field's
# meaning: it is the branch a row's code comes FROM, and the environment
# branches are cut from it. Once live/test/accept/skunkworks exist, each
# environment deploys its own again, which is what the drawer says will happen.
#
# The repository is asked, rather than the config guessed at: one ls-remote,
# against a clone that is about to happen anyway. If it cannot be asked the row
# branch wins, which is the old behaviour and the safe direction: a name that
# exists beats one that may not.
ROWBRANCH="$(grep -v '^[[:space:]]*#' "$SITES_CONF" | grep '|' \
    | awk -F'|' -v n="$ROW" '{ gsub(/ /, "", $2); if ($2 == n) { print $10; exit } }')"
ROWBRANCH="$(trim "$ROWBRANCH")"

if [ -n "$ROWBRANCH" ] && [ "$ROWBRANCH" != "-" ]; then
    ENV_BRANCH_EXISTS=""
    if [ -n "$REPO" ] && [ "$REPO" != "-" ]; then
        # The token is minted here rather than passed in: this runs from a
        # Jenkins job, and a token in a job parameter is a token in a log.
        _TOK=""
        for _sh in /usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh; do
            [ -f "$_sh" ] || continue
            _TOK="$(SITES_CONF="$SITES_CONF" bash "$_sh" 2>/dev/null || true)"
        done
        if [ -n "$_TOK" ]; then
            ENV_BRANCH_EXISTS="$(GH_TOKEN="$_TOK" git \
                -c credential.helper= \
                -c credential.helper="$GIT_CRED" -c credential.useHttpPath=true \
                ls-remote --heads "$REPO" "$BRANCH" 2>/dev/null || true)"
        else
            ENV_BRANCH_EXISTS="$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$REPO" "$BRANCH" 2>/dev/null || true)"
        fi
        unset _TOK _sh
    fi
    [ -z "$ENV_BRANCH_EXISTS" ] && BRANCH="$ROWBRANCH"
fi

# The .NET project to publish, for an app row.
#
# NOT IN THE CONFIG, and it does not need to be. The fourth field is where the
# built dll LANDS on this machine, which says nothing about the repository
# layout: `portfolio/mvp/PortfolioMVP.dll` is a deploy path, and the project in
# the repository is `PortfolioMVP`.
#
# The dll's own name is the link. .NET names the assembly after the project, so
# the directory holding the .csproj is the dll name without its extension.
# Checked against both repositories on 2026-08-23: PortfolioMVP,
# progress-app, ISPAddressCheckerAPI and
# ISPAddressCheckerStatusDashboard all exist exactly so.
#
# A repository that breaks that habit needs the project written down somewhere,
# and this is where the reader should be told so rather than left guessing.
DLLPATH="$(grep -v '^[[:space:]]*#' "$SITES_CONF" | grep '|' \
    | awk -F'|' -v n="$ROW" '{ gsub(/ /, "", $2); if ($2 == n) { print $4; exit } }')"
DLLPATH="$(trim "$DLLPATH")"
PROJECT=""
case "$DLLPATH" in
    *.dll)
        PROJECT="${DLLPATH##*/}"
        PROJECT="${PROJECT%.dll}"
        ;;
    # A Docker row (item 140) names its Dockerfile, and the pipeline builds that.
    Dockerfile|*/Dockerfile)
        PROJECT="docker:$DLLPATH"
        ;;
esac

printf '%s|%s|%s\n' "$BRANCH" "$REPO" "$PROJECT"
