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
# Generate and enable a systemd unit per app row, one per environment.
#
# The runtime is derived from the path: a .dll is run by dotnet, which is the
# only one supported today. The script is not named after it, so adding a
# second means one case arm rather than a rename.
#
# Replaces the manual step in "Linux Install.docx": copying a directory of
# hand-written .service files off the previous machine into
# /etc/systemd/system. That step cannot survive the machine it was copied from,
# and nothing records what the units contained. Here the unit is generated from
# /etc/hostings/hostings.conf, which is in git.
#
# Safe to re-run: a unit whose content has not changed is left alone, so
# re-running does not restart every site on the box.
#
# Apps are published elsewhere and copied in, so a row whose .dll is not on
# disk yet gets its unit written and enabled but is not started. Copy the dll
# and start it, or reboot.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

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

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

# A redraw needs a terminal. In a Jenkins log \r is not a carriage return, so
# every update lands as its own line and \033[K blanks it: seventeen units
# printed one line of text and sixteen empty ones. Silent there instead, since
# each of these loops already prints a summary when it finishes.
redraw() { [ -t 1 ] || return 0; printf "$@"; }

# Watch-only spinner: shows the command is alive but never signals it. A
# daemon-reload killed halfway leaves systemd's view of the units undefined.
show_spinner_watch_only() {
    local message="$1"
    shift
    # No terminal, no redraw: run it directly rather than spinning silently.
    if [ ! -t 1 ]; then "$@"; return $?; fi

    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    "$@" &
    local cmd_pid=$! tick=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        redraw '\r\033[K\033[34m%s %s\033[0m' "${frames[tick % 10]}" "$message"
        tick=$((tick + 1))
        sleep 0.2 || { printf "\n\033[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\033[0m\n"; break; }
    done
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    redraw '\r\033[K'
    return $exit_code
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    print_action "Override the location with: sudo env SITES_CONF=/path/to/hostings.conf $0"
    exit 1
fi

if ! DOTNET_BIN="$(command -v dotnet)"; then
    print_error "dotnet not found on PATH."
    print_action "Run add_dotnet.sh first, then this script."
    exit 1
fi

# Optional, unlike dotnet: no row uses it yet, so a machine without node is not
# broken. A row that asks for it and cannot get it fails on its own line.
NODE_BIN="$(command -v node 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# hostings.conf settings reader.
#
# Duplicated verbatim in every script that reads hostings.conf rather than sourced
# from a shared file, so each script stays runnable on its own on a machine
# that only has that one script copied to it.
#
# A settings line is `KEY = value` at the start of a line. Row lines are pipe
# separated and comment lines start with #, so neither can ever match.
# -----------------------------------------------------------------------------
# Memoised: this is called once per key per row per environment, and each
# uncached call forks four processes. Without the cache a pre-flight on a
# ten row config spends most of its time in fork rather than doing anything.
declare -A _CONF_CACHE=()
conf_get() {
    local key="$1" default="$2" value
    if [ -n "${_CONF_CACHE[$key]+set}" ]; then
        value="${_CONF_CACHE[$key]}"
    else
        value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
        # tr -d '\r': xargs does not strip a carriage return, and a value is
        # the last thing on its line, so a CRLF config leaves one in it.
        value="$(echo "$value" | tr -d '\r' | sed 's/#.*//' | xargs)"
        _CONF_CACHE[$key]="$value"
    fi
    echo "${value:-$default}"
}

# The account the apps run as. APP_RUN_USER in the config decides it: left to
# guess, the answer came from whoever was typing, and the same script rewrote
# every unit's `User=` to a different account depending on how it was invoked.
#
# The env override is APP_RUN_USER too, not APP_USER: add_dns_records.sh and
# add_mail_store.sh read APP_USER as the human who owns the machine, and one
# exported value must not mean both.
RUN_USER="${APP_RUN_USER:-}"
[ -z "$RUN_USER" ] && RUN_USER="$(conf_get APP_RUN_USER '')"
[ "$RUN_USER" = "-" ] && RUN_USER=""

if [ -z "$RUN_USER" ]; then
    # Each step falls through when it yields nothing. An empty marker file used
    # to dead-end the chain here and the run died on a run user of ''.
    [ -f /etc/manageserver-installer-user ] && \
        RUN_USER="$(xargs < /etc/manageserver-installer-user 2>/dev/null || true)"
    [ -z "$RUN_USER" ] && RUN_USER="${SUDO_USER:-}"
    [ -z "$RUN_USER" ] && RUN_USER="$(logname 2>/dev/null || whoami)"
    print_info "APP_RUN_USER is not set in $SITES_CONF, so the run user was guessed as '$RUN_USER'."
    print_info "Set it there: a guess can rewrite every unit's User= to a different account."
fi

if [ -z "$RUN_USER" ]; then
    print_error "Could not work out which account the apps should run as."
    print_action "Set APP_RUN_USER in $SITES_CONF."
    exit 1
fi

# root passes `id` and would put User=root into every unit, which is the one
# answer this whole arrangement exists to avoid.
if [ "$RUN_USER" = "root" ]; then
    print_error "APP_RUN_USER is root. Units would run every app as root."
    print_action "Name an unprivileged account in $SITES_CONF."
    exit 1
fi

if ! id "$RUN_USER" >/dev/null 2>&1; then
    print_error "Run user '$RUN_USER' does not exist on this machine."
    print_action "Set APP_RUN_USER in $SITES_CONF, or override with: sudo env APP_RUN_USER=<name> $0"
    exit 1
fi

# Environments this machine runs. Every app row is generated once per
# environment, so one row becomes one unit per env.
IFS=',' read -r -a ENV_LIST <<< "$(conf_get ENVS live)"
for i in "${!ENV_LIST[@]}"; do
    ENV_LIST[$i]="$(echo "${ENV_LIST[$i]}" | xargs)"
done

# Does this row exist in this environment?
#
# The Envs field is empty for almost everything, meaning all of them. It exists
# because a test environment proves a build runs, which needs one instance of an
# application rather than one per customer: the four progress tenants are live
# only, and a single row covers test.
row_in_env() {
    local list="$1" env="$2" e
    list="$(echo "$list" | xargs)"
    [ -z "$list" ] || [ "$list" = "-" ] && return 0
    IFS=',' read -r -a _re <<< "$list"
    for e in "${_re[@]}"; do
        [ "$(echo "$e" | xargs)" = "$env" ] && return 0
    done
    return 1
}

# --only-row is a flag as well as a variable, because sudo's env_reset drops
# ONLY_ROWS, and `sudo env ONLY_ROWS=x bash ...` is a different command string
# than the NOPASSWD rule for this script matches. A Jenkins job using the
# variable would die asking for a password.
while [ $# -gt 0 ]; do
    case "$1" in
        --only-row)   ONLY_ROWS="$2"; shift 2 ;;
        --only-row=*) ONLY_ROWS="${1#--only-row=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [--only-row <name,name>]" >&2
            exit 1
            ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ONLY_ROWS narrows a run to named rows, so adding one site does not rewrite the
