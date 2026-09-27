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
# What this machine can build, and what it deliberately cannot.
#
# WHY THE UNSUPPORTED ONES ARE LISTED RATHER THAN HIDDEN
#
# Item 67 settled this for startup projects and the reasoning is the same here:
# a reader whose framework is simply ABSENT from a dropdown has no idea whether
# it is unsupported, misspelled, or a bug. Listed and disabled, with the reason
# and the missing piece named, answers the question in place.
#
# So every platform appears. `supported` says whether a row can be created for
# it today, `reason` says why not, and `needs` names the one thing that would
# change the answer.
#
# THREE KINDS OF "NO", AND THEY ARE NOT THE SAME
#
#   missing-runtime   the shape is right and the machine lacks a tool. A script
#                     exists or could be written. Reversible today.
#   wrong-row-type    it works, but it is not a website: a running server wants
#                     an application row. Choosing it here would be a mistake
#                     whatever is installed.
#   out-of-scope      nothing here serves it at all, at any row type.
#
# A dropdown that renders all three as one grey "unsupported" throws away the
# only information the reader needs, which is whether waiting helps.
#
# Usage:
#   list_site_platforms.sh              JSON, for the console
#   list_site_platforms.sh --table      a table, for a person at a terminal
# =============================================================================

print_error() { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

MODE="json"
case "${1:-}" in
    "")       ;;
    --table)  MODE="table" ;;
    *)
        print_error "Unknown argument: $1"
        printf "\033[33m👉 Use --table, or no argument for JSON.\033[0m\n" >&2
        exit 1 ;;
esac

# -----------------------------------------------------------------------------
# What is actually installed. Asked, never assumed: this script exists to tell
# the truth about THIS machine, so a hardcoded answer would defeat it.
# -----------------------------------------------------------------------------
HAVE_NPM=0
HAVE_NODE_V=""
if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
    HAVE_NPM=1
    HAVE_NODE_V="$(node --version 2>/dev/null || true)"
fi

HAVE_DOTNET=0
command -v dotnet >/dev/null 2>&1 && HAVE_DOTNET=1

HAVE_JAVA=0
command -v java >/dev/null 2>&1 && HAVE_JAVA=1

# The SOCKET, not the php binary. The CLI being present says nothing about
# whether Apache can run a .php file, and that is the question a website row
# actually asks.
HAVE_PHP_FPM=0
for _s in /run/php/php*-fpm.sock; do
    [ -S "$_s" ] && HAVE_PHP_FPM=1 && break
done
unset _s

# -----------------------------------------------------------------------------
# The catalogue.
#
# id | label | kind | supported | reason | needs
#
# `kind` is what the reader is choosing, not how it is built:
#   static  compiles to files a web server serves     -> website row
#   app     stays running and answers requests        -> application row
#   none    this fleet does not serve it at all
# -----------------------------------------------------------------------------
ROWS=()

npm_static() {
    local id="$1" label="$2"
    if [ "$HAVE_NPM" = "1" ]; then
        ROWS+=("$id|$label|static|yes||")
    else
        ROWS+=("$id|$label|static|no|missing-runtime: node and npm are not installed|sudo bash LinuxBasics/install_scripts/add_node.sh")
    fi
}

npm_static vue      "Vue"
npm_static angular  "Angular"
npm_static react    "React"
npm_static svelte   "Svelte"
npm_static astro    "Astro"
npm_static solid    "SolidJS"
npm_static vite     "Vite, no framework"

# Next and Nuxt are the awkward pair: the SAME project is a website or an
# application depending on one setting, so neither answer alone is honest.
if [ "$HAVE_NPM" = "1" ]; then
    ROWS+=("nextjs-static|Next.js, static export|static|yes||")
    ROWS+=("nuxt-static|Nuxt, static generate|static|yes||")
else
    ROWS+=("nextjs-static|Next.js, static export|static|no|missing-runtime: node and npm are not installed|sudo bash LinuxBasics/install_scripts/add_node.sh")
    ROWS+=("nuxt-static|Nuxt, static generate|static|no|missing-runtime: node and npm are not installed|sudo bash LinuxBasics/install_scripts/add_node.sh")
fi
ROWS+=("nextjs-server|Next.js, server mode|app|no|wrong-row-type: it stays running, so it needs an application row and a reverse proxy|an application row, plus a Node service seeder that does not exist yet")
ROWS+=("nuxt-server|Nuxt, server mode|app|no|wrong-row-type: it stays running, so it needs an application row and a reverse proxy|an application row, plus a Node service seeder that does not exist yet")

# Plain files: always available, because there is nothing to install.
ROWS+=("html|Plain HTML, CSS and JavaScript|static|yes||")

# dotnet: an application, and the only application type with a seeder.
if [ "$HAVE_DOTNET" = "1" ]; then
    ROWS+=("dotnet|.NET, Blazor or ASP.NET|app|yes||")
