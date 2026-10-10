#!/usr/bin/env bash
# =============================================================================
# ASK THE VAULT FIRST, THE KEYBOARD SECOND.
#
#   . "$SCRIPT_DIR/secret_ask.sh"
#   value="$(secret_ask transip-api-key --label "the TransIP private key" \
#                       --multiline --validate 'openssl pkey -noout')"
#
#   secret_ask <name> [options]    the secret on stdout
#                                  0 got one, 1 nothing usable given
#
#     --label <text>      what to call it in the ask. Required
#     --multiline         a pasted block (PEM), reflowed, ending at END or EOF
#     --validate <cmd>    fed the value on stdin; non-zero means ask again.
#                         A LITERAL command only: never built from config or
#                         from anything the console can write, because it is
#                         evaluated here and the callers run as root
#     --hint <text>       one line of "how to find it", printed plain
#     --ask               skip the vault read, prompt anyway. For rotation
#     --no-save           do not write a keyboard answer back
#     --no-ask            read the vault and stop; never prompt. For a caller
#                         whose own ask is better than this one's
#
#   secret_save <name>             stores stdin under <name> if there is a
#                                  vault. Never fails the caller
#
# THE PRINT HELPERS HERE ARE PREFIXED `_sa_`, and that is not tidiness. This
# file is SOURCED, so a `print_status` defined here would replace the caller's
# for the rest of its run, and these write to stderr because stdout carries
# the secret. The unprefixed first version moved 43 of add_transip_key.sh's
# messages onto the wrong stream.
#
# The value never touches a file here and never becomes an argument: it is
# read into a variable and written to stdout, as secret_store.sh requires.
#
# A KEYBOARD ANSWER GOES INTO THE VAULT WHEN THERE IS ONE. The owner, 2026-09-20:
# "if available yes". A fresh drive then asks once, ever. No vault means the
# ask happens every install, which is exactly today's behaviour.
# =============================================================================

_sa_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
_sa_success() { printf "\033[32m✅ %s\033[0m\n" "$1" >&2; }
_sa_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
_sa_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
_sa_hint()    { printf "   %s\n" "$1" >&2; }
_sa_prompt()  { printf "\n   \033[33m%s\033[0m " "$1" > "$SA_TTY_OUT"; }

# The terminal, as a pair of handles. Tests point them at a file; everything
# else gets /dev/tty, because a caller may have consumed this script's stdin.
SA_TTY_IN="${SA_TTY_IN:-/dev/tty}"
SA_TTY_OUT="${SA_TTY_OUT:-/dev/tty}"

if [ "${SECRET_READY:-0}" != "1" ]; then
    _sa_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    SECRET_OPTIONAL=1 . "$_sa_dir/secret_store.sh" 2>/dev/null || SECRET_READY=0
fi

# One asterisk per character, as they arrive. read -s shows nothing at all, so
# a paste that landed and one that did not look identical.
_sa_read_masked() {
    local out="" ch
    while IFS= read -rsn1 ch; do
        case "$ch" in
            "")             break ;;
            $'\177'|$'\b')  [ -n "$out" ] && { out="${out%?}"; printf '\b \b' > "$SA_TTY_OUT"; } ;;
            *)              out="$out$ch"; printf '*' > "$SA_TTY_OUT" ;;
        esac
    done < "$SA_TTY_IN"
    printf '\n' > "$SA_TTY_OUT"
    printf '%s' "$out"
}

# A terminal paste arrives as one long line, and PEM wants its body wrapped.
_sa_reflow_pem() {
    local raw header footer body
    raw="$(cat)"
    header="$(printf '%s' "$raw" | grep -oE -- '-----BEGIN [A-Z ]+-----' | head -n1)"
    footer="$(printf '%s' "$raw" | grep -oE -- '-----END [A-Z ]+-----' | head -n1)"
    if [ -z "$header" ] || [ -z "$footer" ]; then printf '%s' "$raw"; return 0; fi
    body="${raw#*"$header"}"; body="${body%"$footer"*}"
    body="$(printf '%s' "$body" | tr -d ' \t\n\r')"
    printf '%s\n' "$header"
    printf '%s' "$body" | fold -w 64
    printf '\n%s\n' "$footer"
}

_sa_read_block() {
    local line out=""
    while IFS= read -r line; do
        out="$out$line"$'\n'
        case "$line" in *"-----END "*) break ;; esac
    done < "$SA_TTY_IN"
    printf '%s' "$out" | tr -d '\r' | _sa_reflow_pem
}

