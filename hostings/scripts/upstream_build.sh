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
# Build one upstream package's image at a release, and prove it starts.
#
#   upstream_build.sh <name> [version] [--rebuild]
#   upstream_build.sh <name> <version> --check     health-check the built image again
#
# No version means the newest stable release by the recipe's RELEASE_RULE.
# The image is upstream-<name>:<version>. It only joins the list of versions
# upstream_promote.sh accepts once a throwaway copy of it has answered on
# HEALTH_PATH, so a release that builds but does not start never reaches a row.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "${s//$'\r'/}"; }
recipe_all() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$RECIPE" | tr -d '\r' | sed 's/[[:space:]]*$//'; }
recipe_get() { local v; v="$(recipe_all "$1" | head -n1)"; printf '%s' "${v:-$2}"; }

# Kill-safe: a build is retried by running this again. Dots, because docker's
# own progress is a wall of layer ids that says nothing about how long is left.
run_logged() {
    local what="$1" limit="$2" log="$3"; shift 3
    printf "\033[34m🔧 %s\033[0m " "$what"
    if [ "$DEBUG_MODE" = "1" ]; then
        printf '\n'; timeout "$limit" "$@" 2>&1 | tee "$log"; return "${PIPESTATUS[0]}"
    fi
    timeout "$limit" "$@" > "$log" 2>&1 &
    local pid=$! rc=0
    while kill -0 "$pid" 2>/dev/null; do printf '.'; sleep 5; done
    wait "$pid" || rc=$?
    printf '\n'
    if [ "$rc" -ne 0 ]; then
        print_error "$what failed (exit $rc). Last lines:"
        tail -n 20 "$log" | sed 's/^/   /'
        print_info "Full log: $log"
    fi
    return "$rc"
}

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
    esac | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1
}

NAME="" VERSION="" REBUILD=0 CHECK_ONLY=0
for a in "$@"; do
    case "$a" in
        --rebuild) REBUILD=1 ;;
        --check)   CHECK_ONLY=1 ;;
        *) if [ -z "$NAME" ]; then NAME="$a"; else VERSION="$a"; fi ;;
    esac
done
if [ -z "$NAME" ]; then
    print_error "Usage: $0 <name> [version] [--rebuild | --check]"
    exit 2
fi

# --- Pre-flight: everything checked before anything is written ---------------

[ "$EUID" -eq 0 ] || { print_error "This needs root: it builds and runs containers."; print_action "sudo bash $0 $*"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIECE="$REPO_ROOT/hostings/upstream/$NAME"
RECIPE="$PIECE/recipe.conf"
STATE="/var/lib/upstream/$NAME"

[ -f "$RECIPE" ] || { print_error "No recipe at $RECIPE"; print_action "Known packages: $(ls "$REPO_ROOT/hostings/upstream" 2>/dev/null | grep -v README | tr '\n' ' ')"; exit 1; }
{ command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; } \
    || { print_error "Docker is not usable."; print_action "sudo bash $REPO_ROOT/install_scripts/check_docker.sh"; exit 1; }
command -v git >/dev/null 2>&1 || { print_error "git is not installed."; exit 1; }

UPSTREAM="$(recipe_get UPSTREAM)"
RULE="$(recipe_get RELEASE_RULE github-stable)"
SOURCE="$(recipe_get SOURCE upstream)"
DOCKERFILE="$(recipe_get DOCKERFILE Dockerfile)"
CPORT="$(recipe_get CONTAINER_PORT 8080)"
HPATH="$(recipe_get HEALTH_PATH /)"
HWAIT="$(recipe_get HEALTH_WAIT 120)"

[ -n "$UPSTREAM" ] || { print_error "$RECIPE has no UPSTREAM."; exit 1; }
case "$RULE" in github-stable) ;; nuget|npm) [ -n "$(recipe_get PACKAGE)" ] || { print_error "RELEASE_RULE $RULE needs PACKAGE in $RECIPE."; exit 1; } ;; *) print_error "RELEASE_RULE '$RULE' is not one this script knows. Known: github-stable, nuget, npm."; exit 1 ;; esac
case "$SOURCE" in
    upstream) ;;
    recipe) [ -f "$PIECE/Dockerfile" ] || { print_error "SOURCE = recipe, but there is no $PIECE/Dockerfile."; exit 1; } ;;
    *) print_error "SOURCE '$SOURCE' must be upstream or recipe."; exit 1 ;;