else
    ROWS+=("dotnet|.NET, Blazor or ASP.NET|app|no|missing-runtime: dotnet is not installed|sudo bash LinuxBasics/install_scripts/add_dotnet.sh")
fi

# Blazor WebAssembly is dotnet that compiles to static files, so it is a
# WEBSITE row even though it is written in C#. Item 67 hit exactly this with
# Portfolio2.0App.Client and called it not-runnable, correctly.
if [ "$HAVE_DOTNET" = "1" ]; then
    ROWS+=("blazor-wasm|Blazor WebAssembly|static|yes||")
else
    ROWS+=("blazor-wasm|Blazor WebAssembly|static|no|missing-runtime: dotnet is not installed|sudo bash LinuxBasics/install_scripts/add_dotnet.sh")
fi

# Java: the runtime installs, and nothing seeds or deploys it.
if [ "$HAVE_JAVA" = "1" ]; then
    ROWS+=("java|Java, Spring Boot|app|no|missing-runtime: java is installed but nothing here seeds or deploys a Java application|a Java arm in seed_app_project.sh and deploy_app.sh")
else
    ROWS+=("java|Java, Spring Boot|app|no|missing-runtime: java is not installed, and nothing here seeds or deploys a Java application|sudo bash LinuxBasics/install_scripts/add_java.sh, then a Java arm in seed_app_project.sh")
fi

ROWS+=("node-api|Node API: Express, NestJS, Fastify|app|no|wrong-row-type: it stays running, so it needs an application row and a reverse proxy|an application row, plus a Node service seeder that does not exist yet")
# PHP IS A WEBSITE ROW, NOT AN APPLICATION ROW, and that is the whole reason it
# is cheap. It has no build step and nothing stays running: Apache hands a .php
# file to the FPM pool per request, so the repository IS the site.
#
# Decided 2026-09-06 by the owner: PHP yes, WordPress no. WordPress keeps its
# content in a database and wp-content rather than in git, so a rebuild from the
# repository would give an empty site.
#
# Reported unsupported if the FPM socket is not there, because without it Apache
# sends the PHP source to the browser rather than running it, and a site that
# publishes its own code is worse than one that refuses to be made.
if [ "$HAVE_PHP_FPM" = "1" ]; then
    ROWS+=("php|PHP, no framework|static|yes||")
else
    ROWS+=("php|PHP, no framework|static|no|missing-runtime: no php-fpm socket, so Apache would serve .php as text|sudo apt install php-fpm, then a2enconf php<version>-fpm")
fi
ROWS+=("python|Python: Django, Flask, FastAPI|app|no|out-of-scope: nothing here installs, seeds or runs a Python application|a runtime installer, a seeder and a deploy arm")
ROWS+=("electron|Electron desktop app|none|no|out-of-scope: a desktop application is not served by a web server at all|nothing. It does not belong on this machine")

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------
if [ "$MODE" = "table" ]; then
    printf "\n\033[36m=== What this machine can build ===\033[0m\n"
    [ "$HAVE_NPM" = "1" ] \
        && printf "\033[36mℹ️ node %s with npm, so npm sites build here.\033[0m\n" "$HAVE_NODE_V" \
        || printf "\033[33m👉 No node or npm, so every npm site is unavailable.\033[0m\n"
    printf "\n%-16s %-34s %-7s %s\n" "ID" "PLATFORM" "ROW" "STATE"
    for r in "${ROWS[@]}"; do
        IFS='|' read -r id label kind sup reason needs <<< "$r"
        if [ "$sup" = "yes" ]; then
            printf "\033[32m%-16s %-34s %-7s %s\033[0m\n" "$id" "$label" "$kind" "available"
        else
            printf "\033[33m%-16s %-34s %-7s %s\033[0m\n" "$id" "$label" "$kind" "$reason"
            [ -n "$needs" ] && printf "%-16s %-34s %-7s   needs: %s\n" "" "" "" "$needs"
        fi
    done
    echo ""
    exit 0
fi

# JSON, for the console's dropdown. Hand-built rather than jq, so this runs on
# a machine that has not installed jq: the fleet cannot assume it.
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

printf '{"node":"%s","platforms":[' "$(json_escape "$HAVE_NODE_V")"
first=1
for r in "${ROWS[@]}"; do
    IFS='|' read -r id label kind sup reason needs <<< "$r"
    [ "$first" = "1" ] || printf ','
    first=0
    printf '{"id":"%s","label":"%s","row":"%s","supported":%s,"reason":"%s","needs":"%s"}' \
        "$(json_escape "$id")" \
        "$(json_escape "$label")" \
        "$(json_escape "$kind")" \
        "$([ "$sup" = "yes" ] && echo true || echo false)" \
        "$(json_escape "$reason")" \
        "$(json_escape "$needs")"
done
printf ']}\n'
