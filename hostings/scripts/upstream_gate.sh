#!/usr/bin/env bash
# -d / --debug: trace every command. Stripped from "$@" so it never reaches the
# script's own argument parsing.
# =============================================================================
# The upgrade gate: what test runs reaches live by the users' votes, never by
# hand alone. Design: .claude/docs/webbuilder-and-upgrade-gate-decisions.md.
#
#   upstream_gate.sh                                 every package's round
#   upstream_gate.sh vote <name> <user> <urgent|up|neutral|down>
#   upstream_gate.sh pause|resume|publish <name>     the owner's buttons
#   upstream_gate.sh tick                            daily, by upstream-gate.timer
#   upstream_gate.sh list                            open rounds, tab separated, for the console
#
# A round is the version test runs while live runs another. Rules, per round:
#   down    blocks until the next stable release starts a new round
#   urgent  mails everyone who has not voted; live after 3 days with no down
#   no down in 7 days                       live (lazy consensus)
#   live with no up or urgent at all        the owner is mailed: untested
# The owner is mailed on urgent, neutral and down. The flow never waits for
# them: pause is optional, and so is publish.
# =============================================================================

set -e

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
# The console reaches this through sudo; its trace would show voters' addresses.
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x


print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
    printf '%s' "${v:-$2}"
}

