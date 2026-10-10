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
# Nextcloud with Euro-Office, as one Docker stack:
#
#   browser -> :PORT front (Caddy) -> /             nextcloud
#                                  -> /eurooffice/  eurooffice (the editor)
#   nextcloud -> db (Postgres), redis (file locking)
#
# ONE PORT FOR BOTH. The editor is served under the same address as Nextcloud,
# and Nextcloud is told it lives at /eurooffice/, so the browser loads it from
# whichever address it reached Nextcloud on: the LAN address, a VPN, or a
# public name that a reverse proxy on another machine serves.
#
# LAN ONLY BY ITSELF. Docker publishes the port past UFW, so the router not
# forwarding it is what keeps it off the internet. A public name is another
# machine's reverse proxy, named with --public-host and --trusted-proxy.
#
# SECRETS. The database password and the editor's JWT secret are generated
# once into DATA_DIR/secrets (0400 files) and handed to the containers as
# files, never as environment variables. The admin password comes
# from a secret store when a secret_ask.sh is found, otherwise it is asked.
#
# Usage:
#   add_nextcloud.sh
#   add_nextcloud.sh --public-host cloud.example.com --trusted-proxy 192.0.2.10
#   add_nextcloud.sh --no-office                     # Nextcloud alone
#   add_nextcloud.sh --update                        # pull newer images
#   add_nextcloud.sh --dump-at 01:30                 # nightly DB dump, default 02:30
#   add_nextcloud.sh --drop-folder /srv/cloudberry   # a host folder every user
#                     sees as /cloudberry; share it over Samba to drop files in
#
# Exit codes:
#   0  Nextcloud (and the editor) answer through the front port
#   1  something needed for the run is missing or failed
#   2  bad usage
# =============================================================================

export DEBIAN_FRONTEND=noninteractive
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_hint()    { printf "   %s\n" "$1"; }

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_TICK=0
spin_tick() {
    printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[SPIN_TICK % 10]}" "$1"
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Watch-only: an image pull killed halfway leaves a partial layer cache.
run_watched() {
    local message="$1"; shift
    if [ "$DEBUG_MODE" = "1" ]; then "$@"; return; fi
    local log; log="$(mktemp)"
    "$@" >"$log" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do spin_tick "$message"; done
    local rc=0
    wait "$pid" || rc=$?
    printf '\r\033[K'
    if [ "$rc" -ne 0 ]; then
        print_error "$message failed (exit $rc)"
        tail -n 20 "$log" >&2
        print_info "Full log: $log"
    else
        rm -f "$log"
    fi
    return $rc
}

# Docker prints no percentage without a terminal, but it names every layer, so
# the bar counts layers: half for downloading, half for unpacking.
pull_bar() {
    local log="$1" total have down unpacked pct filled bar
    [ -s "$log" ] || { echo ""; return; }
    total="$(grep -c ': Pulling fs layer' "$log" 2>/dev/null)"
    down="$(grep -c -E ': (Download complete|Already exists)' "$log" 2>/dev/null)"
    unpacked="$(grep -c -E ': (Pull complete|Already exists)' "$log" 2>/dev/null)"
    have="$(grep -c ": Already exists" "$log" 2>/dev/null)"
    total=$(( ${total:-0} + ${have:-0} ))
    [ "$total" -gt 0 ] || { echo ""; return; }
    pct=$(( (${down:-0} + ${unpacked:-0}) * 50 / total ))
    [ "$pct" -gt 100 ] && pct=100
    filled=$(( pct / 5 ))
    printf -v bar '%*s' "$filled" ''; bar="${bar// /#}"
    printf -v bar '%-20s' "$bar"; bar="${bar// /-}"
    echo " [${bar}] ${pct}%, layers downloaded ${down:-0}/${total}, unpacked ${unpacked:-0}/${total}"
}

