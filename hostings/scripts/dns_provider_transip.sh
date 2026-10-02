#!/usr/bin/env bash
# =============================================================================
# The ONLY file that talks to TransIP. Everything else asks it in verbs.
#
# WHY THIS EXISTS, and it is not tidiness. The owner, 2026-09-11, recorded as
# principle 2b in .claude/docs/project-context.md: an outside service is the
# exception to "every script carries its own copy of the helpers".
#
# Copying print_status costs nothing. Copying the code that reads a private key
# and signs a request is different, and the difference is EXPOSURE: on
# 2026-09-11 SEVEN scripts each read the key and implemented the signature
# themselves. Seven places to leak it, seven to get the signing wrong, seven to
# fix when the provider changes anything.
#
#   add_dns_records.sh        add_mail_dns_records.sh    update_dns_apex.sh
#   transip_dns_challenge.sh  check_domain_available.sh  fetch_domains.sh
#   add_transip_key.sh
#
# SWAPPING PROVIDER IS ONE CONFIG VALUE. `DNS_PROVIDER` in hostings.conf names
# the file; a caller resolves it and never writes an endpoint of its own. A
# second provider is a second file exposing the same verbs, and nothing else
# changes.
#
# SOURCED, NOT RUN. It defines functions and exits nothing.
#
#   . "$SCRIPT_DIR/dns_provider_transip.sh"
#   dns_auth                       buy a token, once per run
#   dns_domains                    every domain on the account, one per line
#   dns_list   <domain>            that zone's records, as JSON
#   dns_add    <domain> <name> <type> <content> [ttl]
#   dns_delete <domain> <name> <type> <content> [ttl]
#
# Every verb returns non-zero on failure and says why on stderr. None of them
# exits: a caller decides whether a failed record is fatal to its own run.
#
# THE KEY IS READ HERE AND NOWHERE ELSE. It is decrypted to a private temporary
# file with mode 600, used, and shredded in the same function. It is never an
# argument, never in an environment variable, and never printed: a key on a
# command line is a key in `ps` and in somebody's scrollback.
#
# A TOKEN LIVES HALF AN HOUR AND IS NEVER WRITTEN TO DISK. It exists for the
# length of the calling process.
#
# Self-check: `bash dns_provider_transip.sh --check` proves a token can be
# minted, which is the only question worth asking of a credential. A key that
# is present on disk and refused by the API looks identical to a good one until
# something tries to use it.
# =============================================================================

# --- Inline utility functions, copied per principle 2 ------------------------
# These are ordinary helpers, so they are copied rather than shared. Only the
# provider itself is centralised. A caller that already defines them keeps its
# own: this file must not overwrite a caller's colours.
if ! declare -F print_status >/dev/null 2>&1; then
    print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1" >&2; }
    print_success() { printf "\033[32m✅ %s\033[0m\n" "$1" >&2; }
    # Yellow means "this needs you", never "warning".
    print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
    print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
    print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
fi

DNS_PROVIDER_NAME="transip"

_dns_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_dns_repo="$(cd "$_dns_dir/../.." && pwd)"
declare -F conf_active >/dev/null \
    || . "$_dns_dir/config.sh" 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
DNS_SITES_CONF="${SITES_CONF:-$(conf_active "$_dns_repo/backup_config")}"
[ -f "$DNS_SITES_CONF" ] || DNS_SITES_CONF="$(conf_active /etc/hostings)"

# A caller usually has conf_get already. Define one only if it does not, and
# read the same file either way.
if ! declare -F conf_get >/dev/null 2>&1; then
    conf_get() {
        local key="$1" default="${2:-}" value
        [ -f "$DNS_SITES_CONF" ] || { echo "$default"; return; }
        # tr -d '\r' first: a value is the last thing on its line, so a CRLF
        # file leaves the carriage return inside it.
        value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$DNS_SITES_CONF" 2>/dev/null \
                 | tr -d '\r' | tail -1 | cut -d= -f2- | sed 's/#.*//' | xargs)"
        [ -z "$value" ] && value="$default"
        echo "$value"
    }
fi

DNS_API_URL="$(conf_get DNS_API_URL "https://api.transip.nl/v6")"
DNS_LOGIN="$(conf_get DNS_LOGIN "")"
DNS_CRED_DIR="$(conf_get DNS_CRED_DIR /etc/transip)"
DNS_CRED_FILE="$DNS_CRED_DIR/api.key.cred"
DNS_CRED_NAME="$(conf_get DNS_CRED_NAME dnsapi)"
DNS_LOGIN_FILE="$DNS_CRED_DIR/login"

