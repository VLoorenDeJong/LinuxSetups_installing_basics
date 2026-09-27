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
# Give a website branch something to serve, so the whole chain can be proved.
#
# A new site row is a repository with a README and a Jenkinsfile in it and no
# page. Everything downstream then works perfectly and shows nothing, so the
# only way to tell a working pipeline from a broken one is to write a page by
# hand first. This writes it.
#
#   seed_site_index.sh                 report what is missing, change nothing
#   seed_site_index.sh --push          write and push the missing pages
#   seed_site_index.sh --only-row example_org
#
# EMPTY MEANS NO index.html, NOT AN EMPTY REPOSITORY.
#
# A repository made by provision_repo.sh already has a README and a Jenkinsfile
# in its first commit, so a literally empty branch never happens and a check for
# one would never fire. What matters for a website is whether there is anything
# to serve, and that is exactly what index.html answers.
#
# EXISTING CONTENT IS NEVER TOUCHED. A branch with an index.html is left alone,
# every time, with no flag to override it. Overwriting a customer's front page
# is not a thing this should be able to do by accident.
#
# THE PAGE CARRIES A BACKGROUND, picked at random from
# /etc/hostings/apache/www/under-construction and committed into the target
# repository, so the site carries its own copy. An empty folder is not an
# error: the page is then plain, which is what it was before.
#
# Application rows are seeded too. Nothing serves an index.html out of an app
# repository, so there it is a marker in GitHub's file list rather than a page.
#
# GIT AUTHENTICATES AS THE GITHUB APP, through repo_host.sh's repo_git, and runs
# as root because minting reads the root-only App key. GIT_PUSH_KEY is for the
# first clone of the machine only, the owner 2026-09-13.
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

print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

PUSH=0
ONLY_ROW=""
while [ $# -gt 0 ]; do
    case "$1" in
        --push)        PUSH=1; shift ;;
        --only-row)    ONLY_ROW="${2:-}"; shift 2 ;;
        --only-row=*)  ONLY_ROW="${1#--only-row=}"; shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--push] [--only-row <name>]" >&2
            echo "" >&2
            echo "  no flags     report which branches have no page to serve" >&2
            echo "  --push       write and push a placeholder to those branches" >&2
            exit 1 ;;
        *) print_error "Unknown argument '$1'"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 $*"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

# Backgrounds for the placeholder, one picked at random per branch. The folder
# carries a README saying what may be dropped in it.
#
# The installed copies of these scripts run from /usr/local/sbin, where ../..
# is /usr and holds none of this, so the pipeline tree is the fallback.
BG_DIR="/etc/hostings/apache/www/under-construction"
[ -d "$BG_DIR" ] || BG_DIR="/etc/hostings/apache/www/under-construction"
[ -d "$BG_DIR" ] || BG_DIR="/var/lib/hosting-manager/config-repo/backup_config/apache/www/under-construction"

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

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
    # A CRLF config leaves a carriage return on the end of every value, and
    # none of the trimming below removes it.
    v="${v//$'\r'/}"
    printf '%s' "$(trim "${v%%#*}")"
}

# A SETTING, not a row. PANEL lines hold pipes too.
conf_rows() {
    grep -v '^[[:space:]]*#' "$SITES_CONF" \
        | grep -vE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' \
        | grep '|'
}

row_in_env() {
    local list e
    list="$(trim "$1")"
    [ -z "$list" ] && return 0
    IFS=',' read -r -a _re <<< "$list"
    for e in ${_re+"${_re[@]}"}; do
        [ "$(trim "$e")" = "$2" ] && return 0
    done
    return 1
}

APP_RUN_USER="$(conf_get APP_RUN_USER)"
[ -z "$APP_RUN_USER" ] && APP_RUN_USER="jenkins"

# WHO PUSHES: the GitHub App, as root, the same identity provision_repo.sh uses
# for every other write. Root because the helper mints from the root-only key,
# one token per owner, so a repository under a second owner still works.
_iface() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}
# shellcheck source=/dev/null
. "$(_iface repo_host.sh)"

as_git_user() { "$@"; }
FILE_OWNER="root"

