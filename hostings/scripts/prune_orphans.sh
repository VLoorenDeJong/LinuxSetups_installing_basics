#!/bin/bash
# =============================================================================
# Delete what the config no longer lists.
#
# One question, one script. Split out of maintain_services.sh on 2026-08-16.
# It does not decide what an orphan is: report_drift.sh does that, and this
# consumes its list. Two places deciding would eventually disagree, and the one
# that deletes is the wrong place to be wrong.
#
# What each kind means, and why they are not treated alike:
#
#   vhost    deleted. Generated from the config, rebuilt by re-running.
#   unit     stopped, disabled, deleted. Same reason.
#   cert     deleted through certbot. Re-issuing costs a Let's Encrypt
#            issuance, so report_drift.sh leaves every doubtful lineage out
#            of the list rather than risk one.
#   vault    one mailbox section removed from a person's entry in the secret
#            store, through person_entry.sh, which re-checks it is stale.
#   secrets  MOVED to /var/backups/hostings-removed/<timestamp>/, never
#            deleted and never under /var/www: it can hold a password that
#            exists nowhere else.
#   docroot  MOVED to /var/www/removed/<timestamp>/, never deleted. A website's
#            content is a checkout and can be republished, but a typo in a row
#            must not be able to destroy files this script did not create.
#   mail     one line removed from a Postfix map or from Dovecot's users file.
#            THE MAILDIR IS NEVER TOUCHED: removing a mailbox deliberately
#            leaves the messages on disk, so what goes is the machine's claim on
#            the address, never the mail behind it.
#
# Nothing a human wrote is ever DELETED. A vhost, a unit or a certificate is
# only called an orphan when it carries "from /etc/hostings/hostings.conf", so
# nothing hand-written is removed; a secrets file carries no such mark and can
# hold what a human typed into the console, which is why it is moved aside
# rather than deleted.
#
# Usage:
#   sudo ./prune_orphans.sh                    work the list out first
#   sudo ./prune_orphans.sh --from /tmp/drift  use a list already computed
#   sudo ./prune_orphans.sh --sweep-removed    delete old moved-aside batches
# =============================================================================

set -e

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

show_spinner_watch_only() {
    local message="$1"
    shift
    if [ ! -t 1 ]; then "$@"; return $?; fi

    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    "$@" &
    local cmd_pid=$! tick=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        redraw '\r\033[K\033[34m%s %s\033[0m' "${frames[tick % 10]}" "$message"
        tick=$((tick + 1))
        sleep 0.2 || { printf "\n\033[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\033[0m\n"; break; }
    done
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    redraw '\r\033[K'
    return $exit_code
}

# A redraw needs a terminal. In a Jenkins log \r is not a carriage return, so
# every update lands as its own line and \033[K blanks it: seventeen units
# printed one line of text and sixteen empty ones. Silent there instead, since
# each of these loops already prints a summary when it finishes.
redraw() { [ -t 1 ] || return 0; printf "$@"; }

apache_configtest_quiet() { apache2ctl configtest >/dev/null 2>&1; }
fpm_test_quiet()          { "php-fpm$1" -t >/dev/null 2>&1; }
disable_unit_quiet()      { systemctl disable --now "$1" >/dev/null 2>&1 || true; }
certbot_delete_quiet()    { certbot delete --cert-name "$1" --non-interactive >"$2" 2>&1; }

usage() {
    echo "Usage: $0 [--from FILE] [--sweep-removed]" >&2
    echo "" >&2
    echo "  --from FILE   a drift list already written by report_drift.sh." >&2
    echo "                Without it, report_drift.sh is run to build one." >&2
    echo "  --sweep-removed  delete /var/www/removed batches older than SWEEP_DAYS (90)." >&2
    exit 1
}

FROM=""
SWEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from)   FROM="$2"; shift 2 ;;
        --from=*) FROM="${1#--from=}"; shift ;;
        --sweep-removed) SWEEP=1; shift ;;
        -h|--help) usage ;;
        *) print_error "Unknown option: $1"; usage ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AVAILABLE_DIR="/etc/apache2/sites-available"
UNIT_DIR="/etc/systemd/system"