# The login may live beside the key rather than in the config, which is how
# add_transip_key.sh leaves it.
if [ -z "$DNS_LOGIN" ] && [ -f "$DNS_LOGIN_FILE" ]; then
    DNS_LOGIN="$(head -n1 "$DNS_LOGIN_FILE" | tr -d '\r' | xargs)"
fi

DNS_TOKEN=""

# -----------------------------------------------------------------------------
# The key. Decrypted here, used here, shredded here.
# -----------------------------------------------------------------------------
_dns_read_key() {
    [ -f "$DNS_CRED_FILE" ] || return 1
    systemd-creds decrypt --name="$DNS_CRED_NAME" "$DNS_CRED_FILE" - 2>/dev/null
}

# -----------------------------------------------------------------------------
# dns_auth: buy a token. Call once per run; the verbs below call it themselves
# if it has not been called, so a caller cannot forget.
# -----------------------------------------------------------------------------
dns_auth() {
    [ -n "$DNS_TOKEN" ] && return 0

    if [ -z "$DNS_LOGIN" ]; then
        print_error "No DNS_LOGIN, so there is no account to authenticate as."
        print_action "Set DNS_LOGIN in $DNS_SITES_CONF, or write it to $DNS_LOGIN_FILE."
        return 1
    fi

    local key body sig resp
    key="$(mktemp)"
    chmod 600 "$key"
    if ! _dns_read_key > "$key"; then
        shred -u "$key" 2>/dev/null || rm -f "$key"
        print_error "No usable API key on this machine ($DNS_CRED_FILE)."
        print_action "Run: sudo bash $_dns_dir/add_dns_records.sh --setup-key"
        return 1
    fi

    # READ-ONLY IS A CAPABILITY THE CALLER ASKS FOR, and it is not decoration.
    # fetch_domains.sh runs from a path a WEB PAGE can trigger, so the
    # credential it holds is deliberately incapable of writing: a token that
    # cannot alter a record cannot be made to alter one. Moving that caller onto
    # this file without carrying the capability across would have swapped an
    # incapable token for a writable one on exactly the path that needs it least.
    #
    # Short-lived for the same reason. A caller asking for read-only gets five
    # minutes unless it says otherwise; a writer gets thirty.
    body="$(python3 - "$DNS_LOGIN" "$(hostname)" "${DNS_READ_ONLY:-0}" "${DNS_TOKEN_MINUTES:-}" <<'PY'
import json, sys, uuid
read_only = sys.argv[3] == "1"
minutes = sys.argv[4] or ("5" if read_only else "30")
print(json.dumps({
    "login": sys.argv[1],
    "nonce": uuid.uuid4().hex,
    "read_only": read_only,
    "expiration_time": minutes + " minutes",
    "label": "dns-provider " + sys.argv[2] + " " + uuid.uuid4().hex[:8],
    "global_key": True,
}, separators=(",", ":")))
PY
)"

    sig="$(printf '%s' "$body" | openssl dgst -sha512 -sign "$key" | openssl base64 -A)"
    shred -u "$key" 2>/dev/null || rm -f "$key"

    resp="$(curl -fsS --max-time "${DNS_TIMEOUT:-30}" -X POST "$DNS_API_URL/auth" \
        -H "Content-Type: application/json" \
        -H "Signature: $sig" \
        -d "$body" 2>&1)" || {
        print_error "The API refused the login."
        print_action "Most likely causes, in order: the key was replaced in the"
        print_action "control panel, DNS_LOGIN does not match the account, or the"
        print_action "key has an IP whitelist while this machine's address changed."
        print_action "Response: $resp"
        return 1
    }

    DNS_TOKEN="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')"
    if [ -z "$DNS_TOKEN" ]; then
        print_error "The API returned no token."
        print_action "Response: $resp"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# The one place a URL is built. Callers name verbs, never endpoints.
