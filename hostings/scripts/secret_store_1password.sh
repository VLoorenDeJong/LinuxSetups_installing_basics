#!/usr/bin/env bash
# =============================================================================
# The secret store's 1Password service file: the ONLY file that runs `op` or
# reads the service account token. Callers source secret_store.sh, never this.
# login-store-decisions.md.
#
# A stored file is a Secure Note titled `file <name>`, its content in a
# concealed field: `file` when it is text, `content` base64 when it is not.
# Not a Document: Connect can read Documents but not write them (decision 9),
# and both service files must agree on the shape. A name can also be pointed
# at an item made by hand in the app: see SECRET_ITEM_<name> below.
#
# The token is read from OP_TOKEN_FILE (root 0600, systemd-creds encrypted by
# add_1password.sh) on every call and handed to `op` through the environment of
# that one command, so it is never an argument and never exported.
#
# Every call is bounded by SECRET_TIMEOUT seconds, default 30: a console save
# waits on it, and a vault that hangs must not hang the page.
#
# secret_store_1password_connect.sh sources this file for the shapes below and
# for sharing, which Connect cannot do.
#
# SOURCED, NOT RUN.
# =============================================================================

# Prefixed and on stderr: a sourced print_error would replace the caller's,
# and stdout here can be carrying a secret.
if ! declare -F _ss_error >/dev/null 2>&1; then
    _ss_error() { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
fi

_op_conf_get() {
    local v
    [ -n "${SITES_CONF:-}" ] || { printf '%s' "$2"; return 0; }
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"; v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

_OP_VAULT="$(_op_conf_get OP_VAULT '')"
_OP_TOKEN_FILE="$(_op_conf_get OP_TOKEN_FILE /root/.op_service_account_token)"

# ONE VAULT PER KIND OF ITEM. The owner, 2026-09-26. Each falls back to OP_VAULT,
# so a config naming one vault still works.
#
#   `<user> on <domain>`                  OP_VAULT_USERS    a person's entry
#   `<address>` (holds an @)              OP_VAULT_MAIL     one mailbox
#   `file <name>`, name in OP_KEY_FILES   OP_VAULT_KEYS     outside accounts
#   a SECRET_ITEM_* title                 OP_VAULT_KEYS     made by hand
#   any other `file <name>`               OP_VAULT          machine files
#   anything else                         OP_VAULT_SYSTEM   Jenkins, Portainer...
_OP_VAULT_USERS="$(_op_conf_get OP_VAULT_USERS "$_OP_VAULT")"
_OP_VAULT_SYSTEM="$(_op_conf_get OP_VAULT_SYSTEM "$_OP_VAULT")"
_OP_VAULT_MAIL="$(_op_conf_get OP_VAULT_MAIL "$_OP_VAULT_USERS")"
_OP_VAULT_KEYS="$(_op_conf_get OP_VAULT_KEYS "$_OP_VAULT")"
_OP_KEY_FILES="$(_op_conf_get OP_KEY_FILES '')"
_OP_KEY_TITLES="$( [ -n "${SITES_CONF:-}" ] \
    && sed -n 's/^[[:space:]]*SECRET_ITEM_[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*//p' "$SITES_CONF" 2>/dev/null \
       | sed -e 's/\r$//' -e 's/[[:space:]]*#.*//' -e 's/[[:space:]]*$//')"

_op_vault_for() {  # <title>
    case "$1" in
        "file "*)
            case " $_OP_KEY_FILES " in
                *" ${1#file } "*) printf '%s' "$_OP_VAULT_KEYS" ;;
                *)                printf '%s' "$_OP_VAULT" ;;
            esac
            return ;;
        *" on "*) printf '%s' "$_OP_VAULT_USERS"; return ;;
        *@*)      printf '%s' "$_OP_VAULT_MAIL"; return ;;
    esac
    if [ -n "$_OP_KEY_TITLES" ] && printf '%s\n' "$_OP_KEY_TITLES" | grep -qxF -- "$1"; then
        printf '%s' "$_OP_VAULT_KEYS"
    else
        printf '%s' "$_OP_VAULT_SYSTEM"
    fi
}

