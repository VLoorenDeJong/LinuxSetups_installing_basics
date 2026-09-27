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
# For every upstream package: is there a stable release newer than what test
# runs? Then build it and put it on test. Run weekly by upstream-check.timer.
#
#   upstream_check.sh            every package
#   upstream_check.sh <name>     one
#
# It never touches any other environment. What reaches live is decided by the
# upgrade gate (.claude/docs/webbuilder-and-upgrade-gate-decisions.md), or by
# hand with upstream_promote.sh.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

# The newest stable version by the recipe's rule. Stable means plain x.y.z:
# anything with a suffix (-canary.3, -rc1, -beta) is a pre-release.
latest_stable() {
    local rule="$1" upstream="$2" package="$3"
    case "$rule" in
        github-stable)
            git ls-remote --tags --refs "$upstream" 2>/dev/null | sed 's#.*refs/tags/##' ;;
        nuget)
            curl -fsSL --max-time 30 "https://api.nuget.org/v3-flatcontainer/${package,,}/index.json" 2>/dev/null \
                | grep -oE '"[^"]+"' | tr -d '"' ;;
        npm)
            curl -fsSL --max-time 30 "https://registry.npmjs.org/${package}" 2>/dev/null \
                | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+":\{' | cut -d'"' -f2 ;;
    esac | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | { [ "${4:-}" = all ] && cat || tail -n1; }
}

# When a version was published, as an ISO date, or nothing if it cannot be told.
release_date() {
    local rule="$1" upstream="$2" package="$3" version="$4" repo
    case "$rule" in
        github-stable)
            repo="${upstream#https://github.com/}"; repo="${repo%.git}"
            curl -fsSL --max-time 30 "https://api.github.com/repos/${repo}/releases/tags/${version}" 2>/dev/null | jq -r '.published_at // empty' ;;
        nuget)
            curl -fsSL --max-time 30 "https://api.nuget.org/v3/registration5-semver1/${package,,}/${version}.json" 2>/dev/null | jq -r '.published // empty' ;;
        npm)
            curl -fsSL --max-time 30 "https://registry.npmjs.org/${package}" 2>/dev/null | jq -r --arg v "$version" '.time[$v] // empty' ;;
    esac
}

# The newest stable version that has been public for COOLDOWN days. A poisoned
# release is usually noticed and pulled within days, so waiting a week lets
# somebody else find it first. A version whose date cannot be read is skipped:
# unknown age is not old enough.
newest_settled() {
    local rule="$1" upstream="$2" package="$3" v date age tried=0
    while IFS= read -r v; do
        [ "$tried" -ge 10 ] && break
        tried=$((tried + 1))
        date="$(release_date "$rule" "$upstream" "$package" "$v")"
        if [ -z "$date" ]; then
            print_info "$v: no publish date found, skipped." >&2
            continue
        fi
        age=$(( ( $(date +%s) - $(date -d "$date" +%s) ) / 86400 ))
        if [ "$age" -ge "$COOLDOWN" ]; then
            echo "$v"; return 0
        fi
        print_info "$v is $age day(s) old, under the ${COOLDOWN}-day cooldown." >&2
    done < <(latest_stable "$rule" "$upstream" "$package" all | sort -Vr)
}

