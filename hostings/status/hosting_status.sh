#!/usr/bin/env bash
#
# Publishes what is true about this machine to a file, every few seconds, so
# the hosting manager can show it without being able to ask systemd anything
# itself. The page runs as www-data and is deliberately locked out; this runs
# as root and hands over a readable answer instead.
#
# Nothing here is a list of things to check. Units, certificates and listening
# ports are DISCOVERED, so a row added tomorrow is covered without an edit.
#
# The file lives on tmpfs under /run: rewritten this often it would otherwise
# be tens of thousands of writes a day onto the boot medium, and status from
# before a reboot is worthless anyway.
#
# Schema, and the contract the page depends on: units, certificates, listening
# and vhosts are a list when the check ran, and null when it could not. Empty
# means "looked, found nothing"; null means "could not look", and every null
# has a sentence in errors saying why. services and configs report only what
# is installed, so a machine without a mail server says nothing about mail
# rather than reporting it broken.
set -u

OUT_DIR="${STATUS_DIR:-/run/hosting-status}"
OUT="$OUT_DIR/status.json"
UNIT_GLOB="${UNIT_GLOB:-app-*}"
FAST_SECONDS="${FAST_SECONDS:-5}"
MID_SECONDS="${MID_SECONDS:-60}"
SLOW_SECONDS="${SLOW_SECONDS:-3600}"
LE_LIVE="${LE_LIVE:-/etc/letsencrypt/live}"

for v in FAST_SECONDS MID_SECONDS SLOW_SECONDS; do
    case "${!v}" in
        ''|*[!0-9]*|0)
            echo "$v must be a positive integer, got '${!v}'" >&2
            exit 1 ;;
    esac
done

mkdir -p "$OUT_DIR" || { echo "cannot create $OUT_DIR" >&2; exit 1; }

# Control characters are stripped rather than escaped: one stray byte in a
# discovered name would otherwise cost the page the whole file, not one row.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[[:cntrl:]]//g'; }

# A collector that could not run publishes null, never an empty list: the page
# must be able to tell "nothing is running" from "nobody could look".
ERRORS=""
add_error() { ERRORS="$ERRORS,\"$(json_escape "$1")\""; }

# Certificates move in months. Checked on the slow loop and cached, so the
# fast loop never pays for openssl.
CERT_JSON='[]'
CERT_CHECKED=0
CERT_ERROR=""

