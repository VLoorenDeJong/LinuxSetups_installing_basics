#!/usr/bin/env bash
set -e

# =============================================================================
# Is Docker usable here? Changes nothing.
#
# A separate script so every container installer asks the same question the
# same way, and so it can be run by hand before one.
#
# Usage:
#   check_docker.sh            # prints what it found
#   check_docker.sh --quiet    # exit code only
#
# Exit codes:
#   0  docker, its daemon and the compose plugin all answer
#   1  one of them does not; the fix is printed
#   2  bad usage
# =============================================================================

print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

QUIET=0
case "${1:-}" in
    "")        ;;
    -q|--quiet) QUIET=1 ;;
    *)         print_error "Unknown option: $1"; exit 2 ;;
esac

fail() {
    if [ "$QUIET" -eq 0 ]; then
        print_error "$1"
        print_action "$2"
    fi
    exit 1
}

command -v docker >/dev/null 2>&1 \
    || fail "Docker is not installed." \
            "Install it: sudo bash $(dirname "$0")/add_docker.sh"

# `docker info` needs the daemon, and root or the docker group to reach it.
docker info >/dev/null 2>&1 \
    || fail "Docker is installed but the daemon does not answer (or this user may not reach it)." \
            "Check it: sudo systemctl status docker"

docker compose version >/dev/null 2>&1 \
    || fail "The docker compose plugin is missing." \
            "Install it: sudo apt-get install -y docker-compose-plugin"

if [ "$QUIET" -eq 0 ]; then
    print_success "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) is running, with compose $(docker compose version --short 2>/dev/null)."
fi
exit 0
