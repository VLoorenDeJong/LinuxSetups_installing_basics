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
# Keep the DNS records for every hostname in hostings.conf in step with the
# config, using the registrar's API.
#
# ONE RECORD HOLDS THE ADDRESS. EVERYTHING ELSE POINTS AT IT.
#
# Every hostname on this machine resolves to the same address, so repeating that
# address in every record buys nothing and costs a great deal: a connection with
# a changing address means every one of them has to be rewritten at once, and a
# run that fails halfway leaves some names working and some not.
#
#   <domain>            A/AAAA   <the address>     not managed here
#   anything.<domain>   CNAME    <domain>            managed here
#
# The apex of a domain is deliberately left alone. Whatever detects an address
# change owns it, this script owns the names, and the two therefore cannot
# overwrite each other. An address change becomes one write per domain instead of
# one per hostname. A CNAME is illegal at an apex in any case.
#
# ONE LIST SAYS WHICH DOMAINS ARE OURS
#
# DNS_DOMAINS in the config names them, and this script manages every hostname
# under any of them. It is a list rather than something worked out from the
# hostnames, because a typo would otherwise invent a domain and aim writes at a
# domain that is not yours.
#
# EVERY OTHER RECORD IS SOMEBODY ELSE'S
#
# Only a CNAME pointing at its own apex is treated as managed. Mail lives
# on record types this script never writes, and TransIP's DKIM entries are
# CNAMEs pointing elsewhere, so both are reported and left exactly as they are.
# Mail is not managed here and is not meant to be.
#
# WHY THE CREDENTIAL IS HANDLED THE WAY IT IS
#
# This registrar's API key cannot be scoped. It is read-only across the whole
# account, or it can do everything including transferring a domain away. A DNS
# updater must write, so it needs the second.
#
# Restricting the key to a source address does not help either: the tool runs
# because the address changed, so a whitelist still holds the old one and
# rejects the only call that matters.
#
# So the protection is where the key lives:
#
#   - the plaintext key exists only long enough to be encrypted, then is removed
#   - systemd-creds encrypts it to a blob that decrypts on this host and nowhere
#     else, so a copy in a backup, on a share, or committed by accident is
#     worthless to anyone
#   - the file it is read from is created here with mode 0600 BEFORE it holds
#     anything, so the key is never briefly world readable
#
# The CI user must never be able to read the blob. It runs code out of a
# repository on this same machine, and a credential it can read turns a pull
# request into a domain transfer.
#
# Usage:
#   sudo ./add_dns_records.sh              report the difference, then apply it
#   sudo ./add_dns_records.sh --check      report only, change nothing
#   sudo ./add_dns_records.sh --setup-key  install or replace the API key
#
# Environment:
#   SITES_CONF     override the config location
#   DNS_KEY_FILE   read the key from here instead of prompting for it
# =============================================================================

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

MODE="apply"

# --only exists because the zones differ in blast radius. example.com is this
# machine's own, while example.net is a customer served elsewhere: a
# write there can take their site off the air. Naming the zone is how one
# hostname gets added without touching the others.
ONLY_DOMAIN=""

# --prune-dns deletes the orphans instead of only reporting them. OFF by
# default and it stays off: a name still in DNS may be one somebody is relying
# on, and removing it is not something a config change should decide on its own.
#
# What it can reach is already narrow, and that is the guard rather than a new
# test: the orphan list holds ONLY CNAMEs whose content is the domain's own
# apex. The apex A/AAAA records, MX, SPF, DMARC, every _domainkey and every
# CNAME pointing anywhere else are not in it and cannot be.
PRUNE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check)     MODE="check" ;;
        --prune-dns) PRUNE=1 ;;
        --setup-key) MODE="setupkey" ;;
        --only)
            shift
            ONLY_DOMAIN="${1:-}"
            if [ -z "$ONLY_DOMAIN" ]; then
                print_error "--only needs a domain, for example --only example.com"
                exit 1
            fi
            ;;
        "")          ;;
        *)
            print_error "Unknown argument: $1"
            print_action "Use --check, --only <domain>, --prune-dns, --setup-key, or no argument at all."
            exit 1
            ;;
    esac
    shift
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 $*"
    exit 1
fi

# -----------------------------------------------------------------------------
# The real invoking user. Never assume $HOME under sudo: it is root's.
#
# NOT APP_RUN_USER. That key pins the account units run as; this wants whoever
# owns the machine, because the key file is dropped in their home over SFTP.
# -----------------------------------------------------------------------------
if [ -n "$APP_USER" ]; then
    RUN_USER="$APP_USER"