# =============================================================================
# What was moved aside, and when it stops being kept.
#
# Nothing here is deleted by a prune: a document root goes to /var/www/removed
# and a secrets file to /var/backups/hostings-removed, so neither can be
# destroyed by a typo in a row. Both therefore only ever grow, which stayed
# invisible until it was measured, so both are reported on every run and
# deleted only when asked for by name.
# =============================================================================
TRASH_ROOTS=(/var/www/removed /var/backups/hostings-removed)
SWEEP_DAYS="${SWEEP_DAYS:-90}"

case "$SWEEP_DAYS" in
    ''|*[!0-9]*|0) print_error "SWEEP_DAYS must be a whole number of days, 1 or more. Got '$SWEEP_DAYS'."
                   exit 1 ;;
esac

report_removed_trash() {
    local root batches old d
    for root in "${TRASH_ROOTS[@]}"; do
        [ -d "$root" ] || continue
        batches="$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)" || batches=0
        [ "$batches" -gt 0 ] || continue

        echo ""
        print_header "Moved aside, still on disk"
        print_status "$root holds $batches batch(es), $(du -sh "$root" 2>/dev/null | cut -f1) in total."

        if [ "$SWEEP" -ne 1 ]; then
            print_info "Nothing here is deleted automatically. Content moved aside is never destroyed by a rerun."
            print_action "Delete what is older than $SWEEP_DAYS days: sudo $0 --sweep-removed"
            print_action "Or look first: sudo du -sh $root/*"
            continue
        fi

        old="$(find "$root" -mindepth 1 -maxdepth 1 -type d -mtime "+$SWEEP_DAYS" 2>/dev/null)" || old=""
        if [ -z "$old" ]; then
            print_info "Nothing in $root is older than $SWEEP_DAYS days, so nothing was deleted."
            continue
        fi
        while IFS= read -r d; do
            [ -z "$d" ] && continue
            if rm -rf "$d"; then
                print_success "Deleted $d, older than $SWEEP_DAYS days."
            else
                print_error "Could not delete $d, left in place."
            fi
        done <<< "$old"
    done
}

HAVE_CERTBOT=0
command -v certbot >/dev/null 2>&1 && HAVE_CERTBOT=1

# The list. Asked for rather than worked out, and refused rather than guessed at
# when it cannot be obtained: an empty list read as "nothing to do" would be
# indistinguishable from a report that failed to run.
CLEANUP_LIST=""
if [ -z "$FROM" ]; then
    REPORTER="$SCRIPT_DIR/report_drift.sh"
    if [ ! -f "$REPORTER" ]; then
        print_error "report_drift.sh is not next to this script, and no --from was given."
        print_info "Nothing was pruned: this script never decides what an orphan is."
        exit 1
    fi
    FROM="$(mktemp)"
    CLEANUP_LIST="$FROM"
    DRIFT_OUT="$FROM" bash "$REPORTER" >/dev/null
elif [ ! -f "$FROM" ]; then
    print_error "No such drift list: $FROM"
    exit 1
fi

mapfile -t ORPHAN < <(grep '^ORPHAN ' "$FROM" | sed 's/^ORPHAN //')
[ -n "$CLEANUP_LIST" ] && rm -f "$CLEANUP_LIST"