# -----------------------------------------------------------------------------
# EVERY CALL IS BOUNDED. check_domain_available.sh runs behind a browser drawer
# and bounded itself at ten seconds, because a lookup that hangs hangs the
# drawer waiting for it. An unbounded interface would have taken that away, so
# DNS_TIMEOUT is a capability the caller sets rather than a number in here.
_dns_api() {
    local method="$1" path="$2" data="${3:-}"
    dns_auth || return 1
    if [ -n "$data" ]; then
        curl -fsS --max-time "${DNS_TIMEOUT:-30}" -X "$method" "$DNS_API_URL$path" \
            -H "Authorization: Bearer $DNS_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -fsS --max-time "${DNS_TIMEOUT:-30}" -X "$method" "$DNS_API_URL$path" \
            -H "Authorization: Bearer $DNS_TOKEN"
    fi
}

# IS THIS NAME STILL FREE TO REGISTER. A registrar question rather than a zone
# one, and it lives here for the same reason everything else does: it is the
# provider's API, and a caller asking it directly would be a seventh copy of
# the key handling.
#
# Prints "<verdict><TAB><the provider's own word>". The verdict is one of free,
# taken or unknown, which is all a caller should reason about; the second field
# is kept because the operator wants TransIP's actual answer, and a status this
# file does not recognise is reported as itself rather than guessed at.
#
# It never fails the caller: somebody asking for a domain deserves an honest
# "could not check" rather than an error.
dns_domain_available() {
    local domain="${1:-}" resp status why
    [ -n "$domain" ] || { printf 'unknown\tnot a domain name'; return 0; }
    resp="$(_dns_api GET "/domain-availability/$domain" 2>/dev/null)" \
        || { printf 'unknown\tcould not reach the provider'; return 0; }
    status="$(printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("availability",{}).get("status","") or "")' 2>/dev/null)"
    if [ -z "$status" ]; then
        why="$(printf '%s' "$resp" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("error","") or "")[:120])' 2>/dev/null)"
        printf 'unknown\t%s' "${why:-no answer from the provider}"
        return 0
    fi
    case "$status" in
        free) printf 'free\t' ;;
        notfree|inyouraccount|internalpull|internalpush) printf 'taken\t%s' "$status" ;;
        *)    printf 'unknown\t%s' "$status" ;;
    esac
}

# One record, as the JSON body the API wants. Built by python3 rather than by
# printf, so a content field holding a quote cannot break the request. SPF and
# DMARC values are full of them.
_dns_record_json() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
print(json.dumps({"dnsEntry": {
    "name": sys.argv[1],
    "expire": int(sys.argv[4]),
    "type": sys.argv[2],
    "content": sys.argv[3],
}}, separators=(",", ":")))
PY
}

# -----------------------------------------------------------------------------
# The verbs.
# -----------------------------------------------------------------------------

# Every domain on the account, one per line.
dns_domains() {
    _dns_api GET "/domains" \
        | python3 -c 'import json,sys; [print(d["name"]) for d in json.load(sys.stdin).get("domains",[])]'
}

# One zone's records, as the API returns them.
# WHAT THIS PROVIDER NEEDS, asked of the provider rather than guessed by the
# caller. One reason per line on stdout, exit 1 if there are any.
#
# It exists because six callers each carried three checks of their own for
# DNS_API_URL, the account name and the key file, plus a tool list. Those are
# TransIP's requirements, written into scripts that are not supposed to know
# whose they are, and they ran BEFORE dns.sh was sourced, so a provider needing
# none of them was refused before it could say so.
#
# The caller decides what to do with the lines. Some collect them into their own
# ERRORS array and print one block; some answer "unknown" and carry on.
# Where a person registers a domain. Needs no key, so a web page may ask.
# No %s: TransIP's order page cannot be prefilled, and appending the name is a 404.
dns_register_url() {
    printf '%s' 'https://www.transip.nl/bestel-domein/check/'
}

dns_preflight() {
    local bad=0 tool
    [ -n "$DNS_API_URL" ] || { printf 'No DNS_API_URL in %s\n' "${SITES_CONF:-the config}"; bad=1; }
    [ -n "$DNS_LOGIN" ]   || { printf 'No TransIP username at %s. Run: sudo bash add_transip_key.sh\n' "$DNS_LOGIN_FILE"; bad=1; }
    [ -f "$DNS_CRED_FILE" ] || { printf 'No API key at %s. Run: sudo bash add_transip_key.sh\n' "$DNS_CRED_FILE"; bad=1; }
    for tool in curl openssl jq systemd-creds python3; do
        command -v "$tool" >/dev/null 2>&1 || \
            { printf '%s is not installed. Run: sudo apt-get install -y %s\n' "$tool" "$tool"; bad=1; }
    done
    return "$bad"
}

