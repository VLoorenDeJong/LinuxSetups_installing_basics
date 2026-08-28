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
# Make this machine wakeable, and print what the watcher needs to wake it.
#
#   sudo ./arm_wake_on_lan.sh              arm it, and keep it armed at boot
#        ./arm_wake_on_lan.sh --status     is it armed right now
#        ./arm_wake_on_lan.sh --print-conf just the block for the watcher
#   sudo ./arm_wake_on_lan.sh --off        stop re-arming it at boot
#
# RUNS ON THE MACHINE THAT SHOULD SLEEP. It is step one of three:
#
#   1. arm_wake_on_lan.sh      here      make it wakeable          <- this
#   2. add_wake_on_access.sh   watcher   wake it when asked for
#   3. add_sleep_when_idle.sh  here      put it away when idle
#
# WHAT IT ACTUALLY CHANGES. `ethtool -s <iface> wol g` tells the NIC to keep
# listening for a magic packet after the machine is off. That setting does not
# survive a power cycle on many cards, r8169 above all, so it is also written
# into a boot unit rather than trusted once.
#
# WHAT IT CANNOT DO. If the BIOS cuts standby power at shutdown the NIC is dead
# and no setting here reaches it. That is one checkbox, usually called ErP
# Ready or EuP, and it must be DISABLED. The physical test is the link LED on
# the network port: lit with the machine off means the card still has power.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'
NC=$'\033[0m'

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPIN_PID=""
spinner_start() {
    [ "${DEBUG_MODE:-0}" = "1" ] && return 0
    local message="$1"
    (
        local i=0
        while true; do
            printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[i % 10]}" "$message"
            i=$((i + 1))
            sleep 0.2
        done
    ) &
    _SPIN_PID=$!
}
spinner_stop() {
    [ -n "$_SPIN_PID" ] || return 0
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf '\r\033[K'
}

MODE="on"
IFACE_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --off)        MODE="off"; shift ;;
        --status)     MODE="status"; shift ;;
        --print-conf) MODE="print-conf"; shift ;;
        --iface)
            if [ $# -lt 2 ]; then
                print_error "--iface needs a name, for example: --iface enp4s0"
                exit 1
            fi
            IFACE_ARG="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 [--iface NAME] [--status] [--print-conf] [--off]" >&2
            exit 1 ;;
        *) print_error "Unknown argument '$1'"; exit 1 ;;
    esac
done

WOL_UNIT="/etc/systemd/system/wol-arm.service"

# =============================================================================
# Which interface. The one carrying the default route, unless told otherwise.
# =============================================================================
IFACE="$IFACE_ARG"
[ -n "$IFACE" ] || IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)"

if [ -z "$IFACE" ]; then
    print_error "Could not work out which interface faces the LAN."
    print_hint "list them and pick the wired one:"
    print_hint "  ${HL}ip -br link${NC}"
    print_hint "then re-run with: ${HL}sudo $0 --iface <name>${NC}"
    exit 1
fi

MAC="$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || true)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
IPV4="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"

read_wol() {
    ethtool "$IFACE" 2>/dev/null | sed -n 's/^[[:space:]]*Wake-on:[[:space:]]*//p' | tail -1
}
read_wol_supported() {
    ethtool "$IFACE" 2>/dev/null | sed -n 's/^[[:space:]]*Supports Wake-on:[[:space:]]*//p' | tail -1
}

# One entry for the watcher's .targets array. Printed rather than typed,
# because a MAC copied by eye is a MAC that is wrong once in ten.
print_conf_block() {
    cat <<BLOCK

    {
      "name": "$HOSTNAME_FQDN",
      "ipv4": "$IPV4",
      "mac": "$MAC",
      "cooldown": 90
    }

BLOCK
}

if [ "$MODE" = "print-conf" ]; then
    print_info "Add this to .targets[] in wake_on_access.json on the watcher:"
    print_conf_block
    exit 0
fi

print_header "Wake on LAN"

if [ "$MODE" = "status" ]; then
    if ! command -v ethtool >/dev/null 2>&1; then
        print_error "No ethtool, so the state cannot be read. Install it: sudo apt-get install ethtool"
        exit 1
    fi
    STATE="$(read_wol)"
    if [ -n "$STATE" ] && [[ "$STATE" == *g* ]]; then
        print_success "$IFACE is armed. Wake-on: $STATE"
    else
        print_error "$IFACE is NOT armed. Wake-on: ${STATE:-unknown}"
        print_hint "arm it with: sudo $0"
    fi
    if [ -f "$WOL_UNIT" ] && systemctl is-enabled --quiet wol-arm.service 2>/dev/null; then
        print_info "It is re-armed at every boot by wol-arm.service."
    else
        print_action "Nothing re-arms it at boot, so it may be lost on the next power cycle."
        print_hint "fix that with: sudo $0"
    fi
    print_info "What the watcher needs:"
    print_conf_block
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    print_error "Changing a NIC setting and installing a boot unit needs sudo."
    print_hint "run with: sudo $0 $*"
    exit 1
fi

if [ "$MODE" = "off" ]; then
    systemctl disable --now wol-arm.service 2>/dev/null || true
    rm -f "$WOL_UNIT"
    systemctl daemon-reload
    print_success "No longer re-armed at boot."
    print_info "The NIC keeps its current setting until the next power cycle."
    print_hint "turn it off now as well with: ethtool -s $IFACE wol d"
    exit 0