elif [ -f /etc/manageserver-installer-user ]; then
    RUN_USER="$(cat /etc/manageserver-installer-user)"
elif [ -n "$SUDO_USER" ]; then
    RUN_USER="$SUDO_USER"
else
    RUN_USER="$(logname 2>/dev/null || whoami)"
fi

if ! id "$RUN_USER" >/dev/null 2>&1; then
    print_error "Resolved run user '$RUN_USER' does not exist on this machine."
    print_action "Set it explicitly with: sudo env APP_USER=<name> $0"
    exit 1
fi
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    print_action "Override with: sudo env SITES_CONF=/path/to/hostings.conf $0"
    exit 1
fi

# -----------------------------------------------------------------------------
# Config readers. Duplicated verbatim rather than sourced, so this script stays
# runnable on its own on a machine that has only this file copied to it.
# -----------------------------------------------------------------------------
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

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"

# Every domain this script manages. Listed rather than worked out from the rows: a
# typo in a hostname would otherwise invent a domain and send writes at a domain
# that is not yours, and a list can be read against the control panel.
_domains_raw="$(conf_get DNS_DOMAINS "")"
DNS_DOMAINS=()
if [ -n "$_domains_raw" ]; then
    IFS=',' read -r -a _z <<< "$_domains_raw"
    for z in "${_z[@]}"; do
        z="$(trim "$z")"
        [ -n "$z" ] && DNS_DOMAINS+=("$z")
    done
fi

if [ -n "$ONLY_DOMAIN" ]; then
    _found=""
    for z in ${DNS_DOMAINS+"${DNS_DOMAINS[@]}"}; do
        [ "$z" = "$ONLY_DOMAIN" ] && _found="$z"
    done
    if [ -z "$_found" ]; then
        print_error "'$ONLY_DOMAIN' is not in DNS_DOMAINS, so this script does not manage it."
        exit 1
    fi
    DNS_DOMAINS=("$_found")
    print_status "Only $_found. Every other zone is left untouched."
fi

# DNS_API_URL is not read here any more: nothing in this file used it once
# dns_preflight took over the checking, and the provider reads its own.
# The account name and the credential paths below stay, because --setup-key
# still stores the key and that is provider setup by definition.
DNS_LOGIN="$(conf_get DNS_LOGIN "")"
DNS_TTL="$(conf_get DNS_TTL 300)"
CRED_DIR="$(conf_get DNS_CRED_DIR /etc/dns-api)"
CRED_FILE="$CRED_DIR/api.key.cred"
CRED_NAME="$(conf_get DNS_CRED_NAME dnsapi)"
LOGIN_FILE="$(conf_get DNS_LOGIN_FILE "$CRED_DIR/login")"

# The account name lives next to the key it belongs to, not in this committed
# config. The FILE WINS: it is what the setup prompt writes, so a stale name
# left in the config cannot quietly authenticate as something else. That
# happened, and it looked like a broken key: one script read the file and
# worked, this one read the config and got a 401.
if [ -f "$LOGIN_FILE" ]; then
    DNS_LOGIN="$(head -n1 "$LOGIN_FILE" | xargs)"
fi

if [ -z "$BASE_DOMAIN" ]; then
    print_error "No BASE_DOMAIN in $SITES_CONF"
    exit 1
fi

# Falling back to the base domain keeps a config without DNS_DOMAINS working
# exactly as it did before the list existed.
[ ${#DNS_DOMAINS[@]} -eq 0 ] && DNS_DOMAINS=("$BASE_DOMAIN")

for z in "${DNS_DOMAINS[@]}"; do
    case "$z" in
        *.*) ;;
        *)
            print_error "DNS_DOMAINS contains '$z', which is not a domain name."
            exit 1
            ;;
    esac
done

# A SCRIPT INSTALLED TO /usr/local/sbin HAS NO SIBLINGS, which is the fault of
# 2026-09-02 that made every sibling lookup fail silently. The interfaces live
# in the pipeline tree, so look there when they are not beside this file.
_iface() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