# Every vault the config names, once each.
_op_vaults() {
    printf '%s\n' "$_OP_VAULT" "$_OP_VAULT_USERS" "$_OP_VAULT_MAIL" "$_OP_VAULT_SYSTEM" "$_OP_VAULT_KEYS" \
        | awk 'NF && !seen[$0]++'
}

# --- shapes, shared with the Connect file -----------------------------------

# AN ITEM MADE BY HAND IN THE APP COUNTS TOO. `file <name>` is what these
# scripts write, and nobody would create that by hand: the app makes an API
# Credential with the secret in `credential`, or a Login with it in `password`.
# So a name MAY be pointed at a human-made item, by title, in hostings.conf:
#
#   SECRET_ITEM_transip_api_key = TransIP API KEY
#
# Dashes in the name become underscores in the key. The WRITE path follows the
# same alias into the same field, which is the point: one secret, one item. A
# read shape that the write path did not share would leave two copies of a
# credential drifting apart, which is the failure this whole store exists to
# remove.
_file_alias() {
    local key
    key="SECRET_ITEM_${1//-/_}"
    _op_conf_get "$key" ''
}

_file_title() {
    local alias
    alias="$(_file_alias "$1")"
    if [ -n "$alias" ]; then printf '%s' "$alias"; else printf 'file %s' "$1"; fi
}

# The labels a person's own item carries, in the order they are believed.
_FILE_PLAIN_LABELS='["credential","password","notesPlain"]'

# TEXT IS STORED AS TEXT. Base64 was never protecting anything: 1Password
# encrypts the vault and the field is CONCEALED either way, so the encoding
# only made a key unreadable in the app. It stays for content that is NOT
# text, where a field would otherwise be corrupted.
#
# The two labels say which is which, so a read never has to guess:
#
#   file      plain text, exactly as written
#   content   base64, and the only thing that is base64
#
# An item written before this keeps `content` and converts on its next write.
# $1 is the file as base64, because a shell variable cannot hold the bytes:
# a command substitution drops every NUL and strips every trailing newline.
_file_is_text() {
    # NUL cannot travel in a JSON string, and invalid UTF-8 comes back mangled.
    printf '%s' "$1" | base64 -d 2>/dev/null | grep -qP '[\x00]' 2>/dev/null && return 1
    printf '%s' "$1" | base64 -d 2>/dev/null | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}