if [ ${#ORPHAN[@]} -eq 0 ]; then
    print_success "Nothing is orphaned. Nothing was pruned."
    report_removed_trash
    exit 0
fi

print_header "Prune"
POOL_ACCOUNTS=()
for entry in "${ORPHAN[@]}"; do
    kind="${entry%% *}"
    b="$(echo "$entry" | awk '{print $2}')"
    case "$kind" in
        vhost)
            # A stale drift file may still name one. Only add_preview_vhosts.sh
            # removes a preview, because only it can put one back.
            case "$b" in
                preview-*)
                    print_info "Left $b alone. add_preview_vhosts.sh owns the previews."
                    continue
                    ;;
            esac
            a2dissite "$b" >/dev/null 2>&1 || true
            rm -f "$AVAILABLE_DIR/$b"
            print_success "Removed vhost $b"
            ;;
        unit)
            show_spinner_watch_only "Stopping $b" disable_unit_quiet "$b"
            # A Docker row's unit (item 140) also leaves an image and the
            # .built marker deploy_docker_app.sh wrote; the unit names both.
            _img="$(sed -n 's/^ExecStart=.*docker run .* \([a-z0-9_.-]*:latest\)$/\1/p' "$UNIT_DIR/$b" 2>/dev/null)"
            _marker="$(sed -n 's/^# docker marker: //p' "$UNIT_DIR/$b" 2>/dev/null)"
            if [ -n "$_img" ] && command -v docker >/dev/null 2>&1; then
                docker image rm -f "$_img" >/dev/null 2>&1 && print_success "Removed image $_img"
            fi
            case "$_marker" in */.docker/*.built) rm -f "$_marker" ;; esac
            unset _img _marker
            rm -f "$UNIT_DIR/$b"
            # A unit that was RUNNING when its file went leaves systemd holding
            # a "not-found / failed" entry for it for ever, so `systemctl
            # --failed` and the console's health line keep naming a row that no
            # longer exists. Measured 2026-09-17 after deleting zznodeapp
            # through the console.
            systemctl reset-failed "$b" >/dev/null 2>&1 || true
            print_success "Removed unit $b"
            ;;
        cert)
            # WHO ELSE POINTS AT IT. A lineage no ROW asks for may still be
            # named by a file the rows do not describe, and deleting it then
            # breaks that service instead of tidying up.
            #
            # Two have happened. Dovecot was pointed at BASE_DOMAIN's lineage
            # and died when a row deletion pruned it (item 43). Then on
            # 2026-09-03 this prune removed example.com while
            # 000-catchall.conf still had its SSLCertificateFile, and Apache
            # could not reload AT ALL until the vhosts were regenerated by hand.
            #
            # So: refuse, name the file, and carry on with the rest. A leftover
            # certificate costs disk; a dangling reference costs the service.
            # -R, not -r. sites-enabled holds nothing but symlinks into
            # sites-available, and -r does not follow them, so this check found
            # zero Apache references every time it ran and the guard below has
            # never once fired for a vhost.
            #
            # /etc/apache2 whole, not the two site directories: conf-available,
            # conf-enabled and ssl.conf can name a lineage too, and scanning one
            # tree means a vhost is not reported twice under both its paths.
            # readlink -f then collapses a symlink onto its target so head -5
            # cannot fill up with the same file twice.
            #
            # -F, not -E: the dots in a domain are literal.
            cert_users="$(grep -RlF "letsencrypt/live/${b}/" \
                /etc/apache2 /etc/dovecot /etc/postfix 2>/dev/null \
                | xargs -r -d '\n' readlink -f 2>/dev/null \
                | sort -u | head -5)"
            if [ -n "$cert_users" ]; then
                print_info "Certificate $b is still named by:"
                printf '%s\n' "$cert_users" | while IFS= read -r u; do
                    [ -n "$u" ] && print_info "  - $u"
                done
                print_action "Left in place. Fix those first, or the service they belong to stops."
            elif [ "$HAVE_CERTBOT" -ne 1 ]; then
                print_info "certbot is missing, so certificate $b was left in place."
            else
                cert_log="$(mktemp)"
                if show_spinner_watch_only "Removing certificate $b" \
                        certbot_delete_quiet "$b" "$cert_log"; then
                    print_success "Removed certificate $b"
                    rm -f "$cert_log"
                else
                    print_error "Could not remove certificate $b, left in place. Last 20 lines:"
                    tail -n 20 "$cert_log"
                    print_action "Full log: $cert_log"
                fi
            fi
            ;;
        mail)
            # One address the machine still accepts, authenticates or forwards
            # while no row claims it. THE MAILDIR IS NEVER TOUCHED HERE:
            # removing a mailbox deliberately leaves the messages on disk, so
            # what is pruned is the machine's claim on the address, not the
            # mail. Re-creating the row reattaches everything, exactly as a
            # forward or a retire does.
            where="$(echo "$entry" | awk '{print $2}')"
            addr="$(echo "$entry"  | awk '{print $3}')"
            case "$addr" in
                *@*.*) : ;;
                *) print_info "Refusing an odd mail address, left alone: $addr"; continue ;;
            esac
            case "$where" in
                delivery) mfile="/etc/postfix/virtual_mailbox_map" ;;
                sender)   mfile="/etc/postfix/sender_login_map" ;;
                forward)  mfile="/etc/postfix/virtual_forwards" ;;
                login)    mfile="/etc/dovecot/users" ;;
                *) print_info "Unknown mail list '$where', left alone: $entry"; continue ;;
            esac
            if [ ! -f "$mfile" ]; then
                print_info "$mfile does not exist, so $addr was left alone."
                continue
            fi
            # The separator differs: the Postfix maps are whitespace, Dovecot is
            # a colon. Anchored either way, so a longer address that merely
            # starts with this one is never matched.
            addr_re="$(printf '%s' "$addr" | sed 's/[][\.^$*+?(){}|\\]/\\&/g')"
            mtmp="$(mktemp)"
            grep -Ev "^${addr_re}([[:space:]]|:)" "$mfile" > "$mtmp" 2>/dev/null || true
            if cmp -s "$mfile" "$mtmp"; then
                print_info "$addr was not in $mfile after all, nothing changed."
                rm -f "$mtmp"
                continue
            fi
            cat "$mtmp" > "$mfile"
            rm -f "$mtmp"
            case "$where" in
                login) DOVECOT_TOUCHED=1 ;;
                *)     POSTFIX_TOUCHED=1 ;;
            esac
            print_success "Removed $addr from $(basename "$mfile"). The maildir is untouched."
            ;;
        vault)
            # A mailbox section in someone's secret-store entry that no row
            # backs any more. THE STORE IS NEVER TOUCHED HERE: person_entry.sh
            # owns the entry naming and the owner rule (principle 2b), and it
            # re-runs its own audit, so a stale drift list cannot make it
            # remove a live mailbox.
            addr="$(echo "$entry" | awk '{print $3}')"
            pe="$SCRIPT_DIR/person_entry.sh"
            [ -f "$pe" ] || pe=/usr/local/sbin/person_entry.sh
            case "$b" in
                mailbox) : ;;
                *) print_error "Unknown vault kind '$b', left alone: $entry"; MOVE_FAILED=1; continue ;;
            esac
            if [ ! -f "$pe" ]; then
                print_error "person_entry.sh is not here, so $addr was left in the vault."
                MOVE_FAILED=1
            elif show_spinner_watch_only "Removing $addr from the vault" \
                    env SITES_CONF="${SITES_CONF:-}" bash "$pe" --forget-mailbox "$addr"; then
                print_success "Removed the vault section for $addr. The mailbox itself is untouched."
            else
                print_error "The vault still holds $addr. Run: sudo $pe --forget-mailbox $addr"
                MOVE_FAILED=1
            fi
            ;;
        secrets)
            # Generated per app row and holding only that row's settings, so it
            # goes with the row. Moved aside rather than deleted, and never
            # under /var/www: it can hold a password that exists nowhere else.
            #
            # The name is checked here because this script consumes a list it
            # did not necessarily write: --from takes any file, and a name with
            # a slash in it would move something else entirely.
            case "$b" in
                ''|*/*|.*) print_info "Refusing an odd secrets name, left alone: $b"; continue ;;
            esac
            trash="/var/backups/hostings-removed/$(date +%Y-%m-%d-%H%M%S)"
            if ! mkdir -p "$trash" || ! chmod 700 "$trash"; then
                print_error "Could not make $trash, so $b was left in place."
                continue
            fi
            if mv "/etc/app-secrets/$b" "$trash/"; then
                print_success "Moved secrets file $b to $trash/"
            else
                print_error "Could not move secrets file $b, left in place."
                MOVE_FAILED=1
            fi
            ;;
        docroot)
            trash="/var/www/removed/$(date +%Y-%m-%d-%H%M%S)"
            # The environment lives in the PARENT, html_test / html_accept /
            # html_skunk, and every environment's copy of a row shares one
            # basename. Flattening them into one batch made the second and third
            # collide, and mv refuses to overwrite a non-empty directory, so two
            # orphans were left in place while the job said SUCCESS.
            dest="$trash/$(basename "$(dirname "$b")")"
            mkdir -p "$dest"
            if mv "$b" "$dest/"; then
                print_success "Moved $b to $dest/"
            else
                print_error "Could not move $b, left in place."
                MOVE_FAILED=1
            fi
            ;;
        pool)
            case "$b" in
                */*) print_info "Refusing an odd pool name, left alone: $b"; continue ;;
                site_*) : ;;
                *) print_info "Refusing an odd pool name, left alone: $b"; continue ;;
            esac
            pool_file="$(ls -d /etc/php/*/fpm/pool.d 2>/dev/null | sort -V | tail -1)/$b.conf"
            if ! grep -qs "from /etc/hostings/hostings.conf" "$pool_file"; then
                print_info "Not a generated pool, left alone: $pool_file"
                continue
            fi
            rm -f "$pool_file"
            # The account goes after the FPM reload: a live worker blocks userdel.
            POOL_ACCOUNTS+=("$b")
            FPM_TOUCHED=1
            print_success "Removed the PHP pool $b"
            ;;
        *)
            print_info "Unknown kind '$kind' in the drift list, left alone: $entry"
            ;;
    esac