# units of every other one. Comma separated, matched on the second column.
#
#   sudo ./add_app_services.sh --only-row mvp_progress
#
# A name matching no row is a typo, and a typo here would silently do nothing,
# so it stops the run rather than reporting success over an empty selection.
ONLY_ROWS="$(echo "${ONLY_ROWS:-}" | xargs)"
declare -A _WANTED=()
if [ -n "$ONLY_ROWS" ]; then
    IFS=',' read -r -a _rw <<< "$ONLY_ROWS"
    for _r in "${_rw[@]}"; do
        _r="$(echo "$_r" | xargs)"
        [ -z "$_r" ] && continue
        # The ServiceType filter is not decoration: a PANEL line is pipe
        # separated too, so without it the console's port validated as a row
        # name and the main loop then skipped it, reporting nothing at all.
        if ! awk -F'|' -v n="$_r" '
                /^[[:space:]]*#/ { next }
                NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
                         gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                         if ($1 !~ /^(app|website|proxy|mailbox)$/) next
                         if ($2 == n) found = 1 }
                END { exit !found }' "$SITES_CONF"; then
            print_error "ONLY_ROWS names '$_r', which is no row in $SITES_CONF."
            print_info "Names are the second column. To list them:"
            print_info "  awk -F'|' '!/^ *#/ && \$1 ~ /app|website|proxy|mailbox/ {print \$2}' $SITES_CONF"
            exit 1
        fi
        _WANTED[$_r]=1
    done
fi

