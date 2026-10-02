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
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# Give an APPLICATION branch something that builds, so the whole chain can be
# proved.
#
# The sibling of seed_site_index.sh, and deliberately the same shape: same
# flags, same reporting, same "never touch existing content" rule. The
# orchestration picks one or the other by row type, so anything true of the
# calling convention has to be true of both.
#
#   seed_app_project.sh                    report what is missing, change nothing
#   seed_app_project.sh --push             create and push the missing projects
#   seed_app_project.sh --only-row demo
#   seed_app_project.sh --template webapi  a different project type
#
# WHY THIS EXISTS. A website's pipeline is proved by a page appearing. An
# application's is not: seed_site_index.sh drops a marker index.html into app
# repositories, and nothing serves it, so a repository with a marker and a
# repository with a working project look identical to every step downstream.
# The build stage then has no .csproj to find, and the first thing that says so
# is a red Jenkins job.
#
# WHAT IT WRITES is whatever `dotnet new` produces. Nothing here composes a
# project by hand: the template is the vendor's, so it stays correct as SDKs
# move, and the row is proved against the same thing a developer would start
# from.
#
# THE TEMPLATE IS A PARAMETER, not a hardcode. `blazor` is the default because
# it is a full web app with a page to look at, and a different type is
# --template away. Nothing in this script knows what the template contains.
#
# EXISTING CONTENT IS NEVER TOUCHED. A branch with any .csproj in it is left
# alone, every time, with no flag to override it. Overwriting somebody's
# application is not a thing this should be able to do by accident.
#
# GIT AND DOTNET RUN AS THE DEPLOY ACCOUNT, NOT AS ROOT. root has no SSH key
# here, so a push as root fails with a permission error that reads like a
# GitHub problem, and a NuGet cache written as root poisons the account that
# has to build afterwards.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

PUSH=0
ONLY_ROW=""
TEMPLATE="blazor"

# The file that says this project is still exactly what this script made, and
# which framework it was made for. Item 97: the README paragraph below is text
# anyone can edit without meaning anything by it, so the re-seed decision reads
# this instead.
SEED_MARKER=".hostings-seed.json"
while [ $# -gt 0 ]; do
    case "$1" in
        --push)        PUSH=1; shift ;;
        --only-row)    ONLY_ROW="${2:-}"; shift 2 ;;
        --only-row=*)  ONLY_ROW="${1#--only-row=}"; shift ;;
        --template)    TEMPLATE="${2:-}"; shift 2 ;;
        --template=*)  TEMPLATE="${1#--template=}"; shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--push] [--only-row <name>] [--template <name>]" >&2
            echo "" >&2
            echo "  no flags       report which branches have no project to build" >&2
            echo "  --push         create and push a project to those branches" >&2
            echo "  --template     dotnet template name, default 'blazor'" >&2
            echo "                 see: dotnet new list" >&2
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

IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS)"
for i in "${!ALL_ENVS[@]}"; do ALL_ENVS[$i]="$(trim "${ALL_ENVS[$i]}")"; done
[ -z "${ALL_ENVS[0]:-}" ] && ALL_ENVS=("live")

print_header "Projects to build"
print_status "Template: $TEMPLATE"

# =============================================================================
# Pre-flight. Everything this needs, checked before the first clone.
# =============================================================================
if ! id "$APP_RUN_USER" >/dev/null 2>&1; then
    print_error "No '$APP_RUN_USER' account, and that is who git and dotnet have to run as."
    exit 1
fi


# THE GITHUB APP, OVER HTTPS, like every other script that reaches GitHub since
# 2026-09-06. This one still cloned over SSH as $APP_RUN_USER, and the jenkins
# key it needed was deleted on 2026-09-04, so seeding failed on every create
# with "Check the key" while every other step of the create succeeded.
#
# The token is minted at the point of use and never stored: it lives an hour.
GH_TOKEN=""
mint_token() {  # [owner]
    local sh
    for sh in /usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh \
              "$(dirname "${BASH_SOURCE[0]}")/github_app_token.sh"; do
        [ -f "$sh" ] || continue
        GH_TOKEN="$(SITES_CONF= \
            bash "$sh" ${1:+"$1"} 2>/dev/null || true)"
        [ -n "$GH_TOKEN" ] && { export GH_TOKEN; return 0; }
    done
    return 1
}