# WHAT THE PROVIDER NEEDS IS THE PROVIDER'S TO SAY. This refused on
# DNS_API_URL, which is a config key only some registrars want, and the advice
# under it named a TransIP script by hand. dns.sh is sourced here rather than
# further down, because dns_preflight has to answer before anything is checked.
#
# --setup-key is the exception and keeps its own checks where they are: storing
# a key is provider setup, this script's oldest job, and the key it stores is
# TransIP's by definition.
# shellcheck source=/dev/null
. "$(_iface dns.sh)"

if [ "$MODE" != "setupkey" ]; then
    if ! _dns_reasons="$(dns_preflight)"; then
        print_error "This machine cannot use its DNS provider yet:"
        while IFS= read -r _line; do
            [ -n "$_line" ] && print_action "  $_line"
        done <<< "$_dns_reasons"
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Writing is switched off until the API has been driven by hand.
#
# Nothing here has ever talked to a real registrar. Reading is safe and is how
# you find out what the domain actually contains, so --check and --setup-key stay
# available. Writing is not: a wrong assumption about how records are named
# would create a pile of them under names nobody meant, in a live domain.
#
# Turn it on in the config once a manual run has proved what the API does.
# -----------------------------------------------------------------------------
DNS_MANAGE="$(conf_get DNS_MANAGE no)"
case "$DNS_MANAGE" in
    y|Y|yes|YES|Yes|true|1) DNS_MANAGE="yes" ;;
    *)                      DNS_MANAGE="no"  ;;
esac

if [ "$MODE" = "apply" ] && [ "$DNS_MANAGE" != "yes" ]; then
    print_header "DNS records"
    print_info "DNS management is switched off, so nothing will be written."
    echo ""
    print_action "This has never run against a real registrar. Before switching it on,"
    print_action "look at what is actually in the domain:"
    echo ""
    print_action "  sudo $0 --check"
    echo ""
    print_action "That reads and reports, and writes nothing. When the report matches"
    print_action "what you expect, set this in $SITES_CONF:"
    echo ""
    print_action "  DNS_MANAGE = yes"
    exit 0
fi

for tool in openssl curl python3 systemd-creds; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print_error "$tool is not installed, and this script cannot work without it."
        print_action "Install it, then run this again."
        exit 1
    fi
done

# =============================================================================
# The key
# =============================================================================

# Read from the terminal rather than stdin. start_install.sh may have consumed
# or redirected its own stdin, and then leftover input silently answers this.
wait_for_enter() {
    if [ -r /dev/tty ]; then
        read -r _ < /dev/tty || true
    else
        print_action "No terminal available, so this cannot prompt. Use DNS_KEY_FILE=..."
        exit 1
    fi
}

key_instructions() {
    local target="$1"
    cat <<EOF

   There is no API key on this machine yet.


   STEP 1   Look in your password vault first.

            Search for the registrar's name. If the private key is already
            there, use that one. An existing key stays valid, so there is
            no need to create another.


   STEP 2   Only if it is not there, create a new one.

            a. Open the registrar's control panel, API section.
            b. Choose Key Pairs. NOT access tokens: those expire and
               cannot be automated.
            c. Add one, label it: $(hostname)
            d. Leave the IP whitelist off. This machine's address changes,
               which is the whole reason this script exists.
            e. The private key is shown ONCE. Copy it now, and save it in
               your password vault before going on.


   STEP 3   Put it in the file that is already waiting for you:

                $target

            It exists, it is empty, and only you can read it. Open it in
            your SFTP file browser, paste the key, save.


   STEP 4   Come back here and press Enter.


   Nothing has been changed yet. The file from step 3 is removed
   automatically once the key has been checked.

EOF
    printf "   [Enter] when the file is ready, Ctrl-C to stop.  "
}

# Everything that can be wrong with a pasted key, each with what to do about it.
validate_key_file() {
    local f="$1"

    if [ ! -f "$f" ]; then
        print_error "Not there yet: $f"
        print_action "Create the file and paste the key into it, then press Enter again."
        return 1
    fi
    if [ ! -s "$f" ]; then
        print_error "The file is still empty: $f"
        print_action "Paste the key and save, then press Enter again."
        return 1
    fi
    if ! grep -q -- "-----BEGIN" "$f" || ! grep -q -- "-----END" "$f"; then
        print_error "That does not look like a key: no BEGIN and END lines found."
        print_action "Copy the whole block, including the -----BEGIN and -----END lines."
        return 1
    fi

    # Windows line endings arrive with the file over SFTP, which copies bytes
    # without translating anything. openssl chokes on them, with an error that
    # says nothing about the cause.
    tr -d '\r' < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    chmod 600 "$f"

    if ! openssl pkey -in "$f" -noout >/dev/null 2>&1; then
        print_error "The key is incomplete or damaged: openssl cannot read it."
        print_action "Most often only part of it was pasted. Copy the whole block again."
        return 1
    fi
    return 0
}