done

# The maps are hashed, so an edited file changes nothing until postmap runs and
# Postfix rereads it. Dovecot's users file is plain text but the daemon caches
# it. Both are done once, after the loop, rather than per address.
if [ "${POSTFIX_TOUCHED:-0}" = "1" ]; then
    for m in /etc/postfix/virtual_mailbox_map /etc/postfix/sender_login_map /etc/postfix/virtual_forwards; do
        [ -f "$m" ] && postmap "$m" 2>/dev/null || true
    done
    postfix reload >/dev/null 2>&1 || systemctl reload postfix >/dev/null 2>&1 || true
    print_success "Postfix maps rebuilt and reloaded."
fi
if [ "${DOVECOT_TOUCHED:-0}" = "1" ]; then
    systemctl reload dovecot >/dev/null 2>&1 || true
    print_success "Dovecot reloaded."
fi
# Only the Jenkins apply prunes, so no console request is running on PHP-FPM
# here for this reload to cut off.
if [ "${FPM_TOUCHED:-0}" = "1" ]; then
    fpm_ver="$(ls -d /etc/php/*/fpm 2>/dev/null | sort -V | tail -1 | cut -d/ -f4)"
    # A reload FPM would reject takes every PHP site down, so ask it first.
    if ! show_spinner_watch_only "Checking the PHP-FPM pools" fpm_test_quiet "$fpm_ver"; then
        print_error "PHP-FPM rejected its pools, so it was NOT reloaded and the removed pools still run."
        print_action "sudo php-fpm${fpm_ver} -t"
        MOVE_FAILED=1
    elif show_spinner_watch_only "Reloading PHP-FPM" systemctl reload "php${fpm_ver}-fpm"; then
        print_success "PHP-FPM reloaded."
    else
        print_error "PHP-FPM did not reload, so the removed pools still run until it does."
        print_action "sudo systemctl reload php${fpm_ver}-fpm"
        MOVE_FAILED=1
    fi