# The token reaches git through a credential helper and through the ENVIRONMENT,
# never the argument list: anything on this machine can read /proc/<pid>/cmdline
# while git runs. --preserve-env carries it across sudo without naming it there.
git_as_app() {
    sudo -n -u "$APP_RUN_USER" --preserve-env=GH_TOKEN git \
        -c credential.helper= \
        -c credential.helper="$REPO_GIT_CRED" -c credential.useHttpPath=true \
        "$@"
}

# Before the first clone, and NOT only when pushing: every repository this
# seeds is private, so the CLONE needs the token too. Guarding the mint behind
# --push left --dry-run unable to read a single branch and reporting it as
# "cannot clone branch 'live'", which reads as a repository with no branches.
if ! mint_token; then
    print_error "No GitHub App token could be minted, so no clone or push would work."
    print_action "Check it: sudo /usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"
    exit 1
fi

# =============================================================================
# ONE FUNCTION PER RUNTIME, looked up by name.
#
# The same shape add_panel_vhosts.sh uses for machine pages, and it is the
# pattern worth copying: adding a language is adding two functions, and nothing
# else in this file moves.
#
#   has_project_<runtime> <dir>            is there already something to build
#   write_project_<runtime> <dir> <name> <err>   put one there
#
# add_app_services.sh knows dotnet and node. Only dotnet is written here,
# because node is not installed on this machine and no row uses it, so a node
# arm would be code nobody could run. It refuses by name instead of falling
# through to a message about dotnet.
# =============================================================================

has_project_dotnet() {
    # ANY .csproj, at any depth. The build stage globs for one the same way, so
    # this asks exactly the question the pipeline asks.
    [ -n "$(find "$1" -name '*.csproj' -not -path '*/.git/*' -print -quit)" ]
}

write_project_dotnet() {
    local dir="$1" row="$2" err="$3" proj_name

    # --name from the row rather than the directory: the directory is a mktemp
    # path and would become the assembly name.
    #
    # Sanitised, because a row name may carry characters a C# namespace cannot.
    # dotnet accepts them and emits a project that does not compile, which
    # fails later and somewhere else.
    proj_name="$(printf '%s' "$row" | tr -cd '[:alnum:]_')"
    [ -z "$proj_name" ] && proj_name="App"
    case "$proj_name" in [0-9]*) proj_name="App$proj_name" ;; esac

    # The directory has to EXIST. dotnet refuses with "the home directory
    # could not be determined" when HOME names one that does not, which is
    # what every seeded branch hit on 2026-09-04: the repository was created
    # and pushed with nothing but a README, and the first deploy then failed
    # with "No <name>.csproj in the repository".
    sudo -n -u "$APP_RUN_USER" mkdir -p "$dir/.seedhome"

    # -f only when the row asked for a version. Without it dotnet new takes the
    # newest SDK installed, and a machine carrying 8 and 10 seeds 10 for a row
    # that meant to stay on LTS.
    local fw=()
    [ -n "${ROW_TFM:-}" ] && fw=(-f "$ROW_TFM")

    sudo -n -u "$APP_RUN_USER" env HOME="$dir/.seedhome" \
        DOTNET_CLI_HOME="$dir/.seedhome" DOTNET_NOLOGO=1 \
        dotnet new "$TEMPLATE" --name "$proj_name" ${fw+"${fw[@]}"} -o "$dir" --force >"$err" 2>&1 || return 1

    # `dotnet new` leaves no .gitignore, and the first build would otherwise
    # commit bin/ and obj/ on somebody's machine.
    if [ ! -f "$dir/.gitignore" ]; then
        sudo -n -u "$APP_RUN_USER" tee "$dir/.gitignore" >/dev/null <<'GITIGNORE'
bin/
obj/
GITIGNORE
    fi
    return 0
}

# UNO WITH SERVER (item 139): Uno's default template, web head plus an ASP.NET
# server, generated in the builder container because the Uno templates live
# there. The row's Path is <name>/<name>.Server.dll.
has_project_uno() { has_project_dotnet "$1"; }