setup_key() {
    local target="${DNS_KEY_FILE:-$RUN_HOME/dns-api.key}"

    print_header "API key"

    if [ -z "$DNS_LOGIN" ]; then
        print_error "No account name at $LOGIN_FILE, and no DNS_LOGIN in $SITES_CONF"
        print_action "Store it with: sudo bash add_transip_key.sh"
        exit 1
    fi

    mkdir -p "$CRED_DIR"
    chmod 700 "$CRED_DIR"

    if [ -z "${DNS_KEY_FILE:-}" ]; then
        # Created here, empty, with the right mode BEFORE it holds anything.
        # A file made by the SFTP client lands at the default umask, which is
        # world readable, and the key would sit exposed until this script ran.
        if [ ! -f "$target" ]; then
            install -o "$RUN_USER" -g "$RUN_USER" -m 600 /dev/null "$target"
        else
            chown "$RUN_USER:$RUN_USER" "$target"
            chmod 600 "$target"
        fi

        while true; do
            key_instructions "$target"
            wait_for_enter
            echo ""
            validate_key_file "$target" && break
            echo ""
        done
    else
        validate_key_file "$target" || exit 1
    fi

    # Encrypt from a pipe. Never as an argument, which would put the key in ps
    # and in the shell history of anyone watching.
    if ! systemd-creds encrypt --name="$CRED_NAME" "$target" "$CRED_FILE" 2>/dev/null; then
        print_error "systemd-creds could not encrypt the key."
        print_action "Check that systemd is 250 or newer: systemctl --version"
        exit 1
    fi
    chmod 600 "$CRED_FILE"
    chown root:root "$CRED_FILE"

    shred -u "$target" 2>/dev/null || rm -f "$target"

    print_success "Key encrypted to $CRED_FILE"
    print_status "The plaintext key has been removed from this machine."
    print_status "It decrypts on this host only, so a copy elsewhere is useless."
}

read_key() {
    if [ ! -f "$CRED_FILE" ]; then
        return 1
    fi
    systemd-creds decrypt --name="$CRED_NAME" "$CRED_FILE" - 2>/dev/null
}

# =============================================================================
# Talking to the API: it does not. dns.sh does.
#
# This script carried its own key reader, its own signature and its own curl,
# which is six copies of that code across the fleet and six places to leak a
# key. Principle 2b: an outside service is the exception to every script
# carrying its own helpers.
#
# It still keeps read_key and the --setup-key path, because storing the key is
# this script's job and always was.
# =============================================================================
# _iface and the dns.sh source both moved up to the pre-flight, where
# dns_preflight needs them.

# =============================================================================
# What the records should be
# =============================================================================

# The hostname list comes from the vhost generator rather than being worked out
# again here. Three scripts deriving hostnames three times is three chances to
# disagree, and a name with a vhost but no DNS record is invisible until someone
# tries to visit it.
print_header "DNS records"
print_status "Config:      $SITES_CONF"
print_status "Domains:     ${DNS_DOMAINS[*]}"
print_status "Mode:        $MODE"

if [ "$MODE" = "setupkey" ]; then
    setup_key
    exit 0
fi

if [ ! -f "$CRED_FILE" ]; then
    print_action "No API key on this machine yet, so it has to be set up first."
    setup_key
fi

# One lister, however many generators there turn out to be. This script does
# not know that admin.<domain> comes from a second one, and that is the point:
# knowing cost a name with a vhost, a certificate, and no record at all.
HOST_SCRIPT="$SCRIPT_DIR/list_served_hostnames.sh"
if [ ! -f "$HOST_SCRIPT" ]; then
    print_error "Cannot find $HOST_SCRIPT, which is where the hostname list comes from."
    exit 1
fi

mapfile -t HOSTNAMES < <(SITES_CONF="$SITES_CONF" bash "$HOST_SCRIPT" --for dns 2>/dev/null)