# Watch-only like run_watched, with the layer bar on the spinner line.
run_pull() {
    local img="$1"
    if [ "$DEBUG_MODE" = "1" ]; then docker pull "$img"; return; fi
    local log; log="$(mktemp)"
    docker pull "$img" >"$log" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do spin_tick "Pulling $img$(pull_bar "$log")"; done
    local rc=0
    wait "$pid" || rc=$?
    printf '\r\033[K'
    if [ "$rc" -ne 0 ]; then
        print_error "Pulling $img failed (exit $rc)"
        tail -n 20 "$log" >&2
        print_info "Full log: $log"
    else
        rm -f "$log"
    fi
    return $rc
}

need_value() { [ -n "$2" ] || { print_error "$1 needs a value."; exit 2; }; }

read_secret() {
    local prompt="$1" out="" ch
    printf '%s' "$prompt" > /dev/tty
    while IFS= read -rsn1 ch < /dev/tty; do
        case "$ch" in
            ''|$'\n')       break ;;
            $'\177'|$'\b')  [ -n "$out" ] && { out="${out%?}"; printf '\b \b' > /dev/tty; } ;;
            *)              out="$out$ch"; printf '*' > /dev/tty ;;
        esac
    done
    printf '\n' > /dev/tty
    SECRET="$out"
}

# --- Arguments ---------------------------------------------------------------
DATA_DIR="/opt/nextcloud"
PORT="10005"
PUBLIC_HOST=""
TRUSTED_PROXY=""
OFFICE=1
UPDATE=0
DUMP_AT="02:30"
DROP_DIR=""
NC_IMAGE="nextcloud:34-apache"
EO_IMAGE="ghcr.io/euro-office/documentserver:latest"
DB_IMAGE="postgres:17-alpine"
REDIS_IMAGE="redis:7-alpine"
CADDY_IMAGE="caddy:2-alpine"
# Fixed, so Nextcloud can trust its own front proxy by address.
SUBNET="172.30.105.0/24"

while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir)      need_value "$1" "${2:-}"; DATA_DIR="$2"; shift 2 ;;
        --port)          need_value "$1" "${2:-}"; PORT="$2"; shift 2 ;;
        --public-host)   need_value "$1" "${2:-}"; PUBLIC_HOST="$2"; shift 2 ;;
        # May repeat: a proxy machine that will change address (a drive swap).
        --trusted-proxy) need_value "$1" "${2:-}"; TRUSTED_PROXY="${TRUSTED_PROXY:+$TRUSTED_PROXY }$2"; shift 2 ;;
        --no-office)     OFFICE=0; shift ;;
        --update)        UPDATE=1; shift ;;
        --dump-at)       need_value "$1" "${2:-}"; DUMP_AT="$2"; shift 2 ;;
        --drop-folder)   need_value "$1" "${2:-}"; DROP_DIR="${2%/}"; shift 2 ;;
        -h|--help)       sed -n '/^# Nextcloud with/,/^#   2  bad usage/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               print_error "Unknown argument: $1"; exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script needs root."
    print_action "Run it with: sudo bash $0 $*"
    exit 2
fi

print_header "Nextcloud"

occ() { docker exec -u www-data nextcloud php occ "$@"; }
is_up() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# --- Pre-flight --------------------------------------------------------------
ERRORS=()
if [ ! -f "$SCRIPT_DIR/check_docker.sh" ]; then
    ERRORS+=("check_docker.sh is missing from $SCRIPT_DIR")
elif ! bash "$SCRIPT_DIR/check_docker.sh"; then
    ERRORS+=("Docker is not usable, see above")
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    ERRORS+=("--port must be a number between 1024 and 65535, not '$PORT'")
elif ss -lnt 2>/dev/null | grep -qE "[:.]${PORT} " && ! is_up nextcloud-front; then
    ERRORS+=("Something else already listens on port $PORT. Find it: sudo ss -lntp | grep :$PORT")