write_project_uno() {
    local dir="$1" row="$2" err="$3" proj_name
    proj_name="$(printf '%s' "$row" | tr -cd '[:alnum:]_')"
    [ -z "$proj_name" ] && proj_name="App"
    case "$proj_name" in [0-9]*) proj_name="App$proj_name" ;; esac
    local bic
    bic="$(dirname "${BASH_SOURCE[0]}")/build_in_container.sh"
    [ -f "$bic" ] || bic=/usr/local/lib/linuxbasics/hostings/scripts/build_in_container.sh
    bash "$bic" new "$dir" unoapp --name "$proj_name" -o . -platforms wasm -server true >"$err" 2>&1 || return 1
    if [ ! -f "$dir/.gitignore" ]; then
        sudo -n -u "$APP_RUN_USER" tee "$dir/.gitignore" >/dev/null <<'GITIGNORE'
bin/
obj/
.publish/
GITIGNORE
    fi
    return 0
}

# DOCKER (item 140): a working ASP.NET sample plus the Dockerfile that builds
# it, so the first push already runs as a container. The app listens on 8080,
# which is what add_app_services.sh publishes on 127.0.0.1:<row port>.
has_project_docker() { [ -f "$1/Dockerfile" ]; }

write_project_docker() {
    local dir="$1" row="$2" err="$3" proj_name
    proj_name="$(printf '%s' "$row" | tr -cd '[:alnum:]_')"
    [ -z "$proj_name" ] && proj_name="App"
    case "$proj_name" in [0-9]*) proj_name="App$proj_name" ;; esac

    sudo -n -u "$APP_RUN_USER" mkdir -p "$dir/.seedhome"
    sudo -n -u "$APP_RUN_USER" env HOME="$dir/.seedhome" \
        DOTNET_CLI_HOME="$dir/.seedhome" DOTNET_NOLOGO=1 \
        dotnet new web --name "$proj_name" -f net10.0 -o "$dir" --force >"$err" 2>&1 || return 1
    sudo -n -u "$APP_RUN_USER" rm -rf "$dir/.seedhome"

    sudo -n -u "$APP_RUN_USER" tee "$dir/Dockerfile" >/dev/null <<DOCKERFILE
# Seeded by seed_app_project.sh. Jenkins builds this image on every push and
# runs it; whatever this file builds must listen on port 8080.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY . .
RUN dotnet publish ${proj_name}.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "${proj_name}.dll"]
DOCKERFILE
    sudo -n -u "$APP_RUN_USER" tee "$dir/.dockerignore" >/dev/null <<'IGNORE'
bin/
obj/
.git/
IGNORE
    [ -f "$dir/.gitignore" ] || sudo -n -u "$APP_RUN_USER" tee "$dir/.gitignore" >/dev/null <<'GITIGNORE'
bin/
obj/
GITIGNORE
    return 0
}

# DOCKER, NODE (item 141). The .NET seed above is the only one that existed
# until 2026-09-17, so a Node container had to bring its own everything. Same
# contract as every Docker row: listen on 8080, the Dockerfile is the Path.
#
# No dependencies, so the image builds on a machine with no registry access
# beyond the base image, and `npm install` cannot fail the first build.
has_project_docker_node() { has_project_docker "$1"; }

write_project_docker_node() {
    local dir="$1" row="$2" err="$3"

    sudo -n -u "$APP_RUN_USER" tee "$dir/server.js" >/dev/null <<'SERVER' 2>"$err" || return 1
// Seeded by seed_app_project.sh. Whatever replaces this must listen on 8080:
// that is the port add_app_services.sh publishes on 127.0.0.1:<row port>.
const http = require('http');

const port = process.env.PORT || 8080;

http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Hello World!\n');
}).listen(port, () => console.log(`listening on ${port}`));
SERVER

    sudo -n -u "$APP_RUN_USER" tee "$dir/package.json" >/dev/null <<PACKAGE
{
  "name": "$(printf '%s' "$row" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-_')",
  "version": "1.0.0",
  "private": true,
  "main": "server.js",
  "scripts": { "start": "node server.js" }
}
PACKAGE

    sudo -n -u "$APP_RUN_USER" tee "$dir/Dockerfile" >/dev/null <<'DOCKERFILE'
# Seeded by seed_app_project.sh. Jenkins builds this image on every push and
# runs it; whatever this file builds must listen on port 8080.
FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
# --omit=dev, and it is a no-op while this seed has no dependencies at all.
RUN npm install --omit=dev
COPY . .
ENV PORT=8080
EXPOSE 8080
CMD ["node", "server.js"]
DOCKERFILE

    sudo -n -u "$APP_RUN_USER" tee "$dir/.dockerignore" >/dev/null <<'IGNORE'
