#!/usr/bin/env bash
# =============================================================================
# Install the hosting stack: the modules chosen for this machine, in order.
#
#   sudo ./install_hostings.sh                      install what INSTALL_MODULES says
#   sudo ./install_hostings.sh --modules            choose the modules again
#   sudo ./install_hostings.sh --config-dir <dir>   use <dir> as /etc/hostings
#
# The config lives in /etc/hostings. --config-dir links that path to a
# directory kept somewhere else, such as a clone of a private repository.
# With no config there yet, a blank template is written and nothing else
# happens: fill it in and run this again.
#
# The modules and their steps are in modules.conf beside this file. The
# choice is saved as INSTALL_MODULES in the config, so a rebuild asks nothing.
# A module that rows in the config need is ticked and cannot be dropped.
#
# Every step is re-runnable. A failed run stops at the failing step; running
# this again redoes the steps before it harmlessly and carries on.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASICS="$(cd "$HERE/.." && pwd)/install_scripts"
MODULES_FILE="$HERE/modules.conf"
TEMPLATE="$HERE/hostings.conf.template"
CONF_DIR="/etc/hostings"

ASK=0
GIVEN_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --modules)    ASK=1; shift ;;
        --config-dir) GIVEN_DIR="${2:-}"; shift 2 ;;
        -h|--help)    sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            print_error "Unknown option '$1'. See --help."; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This installs system services, so it needs root."
    print_action "Run: sudo $0"
    exit 1
fi
[ -f "$MODULES_FILE" ] || { print_error "No modules.conf beside $0."; exit 1; }
. "$HERE/scripts/config.sh" || { print_error "No scripts/config.sh beside $0."; exit 1; }

# =============================================================================
# The config directory
# =============================================================================
print_header "Config"
if [ -n "$GIVEN_DIR" ]; then
    GIVEN_DIR="$(readlink -f "$GIVEN_DIR")"
    [ -d "$GIVEN_DIR" ] || { print_error "--config-dir $GIVEN_DIR is not a directory."; exit 1; }
    if [ -d "$CONF_DIR" ] && [ ! -L "$CONF_DIR" ]; then
        print_error "$CONF_DIR is a real directory, so it was not replaced by a link to $GIVEN_DIR."
        print_action "Move what is in it into $GIVEN_DIR, remove it, and run this again."
        exit 1
    fi
    ln -sfn "$GIVEN_DIR" "$CONF_DIR"
    print_success "$CONF_DIR -> $GIVEN_DIR"
fi
install -d -m 0755 "$CONF_DIR"

CONF_FILE="$(conf_active "$CONF_DIR")"
if [ ! -f "$CONF_FILE" ]; then
    install -m 0644 "$TEMPLATE" "$CONF_DIR/hostings.conf"
    print_success "Wrote a blank config: $CONF_DIR/hostings.conf"
    print_action "Fill in what your modules need (modules.conf says which: conf lines), then run this again."
    exit 2
fi
print_success "Config in force: $CONF_FILE"

conf_value() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF_FILE" | head -1 \
        | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//; s/\r$//'
}

# add_dotnet.sh asks only when neither the caller nor the config answers.
if [ -z "${DOTNET_VERSIONS:-}" ]; then
    DOTNET_VERSIONS="$(conf_value DOTNET_VERSIONS)"
    [ "$DOTNET_VERSIONS" = "-" ] && DOTNET_VERSIONS=""
    [ -n "$DOTNET_VERSIONS" ] && export DOTNET_VERSIONS