# Everything, when nothing was asked for.
row_selected() {
    [ ${#_WANTED[@]} -eq 0 ] && return 0
    [ -n "${_WANTED[$1]:-}" ]
}

print_header "App services"
print_status "Config:       $SITES_CONF"
print_status "Run user:     $RUN_USER"
print_status "dotnet:       $DOTNET_BIN"
print_status "Environments: ${ENV_LIST[*]}"
if [ -n "$ONLY_ROWS" ]; then
    print_status "Rows:         $ONLY_ROWS (everything else left alone)"
fi

# Fail before writing anything if an environment has no app root. A missing
# APP_ROOT would otherwise generate units with ExecStart pointing at a path
# that is just the relative fragment, and every one of them would crash loop.
for env in "${ENV_LIST[@]}"; do
    env_upper="$(echo "$env" | tr '[:lower:]' '[:upper:]')"
    env_root="$(conf_get "APP_ROOT_${env_upper}" "")"
    if [ -z "$env_root" ]; then
        print_error "ENVS lists '$env' but APP_ROOT_${env_upper} is not set in $SITES_CONF"
        exit 1
    fi
    # Created here rather than by the first deploy: a unit whose
    # WorkingDirectory does not exist, or that its own user cannot enter,
    # exits 200/CHDIR and crash loops with no useful message.
    #
    # Created once, never re-owned. add_smb.sh also creates these from the
    # share definitions and chowns them to the share's force user, and two
    # scripts taking turns to own the same tree is how a deploy breaks weeks
    # later. Whoever made it keeps it; the check below is what has to pass.
    if [ ! -d "$env_root" ]; then
        share_group="$RUN_USER"
        getent group www-data >/dev/null 2>&1 && share_group="www-data"
        # setgid so a file written over SMB and one written by a deploy end up
        # in the same group, which is what makes both able to touch it.
        if ! install -d -m 2775 -o "$RUN_USER" -g "$share_group" "$env_root"; then
            print_error "Cannot create app root for '$env': $env_root"
            exit 1
        fi
    fi
    # Joining the group rather than taking the directory: add_smb.sh owns these
    # from the share definitions, and two scripts taking turns to own one tree
    # is how a deploy breaks weeks later. Membership grants the access without
    # changing a single owner.
    if ! sudo -u "$RUN_USER" test -w "$env_root" 2>/dev/null; then
        root_group="$(stat -c '%G' "$env_root" 2>/dev/null)"
        root_mode="$(stat -c '%a' "$env_root" 2>/dev/null)"

        # Group write has to be there for membership to be worth anything.
        case "$root_mode" in
            *[2367]?) ;;
            *) chmod g+ws "$env_root" 2>/dev/null || true
               print_status "Gave the group write on $env_root (was $root_mode)." ;;
        esac

        if [ -n "$root_group" ] && ! id -nG "$RUN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$root_group"; then
            if usermod -aG "$root_group" "$RUN_USER" 2>/dev/null; then
                print_status "Added $RUN_USER to the '$root_group' group, which owns $env_root."
            fi
        fi

        # A group added to a running process is not seen by it, so the test is
        # re-run as a fresh login rather than trusting the change silently.
        if ! sudo -u "$RUN_USER" test -w "$env_root" 2>/dev/null; then
            print_error "$RUN_USER cannot write $env_root, so deploys into '$env' will fail."
            echo "   Owner and mode: $(stat -c '%U:%G %a' "$env_root" 2>/dev/null)"
            echo "   Fix with: sudo chgrp $RUN_USER $env_root && sudo chmod 2775 $env_root"
            exit 1
        fi
        print_success "$RUN_USER can write $env_root."
    fi
done

# =============================================================================
# The backup tree the applications write their second copy into
#
# apply_app_settings.sh writes these paths into every appsettings.json and
# nothing created them, so the app created its own on the first request. Under
# a home directory the run user cannot even enter, that throws, the page 500s,
# the deploy's health check fails and the whole build rolls back. Five rows
# failed that way before it was traced.
# =============================================================================
BACKUP_ROOT="$(conf_get BACKUP_ROOT '')"
[ "$BACKUP_ROOT" = "-" ] && BACKUP_ROOT=""

# Upstream packages (upstream/README.md). Their live data stays out of
# BACKUP_ROOT, which sits inside a guest-writable Samba share.
UPSTREAM_DATA_ROOT="$(conf_get UPSTREAM_DATA_ROOT /srv/upstream_apps)"
UPSTREAM_SECRETS="/etc/upstream"

recipe_all() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tr -d '\r' | sed 's/[[:space:]]*$//'; }

# The row's https address in one environment. Same rules as add_app_vhosts.sh.
public_host() {
    local sub="$1" prefix="$2" label
    case "$sub" in
        @*) label="${sub#@}"
            if [ -z "$prefix" ]; then echo "$BASE_DOMAIN"
            elif [ -n "$label" ]; then echo "${prefix}${label}.${BASE_DOMAIN}"
            else echo "${prefix}${BASE_DOMAIN}"; fi ;;
        =*) if [ -z "$prefix" ]; then echo "${sub#=}"; else echo "${prefix%%-}.${sub#=}"; fi ;;
        *)  echo "${prefix}${sub}.${BASE_DOMAIN}" ;;
    esac
}
BASE_DOMAIN="$(conf_get BASE_DOMAIN '')"

# The LAN preview address of one row in one environment, if PREVIEW_ROWS names
# it: the same rules as add_preview_vhosts.sh. An app that checks the Host
# header (Oqtane's aliases) needs it, or it sends a preview visitor away.
MACHINE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[ -z "$MACHINE_IP" ] && MACHINE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
preview_host() {
    local name="$1" env="$2" env_port="$3" entry n e p
    IFS=',' read -ra _pv <<< "$(conf_get PREVIEW_ROWS '')"
    for entry in "${_pv[@]}"; do
        IFS=':' read -r n e p <<< "$(echo "$entry" | xargs)"
        [ "$n" = "$name" ] || continue
        [ -z "$e" ] || [ "$e" = "$env" ] || continue
        echo "${MACHINE_IP}:${p:-$(( $(conf_get PREVIEW_PORT_BASE 20000) + env_port ))}"
        return
    done
}

# systemd expands % and $ inside ExecStart, so a value holding either would
# silently change.
P_URL="{PUBLIC_URL}" P_HOST="{PUBLIC_HOST}" P_HOSTS="{HOSTS}"

