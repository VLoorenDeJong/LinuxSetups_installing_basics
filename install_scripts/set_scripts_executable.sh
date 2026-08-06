#!/bin/bash

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

print_status() {
    printf "\e[34m🔧 %s\e[0m\n" "$1"
}

print_success() {
    printf "\e[32m✅ %s\e[0m\n" "$1"
}

print_warning() {
    printf "\e[33m⚠️ %s\e[0m\n" "$1"
}

print_error() {
    printf "\e[31m❌ %s\e[0m\n" "$1"
}

# Root check first — everything below may need privileged chmod
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_warning "Please run with: sudo $0"
    exit 1
fi

# Repo root: the parent of install_scripts/. When this repo is consumed as a
# submodule of a larger setup repo, walk up so the superproject's scripts are
# covered too — the parent repo resolves its set_scripts_executable here.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO_DIR/../.gitmodules" ]; then
    REPO_DIR="$(cd "$REPO_DIR/.." && pwd)"
    print_status "Running as submodule — covering superproject: $REPO_DIR"
fi

# Any backup_config directory lives inside the (super)project covered above
BACKUP_CONFIG_DIR="$REPO_DIR/backup_config"

# Mark only shell scripts executable — a recursive chmod +x would also mark
# docs, configs and git internals, which is wrong and noisy
make_scripts_executable() {
    local dir="$1"
    local label="$2"

    if [ ! -d "$dir" ]; then
        print_warning "$label not found (may not be created yet): $dir"
        return 0
    fi

    if find "$dir" -type f -name "*.sh" -exec chmod +x {} +; then
        print_success "All scripts in $label are now executable"
    else
        print_error "Failed to set executable permissions in $label: $dir"
        exit 1
    fi
}

print_status "Setting executable permissions for scripts..."

make_scripts_executable "$REPO_DIR" "repository"

# Covers a backup_config directory when the (super)project has one;
# silently skipped standalone (make_scripts_executable warns if absent)
make_scripts_executable "$BACKUP_CONFIG_DIR" "backup_config"

print_success "Script executable permissions setup complete!"
