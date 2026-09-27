#!/usr/bin/env bash
# =============================================================================
# THE SECRET STORE, in verbs. The interface; the vault is a config value.
# login-store-decisions.md, decision 5.
#
#   . "$SCRIPT_DIR/secret_store.sh"
#   secret_file_get    <name>      the stored file on stdout
#                                  0 found, 1 absent, 2 could not tell
#   secret_file_put    <name>      stores stdin under <name>, replacing any
#                                  file already there
#   secret_file_delete <name>      0 gone (or never there), 2 could not tell
#   secret_preflight               0 if the store can work, or one reason per
#                                  line and 1
#
# CONTENT GOES THROUGH STDIN AND STDOUT, never a temporary file and never an
# argument. A secret written to /tmp outlives the run if it dies, and an
# argument shows in `ps` to every user on the machine. The caller decides
# where a file lands, and writes it atomically.
#
# NO CALLER NAMES A PROVIDER. `SECRET_PROVIDER` in hostings.conf names the
# service file; this resolves and sources it, as dns.sh does for DNS.
#
# CHANGED AND DROPPED ARE DIFFERENT QUESTIONS.
#
#   changed   a second service file exposing these verbs. Nothing else moves
#   dropped   sourcing fails loudly HERE. A caller that can live without the
#             store sources with SECRET_OPTIONAL=1 and tests $SECRET_READY
#
#   secret_entry_set    <entry> <section>
#                                  sets the fields on stdin, one per line as
#                                  `field<TAB>password|text|url<TAB>value`, in one
#                                  section of a person's entry, making the
#                                  entry if it is absent. Section "" is the
#                                  entry's own login: `username`, `password`
#   secret_entry_urls   <entry>     replaces the entry's own URL list with the
#                                  `label<TAB>href` lines on stdin, first one
#                                  primary. This is what autofill matches on; a
#                                  `url` field in a section is only a link
#   secret_entry_share  <entry> <e-mail>
#                                  a link only that address can open, on
#                                  stdout. Nothing is sent: the caller mails it
#                                  1 absent, 2 could not tell
#   secret_entry_delete <entry>    as secret_file_delete
#   secret_entry_titles <title>    every title in the vault that <title> would
#                                  be kept in. 0 listed, 2 could not tell
#   secret_entry_unset takes several sections, one per line, in one write
#   secret_entry_relabel <entry>   renames sections, fields and all, from the
#                                  `old<TAB>new` lines on stdin, in one write,
#                                  and orders the sections by label. 0 done or
#                                  nothing to rename, 1 absent, 2 could not tell
#
# The entry is decision 7's: page login, then each mailbox, then the mail
# client settings. Sharing it is decision 8, a button, never automatic.
# =============================================================================

_ss_error()  { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
_ss_action() { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }

SECRET_READY=0
SECRET_PROVIDER_FILE=""

# A caller from outside this repo (LinuxBasics) passes no config; the one
# beside this file is the only one it could mean.
if [ -z "${SITES_CONF:-}" ]; then
    declare -F conf_active >/dev/null \
        || . "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null \
        || conf_active() { printf '%s/hostings.conf' "$1"; }
    _ss_default_conf="$(conf_active /etc/hostings)"
    [ -f "$_ss_default_conf" ] && SITES_CONF="$_ss_default_conf"
    unset _ss_default_conf
fi

_ss_conf_get() {
    local v
    [ -n "${SITES_CONF:-}" ] || { printf '%s' "$2"; return 0; }
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"; v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

# A name added here is a name every provider has to answer to.
SECRET_REQUIRED_VERBS="secret_file_get secret_file_put secret_file_delete secret_preflight secret_entry_set secret_entry_get secret_entry_unset secret_entry_relabel secret_entry_titles secret_entry_urls secret_entry_share secret_entry_delete"

_secret_load() {
    local dir name cand v missing=""
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # The environment wins over the config, as SITES_CONF does everywhere else.
    name="${SECRET_PROVIDER:-$(_ss_conf_get SECRET_PROVIDER secret_store_1password.sh)}"
    # Sourced as root from a value the console can write: a bare file name only.
    if ! [[ "$name" =~ ^secret_store_[a-z0-9_]+\.sh$ ]]; then
        _ss_error "SECRET_PROVIDER '$name' is not a secret_store_<name>.sh file name."
        return 1
    fi

    for cand in "$dir/$name" \
                "/usr/local/lib/linuxbasics/hostings/scripts/$name"; do
        [ -f "$cand" ] && { SECRET_PROVIDER_FILE="$cand"; break; }
    done
    if [ -z "$SECRET_PROVIDER_FILE" ]; then
        _ss_error "No secret store file called '$name' beside secret_store.sh or in the pipeline tree."
        _ss_action "Set SECRET_PROVIDER in ${SITES_CONF:-hostings.conf}, or put the file there."
        return 1
    fi

    # shellcheck source=/dev/null
    . "$SECRET_PROVIDER_FILE" || { _ss_error "$SECRET_PROVIDER_FILE could not be sourced."; return 1; }

    for v in $SECRET_REQUIRED_VERBS; do
        declare -F "$v" >/dev/null 2>&1 || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
        _ss_error "$SECRET_PROVIDER_FILE does not provide:$missing"
        _ss_action "A secret store file must expose: $SECRET_REQUIRED_VERBS"
        return 1
    fi

    SECRET_READY=1
}

if ! _secret_load; then
    if [ "${SECRET_OPTIONAL:-0}" = "1" ]; then
        _ss_action "Carrying on without the secret store. Anything that needed it is skipped, not guessed."
    else
        return 1 2>/dev/null || exit 1
    fi
fi

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --check)
            printf 'provider: %s\n' "${SECRET_PROVIDER_FILE:-none}"
            printf 'ready:    %s\n' "$SECRET_READY"
            printf 'verbs:    %s\n' "$SECRET_REQUIRED_VERBS"
            [ "$SECRET_READY" = "1" ] || exit 1
            if reasons="$(secret_preflight 2>&1)"; then
                printf 'store:    reachable\n'
            else
                printf 'store:    not usable\n%s\n' "$reasons"; exit 1
            fi
            ;;
        *)
            printf 'Source this file. %s --check names the provider and tries the store.\n' "$0" >&2
            exit 1
            ;;
    esac
fi
