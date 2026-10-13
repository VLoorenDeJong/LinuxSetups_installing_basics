#!/usr/bin/env bash

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
# Join a Wi-Fi network: scan, pick one from a numbered list (or type a name),
# give its password.
#
# As a normal connection it gets an address and a default route that loses to
# the cable's, so the cable stays the way out while it is plugged in.
#
# --only <range> makes it a SIDE network instead: devices in <range> are
# reached through it, and nothing else. No default route, no DNS from it, and
# UFW refuses everything that comes in on it. For devices on an isolated guest
# Wi-Fi that share the home network's addresses, so <range> must be a block
# only they use (reserve their addresses inside it on the router).
#
#   /etc/netplan/60-wifi-<iface>.yaml   the network and its password, root only
#   /etc/sysctl.d/60-wifi-<iface>.conf  with --only: answer ARP on the right side
#
# Usage:
#   sudo add_wifi.sh
#   sudo add_wifi.sh --only 192.168.2.192/27
#   sudo add_wifi.sh --iface wlan1
#   sudo add_wifi.sh --remove
#
# Exit codes:
#   0  connected (or removed)
#   1  something needed for the run is missing or failed
#   2  bad usage
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

# Explaining an ask: plain body, cyan for what to find.
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'
NC=$'\033[0m'
# Signal bars: green strong, yellow usable, red weak, grey the missing bars.
SIG_GOOD=$'\033[32m'
SIG_FAIR=$'\033[33m'
SIG_WEAK=$'\033[31m'
SIG_OFF=$'\033[90m'

# Prompts. print_action cannot be one: it ends with a newline.
prompt_ask()    { printf "\n   \033[33m%s\033[0m %s" "$1" "${2:-}" > /dev/tty; }
prompt_got()    { printf "   \033[32m✅ %s\033[0m\n" "$1"; }
prompt_retry()  { printf "   \033[33m%s\033[0m\n" "$1" > /dev/tty; }

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

restore_tty() { spinner_stop; { stty echo < /dev/tty; } 2>/dev/null || true; }
trap restore_tty EXIT
trap 'restore_tty; exit 130' INT TERM

# One character at a time, a * each, backspace works.
read_secret() {
    local prompt="$1" out="" ch
    printf '%s' "$prompt" > /dev/tty
    while IFS= read -rsn1 ch < /dev/tty; do
        case "$ch" in
            ''|$'\n')       break ;;
            $'\177'|$'\b')  [ -n "$out" ] && { out="${out%?}"; printf '\b \b' > /dev/tty; } ;;
            *)              out="$out$ch"; printf '*' > /dev/tty ;;
        esac
    done
    printf '\n' > /dev/tty
    SECRET="$out"
}

# YAML double-quoted: a backslash or quote in a name or password stays itself.
yaml_q() { local v="${1//\\/\\\\}"; printf '"%s"' "${v//\"/\\\"}"; }

need_value() { [ -n "$2" ] || { print_error "$1 needs a value."; exit 2; }; }

IFACE=""
ONLY=""
REMOVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --iface)  need_value "$1" "${2:-}"; IFACE="$2"; shift 2 ;;
        --only)   need_value "$1" "${2:-}"; ONLY="$2"; shift 2 ;;
        --remove) REMOVE=1; shift ;;
        -h|--help) sed -n '/^# Join a Wi-Fi/,/^#   2  bad usage/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print_error "Unknown option: $1"; exit 2 ;;
    esac
done

print_header "Wi-Fi"

if [ "$EUID" -ne 0 ]; then
    print_error "This script needs root."
    print_action "Run it with: sudo bash $0 $*"
    exit 1
fi

[ -n "$IFACE" ] || IFACE="$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -n 1)"
NETPLAN="/etc/netplan/60-wifi-${IFACE}.yaml"
SYSCTL="/etc/sysctl.d/60-wifi-${IFACE}.conf"

# The firewall's view of this interface. `status numbered` is the listing that
# spells an inbound rule as DENY IN; plain `status` does not.
deny_present() { ufw status numbered 2>/dev/null | grep -qE "Anywhere on ${IFACE}[[:space:]]+DENY IN"; }
deny_remove()  { while deny_present; do ufw --force delete deny in on "$IFACE" >/dev/null 2>&1 || break; done; }
side_remove()  { rm -f "$SYSCTL"; deny_remove; }

