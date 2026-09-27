#!/usr/bin/env bash
set -e

# =============================================================================
# Every hostname this machine serves, asked of the scripts that own them.
#
# WHY THIS EXISTS. add_app_vhosts.sh:862 claimed to be "the single source of
# hostnames", and that claim was false the day add_admin_vhosts.sh was written.
# Four consumers each assembled the list themselves, from two generators, with
# two different calling conventions. Three were taught about the admin names
# and one was not, so admin.example.com held a vhost and a certificate and
# resolved nowhere.
#
# The generator still OWNS its names. This only removes the consumer's need to
# know how many generators there are, or how each one is asked.
#
#   list_served_hostnames.sh              every name, one per line, sorted
#   list_served_hostnames.sh --for dns    only the names that purpose wants
#   list_served_hostnames.sh --except X   every name X does not already derive
#
# ADDING A GENERATOR IS ONE LINE in the table below, not an edit in four
# consumers. That is the whole point of the file.
#
# --for takes a purpose because a third generator will eventually publish a
# name that wants a vhost and no DNS record, or the reverse. Today every
# purpose gets the same list, and the table says so rather than the flag being
# accepted and ignored.
#
# --except is for a consumer that IS one of the generators.
# add_site_certificates.sh carries its own copy of add_app_vhosts.sh's hostname
# logic, deliberately, so that either script stays runnable alone on a machine
# holding only that file; check_generators_agree.sh is the guard on that
# duplication. It still wants every OTHER generator's names, and asking by
# exception means a third generator reaches it without this file being edited.
#
# STDOUT IS THE PRODUCT AND HOLDS NOTHING ELSE. Every message, including the
# usage text and every refusal, goes to stderr. A consumer pipes this straight
# into a list of hostnames, so one line of human text on stdout becomes a
# certificate request for "Usage:" and fails the whole certificate run.
#
# A GENERATOR THAT FAILS IS AN ERROR, NOT AN EMPTY LIST. Swallowing it is how
# the bug this file exists to fix worked: the caller sees a plausible list with
# one name missing and no way to tell. A generator that is present and exits
# non-zero stops this script, with its own stderr quoted.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1" >&2; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1" >&2; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
print_header()  { printf "\n\033[1;35m=== %s ===\033[0m\n" "$1" >&2; }

# -----------------------------------------------------------------------------
# The generators. script : how it is asked : which purposes want its names.
#
# "env"  -> LIST_HOSTS=1 bash <script>
# "flag" -> bash <script> --list
#
# The two conventions are not tidied into one on purpose: each generator's own
# callers already use its convention, and a rename is a change to a script that
# has to stay runnable alone on a machine holding only that file.
# -----------------------------------------------------------------------------
GENERATORS=(
    "add_app_vhosts.sh:env:all"
    "add_admin_vhosts.sh:flag:all"
)

PURPOSE="all"
EXCEPT=""

usage() {
    {
        echo "Usage: list_served_hostnames.sh [--for dns|certs|vhosts|all] [--except <script.sh>]"
        echo ""
        echo "  Prints every hostname this machine serves, one per line, sorted."
        echo "  --except skips one generator, for a consumer that is itself one."
        echo ""
        echo "  Generators asked:"
        for _e in "${GENERATORS[@]}"; do echo "    ${_e%%:*}"; done
    } >&2
    exit 2
}

# A flag whose value is missing otherwise swallows the next flag, or dies in
# shift with no message at all. Both are silent, and silent here means a
# consumer treating an empty list as "nothing to do".
need_value() {
    if [ "$2" -lt 2 ]; then
        print_error "$1 needs a value."
        usage
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --for)      need_value --for $#;    PURPOSE="$2"; shift 2 ;;
        --for=*)    PURPOSE="${1#--for=}";  shift ;;
        --except)   need_value --except $#; EXCEPT="$2"; shift 2 ;;
        --except=*) EXCEPT="${1#--except=}"; shift ;;
        -h|--help)  usage ;;
        *)          print_error "Unknown option: $1"; usage ;;
    esac
done

case "$PURPOSE" in
    all|dns|certs|vhosts) ;;
    *) print_error "Unknown purpose: $PURPOSE"; usage ;;
esac

# An --except naming no generator is always a mistake: a typo, a missing .sh,
# or a generator that has been renamed. Left unchecked it is silently disarmed
# and the consumer re-requests the names it already derived itself.
if [ -n "$EXCEPT" ]; then
    _known=0
    for _e in "${GENERATORS[@]}"; do
        [ "${_e%%:*}" = "$EXCEPT" ] && _known=1
    done
    if [ "$_known" != "1" ]; then
        print_error "--except names no generator: $EXCEPT"
        usage
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/var/lib/hosting-manager/config-repo/backup_config")"

# ONLY_ROWS is cleared for every generator. This list decides which vhosts and
# which certificates are ORPHAN, and --prune deletes those: a list narrowed to
# the rows a run happens to be writing would call every other name an orphan.
ask_generator() {
    local script="$1" how="$2"
    local path="$SCRIPT_DIR/$script"
    case "$how" in
        env)  LIST_HOSTS=1 ONLY_ROWS= SITES_CONF="$SITES_CONF" bash "$path" ;;
        flag) ONLY_ROWS= SITES_CONF="$SITES_CONF" bash "$path" --list ;;
    esac
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM HUP

# Run them at once. Each is a whole pass over the config that writes nothing,
# so neither can affect the other, and one after the other was measured as the
# slowest part of a pre-flight that changes nothing.
ASKED=()
pids=()
for entry in "${GENERATORS[@]}"; do
    IFS=':' read -r g_script g_how g_purposes <<<"$entry"

    if [ -n "$EXCEPT" ] && [ "$g_script" = "$EXCEPT" ]; then
        continue
    fi
    case ",$g_purposes," in
        *",all,"*|*",$PURPOSE,"*) ;;
        *) continue ;;
    esac
    # A generator that is not on this machine is not a failure: a script has to
    # stay runnable alone on a machine holding only that file.
    if [ ! -f "$SCRIPT_DIR/$g_script" ]; then
        print_info "$g_script is not next to this script, so its names are not in this list."
        continue
    fi

    ask_generator "$g_script" "$g_how" \
        >"$TMP_DIR/$g_script.out" 2>"$TMP_DIR/$g_script.err" &
    pids+=("$!")
    ASKED+=("$g_script")
done

i=0
FAILED=0
for p in ${pids+"${pids[@]}"}; do
    g="${ASKED[$i]}"
    i=$((i + 1))
    if ! wait "$p"; then
        print_error "$g failed, so its hostnames are missing rather than absent."
        sed 's/^/     /' "$TMP_DIR/$g.err" >&2 || true
        FAILED=1
        continue
    fi
    # Zero names is a real answer from a generator with nothing to publish, so
    # it is reported rather than refused: a machine whose config has no domain
    # has no admin name, and that is not a fault.
    if [ ! -s "$TMP_DIR/$g.out" ]; then
        print_info "$g published no hostnames."
    fi
done

if [ "$FAILED" = "1" ]; then
    print_action "Run the failing generator on its own to see why, then try again."
    exit 1
fi

if [ ${#ASKED[@]} -eq 0 ]; then
    print_error "No generator was asked, so this list is empty for a reason nobody can see."
    exit 1
fi

# A blank line from a generator with nothing to say is not a hostname. No
# consumer depends on this: each drops its own blanks too.
cat "$TMP_DIR"/*.out | tr -d '\r' | sed '/^[[:space:]]*$/d' | sort -u