fi
# =============================================================================
# Modules
# =============================================================================
declare -a NAME ROWS STEP_MOD STEP_CMD REQUIRES NEEDS_CONF
while IFS='|' read -r kind a b c; do
    kind="$(printf '%s' "$kind" | tr -d '[:space:]')"
    a="$(printf '%s' "$a" | tr -d '[:space:]')"
    case "$kind" in
        module)   NAME[a]="$(printf '%s' "$b" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                  ROWS[a]="$(printf '%s' "$c" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" ;;
        requires) REQUIRES[a]="$(printf '%s' "$b" | xargs)" ;;
        conf)     NEEDS_CONF[a]="$(printf '%s' "$b" | xargs)" ;;
        step)     STEP_MOD+=("$a"); STEP_CMD+=("$(printf '%s' "$b" | tr -d '[:space:]')") ;;
    esac
done < <(grep -vE '^[[:space:]]*(#|$)' "$MODULES_FILE")
IDS=("${!NAME[@]}")

# Modules the rows cannot do without, with the reason.
declare -A LOCKED=()
for m in "${IDS[@]}"; do
    for t in ${ROWS[m]}; do
        grep -qE "^[[:space:]]*${t}[[:space:]]*\|" "$CONF_FILE" || continue
        LOCKED[$m]="${LOCKED[$m]:+${LOCKED[$m]}, }$t rows"
    done
done