# --- Removing ----------------------------------------------------------------
if [ "$REMOVE" -eq 1 ]; then
    rm -f "$NETPLAN"
    side_remove
    netplan generate && networkctl reload >/dev/null 2>&1
    ip link set "$IFACE" down 2>/dev/null || true
    print_success "Wi-Fi on $IFACE removed."
    exit 0
fi

ip_num() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
in_range() {
    local net="${2%/*}" bits="${2#*/}" mask
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( $(ip_num "$1") & mask )) -eq $(( $(ip_num "$net") & mask )) ]
}

# --- Pre-flight --------------------------------------------------------------
ERRORS=()
[ -n "$IFACE" ] && [ -d "/sys/class/net/$IFACE" ] \
    || ERRORS+=("No Wi-Fi interface found. List them: ip -br link")
command -v netplan >/dev/null 2>&1 || ERRORS+=("No netplan: this script expects Ubuntu's network setup.")
systemctl is-active --quiet systemd-networkd \
    || ERRORS+=("systemd-networkd is not running, so netplan's file would be written and never used. On NetworkManager, use nmtui.")
{ : < /dev/tty; } 2>/dev/null || ERRORS+=("No terminal to choose a network on. Run it from an SSH session or the keyboard.")
if [ -n "$ONLY" ]; then
    if ! [[ "$ONLY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
        ERRORS+=("--only '$ONLY' is not a range like 192.168.2.192/27")
    else
        # A route through Wi-Fi for these would take the cable's own traffic with it.
        SSH_FROM="${SSH_CLIENT%% *}"
        GATEWAY="$(ip -4 route show default | awk '{print $3; exit}')"
        for who in "SSH session:$SSH_FROM" "default gateway:$GATEWAY" \
                   $(ip -4 -o addr show scope global | awk -v w="$IFACE" '$2 != w {split($4, a, "/"); print "this machine:" a[1]}'); do
            addr="${who##*:}"
            [[ "$addr" =~ ^[0-9.]+$ ]] && in_range "$addr" "$ONLY" \
                && ERRORS+=("--only $ONLY holds the ${who%:*} ($addr); it would be cut off. Pick a range only the Wi-Fi devices use.")
        done
    fi
    command -v ufw >/dev/null 2>&1 || ERRORS+=("--only needs UFW to refuse what comes in: sudo apt-get install -y ufw")
    ufw status 2>/dev/null | grep -q "Status: active" \
        || ERRORS+=("--only needs UFW active, or the deny rule protects nothing: sudo ufw enable")
fi
if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

if ! command -v iw >/dev/null 2>&1; then
    log="$(mktemp)"
    spinner_start "Installing iw, the Wi-Fi scanner"
    if ! timeout 300 apt-get install -y -qq iw >"$log" 2>&1; then
        spinner_stop
        print_error "Installing iw failed:"
        tail -n 20 "$log"
        print_info "Full log: $log"
        exit 1
    fi
    spinner_stop
    rm -f "$log"
    print_success "Installed iw."
fi
print_success "Pre-flight passed: $IFACE${ONLY:+, side network for $ONLY}."

# --- The ARP and firewall side: --only sets it up, a plain run clears it -------
if [ -n "$ONLY" ]; then
    # Two interfaces in one subnet: each answers ARP only for its own address.
    printf 'net.ipv4.conf.%s.arp_ignore = 1\nnet.ipv4.conf.%s.arp_announce = 2\n' "$IFACE" "$IFACE" > "$SYSCTL"
    sysctl -q -p "$SYSCTL"
    if ! deny_present; then
        # insert 1 refuses an empty rule list, so the first rule is added plainly.
        if ufw status numbered | grep -q '^\[ *1\]'; then
            out="$(ufw insert 1 deny in on "$IFACE" 2>&1)"
        else
            out="$(ufw deny in on "$IFACE" 2>&1)"
        fi
        if ! deny_present; then
            print_error "UFW did not take the deny rule for $IFACE, so nothing was connected:"
            printf '%s\n' "$out" | tail -n 5
            exit 1
        fi
    fi
    print_success "UFW refuses everything that comes in on $IFACE."
elif [ -f "$SYSCTL" ] || deny_present; then
    side_remove
    print_status "Cleared the earlier --only settings: $IFACE is a normal connection now."
fi

# Four bars like a phone: -55 dBm and better is full, -80 and worse is one.
signal_bars() {
    local dbm="${1%%.*}" n colour bars="" i
    local shapes=('▂' '▄' '▆' '█')
    if   [ "$dbm" -ge -55 ]; then n=4; colour="$SIG_GOOD"
    elif [ "$dbm" -ge -67 ]; then n=3; colour="$SIG_GOOD"
    elif [ "$dbm" -ge -75 ]; then n=2; colour="$SIG_FAIR"
    else                          n=1; colour="$SIG_WEAK"; fi
    for i in 1 2 3 4; do
        [ "$i" -le "$n" ] && bars+="${colour}${shapes[i-1]}" || bars+="${SIG_OFF}${shapes[i-1]}"
    done
    printf '%s%s' "$bars" "$NC"
}

# Radio waves leaving the aerial while iw listens, until the scan returns.
scan_networks() {
    local out pid i=0
    local waves=('📡     ' '📡 )   ' '📡 ))  ' '📡 ))) ' '📡  )))' '📡   ))' '📡    )')
    out="$(mktemp)"
    ip link set "$IFACE" up 2>/dev/null || true
    ( for _ in 1 2 3; do iw dev "$IFACE" scan > "$out" 2>/dev/null && [ -s "$out" ] && break; sleep 2; done ) &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        [ "${DEBUG_MODE:-0}" = "1" ] || printf '\r\033[K\033[34m%s Scanning for networks\033[0m' "${waves[i % 7]}"
        i=$((i + 1)); sleep 0.2
    done
    printf '\r\033[K'
    # Strongest per name, strongest first; hidden networks have no name to show.
    mapfile -t NETS < <(awk '
        /^BSS / { if (ssid != "") print sig "\t" ssid; ssid = ""; sig = -100 }
        /^\tsignal:/ { sig = $2 }
        /^\tSSID: / { sub(/^\tSSID: /, ""); ssid = $0 }
        END { if (ssid != "") print sig "\t" ssid }' "$out" \
        | sort -t$'\t' -k1,1 -nr | awk -F'\t' '!seen[$2]++')
    rm -f "$out"
    print_status "Found ${#NETS[@]} networks in $(( i / 5 )) s."
}

choose_network() {
    local i=0 n pick other
    print_action "NEEDED: the Wi-Fi network to join"
    print_hint "strongest first; ${HL}Other${NC} for a network that hides its name, ${HL}R${NC} scans again"
    for n in "${NETS[@]}"; do
        i=$((i + 1))
        printf "   %2d  %s  %-32s %s dBm\n" "$i" "$(signal_bars "${n%%$'\t'*}")" "${n#*$'\t'}" "${n%%$'\t'*}" > /dev/tty
    done
    other=$((i + 1))
    printf "   %2d  ${HL}Other${NC}: type the network's name\n" "$other" > /dev/tty
    SSID=""
    while [ -z "$SSID" ]; do
        prompt_ask "Number" "[1-${other}, R = scan again]: "
        read -r pick < /dev/tty || exit 1
        if [[ "$pick" =~ ^[Rr]$ ]]; then
            scan_networks; choose_network; return
        elif [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -lt "$other" ]; then
            # iw writes é or an emoji as \xNN; the network has the real bytes.
            SSID="$(printf '%b' "${NETS[$((pick - 1))]#*$'\t'}")"; HIDDEN=0
        elif [ "$pick" = "$other" ]; then
            prompt_ask "Network name (the 'SSID'), exactly as written:" ""
            read -r SSID < /dev/tty || exit 1
            HIDDEN=1
        fi
    done
    prompt_got "Network: $SSID"
}

ask_password() {
    # A -d trace would print every keystroke; write_netplan turns it back on.
    { set +x; } 2>/dev/null
    while true; do
        print_action "NEEDED: the password of '$SSID'"
        print_hint "Enter alone for an open network."
        read_secret "   Password: "
        PASS="$SECRET"; unset SECRET
        if [ -n "$PASS" ] && { [ ${#PASS} -lt 8 ] || [ ${#PASS} -gt 63 ]; }; then
            prompt_retry "A Wi-Fi password is 8 to 63 characters; that was ${#PASS}. Try again."
            continue
        fi
        [ -z "$PASS" ] && break
        # Stored for good, so a typo would only show up as a failed join.
        read_secret "   Again: "
        if [ "$SECRET" != "$PASS" ]; then
            unset SECRET
            prompt_retry "They do not match. Try again."
            continue
        fi
        unset SECRET
        break
    done
    if [ -z "$PASS" ]; then
        prompt_got "Password: none, an open network"
    else
        # The length only: any characters shown stay in the scrollback.
        prompt_got "Password: ${#PASS} characters"
    fi
}

write_netplan() {
    local extra
    if [ -n "$ONLY" ]; then
        extra="      dhcp4-overrides:
        use-routes: false
        use-dns: false
      routes:
        - to: ${ONLY}
          scope: link"
    else
        extra="      dhcp4-overrides:
        route-metric: 600"
    fi
    { set +x; } 2>/dev/null
    # The access point's settings; an open, visible network has none: {}.
    local ap=""
    [ -n "$PASS" ] && ap+="          password: $(yaml_q "$PASS")"$'\n'
    # Typed under Other: a network that hides its name is only found by asking.
    [ "$HIDDEN" -eq 1 ] && ap+="          hidden: true"$'\n'
    [ -n "$ap" ] || ap="          {}"$'\n'
    ( umask 077; cat > "$NETPLAN" <<NP
# Generated by add_wifi.sh. The next run overwrites it.
network:
  version: 2
  wifis:
    ${IFACE}:
      optional: true
      dhcp4: true
${extra}
      access-points:
        $(yaml_q "$SSID"):
${ap}
NP
    )
    unset PASS
    chmod 600 "$NETPLAN"
    [ "$DEBUG_MODE" = "1" ] && set -x
    return 0
}

# 0 with ADDR set, or 1 with REASON set.
connect() {
    local out
    ADDR=""; REASON=""
    if ! out="$(netplan generate 2>&1)"; then
        REASON="netplan refused the file: $(printf '%s' "$out" | tail -n 1)"
        return 1
    fi
    # Only this interface: the cable, and an SSH session over it, are not touched.
    networkctl reload >/dev/null 2>&1
    systemctl restart "netplan-wpa-${IFACE}.service" 2>/dev/null || true
    networkctl reconfigure "$IFACE" >/dev/null 2>&1
    spinner_start "Connecting to '$SSID'"
    for _ in $(seq 1 40); do
        ADDR="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')"
        [ -n "$ADDR" ] && break
        sleep 1
    done
    spinner_stop
    [ -n "$ADDR" ] && return 0
    REASON="no address after 40 s: a wrong password, or the network refused this machine"
    return 1
}

retry_or_quit() {
    print_error "Not connected: $REASON"
    print_hint "why, in full: journalctl -u netplan-wpa-${IFACE} -n 20"
    print_action "NEEDED: try again, or stop"
    print_hint "1  Try again: choose the network and password again"
    print_hint "2  Stop: remove what was written, so $IFACE stays off"
    while true; do
        prompt_ask "Type 1 or 2" "[Enter = 1]: "
        read -r answer < /dev/tty || answer=2
        case "$answer" in
            ""|1) prompt_got "Trying again."; return 0 ;;
            2)    rm -f "$NETPLAN"; side_remove; netplan generate >/dev/null 2>&1; networkctl reload >/dev/null 2>&1
                  ip link set "$IFACE" down 2>/dev/null || true
                  print_info "Stopped. Nothing of this attempt is left: no $NETPLAN, no --only firewall rule."
                  exit 1 ;;
        esac
    done
}

# --- Scan, choose, connect: until it works or is stopped ---------------------
scan_networks
while true; do
    choose_network
    ask_password
    write_netplan
    connect && break
    retry_or_quit
    scan_networks
done

print_success "Connected to '$SSID' as $ADDR."
if [ -n "$ONLY" ]; then
    print_info "Through it: $ONLY only. Everything else still goes over the cable."
else
    print_info "The cable stays the way out while it is plugged in."
fi
