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
# Build an npm website checkout, and say which directory to publish.
#
# WHAT IT SUPPORTS, and the boundary is npm rather than a list of frameworks:
# any repository with a package.json carrying a "build" script.
#
#   Vue, Vite, Svelte, Astro   dist/index.html
#   Angular 17 and newer       dist/<project>/browser/index.html
#   Angular 16 and older       dist/<project>/index.html
#   React, Create React App    build/index.html
#
# Named for npm deliberately. A name listing three frameworks would be wrong
# the day a fourth is added, and would suggest an unlisted one is unsupported
# when it works perfectly well.
#
# "STATIC" IS THE OTHER HALF OF THE NAME, and it is the real boundary. npm also
# builds servers, APIs, desktop apps and libraries, and none of those belong
# here: this handles npm projects whose build produces FILES A WEB SERVER CAN
# SERVE, and refuses the rest by name rather than by failing obscurely.
#
# Worth knowing, because the phrase is overloaded: "static site" elsewhere
# usually means a static site generator such as Hugo, Jekyll or Eleventy. Only
# the last of those is npm. Here it means the OUTPUT is static, whatever built
# it.
#
# WHAT IT IS NOT FOR
#
#   a plain HTML site   passed through untouched, so this is safe to call on
#                       every website row rather than only the ones needing it
#   a dotnet row        deploy_app.sh, which publishes a DLL and restarts a unit
#   a java row          nothing exists yet: there is no seeder for one
#   a running Node server  that is an application row with a unit and a reverse
#                       proxy, the opposite of what this produces
#
# WHAT THIS EXISTS FOR
#
# A Vue, Angular, React or Svelte project is not servable as it sits in git: the
# repository holds sources, and Apache needs the compiled output. Until this
# script existed, deploy_static_site.sh copied the checkout verbatim, so such a
# repository published its package.json and src/ and served nothing.
#
# A plain HTML site has no package.json and is passed straight through, so this
# is safe to call on every website row rather than only the ones that need it.
#
# IT PRINTS THE DIRECTORY, IT DOES NOT DEPLOY
#
# One job, and the caller decides what to do with the answer. Everything a
# reader needs goes to stderr and the directory alone goes to stdout, so
#
#     DIR="$(build_npm_static_site.sh ./site)"
#
# is the whole contract and a failure is a non-zero exit, never a path.
#
# IT RUNS AS THE BUILD ACCOUNT, NEVER AS ROOT
#
# `npm ci` and `npm run build` execute lifecycle scripts out of the repository
# being built, which is arbitrary code from a source this machine does not
# control. The website pipeline deliberately has no sudo, so that code runs as
# the CI account and nothing more. Running this under sudo would hand a site
# repository root on the build machine, and it refuses to.
#
# Usage:
#   build_npm_static_site.sh <checkout-dir>
#
# Environment:
#   SKIP_BUILD=1   pass the checkout through untouched, whatever is in it
#   BUILD_CMD      the npm script to run, default: build
#   NPM_FLAGS      extra flags for the install step
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1" >&2; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1" >&2; }

# Yellow means "this needs you", never "warning": a question, an instruction, a
# URL to go and open. Anything the reader cannot act on is cyan.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1" >&2; }

usage() {
    echo "Usage: $0 <checkout-dir>" >&2
    echo "" >&2
    echo "Prints the directory to publish on stdout. Everything else is stderr." >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  SKIP_BUILD=1   pass the checkout through untouched" >&2
    echo "  BUILD_CMD      the npm script to run, default: build" >&2
    echo "  NPM_FLAGS      extra flags for the install step" >&2
    exit 1
}

SRC="${1:-}"
[ -z "$SRC" ] && usage
[ -d "$SRC" ] || { print_error "Not a directory: $SRC"; exit 1; }
SRC="$(cd "$SRC" && pwd)"

BUILD_CMD="${BUILD_CMD:-build}"