node_modules/
.git/
IGNORE
    [ -f "$dir/.gitignore" ] || sudo -n -u "$APP_RUN_USER" tee "$dir/.gitignore" >/dev/null <<'GITIGNORE'
node_modules/
GITIGNORE
    return 0
}

# DOCKER, PYTHON (item 141). Standard library only, for the same reason the
# Node seed has no dependencies: a first build that fails because a package
# index was unreachable is indistinguishable from a broken pipeline.
has_project_docker_python() { has_project_docker "$1"; }

write_project_docker_python() {
    local dir="$1" row="$2" err="$3"

    sudo -n -u "$APP_RUN_USER" tee "$dir/app.py" >/dev/null <<'APP' 2>"$err" || return 1
"""Seeded by seed_app_project.sh.

Whatever replaces this must listen on 8080: that is the port
add_app_services.sh publishes on 127.0.0.1:<row port>.
"""
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = b"Hello World!\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("", port), Handler).serve_forever()
APP

    sudo -n -u "$APP_RUN_USER" tee "$dir/Dockerfile" >/dev/null <<'DOCKERFILE'
# Seeded by seed_app_project.sh. Jenkins builds this image on every push and
# runs it; whatever this file builds must listen on port 8080.
FROM python:3.12-slim
WORKDIR /app
COPY . .
# Unbuffered, or nothing the app prints reaches journalctl until it exits.
ENV PYTHONUNBUFFERED=1
ENV PORT=8080
EXPOSE 8080
CMD ["python", "app.py"]
DOCKERFILE

    sudo -n -u "$APP_RUN_USER" tee "$dir/.dockerignore" >/dev/null <<'IGNORE'
__pycache__/
.git/
IGNORE
    [ -f "$dir/.gitignore" ] || sudo -n -u "$APP_RUN_USER" tee "$dir/.gitignore" >/dev/null <<'GITIGNORE'
__pycache__/
*.pyc
GITIGNORE
    return 0
}

preflight_dotnet() {
    if ! command -v dotnet >/dev/null 2>&1; then
        print_error "No dotnet SDK on this machine, so no project can be created."
        print_action "Install one: sudo LinuxBasics/install_scripts/add_dotnet.sh"
        return 1
    fi
    # The template list, not a guess. A name that does not exist otherwise
    # fails inside the loop, once per branch, with dotnet's wording buried.
    if ! dotnet new list "$TEMPLATE" 2>/dev/null | grep -qE "[[:space:]]${TEMPLATE}[[:space:]]"; then
        print_error "No dotnet template called '$TEMPLATE' on this machine."
        print_action "See what there is: dotnet new list"
        return 1
    fi
    return 0
}

# Checked once, and only when a row in this run actually needs it. It used to
# run unconditionally, which would refuse a whole run of Node or Python
# container rows on a machine with no dotnet SDK: the one thing they do not
# need. See item 141.
DOTNET_CHECKED=""
need_dotnet() {
    [ -n "$DOTNET_CHECKED" ] && return "$DOTNET_CHECKED"
    if preflight_dotnet; then DOTNET_CHECKED=0; else DOTNET_CHECKED=1; fi
    return "$DOTNET_CHECKED"
}

SEEDED=()
HAS_PROJECT=()
SKIPPED=()
FAILED=()
UNSUPPORTED=()

