#!/usr/bin/env bash
set -e

. "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }

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
# A trace prints the secrets this reads, so only a caller who could read them
# anyway gets one: root, or the sudo group. The console passes -d via a * grant.
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# The tail of a Jenkins job's console output, for the hosting manager.
#
# A job that fails leaves the page saying only that it failed. This is what it
# says instead. Read only: it starts nothing and changes nothing.
#
# The token is 0600 root, this runs as root through sudo, and what comes back is
# plain text with the Jenkins log's own formatting stripped of ANSI colour.
#
# Only the jobs the page can start are readable, by key, and the key is matched
# against a fixed list. A job path is never taken from the caller: an argument
# that reached the URL would let anyone with the page read any job on the
# machine, including ones holding credentials in their output.
#
# Usage:
#   sudo ./jenkins_job_log.sh hosting-apply [lines]
#
# lines defaults to 120 and is capped at 400: this is for reading in a dialog,
# not for archiving.
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

MANAGER_HOME="/var/lib/hosting-manager"
TOKEN_FILE="${MANAGER_HOME}/jenkins-token"
# THE PORT COMES FROM THE JENKINS ROW, not from a number repeated here. Six
# scripts held `http://127.0.0.1:11002` as a literal while add_jenkins.sh
# derived it from the config, so moving the port in hostings.conf would have
# moved Jenkins and left every one of these dialling the old one. The symptom
# would be "Jenkins is not answering" with the config saying otherwise.
#
# Same awk as add_jenkins.sh:1031, deliberately duplicated rather than sourced:
# each script here has to run alone on a machine that has only this file.
#
# 11002 stays as the fallback, so a machine whose config cannot be read behaves
# exactly as it did before.
JENKINS_PORT="$(grep -v '^[[:space:]]*#' "${SITES_CONF:-$(conf_active /etc/hostings)}" 2>/dev/null | grep '|' \
    | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$3); if ($2=="jenkins") print $3}' | head -1)"
JENKINS_URL="http://127.0.0.1:${JENKINS_PORT:-11002}"

# Same list as jenkins_job_status.sh, and for the same reason: the page may read
# what it may start, and nothing else.
JOBS=("hosting-apply:machine/apply-config" "machine-update:machine/update-packages")

JOB_KEY="${1:-}"
LINES="${2:-120}"

# --busy: what Jenkins is running and what is queued, as JSON. For the apply
# dialog, which otherwise shows an empty log while its job waits for an executor.
if [ "$JOB_KEY" = "--busy" ]; then
    [ -s "$TOKEN_FILE" ] || { echo "No Jenkins token on this machine." >&2; exit 1; }
    AUTH="$(head -n1 "$TOKEN_FILE")"
    comp="$(curl -fsS -g --max-time 8 -u "$AUTH" \
        "${JENKINS_URL}/computer/api/json?tree=computer[executors[currentExecutable[fullDisplayName,timestamp]]]" 2>/dev/null)" || exit 1
    queue="$(curl -fsS -g --max-time 8 -u "$AUTH" \
        "${JENKINS_URL}/queue/api/json?tree=items[task[name,url],why,inQueueSince]" 2>/dev/null)" || exit 1
    # A queued task's name is the leaf ("deploy-live"), which says nothing about
    # which row waits. The url carries the folder, so the name is built from it.
    jq -cn --argjson c "$comp" --argjson q "$queue" '{
        running: [$c.computer[].executors[].currentExecutable | select(. != null)
                  | {name: (.fullDisplayName | sub("^part of "; "")),
                     since: .timestamp}],
        queued:  [$q.items[] | . as $it | {
            name: ((($it.task.url // "") | sub("^[a-z]+://[^/]+"; "") | split("/")
                    | map(select(. != "" and . != "job"))
                    | (. as $p | ($p | map(test("^[0-9]+$")) | index(true)) as $n
                       | if $n then $p[0:$n] else $p end)
                    | join(" » ")) as $name
                   | if $name == "" then ($it.task.name // "a job") else $name end),
            why: .why, since: .inQueueSince }]
    }'
    exit 0
fi

case "$LINES" in
    ''|*[!0-9]*) LINES=120 ;;
esac
[ "$LINES" -gt 400 ] && LINES=400
[ "$LINES" -lt 1 ] && LINES=120

JOB_PATH=""
for entry in "${JOBS[@]}"; do
    [ "${entry%%:*}" = "$JOB_KEY" ] && JOB_PATH="${entry#*:}"
done

# A row's own deploy console, for the rerun button added 2026-09-10. Bounded the
# same two ways trigger_site_job.sh bounds starting one, and for the same reason:
# the page may read exactly what it may start. The row has to be in the config
# and the environment has to be one the config declares, so neither half of the
# path can be invented by whoever calls this.
if [ -z "$JOB_PATH" ]; then
    case "$JOB_KEY" in
        */deploy-*)
            _row="${JOB_KEY%%/*}"
            _env="${JOB_KEY##*/deploy-}"
            _conf="${SITES_CONF:-$(conf_active /etc/hostings)}"
            _envs="$(grep -E '^[[:space:]]*ENVS[[:space:]]*=' "$_conf" 2>/dev/null \
                     | head -1 | cut -d= -f2- | tr -d ' \r' | tr ',' ' ')"
            case " ${_envs:-live test accept skunk} " in
                *" $_env "*) ;;
                *) echo "'$_env' is not an environment in the config." >&2; exit 1 ;;
            esac
            if awk -F'|' -v n="$_row" '
                    /^[[:space:]]*#/ { next }
                    NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                             if ($2 == n) found = 1 }
                    END { exit !found }' "$_conf" 2>/dev/null; then
                JOB_PATH="${_row}/deploy-${_env}"
            else
                echo "'$_row' is not a row in the published config." >&2
                exit 1
            fi
            ;;
    esac
fi

if [ -z "$JOB_PATH" ]; then
    echo "Unknown job. This reads '${JOBS[0]%%:*}', '${JOBS[1]%%:*}' and <row>/deploy-<env> only." >&2
    exit 1
fi

if [ ! -s "$TOKEN_FILE" ]; then
    echo "No Jenkins token on this machine, so the log cannot be read." >&2
    exit 1
fi

AUTH="$(head -n1 "$TOKEN_FILE")"
job_url="job/${JOB_PATH//\//\/job\/}"

log="$(curl -fsS --max-time 10 -u "$AUTH" \
    "${JENKINS_URL}/${job_url}/lastBuild/consoleText" 2>/dev/null || true)"

if [ -z "$log" ]; then
    echo "Jenkins returned no console output for ${JOB_KEY}. The job may never have run." >&2
    exit 1
fi

# The escape codes are what a terminal draws colour with. In a browser they are
# literal rubbish in the middle of the sentence you are trying to read.
printf '%s\n' "$log" \
    | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//' \
    | tail -n "$LINES"
exit 0