# Refused rather than warned about. A build that runs as root writes a
# root-owned node_modules into a workspace the CI account owns, so the NEXT
# build fails with a permission error that says nothing about this one.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    print_error "This must not run as root: it executes build scripts from the site repository."
    print_action "Run it as the account that owns the workspace, with no sudo."
    exit 1
fi

# -----------------------------------------------------------------------------
# Nothing to build?
#
# A plain HTML site is the common case and must cost nothing, so the question is
# asked before anything else happens.
# -----------------------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" = "1" ]; then
    print_info "SKIP_BUILD=1, so the checkout is published as it is."
    printf '%s\n' "$SRC"
    exit 0
fi

# An Uno WebAssembly site (item 139). Built in the builder container through
# the one script Jenkins may sudo, because this machine's .NET cannot build WASM.
if [ -f "$SRC/global.json" ] && grep -q '"Uno.Sdk"' "$SRC/global.json"; then
    UNO_PROJ="$(cd "$SRC" && grep -rl --include='*.csproj' 'browserwasm' . 2>/dev/null | grep -v '/\.git/' | sort | head -n1)"
    UNO_PROJ="${UNO_PROJ#./}"
    if [ -z "$UNO_PROJ" ]; then
        print_error "This is an Uno repository, but no .csproj targets browserwasm."
        print_action "Add the web head: <TargetFrameworks>net10.0-browserwasm</TargetFrameworks> in the project."
        exit 1
    fi
    UNO_TFM="$(grep -oE 'net[0-9]+\.[0-9]+-browserwasm' "$SRC/$UNO_PROJ" | head -n1)"
    print_header "Building $(basename "$SRC"): Uno WebAssembly, $UNO_PROJ ($UNO_TFM)"
    print_info "In the builder container. The first build of a repository takes about 15 minutes on this machine."
    rm -rf "$SRC/.publish"
    sudo -n bash /usr/local/lib/linuxbasics/hostings/scripts/build_in_container.sh \
        publish "$SRC" "$UNO_PROJ" .publish "$UNO_TFM" >&2
    if [ ! -f "$SRC/.publish/wwwroot/index.html" ]; then
        print_error "The publish finished but left no .publish/wwwroot/index.html."
        exit 1
    fi
    # The Uno build writes AppManifest.js as 0600, and Apache then answers 403
    # and the app never starts.
    chmod -R a+rX "$SRC/.publish/wwwroot"
    printf '%s\n' "$SRC/.publish/wwwroot"
    exit 0
fi

if [ ! -f "$SRC/package.json" ]; then
    print_info "No package.json, so this is a plain site and needs no build."
    printf '%s\n' "$SRC"
    exit 0
fi

print_header "Building $(basename "$SRC")"

# A package.json with no build script is a site that ships its own files and
# merely happens to declare dependencies. Publishing the checkout is right.
if ! grep -qE '"'"$BUILD_CMD"'"[[:space:]]*:' "$SRC/package.json"; then
    print_info "package.json has no \"$BUILD_CMD\" script, so the checkout is published as it is."
    printf '%s\n' "$SRC"
    exit 0
fi

# -----------------------------------------------------------------------------
# Pre-flight: refuse before writing anything.
# -----------------------------------------------------------------------------
if ! command -v npm >/dev/null 2>&1; then
    print_error "This site needs a build and npm is not installed on this machine."
    print_action "Install it: sudo bash LinuxBasics/install_scripts/add_node.sh"
    exit 1
fi

NODE_V="$(node --version 2>/dev/null || echo unknown)"
print_status "node $NODE_V, npm $(npm --version 2>/dev/null || echo unknown)"