# A builder's admin login (recipe LOGIN) lives in the secret store, one login
# entry per row and environment, the way Portainer's admin does: read first,
# so a fresh drive gets the same password back; a new one is stored, and read
# back, before the builder is handed it. No store means the old behaviour, a
# password generated into the env file only.
UPSTREAM_STORE=""
upstream_login() {
    local var="$1" user="$2" pkg="$3" row="$4" env="$5" preview="$6" public="$7" file="$8" entry have got
    if [ -z "$UPSTREAM_STORE" ]; then
        UPSTREAM_STORE=no
        if [ -f "$SCRIPT_DIR/secret_ask.sh" ]; then
            # shellcheck source=/dev/null
            SECRET_OPTIONAL=1 . "$SCRIPT_DIR/secret_ask.sh" 2>/dev/null || true
            [ "${SECRET_READY:-0}" = "1" ] && UPSTREAM_STORE=yes
        fi
    fi
    [ "$UPSTREAM_STORE" = "yes" ] || return 1
    entry="${pkg^} admin, ${row} (${env})"
    got="$(secret_entry_get "$entry" "" 2>/dev/null | awk -F'\t' '$1 == "" && $2 == "password" { print $3; exit }')" || got=""
    have="$(sed -n "s/^${var}=//p" "$file" | head -n1)"
    if [ -n "$got" ]; then
        if [ "$got" != "$have" ]; then
            sed -i "/^${var}=/d" "$file"
            printf '%s=%s\n' "$var" "$got" >> "$file"
            print_status "${entry}: password from the secret store."
        fi
        return 0
    fi
    # Nothing stored: keep the one this drive already uses, or make one.
    [ -n "$have" ] || have="$(openssl rand -hex 16)Aa1!"
    if printf 'username\ttext\t%s\npassword\tpassword\t%s\n' "$user" "$have" | secret_entry_set "$entry" "" \
       && printf 'Preview\t%s\nSite\t%s\n' "$preview" "$public" | secret_entry_urls "$entry" \
       && [ "$(secret_entry_get "$entry" "" 2>/dev/null | awk -F'\t' '$1 == "" && $2 == "password" { print $3; exit }')" = "$have" ]; then
        sed -i "/^${var}=/d" "$file"
        printf '%s=%s\n' "$var" "$have" >> "$file"
        print_status "${entry}: password stored in the secret store."
        return 0
    fi
    print_error "${entry}: the secret store did not keep the password; it stays on this drive only."
    return 1
}
systemd_escape_value() { local v="${1//%/%%}"; printf '%s' "${v//\$/\$\$}"; }

# Every directory between / and BACKUP_ROOT has to be enterable by the run
# user. A home is 0750, so the run user is put in the group that owns it: the
# same choice as env_root above, and for the same reason. Taking ownership of
# somebody's home is not an option, and widening it to 0755 would grant every
# account on the machine what one account needs.
ensure_traversable() {
    local dir="$1" owner_group

    while [ "$dir" != "/" ] && [ -n "$dir" ]; do
        if [ -d "$dir" ] && ! sudo -u "$RUN_USER" test -x "$dir" 2>/dev/null; then
            owner_group="$(stat -c '%G' "$dir" 2>/dev/null)"
            if [ -n "$owner_group" ] && \
               ! id -nG "$RUN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$owner_group"; then
                if usermod -aG "$owner_group" "$RUN_USER" 2>/dev/null; then
                    print_status "Added $RUN_USER to '$owner_group' so it can enter $dir."
                fi
            fi
        fi
        dir="$(dirname "$dir")"
    done
}

if [ -z "$BACKUP_ROOT" ]; then
    print_info "No BACKUP_ROOT in $SITES_CONF, so no application backup folders are made."
else
    ensure_traversable "$(dirname "$BACKUP_ROOT")"
    if [ ! -d "$BACKUP_ROOT" ] && ! install -d -m 2775 -o "$RUN_USER" -g "$RUN_USER" "$BACKUP_ROOT"; then
        print_error "Cannot create the application backup root: $BACKUP_ROOT"
        exit 1
    fi
fi

# THE SANDBOX FOR AN APP THAT RUNS AS THE RUN USER. Audit 2026-10-02, C3.
# The run user is jenkins, which holds root sudo grants, so a broken app must
# not reach sudo (NoNewPrivileges) nor Jenkins' own files and keys. Every app
# shares that uid, so APP_ROOT and BACKUP_ROOT are emptied and only the app's
# own folders are bound back: a sibling's dll and secrets are not there to
# touch. Its state folder is its HOME: ASP.NET keeps its sign-in keys there.
app_sandbox() {  # <app_root> <unit base name> <own dir> <backup dir> [data dir]
    local hide="" e r
    for e in "${ENV_LIST[@]}"; do
        r="$(conf_get "APP_ROOT_$(echo "$e" | tr '[:lower:]' '[:upper:]')" "")"
        [ -n "$r" ] && [ "$r" != "$1" ] && hide="$hide -$r"
    done
    cat <<EOF
Environment=HOME=/var/lib/$2
StateDirectory=$2
NoNewPrivileges=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
TemporaryFileSystem=$1:ro${BACKUP_ROOT:+ $BACKUP_ROOT:ro}
BindPaths=-$3${BACKUP_ROOT:+ -$4}${5:+ -$5}
InaccessiblePaths=-/var/lib/jenkins -/var/lib/hosting-manager -/etc/github-app -/etc/letsencrypt -/etc/app-secrets -/etc/apache2/session-crypto.key${hide}
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
EOF
}