while IFS="|" read -r type name port path sub ds opts auth repo branch rowenvs users mode runtime _rest; do
    type="$(trim "$type")"
    name="$(trim "$name")"
    repo="$(trim "$repo")"
    rowenvs="$(trim "$rowenvs")"
    rowbranch="$(trim "$branch")"

    [ -z "$name" ] && continue
    [ -n "$ONLY_ROW" ] && [ "$name" != "$ONLY_ROW" ] && continue

    # Applications only. A website is seed_site_index.sh's job, and seeding a
    # .csproj into a document root would be served as a downloadable file.
    [ "$type" = "app" ] || continue

    # The row says what it is written in, and that decides which arm runs. The
    # same default add_app_services.sh uses, so the two never disagree about a
    # row that leaves the field empty.
    row_runtime="$(printf '%s' "$(trim "$runtime")" | tr '[:upper:]' '[:lower:]')"
    [ -z "$row_runtime" ] && row_runtime="dotnet"
    # dotnet8 -> base dotnet, framework net8.0. Without it `dotnet new` takes
    # the NEWEST SDK on the machine, which is how rows meant to stay on LTS 8
    # were seeded against 10 on 2026-09-07.
    ROW_TFM=""
    case "$row_runtime" in
        dotnet[0-9]*) ROW_TFM="net${row_runtime#dotnet}.0" ;;
    esac
    row_runtime="${row_runtime%%[0-9]*}"

    # Refused BY NAME, before the clone. add_app_services.sh knows dotnet and
    # node; only dotnet can be seeded, because node is not installed here and
    # no row uses it, so a node arm would be code nobody could run. Saying that
    # beats a message about dotnet templates on a Node row.
    if ! declare -F "write_project_$row_runtime" >/dev/null; then
        UNSUPPORTED+=("$name (runtime '$row_runtime': no seeder for it yet)")
        continue
    fi

    # Only the seeds that run `dotnet new` need an SDK here. A Node or Python
    # container's toolchain is inside its own image.
    case "$row_runtime" in
        dotnet|uno|docker)
            if ! need_dotnet; then
                UNSUPPORTED+=("$name (runtime '$row_runtime': no usable dotnet SDK)")
                continue
            fi
            ;;
    esac

    if [ -z "$repo" ] || [ "$repo" = "new" ]; then
        SKIPPED+=("$name (no repository yet)")
        continue
    fi

    # git@github.com:owner/name.git -> https://github.com/owner/name.git
    # HTTPS because the identity this machine holds is the App, and a token
    # cannot ride on an SSH remote. A row still carrying an SSH URL is
    # converted rather than refused.
    https_url="$repo"
    case "$repo" in
        git@github.com:*) https_url="https://github.com/${repo#git@github.com:}" ;;
    esac

    # The row's own owner: a token for the default org cannot push to a
    # repository in another one, and the create puts it in GITHUB_ORG.
    owner="${https_url#https://github.com/}"; owner="${owner%%/*}"
    if ! mint_token "$owner"; then
        FAILED+=("$name: no GitHub App token could be minted for '$owner'")
        continue
    fi

    work="$(sudo -n -u "$APP_RUN_USER" mktemp -d)"
    dir="$work/repo"

    # ONE COMMIT, PROMOTED, not one commit per branch.
    #
    # It used to clone each branch on its own and run `dotnet new` in every
    # clone, so five identical projects arrived as five different commits and
    # nothing was ever a promotion of anything. The owner, 2026-09-07, looking at
    # the repository on GitHub: the initial commit is shared and the second one
    # is not.
    #
    # dev is seeded, then the same commit is pushed along the promotion chain
    # the DTAP doc already describes:
    #
    #     dev -> skunkworks -> test -> accept -> live
    #
    # A branch is only advanced when it is BEHIND that commit, so a branch
    # somebody has pushed to is reported and left exactly as it is.
    cerr="$work/clone.err"
    if ! git_as_app clone -q "$https_url" "$dir" 2>"$cerr"; then
        FAILED+=("$name (cannot clone): $(tr '\n' ' ' < "$cerr" | tail -c 160)")
        rm -rf "$work"
        continue
    fi
    rm -f "$cerr"

    if ! git_as_app -C "$dir" checkout -q dev 2>/dev/null; then
        FAILED+=("$name (no dev branch to seed from)")
        rm -rf "$work"
        continue
    fi

    # =========================================================================
    # ITEM 97: THE ROW'S .NET VERSION CHANGED AND THE PROJECT IS STILL PRISTINE.
    #
    # Changing the Runtime dropdown did nothing to a repository that already had
    # a project, because the test below is only "is there a .csproj". So a row
    # moved from .NET 10 to .NET 8 kept building 10 for ever, and the drawer and
    # the table disagreed, correctly, which is what the owner asked about on
    # 2026-09-08.
    #
    # THREE TESTS, ALL OF THEM, before anything is thrown away. Each one exists
    # to stop a different way of destroying somebody's work:
    #
    #   the marker file exists       this project was made by this script, and
    #                                the marker says which framework it wanted.
    #                                A README paragraph is text anyone can edit.
    #   the seed commit IS the tip   anything after it is somebody's work.
    #   its author is this script    the commit itself was ours, not a person's
    #                                who happened to leave the tree untouched.
    #
    # Any one of them failing means REFUSE LOUDLY and change nothing. A .csproj
    # is never rewritten behind somebody's back: the framework is changed by
    # making the project again, not by editing the file in place.
    # =========================================================================
    RESEED=0
    if [ -n "$ROW_TFM" ] && [ -f "$dir/$SEED_MARKER" ]; then
        marker_tfm="$(sed -n 's/.*"framework"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
                      "$dir/$SEED_MARKER" | head -1)"
        if [ -n "$marker_tfm" ] && [ "$marker_tfm" != "$ROW_TFM" ]; then
            head_author="$(git_as_app -C "$dir" log -1 --format='%an' 2>/dev/null | tr -d '\r')"
            marker_commit="$(git_as_app -C "$dir" log -1 --format='%H' -- "$SEED_MARKER" 2>/dev/null | tr -d '\r')"
            head_commit="$(git_as_app -C "$dir" rev-parse HEAD 2>/dev/null | tr -d '\r')"
            if [ "$head_author" = "seed_app_project.sh" ] && [ "$marker_commit" = "$head_commit" ]; then
                RESEED=1
            else
                # Loud, and it names which test failed: "nothing happened" is
                # what item 97 exists to stop.
                SKIPPED+=("$name/dev: row wants $ROW_TFM and the project is $marker_tfm, but the branch has work on top of the seed commit, so it was left alone")
            fi
        fi
    fi

    if [ "$RESEED" -eq 1 ] && [ "$PUSH" -eq 0 ]; then
        SEEDED+=("$name/dev — would be made again at $ROW_TFM, replacing $marker_tfm")
        rm -rf "$work"
        continue
    fi

    RESEED_MSG=""
    if [ "$RESEED" -eq 1 ]; then
        RESEED_MSG="Make the $TEMPLATE starter project again, now targeting ${ROW_TFM}"
        # Everything except .git goes, then the seeder runs again. Removing the
        # files rather than editing the .csproj is the whole point: a template
        # decides more than the TargetFramework line.
        find "$dir" -mindepth 1 -maxdepth 1 -name '.git' -prune -o -exec rm -rf {} + 2>/dev/null || true
    fi

    if [ "$RESEED" -eq 0 ] && "has_project_$row_runtime" "$dir"; then
        HAS_PROJECT+=("$name/dev")
        SEED_COMMITTED=0
    elif [ "$PUSH" -eq 0 ]; then
        SEEDED+=("$name/dev (branch dev) — would add a '$TEMPLATE' project${ROW_TFM:+ targeting $ROW_TFM}")
        rm -rf "$work"
        continue
    else
        err="$work/seed.err"
        if ! "write_project_$row_runtime" "$dir" "$name" "$err"; then
            FAILED+=("$name/dev: could not create the project: $(tr '\n' ' ' < "$err" | tail -c 200)")
            rm -f "$err"; rm -rf "$work"
            continue
        fi

        # A MARKER FILE, not just the README paragraph below. Item 97: the
        # re-seed has to know this project is still exactly what this script
        # made, and a README paragraph is text anyone can edit without meaning
        # anything by it. This file says what was made and against which
        # framework, and its presence is one of the three tests.
        sudo -n -u "$APP_RUN_USER" tee "$dir/$SEED_MARKER" >/dev/null <<MARKER
{
  "seededBy": "seed_app_project.sh",
  "template": "$TEMPLATE",
  "framework": "${ROW_TFM:-default}",
  "row": "$name"
}
MARKER

        # A README line saying where it came from, so nobody wonders whether
        # somebody wrote this by hand.
        sudo -n -u "$APP_RUN_USER" tee -a "$dir/README.md" >/dev/null <<README