_sa_valid() {
    local cmd="$1" value="$2"
    [ -n "$value" ] || return 1
    [ -n "$cmd" ] || return 0
    printf '%s' "$value" | eval "$cmd" >/dev/null 2>&1
}

secret_save() {
    local name="$1" value
    value="$(cat)"
    if [ "${SECRET_READY:-0}" != "1" ]; then
        _sa_info "No vault on this machine, so '$name' was not stored. The next install asks again."
        return 0
    fi
    if printf '%s' "$value" | secret_file_put "$name" 2>/dev/null; then
        _sa_success "Put in the vault as '$name'. The next install will not ask."
    else
        _sa_action "The vault would not take '$name'. The value is in use, but the next install asks again."
    fi
    return 0
}

secret_ask() {
    local name="$1"; shift
    local label="" hint="" validate="" multiline=0 force=0 save=1 vault_only=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --label)     label="$2"; shift 2 ;;
            --hint)      hint="$2"; shift 2 ;;
            --validate)  validate="$2"; shift 2 ;;
            --multiline) multiline=1; shift ;;
            --ask)       force=1; shift ;;
            --no-save)   save=0; shift ;;
            --no-ask)    vault_only=1; shift ;;
            *) _sa_error "secret_ask: unknown option '$1'."; return 1 ;;
        esac
    done
    if [ -z "$name" ] || [ -z "$label" ]; then
        _sa_error "secret_ask needs a name and a --label."
        return 1
    fi
    [ "${SECRET_ASK_FORCE:-0}" = "1" ] && force=1

    local value="" rc
    if [ "$force" -eq 0 ] && [ "${SECRET_READY:-0}" = "1" ]; then
        value="$(secret_file_get "$name" 2>/dev/null)"
        rc=$?
        # A key typed or pasted into the vault by hand comes back as one line:
        # the app keeps the text, not the line breaks. Same repair as a paste.
        if [ "$rc" -eq 0 ] && [ "$multiline" -eq 1 ]; then
            value="$(printf '%s' "$value" | _sa_reflow_pem)"
        fi
        case "$rc" in
            0) if _sa_valid "$validate" "$value"; then
                   _sa_info "$label came from the vault, as '$name'. Nothing to type."
                   printf '%s' "$value"
                   return 0
               fi
               _sa_action "The vault's '$name' is not usable, so $label is being asked for instead."
               ;;
            1) [ "$vault_only" -eq 1 ] || _sa_info "The vault has no '$name' yet, so $label is asked for once." ;;
            2) _sa_action "The vault could not be read, so $label is being asked for instead." ;;
        esac
        value=""
    fi

    # The caller has its own ask and only wanted the vault tried.
    if [ "$vault_only" -eq 1 ]; then
        return 1
    fi

    if ! { : < "$SA_TTY_IN"; } 2>/dev/null; then
        _sa_error "$label is not in the vault and there is no terminal to ask at."
        _sa_action "Run this from a terminal, or put it in the vault under '$name'."
        return 1
    fi

    local try again
    for try in 1 2 3; do
        printf '\n' > "$SA_TTY_OUT"
        _sa_action "NEEDED: $label"
        if [ -n "$hint" ]; then _sa_hint "$hint"; fi
        if [ "$multiline" -eq 1 ]; then
            _sa_hint "paste it whole, BEGIN and END lines included, then press Enter."
            value="$(_sa_read_block)"
        else
            _sa_prompt "$label:"
            value="$(_sa_read_masked)"
        fi

        if _sa_valid "$validate" "$value"; then
            # Nothing checks a typed value that has no validator, and it is
            # about to become the vault's truth. So it is typed twice.
            if [ -z "$validate" ] && [ "$save" -eq 1 ] && [ "$multiline" -eq 0 ]; then
                _sa_prompt "Again:"
                again="$(_sa_read_masked)"
                if [ "$value" != "$again" ]; then
                    value=""
                    _sa_error "The two did not match."
                    if [ "$try" -eq 3 ]; then
                        _sa_action "Nothing was stored. Run this again."
                        return 1
                    fi
                    continue
                fi
            fi
            break
        fi

        value=""
        _sa_error "That is not a usable value for $label."
        if [ "$try" -eq 3 ]; then
            _sa_action "Nothing was stored. Run this again with the value to hand."
            return 1
        fi
    done

    if [ "$save" -eq 1 ]; then
        printf '%s' "$value" | secret_save "$name"
    fi

    printf '%s' "$value"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _sa_error "Source this file; it exposes secret_ask and secret_save."
    exit 1
fi