# One row's second copy, for one environment. Made by root and handed to the
# run user, rather than left for the application to create at the moment
# somebody first loads a page.
ensure_backup_dirs() {
    local app="$1" env="$2" dir sub

    [ -z "$BACKUP_ROOT" ] && return 0

    for sub in databases project_photos; do
        dir="${BACKUP_ROOT%/}/${app}/${env}/${sub}"
        [ -d "$dir" ] && continue
        if ! install -d -m 2775 -o "$RUN_USER" -g "$RUN_USER" "$dir"; then
            print_error "Cannot create the backup folder $dir for '$app' in '$env'."
            return 1
        fi
        print_status "Made $dir for $app ($env)."
    done

    if ! sudo -u "$RUN_USER" test -w "${BACKUP_ROOT%/}/${app}/${env}/databases" 2>/dev/null; then
        print_error "$RUN_USER cannot write the backup folder for '$app' in '$env'."
        print_action "Check what owns ${BACKUP_ROOT} and whether $RUN_USER can enter every folder above it."
        return 1
    fi
    return 0
}

UNIT_DIR="/etc/systemd/system"

# =============================================================================
# Clear away the previous unit prefix
#
# Units were named kestrel-<name> until 2026-08-16, after the web server of the
# one runtime this machine happened to run. They are app-<name> now, and the
# pruner below only ever looks at app-*, so an old unit would sit there running
# and holding a port with nothing left that knows about it.
#
# Done by this script rather than by hand, because a machine flashed from this
# branch tomorrow must end up in the same state as one upgraded today. Same
# reason retire_the_console exists in add_hosting_manager.sh.
# =============================================================================
retire_kestrel_units() {
    local f base found=0
    for f in "$UNIT_DIR"/kestrel-*.service; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        systemctl disable --now "$base" >/dev/null 2>&1 || true
        rm -f "$f"
        found=$((found + 1))
    done
    if [ "$found" -gt 0 ]; then
        systemctl daemon-reload
        print_status "Removed $found unit(s) still using the old kestrel- prefix."
    fi
}
retire_kestrel_units

CREATED=()
UPDATED=()
UNCHANGED=()
NOT_STARTED=()
FAILED=()
PLANNED=()
STOPPED=()
NEEDS_RELOAD=0