fi

# =============================================================================
# Pre-flight. Nothing is written until every one of these passes.
# =============================================================================
ERRORS=()

ip link show "$IFACE" >/dev/null 2>&1 || ERRORS+=("No interface called '$IFACE' on this machine. List them with: ip -br link")
[ -n "$MAC" ] || ERRORS+=("Could not read the MAC of $IFACE.")

case "$IFACE" in
    wg*|tun*) ERRORS+=("$IFACE is a tunnel, not a network card. Pick the wired one: ip -br link") ;;
esac

if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

if ! command -v ethtool >/dev/null 2>&1; then
    LOG="$(mktemp)"
    spinner_start "Refreshing package lists..."
    if ! apt-get update >"$LOG" 2>&1; then
        spinner_stop
        print_error "apt-get update failed. Last lines:"
        tail -20 "$LOG"
        print_hint "full log: $LOG"
        exit 1
    fi
    spinner_stop

    spinner_start "Installing ethtool..."
    if apt-get install -y ethtool >"$LOG" 2>&1; then
        spinner_stop
        print_success "ethtool installed."
        rm -f "$LOG"
    else
        rc=$?
        spinner_stop
        print_error "Could not install ethtool (exit $rc). Last lines:"
        tail -20 "$LOG"
        print_hint "full log: $LOG"
        exit 1
    fi
fi

SUPPORTED="$(read_wol_supported)"
BEFORE="$(read_wol)"

# The card is asked what it can do before it is told what to do. "Supports
# Wake-on: d" is hardware or firmware saying no, and no amount of ethtool
# changes it: that is a BIOS setting or a card that cannot.
if [ -z "$SUPPORTED" ]; then
    print_error "ethtool could not read $IFACE's capabilities."
    print_hint "some virtual and USB adapters do not report them at all."
    exit 1
fi

if [[ "$SUPPORTED" != *g* ]]; then
    print_error "$IFACE does not support magic packet wake. Supports Wake-on: $SUPPORTED"
    print_hint "this is the card or the firmware saying no, not a Linux setting."
    print_hint "check the BIOS first, the two settings are usually called:"
    print_hint "  ${HL}ErP Ready / EuP${NC}                        must be DISABLED"
    print_hint "  ${HL}Resume From S5 By PCI-E Device${NC}         must be ENABLED"
    exit 1
fi

case "$IFACE" in
    wl*|wlan*)
        print_action "NOTE: $IFACE looks like wifi."
        print_hint "waking over wifi needs WoWLAN on both the card and the access"
        print_hint "point, and usually does not work. A cable does."
        ;;
esac

# =============================================================================
# The change. One ethtool call, and a unit so it survives a power cycle.
# =============================================================================
print_status "Arming $IFACE for magic packet wake"
if ! ethtool -s "$IFACE" wol g 2>/dev/null; then
    print_error "ethtool refused to set wol g on $IFACE."
    exit 1
fi

AFTER="$(read_wol)"
if [[ "$AFTER" != *g* ]]; then
    print_error "The setting did not stick. Wake-on is still '$AFTER'."
    print_hint "some drivers accept the command and ignore it. Check the BIOS settings above."
    exit 1
fi

print_status "Writing $WOL_UNIT"
# Quoted heredoc with placeholders, so nothing in the unit body is expanded by
# this shell. The paths are substituted afterwards.
cat > "${WOL_UNIT}.new" <<'UNIT_EOF'
[Unit]
Description=Re-arm Wake-on-LAN, which some NICs drop across a power cycle
After=network.target
Requires=network.target

[Service]
Type=oneshot
ExecStart=__ETHTOOL__ -s __IFACE__ wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
sed -i -e "s|__ETHTOOL__|$(command -v ethtool)|" -e "s|__IFACE__|$IFACE|" "${WOL_UNIT}.new"
mv "${WOL_UNIT}.new" "$WOL_UNIT"

systemctl daemon-reload
if ! ENABLE_LOG="$(systemctl enable --now wol-arm.service 2>&1)"; then
    print_error "wol-arm.service refused to start:"
    printf '%s\n' "$ENABLE_LOG" | tail -10
    journalctl -u wol-arm -n 15 --no-pager 2>/dev/null | tail -10
    exit 1
fi

# =============================================================================
# Say what changed, and what it does not cover
# =============================================================================
if [ "$BEFORE" = "$AFTER" ]; then
    print_info "$IFACE was already armed. Wake-on: $AFTER"
else
    print_success "$IFACE armed. Wake-on: $BEFORE -> $AFTER"
fi
print_success "Re-armed at every boot by wol-arm.service."
echo ""
print_info "What the watcher needs. Add it to .targets[] in wake_on_access.json over there:"
print_conf_block
print_info "NOT CHECKED from here, and it is the usual reason this fails:"
print_hint "  ${HL}ErP Ready / EuP${NC} in the BIOS must be DISABLED, or the card"
print_hint "  loses power at shutdown and never hears anything."
print_hint "  The test is physical: shut down, then look at the link LED on the"
print_hint "  network port. Lit means the card still has standby power."
echo ""
print_action "Prove it before relying on it: shut this machine down, then from the"
print_hint "watcher run ${HL}sudo ./add_wake_on_access.sh --test${NC}"