collect_certs() {
    local out="" name dir end days now staging
    now=$(date +%s)
    CERT_ERROR=""
    if ! command -v openssl >/dev/null 2>&1; then
        CERT_JSON='null'
        CERT_ERROR="openssl is not installed, so certificate expiry is unknown"
        return
    fi
    # An absent live directory means no certificate has ever been issued here,
    # which is a real answer. An unreadable one is a failure to look.
    if [ ! -d "$LE_LIVE" ]; then CERT_JSON='[]'; return; fi
    if [ ! -r "$LE_LIVE" ] || [ ! -x "$LE_LIVE" ]; then
        CERT_JSON='null'
        CERT_ERROR="cannot read $LE_LIVE, so certificate expiry is unknown"
        return
    fi
    for dir in "$LE_LIVE"/*/; do
        [ -r "$dir/cert.pem" ] || continue
        name=$(basename "$dir")
        end=$(openssl x509 -enddate -noout -in "$dir/cert.pem" 2>/dev/null | cut -d= -f2)
        [ -n "$end" ] || continue
        end=$(date -d "$end" +%s 2>/dev/null) || continue
        days=$(( (end - now) / 86400 ))
        # Read from the certificate, never stored: Let's Encrypt's staging
        # issuer carries "(STAGING)" in its name, so the page cannot show a
        # test certificate as a real one.
        staging=false
        openssl x509 -issuer -noout -in "$dir/cert.pem" 2>/dev/null \
            | grep -q "(STAGING)" && staging=true
        out="$out,{\"name\":\"$(json_escape "$name")\",\"days\":$days,\"staging\":$staging}"
    done
    CERT_JSON="[${out#,}]"
}

# The collectors assign to a global rather than printing, so that a failure
# they notice can reach ERRORS. A command substitution would lose it: the
# assignment would happen in the subshell and die with it.
UNITS_JSON='null'
PORTS_JSON='null'
# null until collect_listeners runs, which collect_ports skips when ss failed.
# The page must be able to tell "nothing is listening" from "nobody could look".
LISTENERS_JSON='null'
SERVICES_JSON='null'

# The services the page's non-app rows depend on. Reported only when the
# unit exists: a machine without a mail server should say nothing about mail,
# not report it as broken.
SHARED_SERVICES="apache2 postfix dovecot jenkins webmin"

collect_services() {
    local out="" svc state
    for svc in $SHARED_SERVICES; do
        systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q . || continue
        state=$(systemctl is-active "${svc}.service" 2>/dev/null)
        [ -n "$state" ] || state="unknown"
        out="$out,\"$(json_escape "$svc")\":\"$(json_escape "$state")\""
    done
    SERVICES_JSON="{${out#,}}"
}

# Config checks fork a validator, so they are not on the fast loop. They are
# not on the slow one either: a config becomes valid or invalid the moment
# Apply runs, and an hour of showing the old answer is an hour of lying.
CONFIG_JSON='{}'
VHOSTS_JSON='null'
CONFIG_CHECKED=0

# Only the first line is kept. A failing configtest prints a paragraph, and the
# page has one tooltip to put it in.
config_entry() {
    local label="$1"; shift
    local msg rc
    msg=$("$@" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        printf ',"%s":{"ok":true}' "$(json_escape "$label")"
    else
        printf ',"%s":{"ok":false,"message":"%s"}' \
            "$(json_escape "$label")" \
            "$(json_escape "$(printf '%s' "$msg" | head -n 1)")"
    fi
}

collect_configs() {
    local out=""
    command -v apache2ctl >/dev/null 2>&1 && out="$out$(config_entry apache2 apache2ctl configtest)"
    command -v postfix    >/dev/null 2>&1 && out="$out$(config_entry postfix postfix check)"
    command -v doveconf   >/dev/null 2>&1 && out="$out$(config_entry dovecot doveconf -n)"
    CONFIG_JSON="{${out#,}}"
}

# Which ports the firewall lets in, and whether it is on at all. Published as
# fact, not as a verdict: a Kestrel port SHOULD be listening and SHOULD NOT be
# open here, while 443 should be both. Only the page knows which row is which.
FIREWALL_JSON='null'

collect_firewall() {
    local raw rc out="" p
    command -v ufw >/dev/null 2>&1 || { FIREWALL_JSON='null'; return; }
    raw=$(ufw status 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then
        FIREWALL_JSON='null'
        add_error "ufw status exited $rc, so the firewall state is unknown"
        return
    fi
    while read -r p; do
        [ -n "$p" ] || continue
        out="$out,$p"
    done < <(printf '%s\n' "$raw" | awk '/ALLOW/ {print $1}' \
             | cut -d/ -f1 | grep -E '^[0-9]+$' | sort -un)
    if printf '%s' "$raw" | grep -qi "Status: active"; then
        FIREWALL_JSON="{\"active\":true,\"ports\":[${out#,}]}"
    else
        FIREWALL_JSON="{\"active\":false,\"ports\":[${out#,}]}"
    fi
}

collect_vhosts() {
    local out="" f name
    if [ ! -d /etc/apache2/sites-enabled ]; then
        VHOSTS_JSON='null'
        return
    fi
    for f in /etc/apache2/sites-enabled/*.conf; do
        [ -e "$f" ] || continue
        name=$(basename "$f" .conf)
        out="$out,\"$(json_escape "$name")\""
    done
    VHOSTS_JSON="[${out#,}]"
}

collect_units() {
    local out="" raw rc unit active sub
    raw=$(systemctl list-units "$UNIT_GLOB" --all --no-legend --plain 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        UNITS_JSON='null'
        add_error "systemctl list-units exited $rc, so service state is unknown"
        return
    fi
    while read -r unit active sub; do
        [ -n "$unit" ] || continue
        out="$out,{\"unit\":\"$(json_escape "$unit")\",\"active\":\"$(json_escape "$active")\",\"sub\":\"$(json_escape "$sub")\"}"
    done < <(printf '%s\n' "$raw" | awk '{print $1, $3, $4}')
    UNITS_JSON="[${out#,}]"
}

# What each unit's build actually targets, read out of the build itself.
#
# The version is nowhere in hostings.conf on purpose: `dotnet <app>.dll` picks a
# runtime from the build's own runtimeconfig.json, so a number in the config
# would be a second copy of a fact that can disagree with the first.
#
# On the minute loop, not the hourly one: a deploy that has just finished has
# to show its version now. It costs a `systemctl show` plus a file read per unit.
RUNTIME_JSON='{}'
INSTALLED_JSON='null'
collect_runtimes() {
    local out="" unit dll cfg ver name raw

    raw=$(systemctl list-units "$UNIT_GLOB" --all --no-legend --plain 2>/dev/null) || { RUNTIME_JSON='null'; return; }

    while read -r unit; do
        [ -n "$unit" ] || continue
        # The dll the unit was told to run. Taken from the unit rather than from
        # the config, so this reports what is RUNNING, not what was intended.
        dll=$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | grep -o '[^ ";]*\.dll' | head -1)
        [ -n "$dll" ] || continue
        cfg="${dll%.dll}.runtimeconfig.json"
        [ -r "$cfg" ] || continue

        # includedFrameworks means self-contained: it carries its own runtime.
        if grep -q '"includedFrameworks"' "$cfg" 2>/dev/null; then
            ver="self-contained"
        else
            ver=$(tr -d '\n' < "$cfg" \
                  | sed 's/.*"frameworks\?"[[:space:]]*:[[:space:]]*//' \
                  | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
                  | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
        fi
        [ -n "$ver" ] || continue
        out="$out,\"$(json_escape "$unit")\":\"$(json_escape "$ver")\""
    done < <(printf '%s\n' "$raw" | awk '{print $1}')

    RUNTIME_JSON="{${out#,}}"

    # What this machine could run, so the page can say "needs 9, you have 8 and
    # 10" rather than only naming what the app wants.
    if command -v dotnet >/dev/null 2>&1; then
        local list=""
        while read -r name ver; do
            [ -n "$ver" ] || continue
            list="$list,\"$(json_escape "$ver")\""
        done < <(dotnet --list-runtimes 2>/dev/null | awk '$1 == "Microsoft.AspNetCore.App" {print $1, $2}')
        INSTALLED_JSON="[${list#,}]"
    else
        INSTALLED_JSON='null'
    fi
}

