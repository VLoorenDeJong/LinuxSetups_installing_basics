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
# Let every share be written without a password for a chosen time.
#
#   share_window.sh open <minutes>   5, 10, 15, 60, 120 or 240; again = restart
#   share_window.sh close            close now (the timer calls this too)
#   share_window.sh status           one line of JSON for the console
#
# Open arms the close timer FIRST, so a failure halfway still closes. Then it
# gives smbguest an ACL on every share folder and makes every share writable
# through an override Samba includes. Close takes both away and gives files
# made during the window to the owner of their folder, so a restored database
# belongs to the app again. Design: share-write-window-decisions.md.
# =============================================================================
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    exit 1
fi

MODE="${1:-}"
MINUTES="${2:-}"
SELF="/usr/local/sbin/share_window.sh"
[ -x "$SELF" ] || SELF="$(readlink -f "$0")"
GUEST="smbguest"
OVERRIDE="/etc/samba/share-window.conf"
STATE="/run/share-window.state"
STAMP="/run/share-window.start"
TIMER_UNIT="share-window-close"

# The same refusals as set_share_access.sh: only where a share may live, and
# never a folder a system account set its own modes on (the mail store holds
# the DKIM signing keys).
ROOTS=(/srv /var/www /mnt /media)
for h in /home/*; do
    [ -d "$h" ] && ROOTS+=("$h")
done
SYSTEM_OWNERS="vmail _rspamd postfix dovecot mysql postgres redis systemd-resolve
systemd-network messagebus syslog landscape tss uuidd _apt nobody"

# Never opened, whatever share contains them: the console's code runs with its
# sudo grants, auth holds the login files, certbot answers certificate
# challenges, and a dot-folder in a home holds keys and shell start-up files.
NEVER=(/var/www/hosting-manager /var/www/auth /var/www/certbot)
PRUNE=(\( -path '/home/*/.*')
for n in "${NEVER[@]}"; do
    PRUNE+=(-o -path "$n")
done
PRUNE+=(\) -prune -o)

refused_root() {
    local n
    for n in "${NEVER[@]}"; do
        case "$1" in "$n"|"$n"/*) return 0 ;; esac
    done
    case "$1" in /home/*/.*) return 0 ;; esac
    # A whole home is its owner's dot-files and all.
    [ "$(dirname "$1")" = "/home" ]
}

