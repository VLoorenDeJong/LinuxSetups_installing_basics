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
# Make Samba serve what is published, without publishing anything.
#
# WHY THIS EXISTS. publish_smb.sh does four things in a row: validate, commit
# and push, pull that commit into the tree /etc/samba/smb.conf points at, and
# reload Samba. On 2026-09-09 the third step failed for a day, so several saves
# ended "pushed, Samba was not reloaded": the change was in git and the machine
# kept serving the old file, with nothing in the console able to finish the job.
#
# This is the REPAIR half of publish_smb.sh and nothing else:
#
#   1. fast-forward the live clone onto its branch
#   2. testparm the file Samba actually reads
#   3. reload, and read the shares back out of Samba
#
# It never writes a config, never commits and never pushes, and it refuses a
# file testparm rejects, so the worst it can do is leave Samba as it was.
#
# Usage:
#   sudo ./reload_samba.sh
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This has to run as root: it moves a root-owned clone and reloads Samba."
    print_action "  sudo $0"
    exit 1
fi

SMB_LINK="/etc/samba/smb.conf"

print_header "Reload Samba"

# =============================================================================
# Pre-flight: everything this needs, before anything is touched
# =============================================================================
ERRORS=()

[ -e "$SMB_LINK" ] || ERRORS+=("$SMB_LINK does not exist, so there is nothing to reload.")

for t in testparm smbcontrol smbclient runuser git; do
    command -v "$t" >/dev/null 2>&1 \
        || ERRORS+=("$t is not installed, so this cannot finish. Install samba-common-bin.")
done

LIVE="$(readlink -f "$SMB_LINK" 2>/dev/null || true)"
[ -n "$LIVE" ] && [ -f "$LIVE" ] \
    || ERRORS+=("$SMB_LINK does not resolve to a file.")

LIVE_CLONE=""
if [ -n "$LIVE" ] && [ -f "$LIVE" ]; then
    LIVE_CLONE="$(git -C "$(dirname "$LIVE")" -c safe.directory="*" \
        rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$LIVE_CLONE" ] \
    || ERRORS+=("$LIVE is not inside a git clone, so there is nothing to fast-forward.")

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Cannot reload. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

CLONE_OWNER="$(stat -c %U "$LIVE_CLONE")"
BRANCH="$(runuser -u "$CLONE_OWNER" -- git -C "$LIVE_CLONE" \
    rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    print_error "$LIVE_CLONE is not on a branch, so it cannot be fast-forwarded."
    print_action "  cd $LIVE_CLONE && git status"
    exit 1
fi

print_status "Config: $SMB_LINK -> $LIVE"
print_status "Clone:  $LIVE_CLONE ($CLONE_OWNER, $BRANCH)"

# =============================================================================
# The token
#
# Minted at the point of use, never stored, and it reaches git through the
# environment and a credential helper rather than the argument list: anything on
# this machine can read /proc/<pid>/cmdline while git runs.
#
# A machine whose remote is still git@ takes the plain path and uses whatever
# key that account has, exactly as it did before.
# =============================================================================
GH_TOKEN=""
for _sh in /usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh \
           "${LIVE_CLONE}/hostings/scripts/github_app_token.sh"; do
    [ -f "$_sh" ] || continue
    GH_TOKEN="$(SITES_CONF= \
        bash "$_sh" 2>/dev/null || true)"
    [ -n "$GH_TOKEN" ] && break
done
unset _sh
export GH_TOKEN

REMOTE_URL="$(runuser -u "$CLONE_OWNER" -- git -C "$LIVE_CLONE" \
    remote get-url origin 2>/dev/null || true)"
USE_APP=0
case "$REMOTE_URL" in
    https://*) [ -n "$GH_TOKEN" ] && USE_APP=1 ;;
esac
if [ "$USE_APP" = "1" ]; then
    print_status "Auth:   the GitHub App, over HTTPS"
else
    print_status "Auth:   whatever key $CLONE_OWNER has"
fi

HELPER="$GIT_CRED"

ff_git() {
    if [ "$USE_APP" = "1" ]; then
        runuser -u "$CLONE_OWNER" --preserve-environment -- \
            git -C "$LIVE_CLONE" \
            -c credential.helper= \
            -c credential.helper="$HELPER" \
            "$@"
    else
        runuser -u "$CLONE_OWNER" -- git -C "$LIVE_CLONE" "$@"
    fi
}

# =============================================================================
# Catch the clone up
#
# --ff-only, never a merge: this clone is a copy of a branch and nothing is
# written in it, so anything needing a merge is a fault to look at rather than
# something to resolve here.
# =============================================================================
print_status "Fetching $BRANCH..."
FF_LOG="$(mktemp)"
if ! ff_git fetch origin "$BRANCH" >"$FF_LOG" 2>&1 \
   || ! ff_git merge --ff-only "origin/$BRANCH" >>"$FF_LOG" 2>&1; then
    print_error "Could not fast-forward $LIVE_CLONE, so Samba was not reloaded."
    tail -n 10 "$FF_LOG"
    DIRTY="$(runuser -u "$CLONE_OWNER" -- git -C "$LIVE_CLONE" \
        status --porcelain 2>/dev/null | head -n 10)"
    if [ -n "$DIRTY" ]; then
        print_info "That clone has uncommitted changes, and git will not move over them:"
        printf '%s\n' "$DIRTY"
    fi
    print_action "  cd $LIVE_CLONE && git status"
    print_info "Samba still serves the config it already had."
    rm -f "$FF_LOG"
    exit 1
fi
rm -f "$FF_LOG"
print_success "$LIVE_CLONE is on $(ff_git rev-parse --short HEAD)."

# =============================================================================
# Validate before reloading, not after
#
# Reloading a file testparm rejects is how a working Samba is lost, and whoever
# presses this button is usually already looking at something broken.
# =============================================================================
TP_LOG="$(mktemp)"
if ! testparm -s "$LIVE" >"$TP_LOG" 2>&1; then
    print_error "$LIVE does not pass testparm, so Samba was NOT reloaded."
    tail -n 15 "$TP_LOG"
    rm -f "$TP_LOG"
    exit 1
fi
rm -f "$TP_LOG"
print_success "$LIVE is valid."

# =============================================================================
# Reload
#
# smbcontrol, not systemctl restart: a reload keeps every open connection, and
# one of those is usually the person pressing the button. It broadcasts, so it
# returns 0 with nothing listening: smbd is checked before, and the shares are
# read back after.
# =============================================================================
if ! systemctl is-active --quiet smbd; then
    print_error "smbd is not running, so there was nothing to reload."
    print_info "The config in place is valid and will be read when it starts."
    print_action "  sudo systemctl start smbd"
    exit 1
fi

RELOAD_LOG="$(mktemp)"
if ! smbcontrol all reload-config >"$RELOAD_LOG" 2>&1; then
    print_error "smbcontrol failed, so the new config is not in use."
    tail -n 10 "$RELOAD_LOG"
    rm -f "$RELOAD_LOG"
    exit 1
fi
rm -f "$RELOAD_LOG"

# Asking Samba what it serves, rather than trusting a broadcast that cannot fail.
SHARES="$(smbclient -L localhost -N 2>/dev/null | awk '$2 == "Disk" {print $1}' | tr '\n' ' ')"
if [ -z "$SHARES" ]; then
    print_error "Samba reloaded but lists no shares."
    print_info "That is correct if every share is switched off, and a fault otherwise."
    print_action "  sudo testparm -s $LIVE"
    exit 0
fi

print_success "Samba reloaded. It now serves: $SHARES"
exit 0