if [ ${#HOSTNAMES[@]} -eq 0 ]; then
    print_error "The hostname lister returned no hostnames."
    print_action "Run it on its own to see why: bash $HOST_SCRIPT --for dns"
    exit 1
fi

# Every hostname is placed in the domain it belongs to. The longest match wins, so
# a domain listed inside another one still gets its own names.
declare -A DOMAIN_LABELS=()   # domain -> newline separated labels
NOT_OURS=()                 # hostnames under no listed domain

for host in "${HOSTNAMES[@]}"; do
    host="$(trim "$host")"
    [ -z "$host" ] && continue

    matched=""
    for z in "${DNS_DOMAINS[@]}"; do
        case "$host" in
            "$z"|*".$z")
                [ ${#z} -gt ${#matched} ] && matched="$z"
                ;;
        esac
    done

    if [ -z "$matched" ]; then
        NOT_OURS+=("$host")
        continue
    fi

    # The apex of any domain carries the address, and the address detector owns
    # it. A CNAME is illegal there in any case.
    [ "$host" = "$matched" ] && continue

    DOMAIN_LABELS["$matched"]+="${host%".$matched"}"$'\n'
done


in_list() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
    return 1
}

# Read every domain before reporting, and report every domain before writing to any
# of them. A run that started writing to the first domain while the second was
# still unread could not be judged as a whole, which is the point of a report.
declare -A DOMAIN_ADD=()
declare -A DOMAIN_ORPHAN=()
TOTAL_ADD=0
TOTAL_ORPHAN=0
TOTAL_UNCHANGED=0

echo ""
print_header "What would change"

for domain in "${DNS_DOMAINS[@]}"; do
    # dns_records, not dns_list. The normalised four fields
    # name<TAB>type<TAB>content<TAB>ttl are the shape dns.sh promises; dns_list
    # hands back whatever the provider's API returned, and this script used to
    # dig `.dnsEntries[]` out of it three separate times, which is TransIP's
    # own JSON in a caller that is not supposed to know who TransIP is.
    current_tsv="$(dns_records "$domain")" || {
        print_error "Could not read the current records for $domain."
        print_action "Check that the domain sits in this account, and that DNS_DOMAINS has no typo."
        exit 1
    }

    # A CNAME pointing at the domain's own apex is one this script manages.
    # Anything else, mail included, is somebody's deliberate decision and is
    # reported rather than touched.
    #
    # "@" is the apex written the short way, and TransIP uses it. Reading it as
    # a foreign target made an existing www look unmanaged, so the script tried
    # to add a second one and the API answered 406.
    # A trailing dot is how a zone writes a fully qualified name and "@" is the
    # apex written short, so both read as this domain's own apex.
    mapfile -t cur_managed < <(printf '%s\n' "$current_tsv" | awk -F'\t' -v apex="$domain" '
        $2 == "CNAME" { c = $3; sub(/\.$/, "", c); if (c == apex || c == "@") print $1 }')

    mapfile -t cur_foreign < <(printf '%s\n' "$current_tsv" | awk -F'\t' -v apex="$domain" '
        $2 == "CNAME" { c = $3; sub(/\.$/, "", c); if (c != apex && c != "@") print $1 " -> " $3 }')

    mapfile -t want < <(printf '%s' "${DOMAIN_LABELS[$domain]:-}" | sed '/^$/d' | sort -u)

    to_add=()
    unchanged=0
    orphaned=()

    for label in ${want+"${want[@]}"}; do
        if in_list "$label" ${cur_managed+"${cur_managed[@]}"}; then
            unchanged=$((unchanged + 1))
        else
            to_add+=("$label")
        fi
    done

    for label in ${cur_managed+"${cur_managed[@]}"}; do
        in_list "$label" ${want+"${want[@]}"} || orphaned+=("$label")
    done

    echo ""
    print_status "$domain"

    for l in ${to_add+"${to_add[@]}"}; do
        print_status "  add       $l.$domain  CNAME  $domain"
    done
    for l in ${orphaned+"${orphaned[@]}"}; do
        print_info "  orphaned  $l.$domain  points here but has no row in the config"
    done
    [ "$unchanged" -gt 0 ] && print_success "  unchanged $unchanged record(s) already correct"
    [ ${#to_add[@]} -eq 0 ] && [ ${#orphaned[@]} -eq 0 ] && [ "$unchanged" -eq 0 ] && \
        print_info "  no hostname in the config belongs to this domain"

    if [ ${#cur_foreign[@]} -gt 0 ]; then
        print_info "  left alone, pointing somewhere other than $domain:"
        for e in "${cur_foreign[@]}"; do
            print_info "    $e"
        done
    fi

    DOMAIN_ADD["$domain"]="$(printf '%s\n' ${to_add+"${to_add[@]}"})"
    # The orphan's own four fields, as the API returned them. A delete is
    # matched on name, type, content AND expire together, so a rebuilt TTL
    # deletes nothing and the API says nothing about it.
    DOMAIN_ORPHAN["$domain"]="$(printf '%s\n' "$current_tsv" | awk -F'\t' \
        -v apex="$domain" -v want="${orphaned[*]:-}" '
        BEGIN { n = split(want, a, " "); for (i = 1; i <= n; i++) names[a[i]] = 1 }
        $2 != "CNAME" { next }
        { c = $3; sub(/\.$/, "", c) }
        c != apex && c != "@" { next }
        !($1 in names) { next }
        { print $1 "\t" $2 "\t" $3 "\t" ($4 == "" ? 300 : $4) }')"
    TOTAL_ADD=$((TOTAL_ADD + ${#to_add[@]}))
    TOTAL_ORPHAN=$((TOTAL_ORPHAN + ${#orphaned[@]}))
    TOTAL_UNCHANGED=$((TOTAL_UNCHANGED + unchanged))
done

if [ ${#NOT_OURS[@]} -gt 0 ]; then
    echo ""
    print_info "Not managed here, because they are under no domain in DNS_DOMAINS:"
    for h in "${NOT_OURS[@]}"; do
        print_action "  $h  add $(printf '%s' "$h" | awk -F. '{print $(NF-1)"."$NF}') to DNS_DOMAINS to manage it"
    done
fi

echo ""
if [ "$TOTAL_ADD" -eq 0 ] && [ "$TOTAL_ORPHAN" -eq 0 ]; then
    print_success "Nothing to do. DNS already matches the config in all ${#DNS_DOMAINS[@]} domain(s)."
    exit 0
fi

if [ "$MODE" = "check" ]; then
    print_status "--check, so nothing was written."
    print_status "Run without --check to apply this."
    exit 0
fi

# =============================================================================
# Apply
# =============================================================================
echo ""
print_header "Applying"

for domain in "${DNS_DOMAINS[@]}"; do
    mapfile -t adds < <(printf '%s' "${DOMAIN_ADD[$domain]:-}" | sed '/^$/d')
    [ ${#adds[@]} -eq 0 ] && continue

    for label in "${adds[@]}"; do
        if dns_add "$domain" "$label" CNAME "$domain." "$DNS_TTL" >/dev/null; then
            print_success "added   $label.$domain"
        else
            print_error "Could not add $label.$domain"
            print_info "The records added before this one are already in place."
            print_action "Fix the cause and run this again: it only writes what is missing."
            exit 1
        fi
    done
done

# Orphans are reported and NOT deleted, unless --prune-dns says otherwise. A
# name still in DNS may be one somebody is relying on, and removing it is not
# something a config change should decide by itself.
#
# The delete goes through dns.sh like everything else here now. This block used
# to resolve DNS_PROVIDER itself, which was the resolution and the missing-file
# message about to be copied into seven scripts: the shape principle 2b exists
# to stop, one layer up.
if [ "$TOTAL_ORPHAN" -gt 0 ] && [ "$PRUNE" = "1" ]; then
    echo ""
    print_header "Removing orphaned records"
    pruned=0
    failed=0
    for domain in "${DNS_DOMAINS[@]}"; do
        while IFS=$'\t' read -r o_name o_type o_content o_ttl; do
            [ -n "$o_name" ] || continue
            if dns_delete "$domain" "$o_name" "$o_type" "$o_content" "$o_ttl"; then
                print_success "removed $o_name.$domain  $o_type  $o_content"
                pruned=$((pruned + 1))
            else
                print_error "Could not remove $o_name.$domain"
                failed=$((failed + 1))
            fi
        done <<< "${DOMAIN_ORPHAN[$domain]:-}"
    done
    print_status "$pruned removed, $failed refused."
    [ "$failed" -gt 0 ] && exit 1
elif [ "$TOTAL_ORPHAN" -gt 0 ]; then
    echo ""
    print_info "The orphaned records above were NOT removed."
    print_action "Remove them with: $0 --prune-dns${ONLY_DOMAIN:+ --only $ONLY_DOMAIN}"
    print_info "Only CNAMEs pointing at their own apex can ever be in that list."
fi

echo ""
print_success "DNS is in step with $SITES_CONF"
print_status "The apex record was not touched: whatever tracks the address owns it."
