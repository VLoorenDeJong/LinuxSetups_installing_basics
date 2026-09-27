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
# THE INLINE FALLBACK IS GONE, 2026-09-12. It was principle 2b's read-path
# copy, and it had drifted: four scripts carried the same ten lines and one of
# them had dropped credential.useHttpPath, which is the whole point. The helper
# now arrives through repo_host.sh, which resolves it in one place and in both
# trees, so there is nothing left to drift.
# =============================================================================
# Through repo_host.sh: repo_git is git with the forge's credential helper
# already configured. Four scripts carried this identical ten-line block, and
# md5 said so: e4469ff in seed_app_project.sh, list_repo_branches.sh and
# read_appsettings.sh, byte for byte.
_iface() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}
# shellcheck source=/dev/null
. "$(_iface repo_host.sh)"

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
# The branches in one repository, as JSON, for the row drawer.
#
# WHAT IT IS FOR. The drawer's Source branch box was free text, so the operator
# typed a branch name and found out whether it existed at the first deploy. This
# is what fills a dropdown with the branches that are actually there, and what
# lets the drawer say which environment branches are missing.
#
# ls-remote, NOT a clone. The question is only "what branches exist", and a
# clone of a repository with large assets to answer it is the shape
# list_startup_projects.sh has to pay for reading a .csproj. This is one round
# trip and no disk.
#
# WHAT CROSSES FROM THE BROWSER, and the bound on it. A clone URL, because the
# drawer has one before the row is saved and therefore before anything can look
# it up in the config. It is refused unless it is
#
#   https://github.com/<owner>/<name>[.git]
#
# with owner and name made of the characters GitHub allows in them. So the page
# cannot point this at another host, at a path with a traversal in it, or at
# anything carrying a credential, and the worst it can name is a public GitHub
# repository, which it could have read from the browser anyway.
#
# The App token is used when one can be minted: without it a private repository
# answers "not found", which reads as "no branches" and would be a lie.
#
# Output, on stdout, always JSON:
#
#   {"ok":true,"owner":"<org>","name":"x","default":"main",
#    "branches":["dev","live","main"]}
#   {"ok":false,"error":"why"}
#
# Usage:
#   sudo ./list_repo_branches.sh https://github.com/<org>/x.git
# =============================================================================

# No print_* helpers: everything on stdout is JSON, and a coloured status line
# in the middle of it would break the only caller.

json_err() {
    printf '{"ok":false,"error":%s}\n' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
    exit 0
}

if [ "$EUID" -ne 0 ]; then
    json_err "must run as root"
fi

URL="${1:-}"
[ -n "$URL" ] || json_err "no repository URL was given"

# The whole bound, in one place. Anchored at both ends, so nothing may follow.
if ! printf '%s' "$URL" | grep -qE '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$'; then
    json_err "that is not an https://github.com/<owner>/<name> URL"
fi

SLUG="${URL#https://github.com/}"
SLUG="${SLUG%.git}"
OWNER="${SLUG%%/*}"
NAME="${SLUG##*/}"

case "$OWNER" in .|..) json_err "that owner is not a name" ;; esac
case "$NAME"  in .|..) json_err "that repository is not a name" ;; esac

# =============================================================================
# The token
#
# Minted at the point of use and never stored. It reaches git through the
# environment and a credential helper, never the argument list: anything on this
# machine can read /proc/<pid>/cmdline while git runs.
#
# A repository the App cannot see still answers if it is public, which is
# correct: the question is what branches exist, not who may write them.
# =============================================================================
GH_TOKEN=""
for _sh in /usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh \
           "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github_app_token.sh"; do
    [ -f "$_sh" ] || continue
    GH_TOKEN="$(SITES_CONF= \
        bash "$_sh" 2>/dev/null || true)"
    [ -n "$GH_TOKEN" ] && break
done
unset _sh
export GH_TOKEN


ls_remote() {
    if [ -n "$GH_TOKEN" ]; then
        # repo_git, which also sets credential.useHttpPath. This call set the
        # helper WITHOUT it, so the helper was told the host only and every URL
        # on the forge looked identical: exactly the fault the interface exists
        # to stop each caller repeating.
        repo_git ls-remote --symref "$URL" 2>&1
    else
        GIT_TERMINAL_PROMPT=0 git ls-remote --symref "$URL" 2>&1
    fi
}

# --symref and NO --heads: --heads filters HEAD out of the answer, and HEAD is the
# only thing that names the default branch. Measured 2026-09-09, when every
# lookup came back with an empty default. refs/heads/ is filtered below instead,
# so tags never reach the list.
OUT="$(ls_remote || true)"

if [ -z "$OUT" ]; then
    json_err "that repository has no branches, or it could not be read"
fi
case "$OUT" in
    *"not found"*|*"Repository not found"*|*"could not read"*|*"Authentication failed"*|*fatal:*)
        json_err "$(printf '%s' "$OUT" | tr '\n' ' ' | tail -c 160)"
        ;;
esac

DEFAULT="$(printf '%s' "$OUT" | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p' | head -1)"

BRANCHES="$(printf '%s' "$OUT" \
    | sed -n 's#^[0-9a-f]\{7,\}[[:space:]]*refs/heads/##p' \
    | sort)"

if [ -z "$BRANCHES" ]; then
    json_err "that repository has no branches yet"
fi

# Built by hand rather than with jq: a list of branch names and one default is
# not worth a dependency the page's own path then relies on. Every name is
# escaped the same way the error above is.
esc_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

LIST=""
while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ -n "$LIST" ] && LIST="${LIST},"
    LIST="${LIST}\"$(esc_json "$b")\""
done <<< "$BRANCHES"

printf '{"ok":true,"owner":"%s","name":"%s","default":"%s","branches":[%s]}\n' \
    "$(esc_json "$OWNER")" "$(esc_json "$NAME")" "$(esc_json "$DEFAULT")" "$LIST"
exit 0