[ "$EUID" -eq 0 ] || { print_error "This needs root: it reads the gate's state and promotes images."; print_action "sudo bash $0 $*"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || { print_error "No config at $SITES_CONF"; exit 1; }

TEST_ENV="test"
LIVE_ENV="live"
DAY=86400
URGENT_DAYS="$(conf_get UPGRADE_URGENT_DAYS 3)"
LAZY_DAYS="$(conf_get UPGRADE_LAZY_DAYS 7)"
# Digits only: these go into $(( )), which runs anything else as root.
[[ "$URGENT_DAYS" =~ ^[0-9]{1,3}$ ]] || URGENT_DAYS=3
[[ "$LAZY_DAYS"   =~ ^[0-9]{1,3}$ ]] || LAZY_DAYS=7
USERS_SH="$SCRIPT_DIR/manage_auth_users.sh"
NOW="$(date +%s)"

packages() {
    local r
    for r in "$REPO_ROOT"/hostings/upstream/*/recipe.conf; do
        [ -f "$r" ] && basename "$(dirname "$r")"
    done
}
# The name builds root-written paths, so nothing but a plain word gets that far.
known_package() { [[ "$1" =~ ^[a-z0-9_-]+$ ]] && [ -f "$REPO_ROOT/hostings/upstream/$1/recipe.conf" ]; }

# --- State: /var/lib/upstream/<name>/gate/ ------------------------------------
#   round    "<version> <opened epoch>"
#   votes    "<user> <vote> <epoch>", one line per vote; a user's last one counts
#   paused   present while the owner holds the round
#   urgent-mailed, untested-mailed   so each mail goes out once per round
gate_dir()  { printf '/var/lib/upstream/%s/gate' "$1"; }
running()   { cat "/var/lib/upstream/$1/$2" 2>/dev/null || true; }

# Opens a new round when test moved on, and closes it when live caught up.
# Prints the round's version, or nothing when there is no round.
sync_round() {
    local name="$1" dir test live rv
    dir="$(gate_dir "$name")"
    test="$(running "$name" "$TEST_ENV")"
    live="$(running "$name" "$LIVE_ENV")"
    rv="$(cut -d' ' -f1 "$dir/round" 2>/dev/null || true)"
    if [ -z "$test" ] || [ -z "$live" ] || [ "$test" = "$live" ]; then
        [ -n "$rv" ] && rm -f "$dir/round" "$dir/votes" "$dir/paused" "$dir/"*-mailed
        return 0
    fi
    if [ "$rv" != "$test" ]; then
        mkdir -p "$dir"
        rm -f "$dir/votes" "$dir/paused" "$dir/"*-mailed
        printf '%s %s\n' "$test" "$NOW" > "$dir/round"
    fi
    printf '%s' "$test"
}

# The last vote per user, as "<user> <vote> <epoch>".
current_votes() {
    [ -f "$1/votes" ] || return 0
    awk '{ last[$1] = $0 } END { for (u in last) print last[u] }' "$1/votes" | sort
}
count_vote() { current_votes "$1" | awk -v v="$2" '$2 == v' | wc -l; }
first_urgent() { current_votes "$1" | awk '$2 == "urgent" { print $3 }' | sort -n | head -n1; }

voters()   { bash "$USERS_SH" --role-holders 2>/dev/null | tr ' ' '\n' | sed '/^$/d'; }
owner()    { voters | head -n1; }
email_of() { bash "$USERS_SH" --email-of "$1" 2>/dev/null | head -n1; }

send_notice() {  # <to> <subject> <text>
    local sendmail from
    [ -n "$1" ] || return 0
    case "$1$2" in *$'\n'*|*$'\r'*) print_error "Refused a mail header with a line break in it."; return 0 ;; esac
    sendmail="$(command -v sendmail 2>/dev/null || echo /usr/sbin/sendmail)"
    [ -x "$sendmail" ] || { print_action "No sendmail, so '$2' was not mailed to $1."; return 0; }
    from="$(conf_get NOTIFY_FROM "noreply@$(conf_get BASE_DOMAIN "$(hostname)")")"
    {
        printf 'From: %s\nTo: %s\nSubject: %s\n' "$from" "$1" "$2"
        printf 'Content-Type: text/plain; charset=utf-8\n\n%s\n' "$3"
    } | "$sendmail" -t -oi || print_action "sendmail refused '$2' to $1."
}
mail_owner() { send_notice "$(email_of "$(owner)")" "$1" "$2"; }

publish() {  # <name> <version> <why>
    local name="$1" version="$2" why="$3" dir ups
    dir="$(gate_dir "$name")"
    ups=$(( $(count_vote "$dir" up) + $(count_vote "$dir" urgent) ))
    print_status "$name $version → $LIVE_ENV: $why"
    if ! bash "$SCRIPT_DIR/upstream_promote.sh" "$name" "$LIVE_ENV" "$version"; then
        mail_owner "$name $version did NOT reach live" \
            "The gate decided to publish ($why), but upstream_promote.sh failed. Live still runs $(running "$name" "$LIVE_ENV").
Roll back or retry: sudo bash $SCRIPT_DIR/upstream_promote.sh $name $LIVE_ENV <version|previous>"
        return 1
    fi
    if [ "$ups" -eq 0 ]; then
        mail_owner "$name $version is live, UNTESTED" \
            "Published to live ($why) with no thumbs up from anyone. Nobody said it works.
Back to the previous version: sudo bash $SCRIPT_DIR/upstream_promote.sh $name $LIVE_ENV previous"
    fi
    sync_round "$name" >/dev/null
}

report() {  # <name>
    local name="$1" dir version opened days line
    dir="$(gate_dir "$name")"
    version="$(sync_round "$name")"
    print_header "$name"
    printf '   %-6s %s\n   %-6s %s\n' "$TEST_ENV" "$(running "$name" "$TEST_ENV" || true)" \
        "$LIVE_ENV" "$(running "$name" "$LIVE_ENV" || true)"
    if [ -z "$version" ]; then
        print_info "No round: test and live run the same version."
        return 0
    fi
    opened="$(cut -d' ' -f2 "$dir/round")"
    days=$(( (NOW - opened) / DAY ))
    print_info "Round for $version, open $days day(s).$([ -f "$dir/paused" ] && echo ' PAUSED by the owner.')"
    while read -r line; do
        [ -n "$line" ] && printf '   %s\n' "$line"
    done < <(current_votes "$dir" | awk '{ print $1 ": " $2 }')
    [ "$(count_vote "$dir" down)" -gt 0 ] && print_info "Blocked by a thumbs down until the next stable release."
    return 0
}

tick_one() {  # <name>
    local name="$1" dir version opened first
    dir="$(gate_dir "$name")"
    version="$(sync_round "$name")"
    [ -n "$version" ] || return 0
    [ -f "$dir/paused" ] && { print_info "$name $version: paused by the owner."; return 0; }
    [ "$(count_vote "$dir" down)" -gt 0 ] && { print_info "$name $version: blocked by a thumbs down."; return 0; }
    opened="$(cut -d' ' -f2 "$dir/round")"
    first="$(first_urgent "$dir")"
    if [ -n "$first" ] && [ $(( NOW - first )) -ge $(( URGENT_DAYS * DAY )) ]; then
        publish "$name" "$version" "urgent, no thumbs down in $URGENT_DAYS days"
    elif [ $(( NOW - opened )) -ge $(( LAZY_DAYS * DAY )) ]; then
        publish "$name" "$version" "no thumbs down in $LAZY_DAYS days"
    else
        print_info "$name $version: waiting, open $(( (NOW - opened) / DAY )) of $LAZY_DAYS days."
    fi
}

vote() {  # <name> <user> <vote>
    local name="$1" user="$2" v="$3" dir version u
    case "$v" in urgent|up|neutral|down) ;; *) print_error "A vote is urgent, up, neutral or down, not '$v'."; exit 2 ;; esac
    [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || { print_error "'$user' is not a username."; exit 1; }
    voters | grep -qxF "$user" || { print_error "'$user' is not a console user who may vote."; exit 1; }
    dir="$(gate_dir "$name")"
    version="$(sync_round "$name")"
    [ -n "$version" ] || { print_error "$name has no round: test and live run the same version."; exit 1; }
    printf '%s %s %s\n' "$user" "$v" "$NOW" >> "$dir/votes"
    print_success "$user voted $v on $name $version."
    case "$v" in
        urgent|neutral|down)
            mail_owner "$name $version: $user voted $v" \
                "$user voted $v on $name $version, which runs on test.
$([ "$v" = down ] && echo "It stays on test until the next stable release starts a new round.")" ;;
    esac
    if [ "$v" = "urgent" ] && [ ! -f "$dir/urgent-mailed" ]; then
        touch "$dir/urgent-mailed"
        for u in $(voters); do
            current_votes "$dir" | awk -v u="$u" '$1 == u { f = 1 } END { exit !f }' && continue
            send_notice "$(email_of "$u")" "Please test $name $version" \
                "$user asked for $name $version to go live soon. It runs on test now.
Unless somebody votes thumbs down, it goes live in $URGENT_DAYS days."
        done
    fi
}

# --- Main ---------------------------------------------------------------------
ACTION="${1:-status}"
case "$ACTION" in
    status)
        if [ -n "${2:-}" ]; then
            known_package "$2" || { print_error "No upstream package '$2'."; exit 1; }
            report "$2"
        else
            for p in $(packages); do report "$p"; done
        fi
        ;;
    list)
        # For the console, one line per open round, tab separated:
        # name, version, live version, days open, paused 0/1, user:vote,...
        for p in $(packages); do
            v="$(sync_round "$p")"
            [ -n "$v" ] || continue
            d="$(gate_dir "$p")"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$v" "$(running "$p" "$LIVE_ENV")" \
                "$(( (NOW - $(cut -d' ' -f2 "$d/round")) / DAY ))" \
                "$([ -f "$d/paused" ] && echo 1 || echo 0)" \
                "$(current_votes "$d" | awk '{ printf "%s%s:%s", (NR > 1 ? "," : ""), $1, $2 }')"
        done
        ;;
    tick)
        rc=0
        for p in $(packages); do tick_one "$p" || rc=1; done
        exit "$rc"
        ;;
    vote)
        [ $# -eq 4 ] || { print_error "Usage: $0 vote <name> <user> <urgent|up|neutral|down>"; exit 2; }
        known_package "$2" || { print_error "No upstream package '$2'."; exit 1; }
        vote "$2" "$3" "$4"
        ;;
    pause|resume|publish)
        [ -n "${2:-}" ] && known_package "$2" || { print_error "Usage: $0 $ACTION <name>"; exit 2; }
        version="$(sync_round "$2")"
        [ -n "$version" ] || { print_error "$2 has no round: test and live run the same version."; exit 1; }
        case "$ACTION" in
            pause)   touch "$(gate_dir "$2")/paused";  print_success "$2 $version held on test." ;;
            resume)  rm -f "$(gate_dir "$2")/paused";  print_success "$2 $version back under the vote rules." ;;
            publish) publish "$2" "$version" "published now by the owner" ;;
        esac
        ;;
    *)
        print_error "Unknown action '$ACTION'."
        print_action "$0 [status [name] | tick | vote <name> <user> <vote> | pause|resume|publish <name>]"
        exit 2
        ;;
esac