collect_ports() {
    local out="" raw rc p
    raw=$(ss -ltnH 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PORTS_JSON='null'
        add_error "ss -ltnH exited $rc, so listening ports are unknown"
        return
    fi
    while read -r p; do
        [ -n "$p" ] || continue
        out="$out,$p"
    done < <(printf '%s\n' "$raw" | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un)
    PORTS_JSON="[${out#,}]"
    collect_listeners
}

# The same ports with the process holding each one, and the address it answers
# on. A bare number cannot be recognised: the console offers this list when
# somebody is pointing a machine page at a service, and "8080" says nothing
# where "8080, jenkins, loopback only" says which one to pick.
#
# Separate from PORTS_JSON rather than replacing it, so the one thing already
# reading `listening` is untouched.
collect_listeners() {
    local out="" sep="" line addr port name seen=" " local_only
    LISTENERS_JSON='[]'
    while IFS= read -r line; do
        addr="$(printf '%s' "$line" | awk '{print $4}')"
        port="${addr##*:}"
        case "$port" in ''|*[!0-9]*) continue ;; esac
        # One row per port, not per address. Nearly everything here binds both
        # IPv4 and IPv6, which is two lines from ss saying the same thing, and
        # a picker offering 8080 twice is a picker nobody trusts.
        case "$seen" in *" $port "*) continue ;; esac
        seen="$seen$port "
        # users:(("jenkins",pid=123,fd=9)) -> jenkins. Empty when ss could not
        # see the process, which is reported as empty rather than guessed at.
        name="$(printf '%s' "$line" | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p')"
        # Whether it is reachable from off this machine, which is the thing an
        # operator is actually asking when they look at a port list.
        # [::ffff:127.0.0.1] is IPv4-mapped IPv6 and is how Jenkins binds
        # loopback here. Missing that reports the one service deliberately kept
        # off the network as exposed, which is a worse answer than none.
        case "${addr%:*}" in
            127.*|'[::1]'|'[::ffff:127.'*|localhost) local_only=true ;;
            *)                                       local_only=false ;;
        esac
        out="${out}${sep}{\"port\":${port},\"name\":\"$(json_escape "$name")\",\"loopback\":${local_only}}"
        sep=","
    done < <(ss -ltnpH 2>/dev/null | sort -t: -k2 -n)
    LISTENERS_JSON="[${out}]"
}