esac

if [ -z "$VERSION" ]; then
    VERSION="$(latest_stable "$RULE" "$UPSTREAM" "$(recipe_get PACKAGE)")"
    [ -n "$VERSION" ] || { print_error "No stable release found at $UPSTREAM."; print_action "Check the address, or give a version: $0 $NAME <tag>"; exit 1; }
fi
IMAGE="upstream-${NAME}:${VERSION}"

print_header "Building $NAME $VERSION"
print_info "From $UPSTREAM ($SOURCE Dockerfile)"

mkdir -p "$STATE"
touch "$STATE/versions"
if [ "$REBUILD" = "0" ] && [ "$CHECK_ONLY" = "0" ] && grep -qx "$VERSION" "$STATE/versions" && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    print_success "$IMAGE is already built and passed its health check."
    print_action "Put it on test: sudo bash $SCRIPT_DIR/upstream_promote.sh $NAME test $VERSION"
    exit 0
fi

# --- Build ---------------------------------------------------------------------

WORK="$(mktemp -d "/tmp/upstream-${NAME}-XXXXXX")"
HEALTH_NAME="upstream-${NAME}-health"
# Only ever the folder mktemp just made: a guard, not trust in the variable.
cleanup() {
    docker rm -f "$HEALTH_NAME" >/dev/null 2>&1 || true
    case "$WORK" in /tmp/upstream-"$NAME"-??????) rm -rf -- "$WORK" ;; esac
}
trap cleanup EXIT

# A version's fingerprint is recorded the first time it is built. A later build
# of the same version that differs means the release was replaced after the
# fact, which is what a supply-chain attack on a published release looks like.
touch "$STATE/pins"
check_pin() {
    local fp="$1" pinned
    pinned="$(awk -v v="$VERSION" '$1 == v { print $2 }' "$STATE/pins")"
    if [ -z "$pinned" ]; then
        echo "$VERSION $fp" >> "$STATE/pins"
        print_status "Pinned $VERSION to $fp"
    elif [ "$pinned" != "$fp" ]; then
        print_error "$VERSION is not what it was: pinned $pinned, now $fp."
        print_info "Somebody replaced this release after it was first built here. It is not offered to any row."
        print_action "Find out why before trusting it. The pin is in $STATE/pins."
        exit 1
    else
        print_status "Fingerprint matches the pin: $fp"
    fi
}

if [ "$CHECK_ONLY" = "1" ]; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 || { print_error "$IMAGE is not built."; exit 1; }
    print_info "Checking the existing $IMAGE, no rebuild."
elif [ "$SOURCE" = "upstream" ]; then
    run_logged "Fetching $VERSION" 900 "$STATE/fetch.log" \
        git -c url."https://github.com/".insteadOf="git@github.com:" \
            -c url."https://gitlab.com/".insteadOf="git@gitlab.com:" \
            clone --depth 1 --branch "$VERSION" --recurse-submodules --shallow-submodules "$UPSTREAM" "$WORK/src" || exit 1
    print_status "Fetched $UPSTREAM at $VERSION into $WORK/src"
    check_pin "git:$(git -C "$WORK/src" rev-parse HEAD)"
    [ -f "$WORK/src/$DOCKERFILE" ] || { print_error "Release $VERSION has no $DOCKERFILE."; exit 1; }
    run_logged "Building $IMAGE" 3600 "$STATE/build-$VERSION.log" \
        docker build --pull -t "$IMAGE" -f "$WORK/src/$DOCKERFILE" "$WORK/src" || exit 1
else
    run_logged "Building $IMAGE" 3600 "$STATE/build-$VERSION.log" \
        docker build --pull --build-arg "VERSION=$VERSION" -t "$IMAGE-candidate" -f "$PIECE/Dockerfile" "$PIECE" || exit 1
    # Our Dockerfile writes the sha256 of what it downloaded to this path. The
    # candidate tag keeps a refused build from replacing the trusted image.
    fp="sha256:$(docker run --rm --entrypoint cat "$IMAGE-candidate" /upstream-artifact.sha256 | awk '{print $1}')"
    ( check_pin "$fp" ) || { docker image rm "$IMAGE-candidate" >/dev/null 2>&1; exit 1; }
    docker tag "$IMAGE-candidate" "$IMAGE"
    docker image rm "$IMAGE-candidate" >/dev/null