[ "$EUID" -eq 0 ] || { print_error "This needs root: it builds images and restarts units."; print_action "sudo bash $0 $*"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANDIDATE_ENV="test"
. "$SCRIPT_DIR/config.sh" 2>/dev/null || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
COOLDOWN="$(sed -n 's/^[[:space:]]*UPSTREAM_COOLDOWN_DAYS[[:space:]]*=//p' "$SITES_CONF" 2>/dev/null | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
COOLDOWN="${COOLDOWN:-7}"
command -v jq >/dev/null 2>&1 || { print_error "jq is not installed; it reads release dates."; print_action "sudo apt-get install -y jq"; exit 1; }

if [ -n "${1:-}" ]; then
    PACKAGES=("$1")
else
    PACKAGES=()
    for r in "$REPO_ROOT"/hostings/upstream/*/recipe.conf; do
        [ -f "$r" ] && PACKAGES+=("$(basename "$(dirname "$r")")")
    done
fi
[ "${#PACKAGES[@]}" -gt 0 ] || { print_info "No upstream packages in $REPO_ROOT/hostings/upstream."; exit 0; }

# A fresh drive has rows in every environment and nothing in any of them.
# Only then does a version go beyond test on its own: an environment that has
# never run this package gets what test runs. After that, reaching live is the
# upgrade gate's decision, never this script's.
seed_empty_envs() {
    local pkg="$1" version="$2" envs e
    envs="$(awk -F'|' -v rt="upstream:$pkg" '
        /^[[:space:]]*#/ { next }
        { t=$1; gsub(/[[:space:]]/, "", t); r=tolower($14); gsub(/[[:space:]\r]/, "", r) }
        t == "app" && r == rt { e=$11; gsub(/[[:space:]]/, "", e); print (e == "" || e == "-") ? "ALL" : e }
    ' "$SITES_CONF" | tr ',' '\n' | sort -u)"
    if grep -qx ALL <<< "$envs"; then
        envs="$(sed -n 's/^[[:space:]]*ENVS[[:space:]]*=//p' "$SITES_CONF" | head -n1 | tr -d '\r' | tr ',' '\n' | xargs -n1)"
    fi
    for e in $envs; do
        [ "$e" = "$CANDIDATE_ENV" ] && continue
        [ -s "/var/lib/upstream/$pkg/$e" ] && continue
        print_status "$e has never run $pkg: starting it on $version, as test does."
        bash "$SCRIPT_DIR/upstream_promote.sh" "$pkg" "$e" "$version" || return 1
    done
}

FAILED=()
for pkg in "${PACKAGES[@]}"; do
    recipe="$REPO_ROOT/hostings/upstream/$pkg/recipe.conf"
    [ -f "$recipe" ] || { print_error "No recipe for $pkg."; FAILED+=("$pkg"); continue; }
    upstream="$(sed -n 's/^[[:space:]]*UPSTREAM[[:space:]]*=[[:space:]]*//p' "$recipe" | head -n1 | tr -d '\r' | xargs)"
    rule="$(sed -n 's/^[[:space:]]*RELEASE_RULE[[:space:]]*=[[:space:]]*//p' "$recipe" | head -n1 | tr -d '\r' | xargs)"
    package="$(sed -n 's/^[[:space:]]*PACKAGE[[:space:]]*=[[:space:]]*//p' "$recipe" | head -n1 | tr -d '\r' | xargs)"
    newest="$(newest_settled "${rule:-github-stable}" "$upstream" "$package")"
    current="$(cat "/var/lib/upstream/$pkg/$CANDIDATE_ENV" 2>/dev/null || true)"

    print_header "$pkg"
    if [ -z "$newest" ]; then
        print_error "No stable release of $pkg older than $COOLDOWN days could be read from $upstream."
        FAILED+=("$pkg"); continue
    fi
    if [ "$newest" = "$current" ]; then
        print_success "$CANDIDATE_ENV already runs $newest, the newest stable release past the $COOLDOWN-day cooldown."
        seed_empty_envs "$pkg" "$newest" || FAILED+=("$pkg")
        continue
    fi
    if [ -n "$current" ] && [ "$(printf '%s\n%s\n' "$current" "$newest" | sort -V | tail -n1)" = "$current" ]; then
        print_info "$CANDIDATE_ENV runs $current, newer than $newest, the newest stable past the cooldown. Left alone."
        seed_empty_envs "$pkg" "$current" || FAILED+=("$pkg")
        continue
    fi
    print_status "$newest is out; $CANDIDATE_ENV runs ${current:-nothing}."
    if bash "$SCRIPT_DIR/upstream_build.sh" "$pkg" "$newest" \
        && bash "$SCRIPT_DIR/upstream_promote.sh" "$pkg" "$CANDIDATE_ENV" "$newest"; then
        print_success "$pkg $newest is on $CANDIDATE_ENV."
        seed_empty_envs "$pkg" "$newest" || FAILED+=("$pkg")
    else
        FAILED+=("$pkg")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    print_error "Not updated: ${FAILED[*]}"
    exit 1
fi