write_status() {
    local tmp now
    now=$(date +%s)
    ERRORS=""
    collect_units
    collect_ports
    collect_services
    [ -z "$CERT_ERROR" ] || add_error "$CERT_ERROR"

    tmp=$(mktemp "$OUT_DIR/.status.XXXXXX") || return 1
    cat > "$tmp" <<JSON
{
  "checked": $now,
  "checkedText": "$(date -d "@$now" '+%Y-%m-%d %H:%M:%S %Z')",
  "units": $UNITS_JSON,
  "certificates": $CERT_JSON,
  "listening": $PORTS_JSON,
  "listeners": $LISTENERS_JSON,
  "services": $SERVICES_JSON,
  "configs": $CONFIG_JSON,
  "vhosts": $VHOSTS_JSON,
  "firewall": $FIREWALL_JSON,
  "runtimes": $RUNTIME_JSON,
  "dotnetInstalled": $INSTALLED_JSON,
  "errors": [${ERRORS#,}]
}
JSON
    # Atomic: the page must never read a half-written file. On any failure the
    # temp file goes, or a service that runs for months fills tmpfs with them.
    if ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$OUT"; then
        rm -f "$tmp"
        return 1
    fi
}

trap 'rm -f "$OUT_DIR"/.status.* 2>/dev/null; exit 0' TERM INT

# The directory's mtime moves when certbot adds or removes a lineage, so a new
# certificate shows up on the next fast loop instead of up to an hour later.
# A renewal only rewrites symlinks inside a lineage and does not move this
# mtime, so that is still the hourly pass's job. Days remaining can wait; a
# certificate the page reports as missing cannot.
cert_dir_stamp() { stat -c %Y "$LE_LIVE" 2>/dev/null || echo 0; }
LE_STAMP=$(cert_dir_stamp)

while :; do
    now=$(date +%s)
    stamp=$(cert_dir_stamp)
    if [ $(( now - CERT_CHECKED )) -ge "$SLOW_SECONDS" ] || [ "$stamp" != "$LE_STAMP" ]; then
        collect_certs
        CERT_CHECKED=$now
        LE_STAMP=$stamp
    fi
    if [ $(( now - CONFIG_CHECKED )) -ge "$MID_SECONDS" ]; then
        collect_configs
        collect_vhosts
        collect_firewall
        collect_runtimes
        CONFIG_CHECKED=$now
    fi
    write_status || true
    sleep "$FAST_SECONDS"
done