fi
for acct in "${POOL_ACCOUNTS[@]}"; do
    if id "$acct" >/dev/null 2>&1 && ! userdel "$acct" 2>/dev/null; then
        print_error "Could not remove the account $acct, left in place."
        MOVE_FAILED=1
        continue
    fi
    # userdel keeps the group while www-data is in it.
    if getent group "$acct" >/dev/null && ! groupdel "$acct"; then
        print_error "Could not remove the group $acct, left in place."
        MOVE_FAILED=1
        continue
    fi
    print_success "Removed the account $acct"
done

show_spinner_watch_only "Reloading systemd" systemctl daemon-reload
if show_spinner_watch_only "Checking the Apache configuration" apache_configtest_quiet; then
    # Retried because this may be the second reload in a few seconds: the vhost
    # generator reloads before a prune runs. On 2026-08-10 that second one
    # returned "Connection reset by peer" and never reached systemd, so Apache
    # kept serving a vhost the prune had deleted until someone reloaded by hand
    # ten minutes later.
    if ! show_spinner_watch_only "Reloading Apache" systemctl reload apache2; then
        print_action "The reload command failed. Trying once more before believing it."
        sleep 1
        if ! show_spinner_watch_only "Reloading Apache again" systemctl reload apache2; then
            print_error "Apache did not reload, so it is still serving the configuration from before the prune."
            print_info "The files are gone, the running config is not. Look at why:"
            print_action "  sudo systemctl status apache2 --no-pager"
            print_action "  sudo journalctl -u apache2 -n 30 --no-pager"
            print_action "Then reload it again: sudo systemctl reload apache2"
            exit 1
        fi
    fi
else
    print_error "Apache configuration is invalid after pruning, so it was NOT reloaded."
    apache2ctl configtest || true
    exit 1
fi

report_removed_trash

# An orphan left standing is not a successful prune. Without this the job
# reported SUCCESS while two document roots were still being served, which is
# the exact state a prune exists to end.
if [ "${MOVE_FAILED:-0}" = "1" ]; then
    print_error "One or more orphans could not be moved and are still on disk."
    print_action "Look at what is in the way, then run the prune again."
    exit 1
fi

exit 0
