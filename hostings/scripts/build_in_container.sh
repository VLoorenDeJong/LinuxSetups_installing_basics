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
# Run a .NET command inside the WebAssembly builder container.
#
#   build_in_container.sh image
#   build_in_container.sh publish <dir> <project.csproj> <out> [<framework>]
#   build_in_container.sh new     <dir> <dotnet new arguments...>
#
# WHY A CONTAINER: this machine's .NET is Ubuntu's apt build, and the
# wasm-tools workload does not attach to it (UNOWA0001, measured 2026-09-17).
# Microsoft's SDK image with wasm-tools does build Uno. The container only
# COMPILES; what it produces runs natively.
#
# WHY ROOT, and what keeps it small: Jenkins is granted this one script by
# sudo, never the docker group, which would be root outright. The container
# runs as the OWNER of <dir>, sees only <dir> and a NuGet cache, and gets no
# Docker socket. For `publish`, <dir> must sit inside Jenkins' workspace.
# =============================================================================

print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1" >&2; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1" >&2; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

IMAGE="hostings/dotnet-wasm-builder:10.0"
BASE_IMAGE="mcr.microsoft.com/dotnet/sdk:10.0"
WORKSPACE_ROOT="/var/lib/jenkins/workspace"
NUGET_CACHE="/var/cache/hostings/nuget-container"
BUILD_TIMEOUT="90m"

if [ "$EUID" -ne 0 ]; then
    print_error "This needs root: it starts containers."
    exit 1
fi
command -v docker >/dev/null 2>&1 || {
    print_error "Docker is not installed."
    print_action "Install it: sudo bash LinuxBasics/install_scripts/add_docker.sh"
    exit 1
}

ensure_image() {
    if [ "${1:-}" != "rebuild" ] && docker image inspect "$IMAGE" >/dev/null 2>&1; then
        return 0
    fi
    print_status "Building $IMAGE from $BASE_IMAGE (about 3 minutes, once)"
    local ctx; ctx="$(mktemp -d)"
    cat > "$ctx/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_CLI_HOME=/opt/dotnet-home NUGET_PACKAGES=/nuget
# Emscripten, which wasm-tools drives, needs a python on PATH.
RUN apt-get update && apt-get install -y --no-install-recommends python3 python-is-python3 \\
 && rm -rf /var/lib/apt/lists/*
RUN dotnet workload install wasm-tools
RUN mkdir -p /opt/dotnet-home /nuget && dotnet new install Uno.Templates \\
 && chmod -R a+rwX /opt/dotnet-home /nuget
EOF
    if ! docker build --pull -t "$IMAGE" "$ctx" >&2; then
        rm -rf "$ctx"
        print_error "Could not build $IMAGE."
        return 1
    fi
    rm -rf "$ctx"
    print_success "Built $IMAGE."
}

# A relative path with no way out of <dir>.
safe_rel() {
    case "$1" in
        ""|/*|..|../*|*/../*|*/..) return 1 ;;
    esac
    return 0
}

run_in() {
    local dir="$1"; shift
    local owner; owner="$(stat -c '%u:%g' "$dir")"
    if [ "${owner%%:*}" = "0" ]; then
        print_error "$dir is owned by root; refusing to build as root."
        return 1
    fi
    # One cache per build account, not one 0777 cache: a shared writable cache
    # lets any local account plant a package the next build trusts. Audit M5.
    local cache="$NUGET_CACHE/${owner%%:*}"
    # Still 0777 means the old shared cache: anything in it may be planted, so
    # it is emptied once. A cache costs a re-download, nothing more.
    # The mode is read first and closed second, so nothing can be planted
    # between the emptying and the chmod.
    local was_shared=""
    [ -d "$NUGET_CACHE" ] && [ ! -L "$NUGET_CACHE" ] \
        && was_shared="$(find "$NUGET_CACHE" -maxdepth 0 -perm -0002)"
    install -d -m 0755 -o root -g root "$NUGET_CACHE"
    if [ -n "$was_shared" ]; then
        find "$NUGET_CACHE" -mindepth 1 -delete
        print_info "Emptied the old shared NuGet cache $NUGET_CACHE, which any account could write to."
    fi
    # Left over from the old 0777 cache, a link here would make root chown its target.
    if [ -L "$cache" ] || { [ -e "$cache" ] && [ ! -d "$cache" ]; }; then
        print_error "$cache is not a plain directory; refusing to build."
        print_action "Look at it, then: sudo rm -rf $cache"
        return 1
    fi
    install -d -m 0700 -o "${owner%%:*}" -g "${owner##*:}" "$cache"
    timeout "$BUILD_TIMEOUT" docker run --rm \
        --user "$owner" \
        -e HOME=/tmp \
        -v "$dir":/src \
        -v "$cache":/nuget \
        -w /src \
        "$IMAGE" "$@" >&2
}

MODE="${1:-}"
[ $# -gt 0 ] && shift

# Jenkins is granted this script for publishing only: `new` runs as the owner
# of any directory it is pointed at.
if [ "${SUDO_USER:-}" = "jenkins" ] && [ "$MODE" != "publish" ]; then
    print_error "Only 'publish' may be run through sudo by jenkins."
    exit 2
fi

case "$MODE" in
    image)
        ensure_image "${1:-}"
        ;;
    publish)
        [ $# -ge 3 ] || { print_error "Usage: $0 publish <dir> <project.csproj> <out> [<framework>]"; exit 2; }
        DIR="$(realpath -e "$1" 2>/dev/null)" || { print_error "No such directory: $1"; exit 2; }
        case "$DIR/" in
            "$WORKSPACE_ROOT"/*) ;;
            *) print_error "Refusing $DIR: publish only builds inside $WORKSPACE_ROOT."; exit 2 ;;
        esac
        safe_rel "$2" || { print_error "Project path must be relative and stay inside the checkout: $2"; exit 2; }
        safe_rel "$3" || { print_error "Output path must be relative and stay inside the checkout: $3"; exit 2; }
        [ -f "$DIR/$2" ] || { print_error "No project at $DIR/$2"; exit 2; }
        FW=()
        if [ -n "${4:-}" ]; then
            echo "$4" | grep -qE '^net[0-9]+\.[0-9]+(-[a-z0-9]+)?$' || { print_error "Not a framework name: $4"; exit 2; }
            FW=(-f "$4")
        fi
        ensure_image
        print_status "dotnet publish $2 -c Release -o $3 ${FW[*]} (in $IMAGE)"
        run_in "$DIR" dotnet publish "$2" -c Release -o "$3" ${FW+"${FW[@]}"}
        print_success "Published to $DIR/$3"
        ;;
    new)
        [ $# -ge 2 ] || { print_error "Usage: $0 new <dir> <dotnet new arguments...>"; exit 2; }
        DIR="$(realpath -e "$1" 2>/dev/null)" || { print_error "No such directory: $1"; exit 2; }
        shift
        ensure_image
        run_in "$DIR" dotnet new "$@"
        ;;
    *)
        print_error "Usage: $0 image | publish <dir> <project> <out> [<framework>] | new <dir> <args...>"
        exit 2
        ;;
esac
