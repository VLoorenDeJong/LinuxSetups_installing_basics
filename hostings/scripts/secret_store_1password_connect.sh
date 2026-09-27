#!/usr/bin/env bash
# =============================================================================
# The secret store through the local 1Password Connect server
# (add_1password_connect.sh). Same verbs, same item shapes as
# secret_store_1password.sh, which this file sources: Connect writes to a local
# cache, off the service account's 100 writes an hour. Decision 9.
#
# SHARING STILL GOES THROUGH THE SERVICE ACCOUNT. Connect has no share call
# and cannot write Documents, which is why stored files are Secure Notes in
# both files.
#
# The Connect token is read from OP_CONNECT_TOKEN_FILE per call and handed to
# curl as a header file, never as an argument: argv shows in `ps`.
#
# SOURCED, NOT RUN.
# =============================================================================

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/secret_store_1password.sh" || return 1

_CX_URL="http://127.0.0.1:$(_op_conf_get OP_CONNECT_PORT 11004)"
_CX_TOKEN_FILE="$(_op_conf_get OP_CONNECT_TOKEN_FILE /root/.op_connect_token)"
_CX_VAULT_ID=""
declare -gA _CX_VAULT_IDS=()

# $1 method, $2 path, rest to curl. Sets _CX_BODY and _CX_CODE rather than
# printing, so a caller never runs it in a subshell and loses the code.
# 000 means no answer at all.
_cx() {
    local method="$1" path="$2" out
    shift 2
    out="$(curl -sS --max-time "${SECRET_TIMEOUT:-30}" -X "$method" -w '\n%{http_code}' \
                -H @<(printf 'Authorization: Bearer %s\nContent-Type: application/json' \
                             "$(_op_token_file_read "$_CX_TOKEN_FILE" op-connect-token)") \
                "$@" "${_CX_URL}${path}" 2>/dev/null)"
    _CX_CODE="${out##*$'\n'}"
    _CX_BODY="${out%$'\n'*}"
}

# Sets _CX_VAULT_ID to the vault named $1, looked up once per run. The write,
# settle and delete that follow an _cx_item use the vault it chose.
_cx_vault() {  # <vault name>
    local name="${1:-$_OP_VAULT}"
    _CX_VAULT_ID="${_CX_VAULT_IDS[$name]:-}"
    [ -n "$_CX_VAULT_ID" ] && return 0
    _cx GET /v1/vaults -G --data-urlencode "filter=name eq \"$name\""
    [ "$_CX_CODE" = 200 ] && _CX_VAULT_ID="$(printf '%s' "$_CX_BODY" | jq -r '.[0].id // empty')"
    [ -n "$_CX_VAULT_ID" ] && { _CX_VAULT_IDS[$name]="$_CX_VAULT_ID"; return 0; }
    _ss_error "Connect could not find vault '$name' (HTTP $_CX_CODE)."
    return 2
}

# The stored item by title, in _CX_ITEM. 0 found, 1 absent, 2 could not tell.
_cx_item() {
    local id
    _CX_ITEM=""
    _cx_vault "$(_op_vault_for "$1")" || return 2
    _cx GET "/v1/vaults/$_CX_VAULT_ID/items" -G --data-urlencode "filter=title eq \"$1\""
    [ "$_CX_CODE" = 200 ] || { _ss_error "Connect refused the lookup of '$1' (HTTP $_CX_CODE)."; return 2; }
    id="$(printf '%s' "$_CX_BODY" | jq -r '.[0].id // empty')"
    [ -n "$id" ] || return 1
    _cx GET "/v1/vaults/$_CX_VAULT_ID/items/$id"
    [ "$_CX_CODE" = 200 ] || { _ss_error "Connect refused '$1' (HTTP $_CX_CODE)."; return 2; }
    _CX_ITEM="$_CX_BODY"
}

# $1 the stored item, or "" to create; $2 the item to write. Never piped in:
# _cx has to run in this shell for _CX_CODE to survive.
_cx_write() {
    local id body
    body="$(printf '%s' "$2" | jq -c --arg v "$_CX_VAULT_ID" '.vault = {id: $v}')" || return 2
    if [ -n "$1" ]; then
        id="$(printf '%s' "$1" | jq -r .id)"
        _cx PUT "/v1/vaults/$_CX_VAULT_ID/items/$id" --data-binary @<(printf '%s' "$body")
    else
        _cx POST "/v1/vaults/$_CX_VAULT_ID/items" --data-binary @<(printf '%s' "$body")
    fi
    # Connect says WHY in the body, and a bare code cannot be debugged: the
    # 400 of 2026-09-20 is unexplained because this line threw its reason away.
    case "$_CX_CODE" in
        200|201) ;;
        *) _ss_error "Connect refused the write (HTTP $_CX_CODE): $(printf '%s' "$_CX_BODY" | tr -d '\n' | head -c 300)"
           return 2 ;;
    esac
    _cx_settle "$(printf '%s' "$_CX_BODY" | jq -r .id)" "$body"
}