fi
[ "$CHECK_ONLY" = "1" ] || print_status "Built $IMAGE ($(docker image inspect -f '{{.Size}}' "$IMAGE" | awk '{printf "%d MB", $1/1048576}'))"

# --- Health: a throwaway copy with empty data must answer ---------------------

# The same confinement as the rows get (add_app_services.sh), so a release
# that only works with more rights fails here and not on a customer's editor.
bash "$SCRIPT_DIR/upstream_net.sh"
run_args=(-d --name "$HEALTH_NAME" -p "127.0.0.1::$CPORT"
    --security-opt no-new-privileges --cap-drop ALL --pids-limit 512 --memory "$(recipe_get MEMORY 768m)")
for c in $(recipe_get CAPS); do run_args+=(--cap-add "$c"); done
if [ "$(recipe_get READ_ONLY yes)" = "yes" ]; then
    run_args+=(--read-only --tmpfs /tmp)
    for w in $(recipe_get WRITABLE); do run_args+=(--tmpfs "$w"); done
fi
[ "$(recipe_get EGRESS no)" = "yes" ] || run_args+=(--network upstream-net)
RUN_AS="$(recipe_get USER)"
[ -z "$RUN_AS" ] || run_args+=(--user "$RUN_AS")
while IFS= read -r m; do
    [ -n "$m" ] || continue
    mkdir -p "$WORK/data/${m%%:*}"
    [ -z "$RUN_AS" ] || chown "$RUN_AS" "$WORK/data/${m%%:*}"
    run_args+=(-v "$WORK/data/${m%%:*}:${m#*:}")
done < <(recipe_all MOUNT)
P_URL="{PUBLIC_URL}" P_HOST="{PUBLIC_HOST}" P_HOSTS="{HOSTS}"
while IFS= read -r e; do
    [ -n "$e" ] || continue
    e="${e//"$P_URL"/http://127.0.0.1}"; e="${e//"$P_HOSTS"/127.0.0.1}"; run_args+=(-e "${e//"$P_HOST"/127.0.0.1}")
done < <(recipe_all ENV)
while IFS= read -r s; do
    [ -n "$s" ] || continue
    run_args+=(-e "$s=$(openssl rand -hex 16)Aa1!")
done < <(recipe_all SECRET)

docker rm -f "$HEALTH_NAME" >/dev/null 2>&1 || true
docker run "${run_args[@]}" "$IMAGE" >/dev/null
hport="$(docker port "$HEALTH_NAME" "$CPORT/tcp" | head -n1 | sed 's/.*://')"

printf "\033[34m🔧 %s\033[0m " "Waiting up to ${HWAIT}s for $HPATH"
code="000"
for _ in $(seq 1 "$HWAIT"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${hport}${HPATH}" || true)"
    [ "$code" != "000" ] && break
    docker inspect -f '{{.State.Running}}' "$HEALTH_NAME" 2>/dev/null | grep -q true || break
    printf '.'; sleep 1
done
printf '\n'
docker logs --tail 40 "$HEALTH_NAME" > "$STATE/health-$VERSION.log" 2>&1 || true

if [ "$code" = "000" ] || [ "$code" -ge 500 ]; then
    print_error "$IMAGE built, but did not answer on $HPATH (HTTP $code), so it is not offered to any row."
    tail -n 20 "$STATE/health-$VERSION.log" | sed 's/^/   /'
    print_info "Full log: $STATE/health-$VERSION.log"
    exit 1
fi
print_status "A throwaway copy answered $HPATH with HTTP $code"

grep -qx "$VERSION" "$STATE/versions" || echo "$VERSION" >> "$STATE/versions"
print_success "$IMAGE is built and healthy."
print_action "Put it on test: sudo bash $SCRIPT_DIR/upstream_promote.sh $NAME test $VERSION"
