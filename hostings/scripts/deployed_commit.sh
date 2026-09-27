#!/usr/bin/env bash
set -e

. "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }

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
# What is deployed for one row and environment, and whether the branch has
# moved since.
#
#   deployed_commit.sh <row> <env>
#
# The owner, 2026-09-10, item 104 feature 5: a row that says "Succeeded" says
# nothing about whether it succeeded at deploying THIS morning's commit. The
# deploy already records what it put on the machine; this compares that against
# what the branch points at now.
#
# READ ONLY. It writes nothing, starts nothing and creates no clone: the remote
# side is one `git ls-remote`, which asks for a ref and downloads no objects.
#
# BOUNDED THE SAME TWO WAYS as every other job call the page can make: the row
# must be in the published config, and the environment must be one ENVS
# declares. Neither half of a path is ever taken from the caller.
#
# Output is JSON on stdout:
#
#   {"deployed":"0146693","head":"9fa21c8","behind":true,"branch":"live"}
#
# `behind` is null when it could not be worked out, which is NOT the same as
# false: a page that shows "up to date" because a lookup failed is worse than
# one that says it does not know.
# =============================================================================

# No print_* helpers: everything on stdout is JSON, and a coloured status line
# in the middle of it would break the only caller.

if [ "$EUID" -ne 0 ]; then
    echo '{"error":"must run as root"}'
    exit 1
fi

ROW="${1:-}"
ENV="${2:-}"
CONF="${SITES_CONF:-$(conf_active /etc/hostings)}"
MARKER_DIR="/var/lib/jenkins/last-deployed"

if [ -z "$ROW" ] || [ -z "$ENV" ]; then
    echo '{"error":"usage: deployed_commit.sh <row> <env>"}'
    exit 1
fi

ENVS_LINE="$(grep -E '^[[:space:]]*ENVS[[:space:]]*=' "$CONF" 2>/dev/null \
             | head -1 | cut -d= -f2- | tr -d ' \r' | tr ',' ' ')"
case " ${ENVS_LINE:-live test accept skunk} " in
    *" $ENV "*) ;;
    *) echo '{"error":"not an environment"}'; exit 1 ;;
esac

if ! awk -F'|' -v n="$ROW" '
        /^[[:space:]]*#/ { next }
        NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                 if ($2 == n) found = 1 }
        END { exit !found }' "$CONF" 2>/dev/null; then
    echo '{"error":"not a row"}'
    exit 1
fi

# WHICH BRANCH AND WHICH REPOSITORY IS ASKED, NOT WORKED OUT AGAIN.
#
# resolve_deploy_target.sh is what the deploy job itself uses, and its rule is
# not "the environment is the branch": it reads <ENV>_BRANCH from the config,
# and the row's own Branch wins only when that environment branch does not
# exist on the remote. A first version of this script reimplemented a simpler
# rule and immediately disagreed with the job, reporting `main` for a live
# deploy the job had done from `live`.
#
# Absolute path, no $SCRIPT_DIR: this file is installed into /usr/local/sbin
# where it has no siblings, which is the trap three scripts fell into on
# 2026-09-02.
RESOLVER="/usr/local/lib/linuxbasics/hostings/scripts/resolve_deploy_target.sh"
[ -f "$RESOLVER" ] || RESOLVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve_deploy_target.sh"

if [ ! -f "$RESOLVER" ]; then
    echo '{"deployed":null,"head":null,"behind":null,"reason":"no resolver"}'
    exit 0
fi

TARGET="$(SITES_CONF="$CONF" bash "$RESOLVER" "$ROW" "$ENV" 2>/dev/null | tail -n1 || true)"
BRANCH="${TARGET%%|*}"
_rest="${TARGET#*|}"
REPO="${_rest%%|*}"

case "$REPO" in
    ''|'-'|'new'|'New'|'NEW')
        echo '{"deployed":null,"head":null,"behind":null,"reason":"no repository"}'
        exit 0
        ;;
esac
[ -z "$BRANCH" ] && BRANCH="$ENV"

DEPLOYED=""
[ -f "${MARKER_DIR}/${ROW}-${ENV}.sha" ] && \
    DEPLOYED="$(tr -d ' \r\n' < "${MARKER_DIR}/${ROW}-${ENV}.sha")"

# ls-remote asks the server for one ref and transfers no objects, so this is
# cheap enough to answer a page with. It authenticates as the GitHub App the
# same way every other outbound call here does; a private repository with no
# token simply comes back empty, which is reported as "not known".
# The minter lives in the PIPELINE TREE, not /usr/local/sbin: that directory
# holds only what the console and sudoers call by name, and this is neither.
# Guessing /usr/local/sbin cost a run that reported "the branch could not be
# read" for a repository the App can reach perfectly well.
#
# The OWNER is passed, because one App installed on two accounts has two
# installation ids and a token minted for the wrong one answers 404 for a
# repository that exists. github_app_token.sh:28 is the record of that costing
# most of a setup.
HEAD_SHA=""
TOKEN=""
MINTER="/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"
[ -f "$MINTER" ] || MINTER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github_app_token.sh"
if [ -f "$MINTER" ]; then
    OWNER=""
    case "$REPO" in
        https://github.com/*)
            OWNER="${REPO#https://github.com/}"
            OWNER="${OWNER%%/*}"
            ;;
    esac
    TOKEN="$(SITES_CONF="$CONF" bash "$MINTER" ${OWNER:+"$OWNER"} 2>/dev/null || true)"
fi

URL="$REPO"
if [ -n "$TOKEN" ]; then
    case "$URL" in
        https://github.com/*) URL="https://x-access-token:${TOKEN}@github.com/${URL#https://github.com/}" ;;
    esac
fi

HEAD_SHA="$(GIT_TERMINAL_PROMPT=0 timeout 15 git ls-remote "$URL" \
            "refs/heads/${BRANCH}" 2>/dev/null | awk '{print $1; exit}')"

# null, not false. "Up to date" because a lookup failed is a lie the page would
# have no way to notice.
BEHIND=null
if [ -n "$DEPLOYED" ] && [ -n "$HEAD_SHA" ]; then
    if [ "$DEPLOYED" = "$HEAD_SHA" ]; then BEHIND=false; else BEHIND=true; fi
fi

json_str() {
    [ -z "$1" ] && { printf 'null'; return; }
    printf '"%s"' "$1"
}

printf '{"deployed":%s,"head":%s,"behind":%s,"branch":%s}\n' \
    "$(json_str "$DEPLOYED")" "$(json_str "$HEAD_SHA")" \
    "$BEHIND" "$(json_str "$BRANCH")"
exit 0