dns_list() {
    local domain="${1:-}"
    [ -n "$domain" ] || { print_error "dns_list needs a domain."; return 1; }
    _dns_api GET "/domains/$domain/dns"
}

# NORMALISED, which dns_list is not: name<TAB>type<TAB>content<TAB>ttl, one per
# line. That is the shape dns.sh promises callers, so a second provider returns
# the same four fields whatever its own JSON looks like.
#
# dns_list stays beside it and stays raw, because add_dns_records.sh's prune
# path already reads TransIP's own field names.
dns_records() {
    local domain="${1:-}"
    [ -n "$domain" ] || { print_error "dns_records needs a domain."; return 1; }
    _dns_api GET "/domains/$domain/dns" | python3 -c '
import json, sys
for e in json.load(sys.stdin).get("dnsEntries", []):
    print("\t".join([e.get("name", ""), e.get("type", ""),
                     e.get("content", ""), str(e.get("expire", ""))]))
' 2>/dev/null
}

# EVERY POSITIONAL A VERB TAKES IS `${n:-}`, and the guard below it is the
# reason. Written as "$3" the assignment itself dies under `set -u` with
# `$3: unbound variable`, which every caller has on line 2, so the message
# written for exactly that mistake could never be reached. Found 2026-09-12 by
# calling the verbs short an argument while a second provider was being
# written, and it was identical in both files.
#
# The internal helpers above keep "$1": they are called only from this file,
# with literal arguments, and an empty key there should die loudly rather than
# read as a default.
dns_add() {
    local domain="${1:-}" name="${2:-}" type="${3:-}" content="${4:-}" ttl="${5:-300}"
    if [ -z "$domain" ] || [ -z "$name" ] || [ -z "$type" ] || [ -z "$content" ]; then
        print_error "dns_add needs domain, name, type and content."
        return 1
    fi
    _dns_api POST "/domains/$domain/dns" \
        "$(_dns_record_json "$name" "$type" "$content" "$ttl")" >/dev/null
}

# REPLACE the record of this name and type, rather than adding a second one.
# An apex A record is one value: adding another gives the zone two answers and
# round-robins visitors between a live machine and a dead one, which is why
# update_dns_apex.sh has always needed this as its own verb.
dns_update() {
    local domain="${1:-}" name="${2:-}" type="${3:-}" content="${4:-}" ttl="${5:-300}"
    if [ -z "$domain" ] || [ -z "$name" ] || [ -z "$type" ] || [ -z "$content" ]; then
        print_error "dns_update needs domain, name, type and content."
        return 1
    fi
    _dns_api PATCH "/domains/$domain/dns"         "$(_dns_record_json "$name" "$type" "$content" "$ttl")" >/dev/null
}

# DELETE carries the record in the BODY, not in the path: TransIP identifies a
# record by all four fields together, so a wrong TTL deletes nothing and says
# nothing. Pass the values dns_list returned, never values you rebuilt.
dns_delete() {
    local domain="${1:-}" name="${2:-}" type="${3:-}" content="${4:-}" ttl="${5:-300}"
    if [ -z "$domain" ] || [ -z "$name" ] || [ -z "$type" ] || [ -z "$content" ]; then
        print_error "dns_delete needs domain, name, type and content."
        return 1
    fi
    _dns_api DELETE "/domains/$domain/dns" \
        "$(_dns_record_json "$name" "$type" "$content" "$ttl")" >/dev/null
}

# -----------------------------------------------------------------------------
# --check: can a token be minted? Run directly, never when sourced.
# -----------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --check)
            print_status "Provider:  $DNS_PROVIDER_NAME"
            print_status "Endpoint:  $DNS_API_URL"
            print_status "Login:     ${DNS_LOGIN:-(none)}"
            print_status "Key:       $DNS_CRED_FILE"
            if dns_auth; then
                print_success "A token was minted, so the key works right now."
            else
                print_error "No token could be minted."
                exit 1
            fi
            ;;
        *)
            print_info "This file is sourced, not run. It defines dns_auth, dns_domains,"
            print_info "dns_list, dns_add and dns_delete."
            print_action "To test the credential: bash $0 --check"
            ;;
    esac
fi