## Starter project

Created by \`seed_app_project.sh\` from the \`$TEMPLATE\` template${ROW_TFM:+, targeting \`$ROW_TFM\`}, so
this branch has something that builds. Replace it with the real application:
nothing overwrites a branch that already has a \`.csproj\`.
README

        # `git add -A` and not `commit -a`. The project is entirely NEW files,
        # and -a stages only tracked ones, so the commit would find nothing and
        # the push would say "Everything up-to-date".
        if git_as_app -C "$dir" add -A 2>"$err" \
           && git_as_app -C "$dir" \
                -c user.email="${APP_RUN_USER}@$(hostname)" \
                -c user.name="seed_app_project.sh" \
                commit -q -m "${RESEED_MSG:-Add a $TEMPLATE starter project so this environment builds}" 2>>"$err" \
           && git_as_app -C "$dir" push -q "$https_url" dev 2>>"$err"; then
            SEEDED+=("$name/dev (branch dev, $TEMPLATE${ROW_TFM:+, $ROW_TFM})")
            SEED_COMMITTED=1
        else
            FAILED+=("$name/dev: $(tr '\n' ' ' < "$err" | tail -c 200)")
            rm -f "$err"; rm -rf "$work"
            continue
        fi
        rm -f "$err"
    fi

    # The promotion order, lowest environment first. Only the ones this row
    # actually has: a row without accept has nothing to promote into it.
    SEED_SHA="$(git_as_app -C "$dir" rev-parse HEAD 2>/dev/null | tr -d '\r')"
    for env in skunk test accept live; do
        row_in_env "$rowenvs" "$env" || continue
        printf '%s\n' "${ALL_ENVS[@]}" | grep -qx "$env" || continue

        # A ROW THAT NAMES ITS BRANCH HAS ANSWERED THE QUESTION, the same rule
        # provision_repo.sh's branches_for() uses.
        if [ -n "$rowbranch" ]; then
            br="$rowbranch"
        else
            env_upper="$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')"
            br="$(conf_get "${env_upper}_BRANCH")"
            [ -z "$br" ] && br="$env"
        fi

        if ! git_as_app -C "$dir" rev-parse -q --verify "origin/$br" >/dev/null 2>&1; then
            SKIPPED+=("$name/$env (no branch '$br' to promote into)")
            continue
        fi

        tip="$(git_as_app -C "$dir" rev-parse "origin/$br" 2>/dev/null | tr -d '\r')"
        if [ "$tip" = "$SEED_SHA" ]; then
            HAS_PROJECT+=("$name/$env (already at the seed commit)")
            continue
        fi

        # Behind the seed commit, so pushing it is a fast-forward and nothing
        # is rewritten. Anything else is somebody's work and is left alone.
        if ! git_as_app -C "$dir" merge-base --is-ancestor "$tip" "$SEED_SHA" 2>/dev/null; then
            SKIPPED+=("$name/$env (branch '$br' has its own commits, so it was not promoted)")
            continue
        fi

        if [ "$PUSH" -eq 0 ]; then
            SEEDED+=("$name/$env (branch $br) — would be promoted to the seed commit")
            continue
        fi

        perr="$work/$env.push.err"
        if git_as_app -C "$dir" push -q "$https_url" "$SEED_SHA:refs/heads/$br" 2>"$perr"; then
            SEEDED+=("$name/$env (branch $br, promoted from dev)")
        else
            FAILED+=("$name/$env: $(tr '\n' ' ' < "$perr" | tail -c 200)")
        fi
        rm -f "$perr"
    done
    rm -rf "$work"
done < <(conf_rows)

for r in ${HAS_PROJECT+"${HAS_PROJECT[@]}"}; do print_status  "Already has a project: $r"; done
for r in ${SEEDED+"${SEEDED[@]}"};      do print_success "$r"; done
for r in ${SKIPPED+"${SKIPPED[@]}"};    do print_info    "$r"; done
for r in ${UNSUPPORTED+"${UNSUPPORTED[@]}"}; do print_info "$r"; done
for r in ${FAILED+"${FAILED[@]}"};      do print_error   "$r"; done

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
    print_error "Some branches were not seeded."
    exit 1
fi

if [ ${#SEEDED[@]} -eq 0 ] && [ ${#HAS_PROJECT[@]} -eq 0 ] && [ ${#SKIPPED[@]} -eq 0 ]; then
    # NOT "every branch already has one". With no application rows at all
    # there is no branch to have anything, and saying otherwise reads as a
    # pass over work that was never attempted.
    print_info "No application row in the config, so there was nothing to seed."
elif [ ${#SEEDED[@]} -eq 0 ]; then
    print_success "Every application branch already has a project."
else
    if [ "$PUSH" -eq 0 ]; then
        print_action "Nothing was written. Add --push to create these."
    else
        print_success "${#SEEDED[@]} branch(es) seeded."
        print_status "The next deploy builds them. Prove it with verify_app.sh."
    fi
fi