# A write is readable about a second after Connect accepts it (measured
# 2026-09-19). Until then a lookup misses it or returns the old values, and the
# next put makes a second item or undoes this one. So a write returns only once
# its own values read back. Not the version: an update answers with the old one.
#
# THE URL LIST IS CHECKED TOO. Fields alone made this blind to a write that
# only changed .urls: the test passed against the item as it was BEFORE the
# write, settle returned at once, and the next write rebuilt from a read that
# still had no URL list and silently removed it again.
_cx_settle() {
    local id="$1" i
    for i in $(seq 1 20); do
        _cx GET "/v1/vaults/$_CX_VAULT_ID/items/$id"
        [ "$_CX_CODE" = 200 ] \
            && printf '%s' "$_CX_BODY" | jq -e --slurpfile w <(printf '%s' "$2") '
                   [.fields[]? | {label, value}] as $got
                   | all($w[0].fields[]? | {label, value}; . as $f | any($got[]; . == $f))
                     and (([.urls[]? | {label, href}] | sort)
                          == ([$w[0].urls[]? | {label, href}] | sort))' >/dev/null \
            && return 0
        sleep 0.5
    done
    _ss_error "Connect accepted the write but did not read it back within 10 s."
    return 2
}

_cx_delete() {
    local rc id
    _cx_item "$1"; rc=$?
    [ "$rc" -eq 1 ] && return 0
    [ "$rc" -eq 0 ] || return 2
    id="$(printf '%s' "$_CX_ITEM" | jq -r .id)"
    _cx DELETE "/v1/vaults/$_CX_VAULT_ID/items/$id"
    case "$_CX_CODE" in 200|204|404) return 0 ;; esac
    _ss_error "Connect refused the delete (HTTP $_CX_CODE)."
    return 2
}

secret_file_get() {
    local rc
    _cx_item "$(_file_title "$1")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$_CX_ITEM" | _file_content
}

secret_file_put() {
    local rc new
    _cx_item "$(_file_title "$1")"; rc=$?
    [ "$rc" -eq 2 ] && return 2
    new="$(_file_item "$1" "$_CX_ITEM")" || return 2
    _cx_write "$_CX_ITEM" "$new"
}

secret_file_delete() { _cx_delete "$(_file_title "$1")"; }

# THE THREE WRITE VERBS RETRY. Connect answered one PUT with 400 on
# 2026-09-20, on the second of two writes to the same item in a row, and the
# same write succeeded on its own afterwards. It was not reproduced, so the
# cause is unproven; a re-read and one more attempt costs two seconds and is
# what the service account's side already does for 409.
_cx_retry() { case "$_CX_CODE" in 400|409) return 0 ;; esac; return 1; }

secret_entry_set() {
    local name="$1" section="$2" fields new rc try
    fields="$(cat)"
    for try in 1 2 3 4; do
        _cx_item "$name"; rc=$?
        [ "$rc" -eq 2 ] && return 2
        new="$(_entry_merge "$name" "$section" "$_CX_ITEM" "$fields" "${SECRET_ENTRY_REPLACE:-}")" || return 2
        [ "$new" = '"same"' ] && return 0
        _cx_write "$_CX_ITEM" "$new" && return 0
        _cx_retry || return 2
        sleep 2
    done
    return 2
}


# Reading and dropping go through Connect too: the jq is the sourced file's, so
# only the fetch and the write differ.
secret_entry_get() {
    local rc
    _cx_item "$1"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$_CX_ITEM" | _entry_read "${2:-}"
}

secret_entry_unset() {
    local new rc try
    for try in 1 2 3 4; do
        _cx_item "$1"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        new="$(printf '%s' "$_CX_ITEM" | _entry_drop "$2")" || return 2
        [ "$new" = '"same"' ] && return 0
        _cx_write "$_CX_ITEM" "$new" && return 0
        _cx_retry || return 2
        sleep 2
    done
    return 2
}

secret_entry_relabel() {
    local new rc try pairs
    pairs="$(cat)"
    for try in 1 2 3 4; do
        _cx_item "$1"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        new="$(printf '%s' "$_CX_ITEM" | _entry_relabel "$pairs")" || return 2
        [ "$new" = '"same"' ] && return 0
        _cx_write "$_CX_ITEM" "$new" && return 0
        _cx_retry || return 2
        sleep 2
    done
    return 2
}

secret_entry_urls() {
    local lines new rc try
    lines="$(cat)"
    for try in 1 2 3 4; do
        _cx_item "$1"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        new="$(printf '%s' "$_CX_ITEM" | _entry_urls "$lines")" || return 2
        [ "$new" = '"same"' ] && return 0
        _cx_write "$_CX_ITEM" "$new" && return 0
        _cx_retry || return 2
        sleep 2
    done
    return 2
}
secret_entry_delete() { _cx_delete "$1"; }

secret_entry_titles() {
    _cx_vault "$(_op_vault_for "$1")" || return 2
    _cx GET "/v1/vaults/$_CX_VAULT_ID/items"
    [ "$_CX_CODE" = 200 ] || { _ss_error "Connect refused the item list (HTTP $_CX_CODE)."; return 2; }
    printf '%s' "$_CX_BODY" | jq -r '.[].title'
}

# secret_entry_share is the service account's, from the file sourced above.

secret_preflight() {
    _op_preflight || return 1
    [ -r "$_CX_TOKEN_FILE" ] \
        || { echo "Cannot read the Connect token at $_CX_TOKEN_FILE. Run: sudo bash add_1password_connect.sh"; return 1; }
    local v
    while IFS= read -r v; do
        _cx_vault "$v" >/dev/null 2>&1 \
            || { echo "Connect does not answer or cannot see '$v'. Test it: sudo bash add_1password_connect.sh --test-only"; return 1; }
    done < <(_op_vaults)
}