declare -A TICK=()
SAVED="$(conf_value INSTALL_MODULES | tr -d ' ')"
for m in ${SAVED//,/ }; do [ -n "${NAME[m]:-}" ] && TICK[$m]=1; done

show_modules() {
    local m mark
    echo ""
    for m in "${IDS[@]}"; do
        mark="[ ]"; [ "${TICK[$m]:-0}" = 1 ] && mark="[x]"
        if [ -n "${LOCKED[$m]:-}" ]; then
            printf "  %d. %-30s %s  locked: %s\n" "$m" "${NAME[m]}" "$mark" "${LOCKED[$m]}"
        else
            printf "  %d. %-30s %s\n" "$m" "${NAME[m]}" "$mark"
        fi
    done
    echo "  a. all      c. clear"
}
lock_required() { local m; for m in "${!LOCKED[@]}"; do TICK[$m]=1; done; }

save_modules() {
    local list="" m new
    for m in "${IDS[@]}"; do [ "${TICK[$m]:-0}" = 1 ] && list="${list:+$list,}$m"; done
    if grep -qE '^[[:space:]]*INSTALL_MODULES[[:space:]]*=' "$CONF_FILE"; then
        # Written through, not replaced: the file keeps its owner and mode.
        new="$(sed -E "s|^[[:space:]]*INSTALL_MODULES[[:space:]]*=.*|INSTALL_MODULES = $list|" "$CONF_FILE")"
        printf '%s\n' "$new" > "$CONF_FILE"
    else
        printf '\n# Modules install_hostings.sh installs. Change with: install_hostings.sh --modules\nINSTALL_MODULES = %s\n' "$list" >> "$CONF_FILE"
    fi
    print_success "Saved INSTALL_MODULES = $list in $CONF_FILE"
}

print_header "Modules"
if [ "$ASK" = 1 ] || [ -z "$SAVED" ]; then
    if ! { : < /dev/tty; } 2>/dev/null; then
        print_error "No INSTALL_MODULES in $CONF_FILE, and no terminal to ask at."
        print_action "Add: INSTALL_MODULES = 1   (or run with --modules to choose from a list)"
        exit 1
    fi
    lock_required
    while true; do
        show_modules
        printf "\033[33mChoose (e.g. 1,4,6), Enter keeps the ticks: \033[0m"
        read -r answer < /dev/tty || answer=""
        answer="$(printf '%s' "$answer" | tr -d ' ')"
        case "$answer" in
            "") break ;;
            a|A) for m in "${IDS[@]}"; do TICK[$m]=1; done ;;
            c|C) TICK=() ;;
            *)
                bad=0
                for m in ${answer//,/ }; do [ -n "${NAME[m]:-}" ] 2>/dev/null || bad=1; done
                if [ "$bad" = 1 ]; then print_error "Numbers from the list, comma separated, or a or c."; continue; fi
                TICK=()
                for m in ${answer//,/ }; do TICK[$m]=1; done
                ;;
        esac
        lock_required
    done
    save_modules
else
    for m in "${!LOCKED[@]}"; do
        [ "${TICK[$m]:-0}" = 1 ] && continue
        print_info "INSTALL_MODULES leaves out ${NAME[m]}, but ${LOCKED[$m]} need it: installing it anyway."
        TICK[$m]=1
    done
fi
# What a chosen module stands on is installed with it, so choosing the one
# thing a machine needs is enough.
added=1
while [ "$added" = 1 ]; do
    added=0
    for m in "${IDS[@]}"; do
        [ "${TICK[$m]:-0}" = 1 ] || continue
        for r in ${REQUIRES[m]:-}; do
            [ -n "${NAME[r]:-}" ] || { print_error "modules.conf: module $m requires $r, which does not exist."; exit 1; }
            [ "${TICK[$r]:-0}" = 1 ] && continue
            TICK[$r]=1; added=1
            print_info "${NAME[m]} needs ${NAME[r]}: installing it too."
        done
    done
done

chosen=""
for m in "${IDS[@]}"; do [ "${TICK[$m]:-0}" = 1 ] && chosen="${chosen:+$chosen, }$m ${NAME[m]}"; done
print_status "Modules: ${chosen:-none}"

# Only the settings the chosen modules read are demanded.
MISSING=()
for m in "${IDS[@]}"; do
    [ "${TICK[$m]:-0}" = 1 ] || continue
    for k in ${NEEDS_CONF[m]:-}; do
        v="$(conf_value "$k")"
        [ -n "$v" ] && [ "$v" != "-" ] && continue
        [[ " ${MISSING[*]} " == *" $k "* ]] || MISSING+=("$k")
    done
done
if [ ${#MISSING[@]} -gt 0 ]; then
    print_error "$CONF_FILE has no ${MISSING[*]}, which the chosen modules need."
    print_action "Fill them in, then run this again."
    exit 1
fi

# =============================================================================
# Steps
# =============================================================================
resolve() {
    local s="${1%%:*}"
    [ -f "$HERE/scripts/$s" ] && { printf '%s' "$HERE/scripts/$s"; return 0; }
    [ -f "$BASICS/$s" ]       && { printf '%s' "$BASICS/$s"; return 0; }
    return 1
}

# A step two chosen modules both list runs once, at its first place. A module
# repeating its own step (add_app_vhosts.sh) does so on purpose and keeps both.
RUN=()
declare -A QUEUED_BY=()
for i in "${!STEP_CMD[@]}"; do
    m="${STEP_MOD[i]}"; s="${STEP_CMD[i]}"
    [ "${TICK[$m]:-0}" = 1 ] || continue
    if [ -n "${QUEUED_BY[$s]:-}" ] && [ "${QUEUED_BY[$s]}" != "$m" ]; then continue; fi
    QUEUED_BY[$s]="$m"
    RUN+=("$s")
done
NOT_FOUND=()
for s in "${RUN[@]}"; do resolve "$s" >/dev/null || NOT_FOUND+=("${s%%:*}"); done
if [ ${#NOT_FOUND[@]} -gt 0 ]; then
    print_error "Missing step scripts: ${NOT_FOUND[*]}. Nothing was run."
    exit 1
fi

n=0
for s in "${RUN[@]}"; do
    n=$((n + 1))
    path="$(resolve "$s")"
    arg=""; [ "$s" != "${s%%:*}" ] && arg="${s#*:}"
    print_header "[$n/${#RUN[@]}] ${s%%:*}${arg:+ $arg}"
    if ! bash "$path" ${arg:+"$arg"}; then
        print_error "${s%%:*} failed. Steps 1 to $((n - 1)) are done."
        print_action "Fix what it said, then run this again: it carries on from here."
        exit 1
    fi
done

print_header "Done"
print_success "Installed: ${chosen:-nothing}"