while IFS='|' read -r type name port path subdomain datasource options auth repo branch rowenvs authusers repomode runtime enabled owner; do
    # Strip comments and blanks before touching the fields
    type="$(echo "$type" | sed 's/#.*//' | xargs)"
    [ -z "$type" ] && continue
    [ "$type" != "app" ] && continue

    name="$(echo "$name" | xargs)"
    row_selected "$name" || continue
    port="$(echo "$port" | xargs)"
    path="$(echo "$path" | xargs)"

    # Empty and `-` both mean dotnet: it is what every row was before the field
    # existed, so a config written against the old format still works.
    row_runtime="$(echo "${runtime:-}" | sed 's/#.*//' | xargs)"
    row_runtime="$(echo "$row_runtime" | tr '[:upper:]' '[:lower:]')"
    { [ -z "$row_runtime" ] || [ "$row_runtime" = "-" ]; } && row_runtime="dotnet"
    # dotnet8 and dotnet10 name the version a project was CREATED against. The
    # unit runs `dotnet <app>.dll` either way: the framework comes out of the
    # build's runtimeconfig.json, never out of this field.
    case "$row_runtime" in dotnet*) row_runtime="${row_runtime%%[0-9]*}" ;; esac

    # A row written before the Enabled field existed has no fifteenth column,
    # and everything was enabled until then. A disabled application still gets
    # its unit written: what stops is the running of it.
    # The CR is stripped before xargs, which does not strip it. This is the
    # LAST field on the line, so it is the one a CRLF config reaches, and
    # "no\r" is not "no": the row would have read as enabled.
    enabled="${enabled//$'\r'/}"
    row_enabled="$(echo "${enabled:-}" | sed 's/#.*//' | xargs | tr '[:upper:]' '[:lower:]')"
    { [ -z "$row_enabled" ] || [ "$row_enabled" = "-" ]; } && row_enabled="yes"

    if [ -z "$name" ] || [ -z "$port" ] || [ -z "$path" ]; then
        print_error "Incomplete app row, needs name, port and path: '$name'"
        FAILED+=("${name:-<unnamed>} (incomplete config row)")
        continue
    fi

    # One row, one unit per environment. The row carries the test port and a
    # path relative to that environment's app root, and everything else is
    # derived, so adding an environment never touches a row.
    for env in "${ENV_LIST[@]}"; do
        row_in_env "$rowenvs" "$env" || continue
        env_upper="$(echo "$env" | tr '[:lower:]' '[:upper:]')"
        app_root="$(conf_get "APP_ROOT_${env_upper}" "")"
        suffix="$(conf_get "${env_upper}_UNIT_SUFFIX" "")"
        offset="$(conf_get "${env_upper}_PORT_OFFSET" 0)"

        env_port=$((port + offset))
        env_path="${app_root%/}/${path#/}"

        unit_name="app-${name}${suffix}.service"
        unit_file="$UNIT_DIR/$unit_name"
        work_dir="$(dirname "$env_path")"

        # Upstream packages keep their data under UPSTREAM_DATA_ROOT instead.
        if [[ "$row_runtime" != upstream:* ]] && ! ensure_backup_dirs "$name" "$env"; then
            FAILED+=("$name ($env: no writable backup folder)")
            continue
        fi

        # The row says what it is written in, and that decides what the unit
        # executes. Adding a language is one arm here, not a new row type.
        unit_user="$RUN_USER"
        unit_extra=""
        # The data folder, resolved as apply_app_settings.sh does: =<path> as
        # written, another row's name as that row's wwwroot, else inside work_dir.
        ds="$(echo "${datasource:-}" | xargs)"
        data_dir=""
        case "$ds" in
            ""|-) ;;
            =*)   data_dir="${ds#=}" ;;
            *)    ds_path="$(grep -v '^[[:space:]]*#' "$SITES_CONF" | awk -F'|' -v n="$ds" \
                      '{ gsub(/ /, "", $2); if ($2 == n) { gsub(/ /, "", $4); print $4; exit } }')"
                  [ -n "$ds_path" ] && data_dir="${app_root%/}/$(dirname "${ds_path#/}")/wwwroot" ;;
        esac
        sandbox="$(app_sandbox "$app_root" "app-${name}${suffix}" "$work_dir" \
            "${BACKUP_ROOT%/}/${name}/${env}" "$data_dir")"
        case "$row_runtime" in
            dotnet|uno)
                exec_start="${DOTNET_BIN} ${env_path} --urls \"http://localhost:${env_port}\""
                ;;
            # Item 140. The image is built by deploy_docker_app.sh, which writes
            # the .built marker only after a successful build, so the existing
            # "artifact not on disk" test below holds for containers too.
            # Root, because starting a container is root; the container itself
            # is published on loopback only, and Apache is its door.
            # docker_node and docker_python (item 141) differ only in what a
            # NEW repository is seeded with. The row runs identically: an image
            # built from its Dockerfile, listening on 8080.
            docker|docker_*)
                image="app-$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')${suffix}"
                env_path="${app_root%/}/.docker/${image}.built"
                work_dir="/"
                unit_user="root"
                sandbox=""
                exec_start="/usr/bin/docker run --rm --name ${image} -p 127.0.0.1:${env_port}:8080 -e ASPNETCORE_ENVIRONMENT=Production ${image}:latest"
                # The marker comment is how prune_orphans.sh finds it again.
                unit_extra="ExecStartPre=-/usr/bin/docker rm -f ${image}