# =============================================================================
# SITE PROJECT SEEDERS, one per platform, dispatched by name.
#
# Same shape as seed_app_project.sh's write_project_<runtime>, deliberately: a
# platform is added by writing one function, an unknown one is refused by name
# before anything is cloned, and neither needs this loop touched.
#
# THE PLATFORM IS THE ROW'S RUNTIME FIELD, which is unused on a website row and
# already validated, so no fifteenth field and no config migration. `-` or empty
# means the placeholder page, which is what every existing row gets.
#
# WHY THESE ARE DELIBERATELY TINY. They exist to prove the pipeline, not to
# start a real site: npm ci, npm run build, find the output, publish it, serve
# it. A framework's own scaffold does the same job and takes minutes, pulls
# hundreds of megabytes and changes shape between releases. The owner's call,
# 2026-09-05: a POC, not a starter kit.
#
# Angular is the exception and uses `ng new`, because a hand-written Angular
# project needs angular.json, two tsconfigs and a builder configuration, and a
# wrong one fails inside the CLI rather than here.
#
# EACH ONE MUST DO THREE THINGS the dotnet seeder learned the hard way:
#   1. give npm a HOME that EXISTS, or it fails with a message about the home
#      directory and the branch ends up with a README and nothing else
#   2. write a .gitignore, or the first commit carries node_modules, which for
#      Angular is roughly 300 MB
#   3. leave a package-lock.json, so the build runs `npm ci` against pinned
#      versions instead of resolving afresh every time
# =============================================================================

# Shared by every npm seeder: the lockfile is what makes the build reproducible,
# and generating it here is the only moment there is to do it.
_npm_lock_and_clean() {
    local dir="$1" err="$2"
    as_git_user mkdir -p "$dir/.seedhome"
    # `cd` INSIDE the command, not --prefix and not a caller that happens to be
    # in the right place. npm resolves package.json from its working directory,
    # and this runs from wherever the caller stood: the first version failed
    # with "enoent ... /package.json", naming a path that was never written.
    if ! as_git_user bash -c "cd '$dir' && HOME='$dir/.seedhome' npm install --package-lock-only --no-audit --no-fund" >"$err" 2>&1; then
        # Retried once with the flag that a stock Angular scaffold needs on
        # npm 10.9.8, and said out loud rather than applied silently.
        as_git_user bash -c "cd '$dir' && HOME='$dir/.seedhome' npm install --package-lock-only --legacy-peer-deps --no-audit --no-fund" >>"$err" 2>&1 || return 1
        print_action "  the lockfile needed --legacy-peer-deps: this project has conflicting peer dependencies."
    fi
    as_git_user rm -rf "$dir/.seedhome" "$dir/node_modules"
    return 0
}

_npm_gitignore() {
    as_git_user tee "$1/.gitignore" >/dev/null <<'GITIGNORE'
node_modules/
dist/
.seedhome/
GITIGNORE
}

# A page that says which platform built it, so a browser confirms the pipeline
# rather than merely answering 200. Shared markup, one line different.
# $3 is what actually happened between the repository and the browser, because
# it is not the same for every platform and a page claiming a step that never
# ran is a page that lies. PHP has no build at all: the file Apache serves IS
# the file in the repository.
_poc_body() {
    local built="${3:-<code>npm run build</code> ran, its output was located and published}"
    printf '%s' "<h1>$2</h1><p>Seeded by seed_site_index.sh to prove the pipeline. If you are reading this, the repository was created, $2 was installed, ${built}, and Apache served it.</p><p>Replace it with the real site: nothing overwrites a project once one exists.</p>"
}

has_site_html()  { [ -f "$1/index.html" ]; }
has_site_php()   { [ -f "$1/index.php" ]; }
has_site_vue()   { [ -f "$1/package.json" ]; }
has_site_react() { [ -f "$1/package.json" ]; }
has_site_svelte(){ [ -f "$1/package.json" ]; }
has_site_angular(){ [ -f "$1/package.json" ]; }