in_roots() {
    local r
    for r in "${ROOTS[@]}"; do
        case "$1" in "$r"|"$r"/*) return 0 ;; esac
    done
    return 1
}

# name<TAB>path for every share with a folder, read from the running config.
list_shares() {
    testparm -s 2>/dev/null | awk '
        /^\[/ { name = substr($0, 2, length($0) - 2); next }
        /^[[:space:]]*path = / && name != "global" && name != "printers" && name != "print$" {
            sub(/^[[:space:]]*path = /, ""); print name "\t" $0 }'
}

share_paths() {
    local name path resolved
    while IFS=$'\t' read -r name path; do
        resolved="$(readlink -f -- "$path" 2>/dev/null || true)"
        [ -n "$resolved" ] && [ -d "$resolved" ] && in_roots "$resolved" || continue
        refused_root "$resolved" && continue
        # Printed by find only when the owner is not a system account.
        find "$resolved" -maxdepth 0 "${SKIP_SYSTEM[@]}" 2>/dev/null
    done < <(list_shares)
}

# find tests that skip a system account's entries. Only accounts that exist:
# find refuses an unknown -user name outright.
SKIP_SYSTEM=()
for s in $SYSTEM_OWNERS; do
    id "$s" >/dev/null 2>&1 && SKIP_SYSTEM+=(\! -user "$s")
done

# Paths whose ACL, once smbguest's entries are gone, names nobody else: those
# lose the ACL entirely (-b). Paths that still name someone but whose default
# ACL names nobody lose only the default (-k). Read from one getfacl -R pass.
leftover_acls() {  # <root> <b|k>
    getfacl -R -P -s -p "$1" 2>/dev/null | awk -v want="$2" '
        function done_block() {
            if (path == "") return
            if (want == "b" && !named) print path
            if (want == "k" && named && hasdef && !defnamed) print path
        }
        /^# file: / { done_block(); path = substr($0, 9); named = hasdef = defnamed = 0; next }
        /^default:/ { hasdef = 1 }
        /^(default:)?(user|group):[^:]+:/ { named = 1 }
        /^default:(user|group):[^:]+:/ { defnamed = 1 }
        END { done_block() }'
}

status_json() {
    local now ends acl=0
    now="$(date +%s)"
    ends="$(cat "$STATE" 2>/dev/null || echo 0)"
    [ -s "$OVERRIDE" ] && acl=1
    if [ "$ends" -gt "$now" ] 2>/dev/null; then
        printf '{"open":true,"ends":%s,"left":%s}\n' "$ends" "$((ends - now))"
    else
        # Open past its end time means the close failed: the page shows it red.
        printf '{"open":false,"stuck":%s}\n' "$([ "$acl" = 1 ] && echo true || echo false)"
    fi
}

reload_samba() {
    systemctl is-active --quiet smbd || return 0
    smbcontrol all reload-config >/dev/null 2>&1 \
        || print_error "Samba did not reload. Check it with: sudo systemctl status smbd"
}

case "$MODE" in
    status)
        status_json
        exit 0 ;;
    open)
        case "$MINUTES" in
            5|10|15|60|120|240) : ;;
            *) print_error "Minutes must be 5, 10, 15, 60, 120 or 240."; exit 1 ;;
        esac ;;
    close) : ;;
    *)
        print_error "Usage: $0 open <minutes> | close | status"
        exit 1 ;;
esac

# --- pre-flight --------------------------------------------------------------
ERRORS=()
command -v setfacl  >/dev/null 2>&1 || ERRORS+=("setfacl is missing. Install it: sudo apt-get install -y acl")
command -v testparm >/dev/null 2>&1 || ERRORS+=("testparm is missing. Install it: sudo apt-get install -y samba-common-bin")
id "$GUEST" >/dev/null 2>&1 || ERRORS+=("The account $GUEST does not exist. Run add_smb_guest.sh first.")
if [ "${#ERRORS[@]}" -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

if [ "$MODE" = "open" ]; then
    print_header "Opening the shares for writing, $MINUTES minutes"

    # The timer first. A restart replaces the old one rather than adding one.
    systemctl stop "${TIMER_UNIT}.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "${TIMER_UNIT}.service" "${TIMER_UNIT}.timer" >/dev/null 2>&1 || true
    systemd-run --quiet --unit="$TIMER_UNIT" --on-active="${MINUTES}m" \
        --timer-property=AccuracySec=1s /bin/bash "$SELF" close
    echo "$(( $(date +%s) + MINUTES * 60 ))" > "$STATE"
    print_success "Close timer armed: $(date -d "@$(cat "$STATE")" '+%H:%M:%S')."

    # A restart keeps the first start, so close still finds every file made.
    [ -f "$STAMP" ] && [ -s "$OVERRIDE" ] || touch "$STAMP"

    ACL_DONE=0
    while IFS= read -r root; do
        find "$root" -xdev "${PRUNE[@]}" -type d "${SKIP_SYSTEM[@]}" \
            -exec setfacl -P -m "u:${GUEST}:rwx,d:u:${GUEST}:rwx" {} + 2>/dev/null || true
        find "$root" -xdev "${PRUNE[@]}" -type f "${SKIP_SYSTEM[@]}" \
            -exec setfacl -P -m "u:${GUEST}:rw" {} + 2>/dev/null || true
        # Write on a folder is rename inside it, so the folder holding a
        # protected one is read-only, or the guest could swap the console out.
        for n in "${NEVER[@]}"; do
            case "$(dirname "$n")" in
                "$root"|"$root"/*) setfacl -P -m "u:${GUEST}:rx,d:u:${GUEST}:rwx" "$(dirname "$n")" 2>/dev/null || true ;;
            esac
        done
        ACL_DONE=$((ACL_DONE + 1))
        print_status "Writable for $GUEST: $root"
    done < <(share_paths)

    {
        echo "# Written by share_window.sh while a write window is open."
        echo "# Emptied when it closes. Never edit by hand."
        while IFS=$'\t' read -r name _path; do
            printf '[%s]\n   read only = No\n   force user = %s\n' "$name" "$GUEST"
        done < <(list_shares)
    } > "$OVERRIDE.tmp"
    mv "$OVERRIDE.tmp" "$OVERRIDE"
    chmod 0644 "$OVERRIDE"
    reload_samba
    print_success "$ACL_DONE share folders writable without a password until $(date -d "@$(cat "$STATE")" '+%H:%M')."
    status_json
    exit 0
fi

# --- close -------------------------------------------------------------------
print_header "Closing the share write window"
systemctl stop "${TIMER_UNIT}.timer" >/dev/null 2>&1 || true

: > "$OVERRIDE"
reload_samba
print_success "Shares are back to their own settings."

# True when the guest could write here without the window: then a file it made
# is ordinary share use and keeps its owner.
guest_could_write() {
    local dir="$1" owner group perms
    owner="$(stat -c %U "$dir")"; group="$(stat -c %G "$dir")"; perms="$(stat -c %A "$dir")"
    [ "$owner" = "$GUEST" ] && return 0
    [ "${perms:5:1}" = "w" ] && id -nG "$GUEST" | tr ' ' '\n' | grep -qx "$group" && return 0
    [ "${perms:8:1}" = "w" ] && return 0
    return 1
}

REOWNED=0
while IFS= read -r root; do
    find "$root" -xdev "${PRUNE[@]}" -type d -exec setfacl -P -x "u:${GUEST},d:u:${GUEST}" {} + 2>/dev/null || true
    find "$root" -xdev "${PRUNE[@]}" -type f -exec setfacl -P -x "u:${GUEST}" {} + 2>/dev/null || true
    # A bare default ACL left behind would replace the umask for every new file.
    leftover_acls "$root" b | xargs -r -d '\n' setfacl -P -b 2>/dev/null || true
    leftover_acls "$root" k | xargs -r -d '\n' setfacl -P -k 2>/dev/null || true

    if [ -f "$STAMP" ]; then
        while IFS= read -r -d '' made; do
            parent="$(dirname "$made")"
            guest_could_write "$parent" && continue
            # -h: a file swapped for a link since find saw it moves the link,
            # not its target. o-w: a guest-chosen world-writable mode would
            # outlive the window on a file that now belongs to someone else.
            chown -h --reference="$parent" "$made" && chmod o-w "$made" \
                && REOWNED=$((REOWNED + 1))
        done < <(find "$root" -xdev "${PRUNE[@]}" -user "$GUEST" -newer "$STAMP" \! -type l -print0 2>/dev/null)
    fi
done < <(share_paths)

rm -f "$STATE" "$STAMP"
print_success "Write access removed. $REOWNED file(s) given to the owner of their folder."
status_json
