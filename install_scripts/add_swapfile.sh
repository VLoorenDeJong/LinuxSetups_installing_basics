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
# Create a swapfile, and make swap emergency-only rather than routine.
#
# A Raspberry Pi running Ubuntu Server ships with zero swap. At 8GB that is
# fine for steady state, but it removes the one buffer the kernel has when a
# build spikes: with no swap the OOM killer runs immediately, and it picks a
# victim by score, not by importance. On a web host that means a live Kestrel
# service dies so that a compile can finish.
#
# Swap does not make the machine faster. It makes the failure mode "slow for a
# few seconds" instead of "a service disappeared".
#
# Two deliberate choices:
#
#   swappiness 10, not the default 60. The point of this file is a spike
#   buffer, not a place to page out an idle service. At 60 the kernel will
#   swap out pages that are merely cold, which on SD-card storage is slow and
#   wears the card. At 10 it only reaches for swap under real pressure.
#
#   A swapfile, not a swap partition. A file can be resized or deleted with
#   two commands and does not require touching the partition table.
#
# Size: first argument, or SWAP_SIZE_MB, default 2048. Safe to re-run: an
# existing swapfile of the right size is left alone, and any other active swap
# means this script does nothing at all.
#
# Usage:
#   sudo ./add_swapfile.sh          # 2GB
#   sudo ./add_swapfile.sh 4096     # 4GB
# =============================================================================

# --- Inline utility functions (always defined, no sourcing required) ---
print_status() {
    printf "\033[34m🔧 %s\033[0m\n" "$1"
}

print_success() {
    printf "\033[32m✅ %s\033[0m\n" "$1"
}

print_warning() {
    printf "\033[33m⚠️ %s\033[0m\n" "$1"
}

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

if [ "$(id -u)" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_warning "Please run with: sudo $0"
    exit 1
fi

print_header "Swapfile"

SWAPFILE="/swapfile"
SIZE_MB="${1:-${SWAP_SIZE_MB:-2048}}"

if ! [[ "$SIZE_MB" =~ ^[0-9]+$ ]] || [ "$SIZE_MB" -lt 128 ]; then
    print_error "Swap size must be a whole number of MB, at least 128. Got: $SIZE_MB"
    exit 1
fi

# -----------------------------------------------------------------------------
# Existing swap. If the machine already has swap of any kind, whether a
# partition, zram or a swapfile somewhere else, adding a second one is not an
# improvement and may fight an existing tool (dphys-swapfile, zram-config).
# Leave it alone and say what is there.
# -----------------------------------------------------------------------------
EXISTING="$(swapon --show=NAME --noheadings 2>/dev/null || true)"

if [ -n "$EXISTING" ] && ! printf '%s\n' "$EXISTING" | grep -qx "$SWAPFILE"; then
    print_success "Swap is already active on this machine, leaving it alone:"
    swapon --show
    print_status "To replace it with a managed swapfile, disable the existing swap first."
    exit 0
fi

# -----------------------------------------------------------------------------
# Storage warning. Swapping to an SD card is slow and wears the card out. Still
# better than the OOM killer, so this warns rather than refuses.
# -----------------------------------------------------------------------------
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
case "$ROOT_SRC" in
    *mmcblk*)
        print_warning "Root filesystem is on an SD card ($ROOT_SRC)."
        print_warning "Swap here is slow and wears the card. swappiness is set to 10 below"
        print_warning "so it is only touched under real memory pressure."
        ;;
esac

# -----------------------------------------------------------------------------
# Disk space. Allocating a swapfile that fills the root filesystem is a worse
# problem than the one it solves, so keep 1GB of headroom.
# -----------------------------------------------------------------------------
AVAIL_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
NEEDED_MB=$((SIZE_MB + 1024))

# An existing swapfile's space is reclaimed when it is replaced, so it does not
# count against the requirement
if [ -f "$SWAPFILE" ]; then
    CURRENT_MB=$(( $(stat -c %s "$SWAPFILE") / 1024 / 1024 ))
    AVAIL_MB=$((AVAIL_MB + CURRENT_MB))
fi

if [ "$AVAIL_MB" -lt "$NEEDED_MB" ]; then
    print_error "Not enough free space on /. Need ${NEEDED_MB} MB (${SIZE_MB} MB swap + 1024 MB headroom), have ${AVAIL_MB} MB."
    exit 1
fi

TOTAL_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
print_status "RAM: ${TOTAL_MB} MB. Requested swap: ${SIZE_MB} MB. Free on /: ${AVAIL_MB} MB."

# -----------------------------------------------------------------------------
# The swapfile itself
# -----------------------------------------------------------------------------
NEEDS_CREATE=1