fi
# Handed to www-data and the container, so one plain level under /srv only:
# /etc would be chowned.
if [ -n "$DROP_DIR" ] && [[ ! "$DROP_DIR" =~ ^/srv/[A-Za-z0-9_-]+$ ]]; then
    ERRORS+=("--drop-folder '$DROP_DIR' must be /srv/<name>, letters, digits, _ and - only")
elif [ -n "$DROP_DIR" ] && [ -e "$DROP_DIR" ] && [ "$(stat -c %u "$DROP_DIR")" != "33" ]; then
    ERRORS+=("--drop-folder $DROP_DIR already exists and is not www-data's; pick a new folder")
fi
for p in $TRUSTED_PROXY; do
    [[ "$p" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || ERRORS+=("--trusted-proxy '$p' is not an IPv4 address")
done
if [ -n "$PUBLIC_HOST" ] && [ -z "$TRUSTED_PROXY" ]; then
    ERRORS+=("--public-host needs --trusted-proxy: the address of the machine whose proxy serves it")
fi
command -v curl    >/dev/null 2>&1 || ERRORS+=("curl is missing: sudo apt-get install -y curl")
command -v openssl >/dev/null 2>&1 || ERRORS+=("openssl is missing: sudo apt-get install -y openssl")

case "$DATA_DIR" in
    /*) ;;
    *)  ERRORS+=("--data-dir must be an absolute path, got '$DATA_DIR'") ;;
esac
systemd-analyze calendar "$DUMP_AT" >/dev/null 2>&1 \
    || ERRORS+=("--dump-at '$DUMP_AT' is not a time systemd understands, for example 02:30")

MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
if [ "$OFFICE" -eq 1 ] && [ "${MEM_MB:-0}" -lt 3500 ]; then
    ERRORS+=("Euro-Office needs 4 GB of memory and this machine has ${MEM_MB} MB. Use --no-office")
fi

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[ -n "$LAN_IP" ] || ERRORS+=("No LAN address found, so Nextcloud cannot be told which name to trust")

# Optional. Without it the admin password is asked at the keyboard.
STORE=0
for cand in "${SECRET_ASK_SH:-}" "$SCRIPT_DIR/../hostings/scripts/secret_ask.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] || continue
    # shellcheck source=/dev/null
    . "$cand" 2>/dev/null || true
    [ "${SECRET_READY:-0}" = "1" ] && secret_preflight >/dev/null 2>&1 && STORE=1
    break
done

INSTALLED=0
is_up nextcloud && occ status --output=json 2>/dev/null | grep -q '"installed":true' && INSTALLED=1
# A restored drive: config says installed, the dump is the database.
RESTORED_CONF=0
grep -q "'installed' => true" "$DATA_DIR/html/config/config.php" 2>/dev/null \
    && [ -s "$DATA_DIR/dump/nextcloud.sql" ] && RESTORED_CONF=1
[ "$RESTORED_CONF" -eq 1 ] && INSTALLED=1
if [ "$INSTALLED" -eq 0 ] && [ "$STORE" -eq 0 ] && ! { true > /dev/tty; } 2>/dev/null; then
    ERRORS+=("No terminal to ask for the admin password, and Nextcloud is not installed yet")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

print_status "Front:     port ${PORT}, http://${LAN_IP}:${PORT}"
print_status "Public:    ${PUBLIC_HOST:-none}${PUBLIC_HOST:+, through the proxy on $TRUSTED_PROXY}"
print_status "Editor:    $([ "$OFFICE" -eq 1 ] && echo "Euro-Office at /eurooffice/" || echo "none (--no-office)")"
print_status "Data:      $DATA_DIR"
print_success "Pre-flight passed."

# --- Images ------------------------------------------------------------------
IMAGES=("$NC_IMAGE" "$DB_IMAGE" "$REDIS_IMAGE" "$CADDY_IMAGE")
[ "$OFFICE" -eq 1 ] && IMAGES+=("$EO_IMAGE")
for img in "${IMAGES[@]}"; do
    if [ "$UPDATE" -eq 1 ] || ! docker image inspect "$img" >/dev/null 2>&1; then
        run_pull "$img" || exit 1
        print_success "Pulled $img"
    fi
done

# --- Files -------------------------------------------------------------------
mkdir -p "$DATA_DIR"/{html,db}
chmod 0755 "$DATA_DIR"
# Files handed to the containers, not environment variables, so neither
# docker inspect nor the compose file holds a secret.
SECRETS_DIR="$DATA_DIR/secrets"
DB_PASS_FILE="$SECRETS_DIR/db_password"
JWT_FILE="$SECRETS_DIR/jwt_secret"
mkdir -p "$SECRETS_DIR"
chmod 0700 "$SECRETS_DIR"
if [ ! -s "$DB_PASS_FILE" ]; then
    ( umask 077; openssl rand -hex 24 | tr -d '\n' > "$DB_PASS_FILE" )
    print_status "Generated the database password into $DB_PASS_FILE"
fi
if [ ! -s "$JWT_FILE" ]; then
    ( umask 077; openssl rand -hex 32 | tr -d '\n' > "$JWT_FILE" )
    print_status "Generated the editor secret into $JWT_FILE"
fi
# Postgres reads its file after dropping to its own user, uid 70 in alpine.
chown 70:70 "$DB_PASS_FILE"
chmod 0400 "$DB_PASS_FILE"
chown root:root "$JWT_FILE"
chmod 0400 "$JWT_FILE"

TRUSTED_BLOCK=""
[ -n "$TRUSTED_PROXY" ] && TRUSTED_BLOCK="    servers {
        trusted_proxies static $(printf '%s/32 ' $TRUSTED_PROXY)
    }"
OFFICE_ROUTE=""
[ "$OFFICE" -eq 1 ] && OFFICE_ROUTE="    route /eurooffice/* {
        uri strip_prefix /eurooffice
        reverse_proxy eurooffice:80 {
            header_up X-Forwarded-Prefix /eurooffice
        }
    }"

NEW_CADDY="# Generated by add_nextcloud.sh. The next run overwrites it.
{
    auto_https off
${TRUSTED_BLOCK}
}
:80 {
    request_body {
        max_size 10GB
    }
${OFFICE_ROUTE}
    reverse_proxy nextcloud:80
}"

OFFICE_SERVICE=""
[ "$OFFICE" -eq 1 ] && OFFICE_SERVICE="  eurooffice:
    container_name: nextcloud-eurooffice
    image: \"${EO_IMAGE}\"
    restart: unless-stopped
    environment:
      JWT_ENABLED: \"true\"
      # It fetches documents from the nextcloud container, a private address.
      ALLOW_PRIVATE_IP_ADDRESS: \"true\"
    volumes:
      - eurooffice-data:/var/lib/euro-office/documentserver
      - eurooffice-private:/var/www/euro-office/Data
      # With JWT_SECRET unset, the image's entrypoint reads its secret here.
      - ./secrets/jwt_secret:/var/www/euro-office/Data/.private/jwt_secret:ro
    networks: [nextcloud]"
# Named, not ./ folders: a new volume takes the image's own files and ds owner.
OFFICE_VOLUMES=""
[ "$OFFICE" -eq 1 ] && OFFICE_VOLUMES="
volumes:
  eurooffice-data:
  eurooffice-private:"

NEW_COMPOSE="# Generated by add_nextcloud.sh. The next run overwrites it.
services:
  db:
    container_name: nextcloud-db
    image: \"${DB_IMAGE}\"
    restart: unless-stopped
    environment:
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    volumes:
      - ./db:/var/lib/postgresql/data
      - ./secrets/db_password:/run/secrets/db_password:ro
    networks: [nextcloud]
  redis:
    container_name: nextcloud-redis
    image: \"${REDIS_IMAGE}\"
    restart: unless-stopped
    networks: [nextcloud]
  nextcloud:
    container_name: nextcloud
    image: \"${NC_IMAGE}\"
    restart: unless-stopped
    depends_on: [db, redis]
    environment:
      REDIS_HOST: redis
      APACHE_DISABLE_REWRITE_IP: \"1\"
      PHP_UPLOAD_LIMIT: 10G
    volumes:
      - ./html:/var/www/html${DROP_DIR:+
      - ${DROP_DIR}:/drop}
    networks: [nextcloud]
${OFFICE_SERVICE}
  front:
    container_name: nextcloud-front
    image: \"${CADDY_IMAGE}\"
    restart: unless-stopped
    ports:
      - \"${PORT}:80\"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    networks: [nextcloud]
networks:
  nextcloud:
    ipam:
      config:
        - subnet: ${SUBNET}${OFFICE_VOLUMES}"

write_if_changed() {
    local file="$1" content="$2"
    if [ -f "$file" ] && [ "$(cat "$file")" = "$content" ]; then
        print_success "$(basename "$file") unchanged."
    else
        printf '%s\n' "$content" > "$file"
        chmod 0644 "$file"
        print_success "Wrote $file"
    fi
}
# Owned by www-data (33, the same id inside the container), group-sticky so
# files Samba writes as www-data stay readable to Nextcloud.
[ -n "$DROP_DIR" ] && install -d -o 33 -g 33 -m 2770 "$DROP_DIR"
write_if_changed "$DATA_DIR/Caddyfile" "$NEW_CADDY"
write_if_changed "$DATA_DIR/docker-compose.yml" "$NEW_COMPOSE"

# --- Start it ----------------------------------------------------------------
if ! run_watched "Starting the stack" docker compose --project-directory "$DATA_DIR" up -d --remove-orphans; then
    print_action "Logs: sudo docker compose --project-directory $DATA_DIR logs --tail 30"
    exit 1
fi
# The Caddyfile is read at start only. A just-started Caddy refuses the reload
# until its admin port is up, so it is retried for 10 s.
RELOAD_OK=0
for _ in $(seq 1 20); do
    if RELOAD="$(docker exec nextcloud-front caddy reload --config /etc/caddy/Caddyfile 2>&1)"; then
        RELOAD_OK=1
        break
    fi
    printf '%s' "$RELOAD" | grep -q 'connection refused' || break
    sleep 0.5
done
if [ "$RELOAD_OK" -ne 1 ]; then
    print_error "Caddy refused the Caddyfile, so it still serves the old one:"
    printf '%s\n' "$RELOAD" | tail -n 10 | sed 's/^/   /'
    exit 1
fi
print_success "Containers started."

wait_until() {
    local what="$1" limit="$2" check="$3" start
    start="$(date +%s)"
    while [ $(( $(date +%s) - start )) -lt "$limit" ]; do
        if eval "$check"; then printf '\r\033[K'; return 0; fi
        spin_tick "Waiting for $what, $(( $(date +%s) - start ))s of ${limit}s"
    done
    printf '\r\033[K'
    return 1
}

# Restored from a backup: the database starts empty, so the dump goes in
# before Nextcloud is asked anything.
if [ "$RESTORED_CONF" -eq 1 ]; then
    # Over TCP: the first start's init server answers on the socket only, then
    # restarts and would cut the load off.
    if ! wait_until "the database" 120 'docker exec nextcloud-db pg_isready -h 127.0.0.1 -U nextcloud >/dev/null 2>&1'; then
        print_error "The database did not come up within 120s."
        exit 1
    fi
    TABLES="$(docker exec nextcloud-db psql -tA -U nextcloud nextcloud \
        -c "select count(*) from information_schema.tables where table_name like 'oc_%'" 2>/dev/null || echo 0)"
    if [ "${TABLES:-0}" -eq 0 ]; then
        # The fresh container already made the nextcloud role; that one line fails.
        if ! docker exec -i nextcloud-db psql -q -U nextcloud nextcloud \
                < "$DATA_DIR/dump/nextcloud.sql" >/dev/null 2>"$DATA_DIR/dump/restore.log"; then
            print_error "Loading the dump failed: $DATA_DIR/dump/restore.log"
            exit 1
        fi
        print_success "Database loaded from $DATA_DIR/dump/nextcloud.sql"
    fi
fi

# The first start copies Nextcloud into ./html before occ exists.
if ! wait_until "Nextcloud's files" 300 'occ status >/dev/null 2>&1'; then
    print_error "Nextcloud did not come up within 300s. Last lines:"
    docker logs --tail 20 nextcloud 2>&1 | sed 's/^/   /'
    exit 1
fi

# --- Install, once -----------------------------------------------------------
if occ status --output=json 2>/dev/null | grep -q '"installed":true'; then
    print_success "Nextcloud is already installed, so no password is asked."
else
    ENTRY="Nextcloud admin"
    PASSWORD=""
    entry_password() {
        secret_entry_get "$ENTRY" "" 2>/dev/null | awk -F'\t' '$1 == "" && $2 == "password" { print $3; exit }'
    }
    if [ "$STORE" -eq 1 ]; then
        PASSWORD="$(entry_password)" || PASSWORD=""
        if [ ${#PASSWORD} -ge 12 ]; then
            print_status "Admin password read from the secret store ('$ENTRY')."
        else
            # Stored before Nextcloud sees it: a password nobody holds is a lockout.
            PASSWORD="$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-20)"
            if printf 'username\ttext\tadmin\npassword\tpassword\t%s\n' "$PASSWORD" \
                    | secret_entry_set "$ENTRY" "" \
               && printf 'Nextcloud\t%s\n' "http://$LAN_IP:$PORT" \
                    | secret_entry_urls "$ENTRY" \
               && [ "$(entry_password)" = "$PASSWORD" ]; then
                print_status "New admin password generated and stored in '$ENTRY'."
            else
                PASSWORD=""
                print_error "The secret store did not keep a new password, so it was not used."
            fi
        fi
    fi
    if [ -z "$PASSWORD" ]; then
        if ! { true > /dev/tty; } 2>/dev/null; then
            print_error "No terminal to ask for the admin password instead. Nextcloud is not installed."
            exit 1
        fi
        echo ""
        print_action "NEEDED: a password for Nextcloud's 'admin' account"
        while true; do
            read_secret "   Nextcloud admin password: "; p1="$SECRET"; unset SECRET
            if [ ${#p1} -lt 12 ]; then
                printf "   \033[33mAt least 12 characters.\033[0m\n" > /dev/tty; continue
            fi
            read_secret "   Again: "; p2="$SECRET"; unset SECRET
            [ "$p1" = "$p2" ] && { PASSWORD="$p1"; break; }
            printf "   \033[33mThey do not match. Try again.\033[0m\n" > /dev/tty
        done
        unset p1 p2
    fi

    # The admin password goes in from the environment, so ps never shows it.
    # The DB password does show in ps during this one install: occ takes no
    # other way, and the image's own auto-install does the same.
    DB_PASS="$(cat "$DB_PASS_FILE")"
    if ! run_watched "Installing Nextcloud (a few minutes on a Pi)" \
            docker exec -u www-data nextcloud php occ maintenance:install \
            --database pgsql --database-host db --database-name nextcloud \
            --database-user nextcloud --database-pass "$DB_PASS" \
            --admin-user admin --admin-pass "$(openssl rand -hex 24)" \
            --data-dir /var/www/html/data; then
        unset PASSWORD DB_PASS
        exit 1
    fi
    unset DB_PASS
    if ! OC_PASS="$PASSWORD" docker exec -e OC_PASS -u www-data nextcloud \
            php occ user:resetpassword --password-from-env admin >/dev/null 2>&1; then
        unset PASSWORD
        print_error "Nextcloud is installed, but the admin password could not be set."
        print_action "Set it by hand: sudo docker exec -it -u www-data nextcloud php occ user:resetpassword admin"
        exit 1
    fi
    unset PASSWORD
    print_success "Installed, with the account 'admin'."
fi

# --- Names and proxies, every run --------------------------------------------
# Each address it is reached on, plus the container name the editor calls back on.
TRUSTED=("localhost" "$LAN_IP" "nextcloud")
[ -n "$PUBLIC_HOST" ] && TRUSTED+=("$PUBLIC_HOST")
occ config:system:delete trusted_domains >/dev/null
for i in "${!TRUSTED[@]}"; do
    occ config:system:set trusted_domains "$i" --value="${TRUSTED[$i]}" >/dev/null
done
# Its own front proxy. The machine in front of THAT one is trusted by Caddy,
# which then passes on the original scheme and host.
occ config:system:set trusted_proxies 0 --value="$SUBNET" >/dev/null
if [ -n "$PUBLIC_HOST" ]; then
    occ config:system:set overwrite.cli.url --value="https://$PUBLIC_HOST" >/dev/null
else
    occ config:system:set overwrite.cli.url --value="http://$LAN_IP:$PORT" >/dev/null
fi
print_success "Trusted names: ${TRUSTED[*]}"

# --- The editor --------------------------------------------------------------
if [ "$OFFICE" -eq 1 ]; then
    # Font generation on the first start takes minutes on a Pi.
    if ! wait_until "Euro-Office" 900 '[ "$(curl -s --max-time 5 "http://127.0.0.1:${PORT}/eurooffice/healthcheck")" = "true" ]'; then
        print_error "Euro-Office did not answer its health check within 900s. Last lines:"
        docker logs --tail 20 nextcloud-eurooffice 2>&1 | sed 's/^/   /'
        exit 1
    fi
    print_success "Euro-Office answers its health check."

    if ! occ app:list --output=json 2>/dev/null | grep -q '"eurooffice"'; then
        run_watched "Installing the Euro-Office connector" \
            docker exec -u www-data nextcloud php occ app:install eurooffice || exit 1
    fi
    occ app:enable eurooffice >/dev/null 2>&1 || true
    # Relative, so the browser loads the editor from the address it is on.
    occ config:app:set eurooffice DocumentServerUrl         --value="/eurooffice/" >/dev/null
    occ config:app:set eurooffice DocumentServerInternalUrl --value="http://eurooffice/" >/dev/null
    occ config:app:set eurooffice StorageUrl                --value="http://nextcloud/" >/dev/null
    # ODF opens read-only by default; saving it back may lose some formatting.
    occ config:app:set eurooffice editFormats --value='{"odt":"true","ods":"true","odp":"true"}' >/dev/null
    # Nextcloud merges config/*.config.php, and the connector falls back to its
    # 'eurooffice' system entry when no app value is set. Written from here, so
    # the secret is on no command line.
    NC_JWT_CONF="$DATA_DIR/html/config/eurooffice.config.php"
    ( umask 077
      printf "<?php\n\$CONFIG = array('eurooffice' => array('jwt_secret' => '%s'));\n" \
          "$(cat "$JWT_FILE")" > "$NC_JWT_CONF" )
    chown 33:33 "$NC_JWT_CONF"
    chmod 0600 "$NC_JWT_CONF"
    occ config:app:delete eurooffice jwt_secret >/dev/null 2>&1 || true
    CHECK="$(occ eurooffice:documentserver --check 2>&1 || true)"
    printf '%s\n' "$CHECK" | sed 's/^/   /'
    if printf '%s' "$CHECK" | grep -qi 'error\|fail'; then
        print_error "The connector cannot reach Euro-Office, see above."
        exit 1
    fi
    print_success "Connector set: editor at /eurooffice/, internal calls container to container."
fi

# --- The drop folder ---------------------------------------------------------
# External storage, type Local: Nextcloud looks at the folder on every visit,
# so a file put in over Samba shows up and can be shared by link.
if [ -n "$DROP_DIR" ]; then
    DROP_NAME="/$(basename "$DROP_DIR")"
    occ app:enable files_external >/dev/null
    if occ files_external:list --output=json 2>/dev/null | tr -d '\\' | grep -qF "\"mount_point\":\"${DROP_NAME}\""; then
        print_success "Drop folder already shown as $DROP_NAME."
    else
        MOUNT_ID="$(occ files_external:create "$DROP_NAME" local null::null -c datadir=/drop 2>&1 | grep -oE '[0-9]+' | tail -n1)"
        [ -n "$MOUNT_ID" ] || { print_error "Nextcloud did not create the $DROP_NAME folder."; exit 1; }
        occ files_external:option "$MOUNT_ID" filesystem_check_changes 1 >/dev/null
        print_success "Drop folder $DROP_DIR shown to every user as $DROP_NAME."
    fi
fi

# --- Nightly database dump ---------------------------------------------------
# A file copy of a running Postgres may not restore; a dump always does. It
# lands in $DATA_DIR/dump before a 03:00 backup of /opt copies it.
mkdir -p "$DATA_DIR/dump"
chmod 0700 "$DATA_DIR/dump"
DUMP_SERVICE="# Generated by add_nextcloud.sh. The next run overwrites it.
[Unit]
Description=Dump Nextcloud's database to $DATA_DIR/dump
After=docker.service

[Service]
Type=oneshot
UMask=0077
# Roles too: Nextcloud logs in as its own oc_admin, which pg_dump leaves out.
ExecStart=/bin/sh -c '{ docker exec nextcloud-db pg_dumpall -U nextcloud --roles-only && docker exec nextcloud-db pg_dump -U nextcloud nextcloud; } > \"$DATA_DIR/dump/nextcloud.sql.tmp\" && mv \"$DATA_DIR/dump/nextcloud.sql.tmp\" \"$DATA_DIR/dump/nextcloud.sql\"'"
DUMP_TIMER="# Generated by add_nextcloud.sh. The next run overwrites it.
[Unit]
Description=Dump Nextcloud's database nightly at ${DUMP_AT}

[Timer]
OnCalendar=${DUMP_AT}
Persistent=true

[Install]
WantedBy=timers.target"
write_if_changed /etc/systemd/system/nextcloud-db-dump.service "$DUMP_SERVICE"
write_if_changed /etc/systemd/system/nextcloud-db-dump.timer "$DUMP_TIMER"
systemctl daemon-reload
if ! systemctl enable --now nextcloud-db-dump.timer; then
    print_error "The nightly dump timer could not be enabled: sudo systemctl status nextcloud-db-dump.timer"
    exit 1
fi
if run_watched "Dumping the database" systemctl start nextcloud-db-dump.service \
   && [ -s "$DATA_DIR/dump/nextcloud.sql" ]; then
    print_success "Database dumped to $DATA_DIR/dump/nextcloud.sql, and nightly at ${DUMP_AT}."
else
    print_error "The database dump failed: sudo journalctl -u nextcloud-db-dump.service -n 20"
    exit 1
fi

# --- Prove it ----------------------------------------------------------------
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}/status.php")"
if [ "$CODE" != "200" ]; then
    print_error "Nextcloud's status page answers $CODE through the front port."
    exit 1
fi
print_success "Nextcloud answers through port ${PORT}."

echo ""
print_success "Nextcloud is up."
print_action "Open http://${LAN_IP}:${PORT} and sign in as admin."
[ -n "$PUBLIC_HOST" ] && print_info "Publicly: https://${PUBLIC_HOST}, once the proxy on ${TRUSTED_PROXY} serves it."
print_info "Newer images: re-run with --update"
print_info "Logs: sudo docker compose --project-directory $DATA_DIR logs --tail 30"