ExecStop=/usr/bin/docker stop ${image}
# docker marker: ${env_path}"
                ;;
            # Somebody else's application, built by upstream_build.sh and put
            # on this environment by upstream_promote.sh, which writes the
            # version file used here as the "artifact on disk" marker.
            upstream:*)
                pkg="${row_runtime#upstream:}"
                recipe="$REPO_ROOT/hostings/upstream/${pkg}/recipe.conf"
                if [ ! -f "$recipe" ]; then
                    print_error "Row '$name' runs upstream package '$pkg', and there is no $recipe."
                    FAILED+=("$name (no recipe for upstream:$pkg)")
                    continue
                fi
                cname="app-${name}${suffix}"
                # The builder was switched in the console: export the site from
                # the old one now, while it still runs. It moves into the new
                # one after the second pass (upstream_transfer.sh). If the
                # export fails, the row keeps its old builder.
                old_pkg="$(sed -nE 's/^ExecStart=.* upstream-([a-z0-9_.-]+):[a-z0-9_-]+$/\1/p' "$unit_file" 2>/dev/null || true)"
                if [ -n "$old_pkg" ] && [ "$old_pkg" != "$pkg" ]; then
                    if bash "$SCRIPT_DIR/upstream_transfer.sh" --export-pending "$name" "$env" "$old_pkg" "$pkg"; then
                        UPSTREAM_SWITCHED=1
                    else
                        print_error "Row '$name' ($env) stays on $old_pkg: its site could not be exported for the switch to $pkg."
                        FAILED+=("$name/$env (switch $old_pkg to $pkg: export failed)")
                        continue
                    fi
                fi
                env_path="/var/lib/upstream/${pkg}/${env}"
                work_dir="/"
                unit_user="root"
                sandbox=""
                cport="$(recipe_all "$recipe" CONTAINER_PORT | head -n1)"

                ds="$(echo "$datasource" | xargs)"
                case "$ds" in
                    =/*) data_root="${ds#=}" ;;
                    *)   data_root="${UPSTREAM_DATA_ROOT%/}/${name}/${env}" ;;
                esac
                # One folder per builder: switching a row to another builder
                # must not mix their files, and switching back finds the old site.
                data_root="${data_root%/}/${pkg}"
                host="$(public_host "$(echo "$subdomain" | xargs)" "$(conf_get "${env_upper}_HOST_PREFIX" "")")"
                pv="$(preview_host "$name" "$env" "$env_port")"
                # Preview first: an app that sends every address to its first
                # (Oqtane) then stays on the preview port on a test machine.
                hosts="${pv:+$pv,}${host}"

                # Somebody else's code: no rights it does not need, no way out
                # to the internet or to this machine (upstream_net.sh), and a
                # read-only filesystem except what the recipe names.
                exec_start="/usr/bin/docker run --rm --name ${cname} -p 127.0.0.1:${env_port}:${cport:-8080}"
                exec_start+=" --security-opt no-new-privileges --cap-drop ALL --pids-limit 512 --memory $(recipe_all "$recipe" MEMORY | head -n1 | grep . || echo 768m)"
                for c in $(recipe_all "$recipe" CAPS | head -n1); do exec_start+=" --cap-add $c"; done
                if [ "$(recipe_all "$recipe" READ_ONLY | head -n1 | grep . || echo yes)" = "yes" ]; then
                    exec_start+=" --read-only --tmpfs /tmp"
                    for w in $(recipe_all "$recipe" WRITABLE | head -n1); do exec_start+=" --tmpfs $w"; done
                fi
                [ "$(recipe_all "$recipe" EGRESS | head -n1)" = "yes" ] || exec_start+=" --network upstream-net"
                while IFS= read -r m; do
                    [ -n "$m" ] || continue
                    install -d -m 750 "${data_root}/${m%%:*}"
                    exec_start+=" -v ${data_root}/${m%%:*}:${m#*:}"
                done < <(recipe_all "$recipe" MOUNT)
                # Folders inside the mounts the app expects but does not make.
                for d in $(recipe_all "$recipe" MKDIR | head -n1); do install -d -m 755 "${data_root}/${d}"; done
                while IFS= read -r e; do
                    [ -n "$e" ] || continue
                    e="${e//"$P_URL"/https://$host}"; e="${e//"$P_HOSTS"/$hosts}"; e="${e//"$P_HOST"/$host}"
                    exec_start+=" -e \"$(systemd_escape_value "$e")\""
                done < <(recipe_all "$recipe" ENV)

                # Generated once and kept: a new session secret would sign
                # every user out on each apply.
                secrets_file="${UPSTREAM_SECRETS}/${cname}.env"
                install -d -m 700 "$UPSTREAM_SECRETS"
                [ -f "$secrets_file" ] || install -m 600 /dev/null "$secrets_file"
                while IFS= read -r s; do
                    [ -n "$s" ] || continue
                    login="$(recipe_all "$recipe" LOGIN | awk -v s="$s" '$1 == s { print $2; exit }')"
                    if [ -n "$login" ]; then
                        upstream_login "$s" "${login//"$P_HOST"/$host}" "$pkg" "$name" "$env" \
                            "http://${pv:-$host}" "https://$host" "$secrets_file" || true
                    fi
                    grep -q "^${s}=" "$secrets_file" || echo "${s}=$(openssl rand -hex 16)Aa1!" >> "$secrets_file"
                done < <(recipe_all "$recipe" SECRET)
                exec_start+=" --env-file ${secrets_file} upstream-${pkg}:${env}"

                unit_extra="ExecStartPre=/bin/bash /usr/local/lib/linuxbasics/hostings/scripts/upstream_net.sh
ExecStartPre=-/usr/bin/docker rm -f ${cname}
ExecStop=/usr/bin/docker stop ${cname}"
                ;;
            node)
                if [ -z "$NODE_BIN" ]; then
                    print_error "Row '$name' is a Node application but node is not installed."
                    FAILED+=("$name (node not on PATH)")
                    continue
                fi
                # PORT is what every Node framework reads. Nothing here proves a
                # given app honours it: this arm is written, not exercised.
                exec_start="${NODE_BIN} ${env_path}"
                ;;
            *)
                print_error "Row '$name' has an application type this script cannot run: '$row_runtime'"
                echo "   Known types: dotnet, uno, docker, docker_node, docker_python, node, upstream:<package>. Fix the last field of the row in $SITES_CONF."
                FAILED+=("$name (unknown application type '$row_runtime')")
                continue
                ;;
        esac

        new_unit="$(cat <<EOF
# Generated by add_app_services.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.
[Unit]
Description=App ${name} (${env}) on port ${env_port}
After=network.target

[Service]
WorkingDirectory=${work_dir}
ExecStart=${exec_start}${unit_extra:+
${unit_extra}}
Restart=always
# Long enough that a crash loop does not hammer the box, short enough that a
# transient failure recovers without anyone noticing
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=app-${name}${suffix}
User=${unit_user}${sandbox:+
${sandbox}}
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false

[Install]
WantedBy=multi-user.target
EOF
)"

        if [ -f "$unit_file" ] && [ "$(cat "$unit_file")" = "$new_unit" ]; then
            UNCHANGED+=("$name/$env")
        else
            if [ -f "$unit_file" ]; then
                UPDATED+=("$name/$env")
            else
                CREATED+=("$name/$env")
            fi
            printf '%s\n' "$new_unit" > "$unit_file"
            chmod 644 "$unit_file"
            NEEDS_RELOAD=1
        fi

        # The app is published elsewhere and deployed in. A unit pointing at a
        # missing dll would just crash loop, so it is enabled for next boot in
        # the second pass but never started.
        if [ ! -f "$env_path" ]; then
            NOT_STARTED+=("$name/$env (dll not on disk: $env_path)")
            # Not starting it is not enough: an earlier run may have started it
            # when the dll was there, or against an older path, and
            # Restart=always then loops it forever against a WorkingDirectory
            # that does not exist. Stopped unconditionally rather than after an
            # is-active test, because a unit stuck in auto-restart reports
            # "activating", which is-active does not treat as running.
            systemctl stop "$unit_name" >/dev/null 2>&1 || true
        fi

        PLANNED+=("$name|$env|$unit_name|$env_path|$row_enabled")
    done
done < "$SITES_CONF"

if [ "$NEEDS_RELOAD" -eq 1 ]; then
    show_spinner_watch_only "Reloading systemd" systemctl daemon-reload
    print_success "systemd reloaded."
fi

# Enable and start in a second pass, after daemon-reload, so systemd is
# reading the units we just wrote rather than the previous version. The list
# comes from the first pass so the two cannot disagree about which rows apply.
TOTAL=${#PLANNED[@]}
INDEX=0

[ "$TOTAL" -gt 0 ] && print_status "Enabling and starting units..."

for entry in ${PLANNED+"${PLANNED[@]}"}; do
    IFS="|" read -r name env unit_name env_path row_enabled <<< "$entry"
    INDEX=$((INDEX + 1))
    redraw '\r\033[K[%2d/%2d] %s (%s)' "$INDEX" "$TOTAL" "$unit_name" "$env"

    # A disabled row keeps its unit file, its folder and its port. What stops
    # is the running of it, and it stays stopped across a reboot.
    if [ "$row_enabled" = "no" ]; then
        systemctl disable "$unit_name" >/dev/null 2>&1 || true
        systemctl stop    "$unit_name" >/dev/null 2>&1 || true
        STOPPED+=("$name/$env")
        continue
    fi

    if ! systemctl enable "$unit_name" >/dev/null 2>&1; then
        redraw '\r\033[K'
        print_error "Could not enable $unit_name"
        FAILED+=("$name/$env (enable failed)")
        continue
    fi

    # Enabled for next boot, but starting it now would only crash loop
    [ ! -f "$env_path" ] && continue

    if systemctl is-active --quiet "$unit_name"; then
        systemctl restart "$unit_name" >/dev/null 2>&1 || true
    else
        systemctl start "$unit_name" >/dev/null 2>&1 || true
    fi

    # Give it a moment to fall over on a bad dll before reporting success
    for _ in 1 2 3 4; do
        sleep 0.5 || break
        printf '.'
    done

    if ! systemctl is-active --quiet "$unit_name"; then
        redraw '\r\033[K'
        print_error "$unit_name did not stay running."
        print_action "Logs: sudo journalctl -u $unit_name -n 30 --no-pager"
        FAILED+=("$name/$env (unit not active)")
    fi
done
[ "$TOTAL" -gt 0 ] && redraw '\r\033[K'

echo ""
# A switched builder takes in the site exported above, once it answers. A
# switch whose new builder is not built yet finishes when it is promoted.
if [ "${UPSTREAM_SWITCHED:-0}" = "1" ] || [ -n "$(ls /var/lib/upstream/pending 2>/dev/null | grep -v '.done$')" ]; then
    bash "$SCRIPT_DIR/upstream_transfer.sh" --import-pending || true
fi

[ ${#CREATED[@]} -gt 0 ]     && print_success "Created:   ${CREATED[*]}"
[ ${#STOPPED[@]} -gt 0 ]     && print_info    "Disabled:  ${STOPPED[*]}"
[ ${#UPDATED[@]} -gt 0 ]     && print_success "Updated:   ${UPDATED[*]}"
[ ${#UNCHANGED[@]} -gt 0 ]   && print_success "Unchanged: ${UNCHANGED[*]}"

if [ ${#NOT_STARTED[@]} -gt 0 ]; then
    print_info "Enabled but not started, no published app yet:"
    for entry in "${NOT_STARTED[@]}"; do
        print_info "  - $entry"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    print_error "Problems:"
    for entry in "${FAILED[@]}"; do
        print_error "  - $entry"
    done
    exit 1
fi

print_success "App services configured."