if [ -f "$SWAPFILE" ]; then
    CURRENT_MB=$(( $(stat -c %s "$SWAPFILE") / 1024 / 1024 ))
    if [ "$CURRENT_MB" -eq "$SIZE_MB" ]; then
        print_success "$SWAPFILE already exists at ${SIZE_MB} MB."
        NEEDS_CREATE=0
    else
        print_status "$SWAPFILE is ${CURRENT_MB} MB, resizing to ${SIZE_MB} MB."
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
    fi
fi

if [ "$NEEDS_CREATE" -eq 1 ]; then
    print_status "Allocating ${SIZE_MB} MB. This takes a moment on slow storage."

    # fallocate is instant but can produce a file mkswap rejects on some
    # filesystems, so its result is checked rather than trusted. dd is the
    # fallback: slow, but it writes every block.
    if ! fallocate -l "${SIZE_MB}M" "$SWAPFILE" 2>/dev/null; then
        print_warning "fallocate unavailable here, falling back to dd."
        rm -f "$SWAPFILE"
        if ! dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SIZE_MB" status=progress; then
            print_error "Could not allocate $SWAPFILE."
            rm -f "$SWAPFILE"
            exit 1
        fi
    fi

    # Before mkswap, not after: a swapfile readable by any user exposes
    # whatever the kernel paged out to it. mkswap refuses a world-readable file
    # anyway, but only with a warning on some versions.
    chmod 600 "$SWAPFILE"

    if ! mkswap "$SWAPFILE" >/dev/null; then
        print_warning "mkswap rejected the fallocate'd file, rewriting it with dd."
        rm -f "$SWAPFILE"
        if ! dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SIZE_MB" status=progress; then
            print_error "Could not allocate $SWAPFILE."
            rm -f "$SWAPFILE"
            exit 1
        fi
        chmod 600 "$SWAPFILE"
        if ! mkswap "$SWAPFILE" >/dev/null; then
            print_error "mkswap failed on $SWAPFILE."
            rm -f "$SWAPFILE"
            exit 1
        fi
    fi

    print_success "Swapfile created and formatted."
fi

# Permissions are re-checked even on the already-exists path: a swapfile
# restored from a backup or copied by hand can arrive world-readable
chmod 600 "$SWAPFILE"

if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    if ! swapon "$SWAPFILE"; then
        print_error "Could not activate $SWAPFILE."
        exit 1
    fi
    print_success "Swap activated."
else
    print_success "Swap already active."
fi

# -----------------------------------------------------------------------------
# Persistence. Without an fstab entry the swapfile exists but is not used after
# a reboot, which is the worst outcome: the disk space is spent and the
# protection is gone, and nothing reports it.
# -----------------------------------------------------------------------------
FSTAB_LINE="$SWAPFILE none swap sw 0 0"

if grep -qE "^[[:space:]]*${SWAPFILE}[[:space:]]" /etc/fstab; then
    print_success "fstab entry already present."
else
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y_%m_%d-%d-%m-%Y_%H-%M)"
    printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
    print_success "fstab entry added, swap will survive a reboot."
fi

# -----------------------------------------------------------------------------
# swappiness. A drop-in rather than an edit to /etc/sysctl.conf, so the setting
# is visibly ours and removing the file removes the change cleanly.
# -----------------------------------------------------------------------------
SYSCTL_FILE="/etc/sysctl.d/99-swappiness.conf"

NEW_SYSCTL="$(cat <<'EOF'
# Generated by add_swapfile.sh
#
# This swapfile exists as a spike buffer, not as extra memory. The default
# swappiness of 60 pages out merely-cold memory, which on SD-card storage is
# slow and wears the card. At 10 the kernel only reaches for swap under real
# pressure, which is the only time it is wanted.
vm.swappiness=10
EOF
)"

if [ -f "$SYSCTL_FILE" ] && [ "$(cat "$SYSCTL_FILE")" = "$NEW_SYSCTL" ]; then
    print_success "swappiness drop-in already in place."
else
    printf '%s\n' "$NEW_SYSCTL" > "$SYSCTL_FILE"
    chmod 644 "$SYSCTL_FILE"
    print_success "swappiness set to 10."
fi

sysctl -q -w vm.swappiness=10

# -----------------------------------------------------------------------------
# Verify rather than assume. The whole point of this script is that swap is
# actually available when memory runs short, so confirm the kernel agrees.
# -----------------------------------------------------------------------------
ACTIVE_MB="$(free -m | awk '/^Swap:/ {print $2}')"

if [ "${ACTIVE_MB:-0}" -lt 1 ]; then
    print_error "No swap is active after all of the above. Check: swapon --show"
    exit 1
fi

print_status "Active swap: ${ACTIVE_MB} MB, swappiness $(cat /proc/sys/vm/swappiness)."
swapon --show
print_success "Swapfile configured."