# stdin: the file. stdout: a new item, or with $2 the stored item, updated.
#
# A human-made item is written back in place, plain, in the field it already
# uses: moving it would take the secret out of the item they can read.
_file_item() {
    local b64 text=0
    # HELD AS BASE64, NEVER AS BYTES. `$(cat)` drops every NUL and strips every
    # trailing newline, so a binary came back corrupt and a text file came back
    # one byte short. base64 has neither, so the variable is safe.
    b64="$(base64 -w0)"
    _file_is_text "$b64" && text=1
    jq -c -n --rawfile c <(printf '%s' "$b64") \
             --rawfile p <(printf '%s' "$b64" | base64 -d) \
             --argjson text "$text" \
             --arg t "$(_file_title "$1")" \
             --argjson plain "$_FILE_PLAIN_LABELS" \
             --slurpfile item <(printf '%s' "${2:-null}") '
        ($item[0] // {title: $t, category: "SECURE_NOTE", fields: []})
        | . as $i
        | (($i.fields[]? | select(.label as $l | $plain | index($l))
                        | select(.value != null) | .label) // null) as $field
        | if $field != null
          then .fields |= map(if .label == $field then .value = $p else . end)
          elif $text == 1
          then .fields = [{id: "file", type: "CONCEALED", label: "file", value: $p}]
                         + [.fields[]? | select(.label != "content" and .label != "file")]
          else .fields = [{id: "content", type: "CONCEALED", label: "content", value: $c}]
                         + [.fields[]? | select(.label != "content" and .label != "file")]
          end'
}

# stdin: a stored item. stdout: the file. `file` first, then legacy `content`,
# then the labels a person's own item uses. `jq -j`: a file ends where it ends.
_file_content() {
    local item
    item="$(cat)"
    if printf '%s' "$item" | jq -e 'any(.fields[]?; .label == "file" and .value != null)' >/dev/null; then
        printf '%s' "$item" | jq -j '.fields[] | select(.label == "file") | .value'
    elif printf '%s' "$item" | jq -e 'any(.fields[]?; .label == "content" and .value != null)' >/dev/null; then
        printf '%s' "$item" | jq -j '.fields[] | select(.label == "content") | .value' | base64 -d
    else
        printf '%s' "$item" | jq -j --argjson plain "$_FILE_PLAIN_LABELS" '
            first(.fields[]? | select(.value != null)
                            | select(.label as $l | $plain | index($l)) | .value) // ""'
    fi
}

# $1 entry title, $2 section, $3 stored item or "", $4 the field lines. stdout:
# the item to write, or "same" when writing it would change nothing: the
# service account may write 100 times an hour.
_entry_merge() {
    jq -c -n --rawfile lines <(printf '%s' "$4") --slurpfile item <(printf '%s' "${3:-null}") \
          --arg t "$1" --arg sec "$2" --arg replace "${5:-}" '
        def upsert(p; n):
            if any(.fields[]?; p) then .fields |= map(if p then .value = n.value | .type = n.type else . end)
            else .fields = ((.fields // []) + [n]) end;
        ("s_" + ($sec | ascii_downcase | gsub("[^a-z0-9]+"; "_"))) as $sid
        # replace: the section stops holding whatever it held, in the SAME
        # read-modify-write. Dropping it in a separate call and setting after
        # cannot work: the set re-reads an item the provider has not caught up
        # with yet and merges the old fields straight back in.
        | (if $replace == "replace" and $sec != "" and $item[0] != null
           then $item[0] | .fields = [.fields[]? | select((.section.id // "") != $sid)]
           else $item[0] end) as $base
        | reduce ($lines | split("\n")[] | select(. != "") | split("\t")) as $l
            ($base // {title: $t, category: "LOGIN", fields: []};
             $l[0] as $f | ($l[2:] | join("\t")) as $v
             | (if $l[1] == "password" then "CONCEALED"
                elif $l[1] == "url" then "URL"
                else "STRING" end) as $type
             | if $sec == "" then
                   ($f | ascii_upcase) as $p
                   | upsert(.purpose? == $p; {id: $f, type: $type, purpose: $p, label: $f, value: $v})
               else
                   .sections = (if any(.sections[]?; .id == $sid) then .sections
                                else ((.sections // []) + [{id: $sid, label: $sec}]) end)
                   | upsert(.section.id? == $sid and .label == $f;
                            {type: $type, label: $f, value: $v, section: {id: $sid, label: $sec}})
               end)
        | if $item[0] != null and . == $item[0] then "same" else . end'
}

# THE ITEM'S OWN URL LIST, which is what autofill matches on. A section field
# typed URL is a clickable link and nothing more; only .urls associates the
# entry with a site.
#
# Replaces the list rather than merging it: a link that stops being true has to
# be able to leave. The first line is the primary, the one 1Password opens.
#
# stdin: the item JSON. $1: `label<TAB>href` lines. Prints the new item, or
# "same" when the list already reads like that.
_entry_urls() {
    jq -c --rawfile lines <(printf '%s' "$1") '
        . as $was
        | .urls = [ $lines | split("\n")[] | select(. != "") | split("\t")
                    | {label: .[0], href: (.[1:] | join("\t"))} ]
        | .urls = [ .urls[] | select(.href != "") ]
        | (if (.urls | length) > 0 then .urls[0].primary = true else . end)
        | if . == $was then "same" else . end'
}

# --- op ------------------------------------------------------------------------

# Encrypted to this host. A plain file is still read: a first clone on a
# machine without systemd-creds writes one.
_op_token_file_read() {  # <file> <credential name>
    local t
    t="$(systemd-creds decrypt --name="$2" "$1" - 2>/dev/null)" \
        || t="$(grep -m1 -E '^(ops_|eyJ)' "$1" 2>/dev/null)" || return 2
    printf '%s' "$t" | tr -d '[:space:]'
}

# `op` with the token in its environment only. stdin and stdout pass through.
_op() {
    local token
    token="$(_op_token_file_read "$_OP_TOKEN_FILE" op-token)" || return 2
    [ -n "$token" ] || return 2
    # 9>&-: every lock here is fd 9, and op's background daemon inherited it
    # and held /run/person-entry.lock for good. 2026-09-25.
    OP_SERVICE_ACCOUNT_TOKEN="$token" timeout "${SECRET_TIMEOUT:-30}" op "$@" 9>&-
}

# `op` says an item is missing in this sentence. Anything else is "could not
# tell": a network fault must never read as "the vault is empty", or a setup
# restore would start a fresh drive with no logins and call it success.
_op_is_absent() { case "$1" in *"isn't an item in the"*) return 0 ;; esac; return 1; }

# The stored item as JSON. 0 found, 1 absent, 2 could not tell.
_op_item() {
    local out
    if out="$(_op item get "$1" --vault "$(_op_vault_for "$1")" --format json 2>&1)"; then
        printf '%s' "$out"; return 0
    fi
    _op_is_absent "$out" && return 1
    printf '%s\n' "$out" >&2
    return 2
}

# stdin: the item. $2 non-empty means it exists and is edited, not created.
_op_write() {
    if [ -n "$2" ]; then _op item edit "$1" --vault "$(_op_vault_for "$1")" >/dev/null
    else _op item create --vault "$(_op_vault_for "$1")" >/dev/null; fi
}

_op_delete() {
    local out
    out="$(_op item delete "$1" --vault "$(_op_vault_for "$1")" 2>&1)" && return 0
    _op_is_absent "$out" && return 0
    printf '%s\n' "$out" >&2
    return 2
}

# --- verbs ---------------------------------------------------------------------

secret_file_get() {
    local item rc
    item="$(_op_item "$(_file_title "$1")")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$item" | _file_content
}

secret_file_put() {
    local title item rc
    title="$(_file_title "$1")"
    item="$(_op_item "$title")"; rc=$?
    [ "$rc" -eq 2 ] && return 2
    _file_item "$1" "$item" | _op_write "$title" "$item"
}

secret_file_delete() { _op_delete "$(_file_title "$1")"; }

# A person's entry is a Login item. Not a Document: `op item share` refuses
# those. The item JSON goes through pipes only, because it holds every password
# in the entry and argv is visible in `ps`.
#
# One write per section: 1Password answers 409 Conflict to an edit that follows
# a create too closely, so a conflict is read again and retried.
secret_entry_set() {
    local name="$1" section="$2" fields item new out rc try
    fields="$(cat)"
    for try in 1 2 3 4; do
        item="$(_op_item "$name")"; rc=$?
        [ "$rc" -eq 2 ] && return 2
        new="$(_entry_merge "$name" "$section" "$item" "$fields" "${SECRET_ENTRY_REPLACE:-}")" || return 2
        [ "$new" = '"same"' ] && return 0
        out="$(printf '%s' "$new" | _op_write "$name" "$item" 2>&1)" && return 0
        case "$out" in *"(409)"*) sleep 2 ;; *) break ;; esac
    done
    printf '%s\n' "$out" >&2
    return 2
}

# Retried on 409 for the same reason secret_entry_set is.
secret_entry_urls() {
    local name="$1" lines item new out rc try
    lines="$(cat)"
    for try in 1 2 3 4; do
        item="$(_op_item "$name")"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        new="$(printf '%s' "$item" | _entry_urls "$lines")" || return 2
        [ "$new" = '"same"' ] && return 0
        out="$(printf '%s' "$new" | _op_write "$name" "$item" 2>&1)" && return 0
        case "$out" in *"(409)"*) sleep 2 ;; *) break ;; esac
    done
    printf '%s\n' "$out" >&2
    return 2
}

# The link on stdout. `op` sends nothing: whoever calls this mails it.
secret_entry_share() {
    local name="$1" email="$2" out
    out="$(_op item share "$name" --vault "$(_op_vault_for "$name")" --emails "$email" --expires-in "${SECRET_SHARE_EXPIRES:-7d}" 2>&1)" \
        || { printf '%s\n' "$out" >&2; _op_is_absent "$out" && return 1; return 2; }
    printf '%s\n' "$out" | grep -m1 -o 'https://[^[:space:]]*' || { printf '%s\n' "$out" >&2; return 2; }
}


# READING BACK, so drift between the vault and the machine can be SEEN. The
# machine keeps hashes and the vault keeps plaintext, so the two can only be
# compared by fetching the stored value and testing it against the hash. Added
# 2026-09-20 for report_drift.sh's vault check.
#
# THE VALUES ARE PLAINTEXT. A caller pipes them; it never puts one in argv,
# where `ps` shows it, and never prints one.
#
# stdin: the item JSON. $1: a section label, or empty for every field.
#   $1 empty  ->  section<TAB>label<TAB>value, top-level fields with no section
#   $1 given  ->  label<TAB>value, that section only
# `--urls` in place of a section name lists the item's URL list instead:
# `label<TAB>href`. A URL is not a secret, which is why it is the one thing
# this prints in full.
_entry_read() {
    jq -r --arg sec "$1" '
        if $sec == "--urls" then (.urls[]? | [(.label // ""), (.href // "")] | @tsv)
        else
        ("s_" + ($sec | ascii_downcase | gsub("[^a-z0-9]+"; "_"))) as $sid
        | (.sections // []) as $secs
        | .fields[]?
        | . as $f
        | select($sec == "" or ($f.section.id // "") == $sid)
        | (($secs[] | select(.id == ($f.section.id // "")) | .label) // "") as $slabel
        | (if $sec == "" then [$slabel, ($f.label // $f.id // ""), ($f.value // "")]
           else [($f.label // $f.id // ""), ($f.value // "")] end)
        | @tsv
        end'
}

# 0 printed, 1 no such entry, 2 could not tell. An empty entry prints nothing
# and still returns 0: "nothing in it" and "no answer" are different facts.
secret_entry_get() {
    local item rc
    item="$(_op_item "$1")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$item" | _entry_read "${2:-}"
}

# The reverse of secret_entry_set for a whole section: its fields and the
# section itself go. Used when a mailbox moves to another person's entry, so
# the old owner stops holding a password that is no longer theirs.
#
# stdin: the item JSON. Prints the new item, or "same" when nothing matched.
_entry_drop() {
    # Several sections at once, one per line, in one write: for the same reason
    # _entry_relabel is one write.
    jq -c --arg sec "$1" '
        [$sec | split("\n")[] | select(. != "")
              | "s_" + (ascii_downcase | gsub("[^a-z0-9]+"; "_"))] as $sids
        | . as $was
        | .fields   = [.fields[]?   | select(((.section.id // "") as $i | $sids | index([$i])) | not)]
        | .sections = [.sections[]? | select((.id as $i | $sids | index([$i])) | not)]
        | if . == $was then "same" else . end'
}

# Sections renamed, their fields with them, all in ONE write: renaming one at a
# time re-reads through Connect's lag and undoes the one before. Sections end
# in label order, which is how 1Password shows them. stdin: the item JSON; $1:
# `old<TAB>new` lines. Prints the new item, or "same" when nothing matched.
_entry_relabel() {
    jq -c --rawfile pairs <(printf '%s' "$1") '
        def sid(l): "s_" + (l | ascii_downcase | gsub("[^a-z0-9]+"; "_"));
        . as $was
        | reduce ($pairs | split("\n")[] | select(. != "") | split("\t")) as $p (.;
            sid($p[0]) as $o | sid($p[1]) as $n
            | if any(.sections[]?; .id == $o) | not then . else
                .fields = [.fields[]? | if (.section.id // "") == $o
                                        then .section = {id: $n, label: $p[1]} else . end]
                | .sections = [.sections[]? | if .id == $o then {id: $n, label: $p[1]} else . end]
              end)
        | .sections = ((.sections // []) | unique_by(.id) | sort_by(.label))
        | if . == $was then "same" else . end'
}

# 0 renamed or nothing to rename, 1 no such entry, 2 could not tell.
# stdin: `old<TAB>new` lines.
secret_entry_relabel() {
    local item new rc try out="" pairs
    pairs="$(cat)"
    for try in 1 2 3 4; do
        item="$(_op_item "$1")"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        new="$(printf '%s' "$item" | _entry_relabel "$pairs")" || return 2
        [ "$new" = '"same"' ] && return 0
        out="$(printf '%s' "$new" | _op_write "$1" "$item" 2>&1)" && return 0
        case "$out" in *"(409)"*) sleep 2 ;; *) break ;; esac
    done
    printf '%s\n' "$out" >&2
    return 2
}

# 0 gone or never there, 1 no such entry, 2 could not tell. Retried on 409 for
# the same reason secret_entry_set is: an edit too soon after a write conflicts.
secret_entry_unset() {
    local item new rc try out=""
    for try in 1 2 3 4; do
        item="$(_op_item "$1")"; rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        new="$(printf '%s' "$item" | _entry_drop "$2")" || return 2
        [ "$new" = '"same"' ] && return 0
        out="$(printf '%s' "$new" | _op_write "$1" "$item" 2>&1)" && return 0
        case "$out" in *"(409)"*) sleep 2 ;; *) break ;; esac
    done
    printf '%s\n' "$out" >&2
    return 2
}
secret_entry_delete() { _op_delete "$1"; }

# Every title in the vault the given title would go to, one per line.
# 0 listed (maybe nothing), 2 could not tell.
secret_entry_titles() {  # <a title of the kind wanted>
    local out
    out="$(_op item list --vault "$(_op_vault_for "$1")" --format json 2>&1)" \
        || { printf '%s\n' "$out" >&2; return 2; }
    printf '%s' "$out" | jq -r '.[].title'
}

secret_preflight() { _op_preflight; }

# The Connect file calls this too: sharing needs the service account there.
_op_preflight() {
    local bad=0
    command -v op >/dev/null 2>&1 \
        || { echo "op is not installed. Run: sudo bash add_1password.sh"; bad=1; }
    [ -n "$_OP_VAULT" ] \
        || { echo "No OP_VAULT in ${SITES_CONF:-hostings.conf}."; bad=1; }
    [ -r "$_OP_TOKEN_FILE" ] \
        || { echo "Cannot read the token at $_OP_TOKEN_FILE. It is root-only: run as root."; bad=1; }
    [ "$bad" = 0 ] || return 1
    local v
    while IFS= read -r v; do
        _op vault get "$v" >/dev/null 2>&1 \
            || { echo "The token does not open vault '$v'. Test it: sudo bash add_1password.sh --test-only"; return 1; }
    done < <(_op_vaults)
}