# PHP HAS NO BUILD STEP, which is what makes it the cheapest platform here. The
# repository IS the site: build_npm_static_site.sh passes anything without a
# package.json straight through, and php8.3-fpm.conf is enabled machine-wide in
# conf-enabled, so every vhost already runs .php with no per-site Apache change.
#
# No database, and that is the boundary. WordPress was considered and refused on
# 2026-09-06: its content lives in a database and wp-content rather than in git,
# so a rebuild from the repository would give an empty site, which is the exact
# opposite of what this machine is for.
#
# One thing worth knowing rather than discovering: PHP-FPM runs one pool as
# www-data for the whole machine, so every PHP site here shares a process user
# and can read the others' files. Fine while every site is the owner's. It is a
# per-site pool the day one is not.
write_site_php() {
    local dir="$1" row="$2" err="$3"
    as_git_user tee "$dir/index.php" >/dev/null <<PHP
<!doctype html>
<meta charset="utf-8">
<title>${row}</title>
<style>
main { font-family: system-ui, sans-serif; margin: 4rem auto; max-width: 34rem;
       line-height: 1.5; padding: 0 1rem; }
code { background: #eee; padding: .1rem .3rem; border-radius: 3px; }
</style>
<main>
$(_poc_body "$row" "PHP" "no build step ran because PHP needs none: this file is served straight from the repository")
<p>Served by PHP <?= PHP_VERSION ?> at <?= date('Y-m-d H:i:s T') ?>.</p>
</main>
PHP
    as_git_user tee "$dir/.gitignore" >/dev/null <<'IGN'
vendor/
*.log
IGN
    return 0
}

write_site_vue() {
    local dir="$1" row="$2" err="$3"
    as_git_user tee "$dir/package.json" >/dev/null <<JSON
{
  "name": "$(printf '%s' "$row" | tr -cd '[:alnum:]-_')",
  "private": true,
  "type": "module",
  "scripts": { "build": "vite build", "dev": "vite" },
  "dependencies": { "vue": "^3.5.13" },
  "devDependencies": { "@vitejs/plugin-vue": "^5.2.1", "vite": "^6.0.7" }
}
JSON
    as_git_user tee "$dir/vite.config.js" >/dev/null <<'JS'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
export default defineConfig({ plugins: [vue()] })
JS
    as_git_user tee "$dir/index.html" >/dev/null <<HTML
<!doctype html>
<meta charset="utf-8">
<title>${row}</title>
<div id="app"></div>
<script type="module" src="/src/main.js"></script>
HTML
    as_git_user mkdir -p "$dir/src"
    as_git_user tee "$dir/src/main.js" >/dev/null <<'JS'
import { createApp } from 'vue'
import App from './App.vue'
createApp(App).mount('#app')
JS
    as_git_user tee "$dir/src/App.vue" >/dev/null <<VUE
<template>
  <main>$(_poc_body "$row" "Vue")</main>
</template>
<style>
main { font-family: system-ui, sans-serif; margin: 4rem auto; max-width: 34rem;
       line-height: 1.5; padding: 0 1rem; }
code { background: #eee; padding: .1rem .3rem; border-radius: 3px; }
</style>
VUE
    _npm_gitignore "$dir"
    _npm_lock_and_clean "$dir" "$err"
}

write_site_react() {
    local dir="$1" row="$2" err="$3"
    as_git_user tee "$dir/package.json" >/dev/null <<JSON
{
  "name": "$(printf '%s' "$row" | tr -cd '[:alnum:]-_')",
  "private": true,
  "type": "module",
  "scripts": { "build": "vite build", "dev": "vite" },
  "dependencies": { "react": "^19.0.0", "react-dom": "^19.0.0" },
  "devDependencies": { "@vitejs/plugin-react": "^4.3.4", "vite": "^6.0.7" }
}
JSON
    as_git_user tee "$dir/vite.config.js" >/dev/null <<'JS'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({ plugins: [react()] })
JS
    as_git_user tee "$dir/index.html" >/dev/null <<HTML
<!doctype html>
<meta charset="utf-8">
<title>${row}</title>
<div id="root"></div>
<script type="module" src="/src/main.jsx"></script>
HTML
    as_git_user mkdir -p "$dir/src"
    as_git_user tee "$dir/src/main.jsx" >/dev/null <<JSX
import { createRoot } from 'react-dom/client'
const body = \`$(_poc_body "$row" "React")\`
createRoot(document.getElementById('root')).render(
  <main style={{ fontFamily: 'system-ui, sans-serif', margin: '4rem auto',
                 maxWidth: '34rem', lineHeight: 1.5, padding: '0 1rem' }}
        dangerouslySetInnerHTML={{ __html: body }} />
)
JSX
    _npm_gitignore "$dir"
    _npm_lock_and_clean "$dir" "$err"
}

write_site_svelte() {
    local dir="$1" row="$2" err="$3"
    as_git_user tee "$dir/package.json" >/dev/null <<JSON
{
  "name": "$(printf '%s' "$row" | tr -cd '[:alnum:]-_')",
  "private": true,
  "type": "module",
  "scripts": { "build": "vite build", "dev": "vite" },
  "devDependencies": { "@sveltejs/vite-plugin-svelte": "^5.0.3",
                       "svelte": "^5.16.0", "vite": "^6.0.7" }
}
JSON
    as_git_user tee "$dir/vite.config.js" >/dev/null <<'JS'
import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
export default defineConfig({ plugins: [svelte()] })
JS
    as_git_user tee "$dir/index.html" >/dev/null <<HTML
<!doctype html>
<meta charset="utf-8">
<title>${row}</title>
<div id="app"></div>
<script type="module" src="/src/main.js"></script>
HTML
    as_git_user mkdir -p "$dir/src"
    as_git_user tee "$dir/src/main.js" >/dev/null <<'JS'
import App from './App.svelte'
import { mount } from 'svelte'
mount(App, { target: document.getElementById('app') })
JS
    as_git_user tee "$dir/src/App.svelte" >/dev/null <<SV
<main>$(_poc_body "$row" "Svelte")</main>
<style>
main { font-family: system-ui, sans-serif; margin: 4rem auto; max-width: 34rem;
       line-height: 1.5; padding: 0 1rem; }
</style>
SV
    _npm_gitignore "$dir"
    _npm_lock_and_clean "$dir" "$err"
}

# Angular alone uses its own CLI. A hand-written Angular project needs
# angular.json, two tsconfigs and a builder block, and getting one wrong fails
# inside the CLI with a message about the workspace rather than here.
write_site_angular() {
    local dir="$1" row="$2" err="$3" proj
    proj="$(printf '%s' "$row" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
    [ -z "$proj" ] && proj="app"
    case "$proj" in [0-9]*) proj="app$proj" ;; esac

    as_git_user mkdir -p "$dir/.seedhome"

    # SCAFFOLDED INTO A SUBDIRECTORY AND MOVED IN, not straight into the clone.
    #
    # `ng new --directory .` refuses outright when anything it would write
    # already exists, and provision_repo.sh has always put a README.md there
    # first: "conflicted on path /README.md", which names Angular's complaint
    # and not the cause. The CLI has no reliable overwrite for this, so it is
    # given an empty directory instead and its output moved over the clone.
    #
    # --minimal drops the test harness, which a POC does not need and which more
    # than doubles the install. --skip-install because the lockfile step below
    # is what installs, and doing it twice is the slowest part of the seed.
    if ! as_git_user bash -c "cd '$dir' && HOME='$dir/.seedhome' npm exec --yes -- @angular/cli@latest new '$proj' --directory .ngseed --defaults --minimal --skip-git --skip-install --style=css --ssr=false" >"$err" 2>&1; then
        return 1
    fi
    # Dotfiles included, and the scaffold's README wins: it describes the
    # project that is actually there.
    as_git_user bash -c "cd '$dir/.ngseed' && for f in .[!.]* *; do [ -e \"\$f\" ] && cp -a \"\$f\" '$dir'/; done" >>"$err" 2>&1 || return 1
    as_git_user rm -rf "$dir/.ngseed"
    _npm_gitignore "$dir"
    _npm_lock_and_clean "$dir" "$err"
}

# UNO IS GENERATED INSIDE THE BUILDER CONTAINER, because the Uno templates and
# the wasm-tools workload live there and not on this machine's .NET (item 139).
# Uno's own default template, web head only: the same `dotnet new` default the
# Blazor seed takes. It builds through build_in_container.sh publish.
has_site_uno() { [ -n "$(find "$1" -name '*.csproj' -not -path '*/.git/*' -print -quit)" ]; }

write_site_uno() {
    local dir="$1" row="$2" err="$3" proj gen owner
    # Read before the copy: `cp -a gen/.` also copies gen's owner onto $dir,
    # and git then refuses the checkout as dubious ownership.
    owner="$(stat -c '%u:%g' "$dir")"
    proj="$(printf '%s' "$row" | tr -cd '[:alnum:]_')"
    [ -z "$proj" ] && proj="Site"
    case "$proj" in [0-9]*) proj="Site$proj" ;; esac
    gen="$(mktemp -d)"
    # Not root: build_in_container.sh runs the container as the folder's owner.
    chown 65534:65534 "$gen"
    if ! bash "$(_iface build_in_container.sh)" new "$gen" \
            unoapp --name "$proj" -o . -platforms wasm >"$err" 2>&1; then
        rm -rf "$gen"
        return 1
    fi
    cp -a "$gen"/. "$dir"/
    rm -rf "$gen"
    chown -R "$owner" "$dir"
    [ -f "$dir/.gitignore" ] || as_git_user tee "$dir/.gitignore" >/dev/null <<'GITIGNORE'
bin/
obj/
.publish/
GITIGNORE
    return 0
}

preflight_uno() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && return 0
    print_error "Docker is not usable here, and Uno is generated and built in a container."
    print_action "Check it: sudo bash LinuxBasics/install_scripts/check_docker.sh"
    return 1
}

preflight_npm() {
    if ! command -v npm >/dev/null 2>&1; then
        print_error "No npm on this machine, so an npm site cannot be seeded."
        print_action "Install it: sudo bash LinuxBasics/install_scripts/add_node.sh"
        return 1
    fi
    return 0
}
preflight_vue()     { preflight_npm; }
preflight_react()   { preflight_npm; }
preflight_svelte()  { preflight_npm; }
preflight_angular() { preflight_npm; }
preflight_html()    { return 0; }
# The SOCKET, not the php binary: without it Apache serves the source as text.
# Same test as check_config.sh and list_site_platforms.sh use.
preflight_php()     { ls /run/php/php*-fpm.sock >/dev/null 2>&1; }

IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS)"
for i in "${!ALL_ENVS[@]}"; do ALL_ENVS[$i]="$(trim "${ALL_ENVS[$i]}")"; done
[ -z "${ALL_ENVS[0]:-}" ] && ALL_ENVS=("live")

print_header "Pages to serve"

# Proven before anything is cloned, and without --push too: the repositories
# are private, so even the dry run cannot read a branch without a token.
if ! bash "$(_iface git_credential_github_app.sh)" --check >/dev/null 2>&1; then
    print_error "No GitHub App token could be minted, so no clone or push would work."
    print_action "Check it: sudo bash $(_iface git_credential_github_app.sh) --check"
    exit 1
fi
print_info "Git authenticates as the GitHub App."

SEEDED=()
HAS_PAGE=()
SKIPPED=()
FAILED=()

while IFS='|' read -r type name port path sub ds opts auth repo branch rowenvs users mode runtime _rest; do
    type="$(trim "$type")"
    name="$(trim "$name")"
    repo="$(trim "$repo")"
    rowenvs="$(trim "$rowenvs")"
    rowbranch="$(trim "$branch")"

    # The platform, from the row's Runtime field, which a website row does not
    # otherwise use. Lowercased so the config can say Vue or vue, and defaulted
    # to the placeholder page so every row written before today is unaffected.
    site_platform="$(trim "$runtime" | tr '[:upper:]' '[:lower:]')"
    [ -z "$site_platform" ] && site_platform="html"

    [ -z "$name" ] && continue
    [ -n "$ONLY_ROW" ] && [ "$name" != "$ONLY_ROW" ] && continue

    # WEBSITES ONLY, since 2026-09-04.
    #
    # Application rows were seeded here too, on the owner's call 2026-09-02, with a
    # marker index.html: nothing serves it, so it was a note in GitHub's file
    # list rather than a page. That was a stand-in for having nothing better.
    #
    # seed_app_project.sh is the better thing. It writes a project that actually
    # BUILDS, which is what an application's pipeline needs proving and what a
    # marker could never do. Leaving app rows here as well would drop a page
    # into a repository that never serves one.
    case "$type" in
        website|php|docroot) ;;
        *) continue ;;
    esac

    if [ -z "$repo" ] || [ "$repo" = "new" ]; then
        SKIPPED+=("$name (no repository yet)")
        continue
    fi

    # An SSH remote cannot carry the App's token, so an old git@ row is
    # rewritten to the forge's HTTPS form.
    if ! clone_url="$(repo_https_url "$repo")"; then
        FAILED+=("$name (repository '$repo' is not a URL this forge understands)")
        continue
    fi

    work="$(as_git_user mktemp -d)"

    # dev as well as the environments, on the owner's call 2026-09-03. It deploys
    # nowhere, so seeding it looked pointless: it is the DEFAULT branch, which
    # makes it the one GitHub opens, and a repository whose landing page is a
    # lone README reads as empty. It is also where a developer starts, and
    # starting from the page the site actually serves beats starting from
    # nothing.
    SEED_ENVS=("${ALL_ENVS[@]}" dev)
    for env in "${SEED_ENVS[@]}"; do
        if [ "$env" = "dev" ]; then
            br="dev"
        else
            row_in_env "$rowenvs" "$env" || continue
            # A ROW THAT NAMES ITS BRANCH HAS ANSWERED THE QUESTION, the same
            # rule provision_repo.sh's branches_for() has used since
            # 2026-08-23. This script never read the Branch field at all, so a
            # row deploying from `main` was asked for a `live` branch that was
            # never created, and reported as uncloneable.
            if [ -n "$rowbranch" ]; then
                br="$rowbranch"
            else
                env_upper="$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')"
                br="$(conf_get "${env_upper}_BRANCH")"
                [ -z "$br" ] && br="$env"
            fi
        fi

        dir="$work/$env"
        if ! repo_git clone -q --depth 1 --branch "$br" \
                "$clone_url" "$dir" 2>/dev/null; then
            FAILED+=("$name/$env (cannot clone branch '$br')")
            continue
        fi

        if [ -f "$dir/index.html" ]; then
            HAS_PAGE+=("$name/$env")
            continue
        fi

        if [ "$PUSH" -eq 0 ]; then
            SEEDED+=("$name/$env (branch $br) — would add index.html")
            continue
        fi

        # A PLATFORM ROW GETS A PROJECT, not a page.
        #
        # The placeholder below stays the default and is what every existing row
        # keeps getting: this branch only runs when the row asks for one by
        # name, and an unknown name is refused rather than guessed at.
        if [ -n "$site_platform" ] && [ "$site_platform" != "html" ]; then
            if ! declare -F "write_site_$site_platform" >/dev/null; then
                FAILED+=("$name/$env: no seeder for platform '$site_platform'. Known: $(declare -F | sed -n 's/^declare -f write_site_//p' | tr '\n' ' ')")
                continue
            fi
            # A MISSING preflight_ IS NOT A FAILED ONE. Without this the call
            # is a command-not-found and reports "the machine cannot seed a php
            # project", which sent me looking at PHP-FPM when the real answer
            # was that a new platform had a writer and no pre-flight. Same shape
            # as the write_site_ check above, and the same reason for it.
            if ! declare -F "preflight_$site_platform" >/dev/null; then
                FAILED+=("$name/$env: platform '$site_platform' has a seeder but no preflight_$site_platform. Add one beside preflight_html.")
                continue
            fi
            if ! "preflight_$site_platform"; then
                FAILED+=("$name/$env: the machine cannot seed a '$site_platform' project")
                continue
            fi
            err="$dir.err"
            print_status "  seeding a $site_platform project for $name/$env"
            if ! "write_site_$site_platform" "$dir" "$name" "$err"; then
                FAILED+=("$name/$env: $(tr '\n' ' ' < "$err" | tail -c 240)")
                rm -f "$err"
                continue
            fi
            # add -A, not a file list: a project is a tree and nobody should
            # have to keep this list in step with the seeders above.
            if as_git_user git -C "$dir" add -A 2>"$err" \
               && as_git_user git -C "$dir" \
                    -c user.email="${APP_RUN_USER}@$(hostname)" \
                    -c user.name="seed_site_index.sh" \
                    commit -q -m "Seed a $site_platform project so this environment builds and serves" 2>>"$err" \
               && repo_git -C "$dir" push -q origin "$br" 2>>"$err"; then
                SEEDED+=("$name/$env (branch $br) — $site_platform project")
            else
                FAILED+=("$name/$env: $(tr '\n' ' ' < "$err" | tail -c 200)")
            fi
            rm -f "$err"
            continue
        fi

        # A BACKGROUND, PICKED AT RANDOM, one per branch, the way a Minecraft
        # server picks a MOTD. It is committed into the repository so the site
        # carries its own copy and nothing here has to stay reachable.
        #
        # An empty folder is not a failure: the page is then plain, which is
        # what it was before backgrounds existed.
        bg_file=""
        bg_name=""
        if [ -d "$BG_DIR" ]; then
            bg_file="$(find "$BG_DIR" -maxdepth 1 -type f \
                        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
                           -o -iname '*.webp' -o -iname '*.avif' \) \
                        | shuf -n 1 || true)"
        fi
        if [ -n "$bg_file" ]; then
            bg_name="underconstruction.${bg_file##*.}"
            # Written as root into the deploy account's tree, then owned by it,
            # because git has to be able to add what it is about to commit.
            install -m 0644 -o "$FILE_OWNER" "$bg_file" "$dir/$bg_name"
        fi

        # Two shapes, and the difference is one CSS rule. Kept as two blocks
        # rather than one with a hole in it, because a heredoc that sometimes
        # emits an empty rule is harder to read than this.
        if [ -n "$bg_name" ]; then
            as_git_user tee "$dir/index.html" >/dev/null <<HTML
<!doctype html>
<meta charset="utf-8">
<title>${name}: ${env}</title>
<style>
  html, body { height: 100%; margin: 0; }
  body { font-family: system-ui, sans-serif; color: #fff; line-height: 1.5;
         background: #1b1b1b url("${bg_name}") center / cover no-repeat fixed;
         display: flex; align-items: center; justify-content: center; }
  .card { background: rgba(0, 0, 0, .62); padding: 2rem 2.25rem;
          border-radius: 10px; max-width: 34rem; margin: 1rem; }
  code { background: rgba(255, 255, 255, .16); padding: .1rem .3rem;
         border-radius: 3px; }
  h1 { margin-top: 0; }
</style>
<div class="card">
<h1>${name}</h1>
<p>Under construction. This is the <strong>${env}</strong> environment,
   published from the <code>${br}</code> branch.</p>
<p>It is a placeholder. It was added because this branch had no
   <code>index.html</code>, which meant the whole pipeline could run correctly
   and still show nothing. Replace it with the real site: nothing will overwrite
   your page once one exists.</p>
</div>
HTML
        else
            as_git_user tee "$dir/index.html" >/dev/null <<HTML
<!doctype html>
<meta charset="utf-8">
<title>${name}: ${env}</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 4rem auto; max-width: 34rem;
         line-height: 1.5; padding: 0 1rem; }
  code { background: #eee; padding: .1rem .3rem; border-radius: 3px; }
</style>
<h1>${name}</h1>
<p>Under construction. This is the <strong>${env}</strong> environment,
   published from the <code>${br}</code> branch.</p>
<p>It is a placeholder. It was added because this branch had no
   <code>index.html</code>, which meant the whole pipeline could run correctly
   and still show nothing. Replace it with the real site: nothing will overwrite
   your page once one exists.</p>
HTML
        fi

        # `git add` and not `commit -a`. The page is a NEW file, and -a stages
        # only tracked ones, so the commit found nothing to do and the push then
        # said "Everything up-to-date". The failure that reported was a refused
        # push, which sent the reader to look at SSH keys that were never wrong.
        err="$dir.err"
        if as_git_user git -C "$dir" add index.html ${bg_name:+"$bg_name"} 2>"$err" \
           && as_git_user git -C "$dir" \
                -c user.email="${APP_RUN_USER}@$(hostname)" \
                -c user.name="seed_site_index.sh" \
                commit -q -m "Add a placeholder page so this environment serves something" 2>>"$err" \
           && repo_git -C "$dir" push -q origin "$br" 2>>"$err"; then
            SEEDED+=("$name/$env (branch $br)")
        else
            # The message git gave, not a guess about what it meant.
            FAILED+=("$name/$env: $(tr '\n' ' ' < "$err" | tail -c 200)")
        fi
        rm -f "$err"
    done
    rm -rf "$work"
done < <(conf_rows)

for r in ${HAS_PAGE+"${HAS_PAGE[@]}"}; do print_status  "Already has a page: $r"; done
for r in ${SEEDED+"${SEEDED[@]}"};   do print_success "$r"; done
for r in ${SKIPPED+"${SKIPPED[@]}"}; do print_info "$r"; done
for r in ${FAILED+"${FAILED[@]}"};   do print_error   "$r"; done

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
    print_error "Some branches were not seeded."
    exit 1
fi
if [ "$PUSH" -eq 0 ] && [ ${#SEEDED[@]} -gt 0 ]; then
    print_status "Nothing was pushed. Add --push to write these pages."
fi
print_success "Done."