# -----------------------------------------------------------------------------
# Angular pins Node, and Node is one version for the whole machine.
#
# The coupling runs the opposite way from what people expect. The Angular
# version is committed per site in its package.json and `npm ci` installs
# exactly that; Node is installed once by add_node.sh and every site on this
# machine shares it. So an old site does not fail because it is old, it fails
# because the machine moved on without it.
#
# Only combinations known to be refused are stopped here. Anything newer than
# the table is left to the CLI, which knows its own requirements better than a
# hardcoded list ever will.
#
#   Angular 18+   Node 20.11+ or 22
#   Angular 17    Node 18.13+ or 20
#   Angular <= 16 Node 16 or 18
#
# Without this the build dies inside npm with the CLI's own message, which
# names a Node version and no way to get one.
# -----------------------------------------------------------------------------
NG_MAJOR="$(grep -oE '"@angular/core"[[:space:]]*:[[:space:]]*"[^"]*"' "$SRC/package.json" 2>/dev/null \
    | grep -oE '[0-9]+' | head -n1 || true)"
NODE_MAJOR="$(printf '%s' "$NODE_V" | grep -oE '[0-9]+' | head -n1 || true)"

if [ -n "$NG_MAJOR" ] && [ -n "$NODE_MAJOR" ]; then
    NG_NEEDS=""
    NG_SUGGEST=""
    if [ "$NG_MAJOR" -le 16 ] && [ "$NODE_MAJOR" -ge 20 ]; then
        NG_NEEDS="16 or 18"
        NG_SUGGEST=18
    elif [ "$NG_MAJOR" -eq 17 ] && [ "$NODE_MAJOR" -ge 22 ]; then
        NG_NEEDS="18 or 20"
        NG_SUGGEST=20
    fi

    if [ -n "$NG_NEEDS" ]; then
        print_error "This site is Angular $NG_MAJOR, which needs Node $NG_NEEDS. This machine runs $NODE_V."
        print_info "Nothing was installed and nothing was built."
        print_action "Either raise the site: bump @angular/core in its package.json and commit the new lockfile."
        print_action "Or lower the machine: sudo bash LinuxBasics/install_scripts/add_node.sh --major $NG_SUGGEST"
        print_action "There is no per-site Node here, so lowering it changes the build for EVERY site on this machine."
        exit 1
    fi

    print_status "Angular $NG_MAJOR on node $NODE_V"
fi

# A guard that skips itself in silence is the shape items 29 and 59 record. It
# can only happen when `node --version` failed, which npm being present two
# checks earlier makes unlikely, so it says so rather than refusing.
if [ -n "$NG_MAJOR" ] && [ -z "$NODE_MAJOR" ]; then
    print_action "This site is Angular $NG_MAJOR and the node version could not be read ($NODE_V),"
    print_action "  so the version check was skipped. The build will say if they do not match."
fi

# -----------------------------------------------------------------------------
# Install, then build.
#
# `npm ci` when there is a lockfile, because it installs exactly what was
# committed and is the reason a lockfile exists. Without one it refuses
# outright, so `npm install` is the fallback rather than a preference.
# -----------------------------------------------------------------------------
cd "$SRC"

# RETRIED ONCE WITH --legacy-peer-deps, and the retry is said out loud.
#
# Measured 2026-09-05: a stock `ng new` scaffold fails its own install on
# npm 10.9.8 with "Cannot read properties of null (reading 'edgesOut')", which
# names nothing an operator can act on and looks like a broken npm rather than
# a peer-dependency conflict. The same tree installs cleanly with
# --legacy-peer-deps. Vue installed fine, so a blanket flag would weaken every
# other build to fix one.
#
# The retry is not silent: a build that quietly relaxes dependency resolution
# is a build whose lockfile no longer means what it says.
npm_install_with_retry() {
    local mode="$1"
    shift
    # shellcheck disable=SC2086
    if npm "$mode" --no-audit --no-fund ${NPM_FLAGS:-} "$@" >&2; then
        return 0
    fi
    print_action "npm $mode failed. Retrying once with --legacy-peer-deps, which is usually a peer-dependency conflict."
    # shellcheck disable=SC2086
    if npm "$mode" --no-audit --no-fund --legacy-peer-deps ${NPM_FLAGS:-} "$@" >&2; then
        print_action "It succeeded with --legacy-peer-deps, so this project has conflicting peer dependencies."
        print_action "Set NPM_FLAGS=--legacy-peer-deps on the job, or fix the versions in package.json."
        return 0
    fi
    print_error "npm $mode failed both with and without --legacy-peer-deps."
    return 1
}

if [ -f package-lock.json ]; then
    print_status "npm ci, from the committed lockfile"
    npm_install_with_retry ci
else
    print_action "No package-lock.json, so the build is not reproducible: npm install resolves versions afresh."
    print_action "Commit the lockfile to pin them."
    npm_install_with_retry install
fi

print_status "npm run $BUILD_CMD"
npm run "$BUILD_CMD" >&2

# -----------------------------------------------------------------------------
# Where did it put the files?
#
# Every toolchain answers this differently and none of them declares it in a
# way that can be read, so the output is FOUND rather than assumed:
#
#   Vite, Vue, Svelte   dist/index.html
#   Angular 17+         dist/<project>/browser/index.html
#   Angular 16 and back dist/<project>/index.html
#   Create React App    build/index.html
#
# The shallowest directory holding an index.html wins, which is correct for all
# four: where Angular nests, nothing shallower exists to beat it.
#
# Guessing `dist` would publish Angular's empty parent directory, and the site
# would answer 403 with every file present on disk.
# -----------------------------------------------------------------------------
OUT=""
BEST_DEPTH=999
for root in dist build out public .output/public; do
    [ -d "$SRC/$root" ] || continue
    while IFS= read -r found; do
        [ -n "$found" ] || continue
        dir="$(dirname "$found")"
        # Depth relative to the checkout, so dist beats dist/x/browser.
        rel="${dir#$SRC/}"
        depth="$(printf '%s' "$rel" | tr -cd '/' | wc -c)"
        if [ "$depth" -lt "$BEST_DEPTH" ]; then
            BEST_DEPTH="$depth"
            OUT="$dir"
        fi
    done <<EOF
$(find "$SRC/$root" -maxdepth 3 -name index.html -type f 2>/dev/null)
EOF
done

if [ -z "$OUT" ]; then
    print_error "The build succeeded and produced no index.html anywhere under dist, build, out or public."
    print_error "Looked in: $(cd "$SRC" && ls -d dist build out public 2>/dev/null | tr '\n' ' ')"

    # NAMED, NOT LEFT TO BE WORKED OUT. The commonest reason a successful npm
    # build has no index.html is that the project is a server rather than a
    # site, and the answer to that is a different row type, not a fix here.
    # An error that only says "no index.html" sends the reader looking for a
    # build bug that does not exist.
    if grep -qE '"(express|fastify|@nestjs/core|koa|hapi)"[[:space:]]*:' package.json 2>/dev/null; then
        print_error "package.json depends on a web server framework, so this looks like a SERVER, not a site."
        print_action "A running Node application needs an application row with a unit and a reverse proxy,"
        print_action "not a website row. Nothing here can serve it."
        exit 1
    fi
    if grep -qE '"(electron|electron-builder)"[[:space:]]*:' package.json 2>/dev/null; then
        print_error "package.json depends on Electron, so this is a desktop application and not a website."
        exit 1
    fi
    if grep -qE '"(next|nuxt)"[[:space:]]*:' package.json 2>/dev/null; then
        print_error "This is a Next.js or Nuxt project built in SERVER mode, which needs a running process."
        print_action "Either switch it to static export, which writes out/ or .output/public,"
        print_action "or give it an application row instead of a website row."
        exit 1
    fi

    print_action "Check what \"$BUILD_CMD\" writes, and where."
    exit 1
fi

# Said out loud, because a build that quietly published the wrong directory is
# indistinguishable from a broken site until somebody opens it.
FILES="$(find "$OUT" -type f | wc -l)"
BYTES="$(du -sh "$OUT" 2>/dev/null | cut -f1)"
print_success "Built ${FILES} files (${BYTES}) into ${OUT#$SRC/}"

printf '%s\n' "$OUT"
