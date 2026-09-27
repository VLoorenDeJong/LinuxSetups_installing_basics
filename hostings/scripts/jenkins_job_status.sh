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
# Say whether the jobs the hosting manager can start are running.
#
# The page has no way to know a job has finished: starting one is a POST that
# returns immediately, so the button comes back while the work is still going
# and can be pressed again. This is what it asks instead.
#
# READ ONLY. It starts nothing, and it holds no credential the page can see:
# the token is 0600 root, this runs as root through sudo, and what comes back is
# two booleans per job.
#
# Output is JSON on stdout, so the page can read it without parsing prose:
#
#   {"jobs":{"hosting-apply":{"running":false,"queued":false,"result":"SUCCESS","number":42},
#            "machine-update":{"running":true,"queued":false,"result":null,"number":7}}}
#
# A job Jenkins has never built reports running false and result null, which is
# also what a job that does not exist reports. The page treats both the same
# way: nothing is running, so the button is live.
#
# Usage:
#   sudo ./jenkins_job_status.sh
# =============================================================================

# No print_* helpers here: everything this writes to stdout is JSON, and a
# coloured status line in the middle of it would break the only caller.

if [ "$EUID" -ne 0 ]; then
    echo '{"error":"must run as root"}'
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

# The jobs this page can start, and only those. A status call is not a reason to
# hand the page a view of every job on the machine.
#
# Each entry is "key:path". The KEY is what the page already uses in its
# data-job attributes and is deliberately unchanged; the PATH is where the job
# now lives, since they moved into folders. Jenkins spells a folder in a URL as
# another /job/ segment.
JOBS=("hosting-apply:machine/apply-config" "machine-update:machine/update-packages")

if [ ! -s "$TOKEN_FILE" ]; then
    echo '{"error":"no token"}'
    exit 1
fi

AUTH="$(head -n1 "$TOKEN_FILE")"

# -----------------------------------------------------------------------------
# --history <row> <env>: the last 20 builds of one deploy job.
#
# The owner, 2026-09-10: "so I get an idea what to expect and if it goes fast or
# slow". An average alone hides the shape, and a list alone makes you do the
# arithmetic, so this returns both.
#
# Bounded exactly as trigger_site_job.sh bounds starting a job and
# jenkins_job_log.sh bounds reading one: the row must be in the published config
# and the environment must be one ENVS declares. Neither half of the path can be
# invented by the caller.
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--history" ] || [ "${1:-}" = "--stages" ]; then
    h_mode="${1}"
    h_row="${2:-}"
    h_env="${3:-}"
    h_conf="${SITES_CONF:-$(conf_active /etc/hostings)}"
    h_envs="$(grep -E '^[[:space:]]*ENVS[[:space:]]*=' "$h_conf" 2>/dev/null \
              | head -1 | cut -d= -f2- | tr -d ' \r' | tr ',' ' ')"
    case " ${h_envs:-live test accept skunk} " in
        *" $h_env "*) ;;
        *) echo '{"error":"not an environment"}'; exit 1 ;;
    esac
    if ! awk -F'|' -v n="$h_row" '
            /^[[:space:]]*#/ { next }
            NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                     if ($2 == n) found = 1 }
            END { exit !found }' "$h_conf" 2>/dev/null; then
        echo '{"error":"not a row"}'
        exit 1
    fi

    # --stages: which stage the last build is on, what each one concluded and
    # how long it took. From pipeline-stage-view's wfapi, which is in
    # jenkins/plugins.txt so a fresh flash has it too.
    #
    # A raw console is a thousand lines saying where a build got to in about six
    # words. This is those six words.
    if [ "$h_mode" = "--stages" ]; then
        s_json="$(curl -fsS --max-time 8 -u "$AUTH" \
            "${JENKINS_URL}/job/${h_row}/job/deploy-${h_env}/lastBuild/wfapi/describe" \
            2>/dev/null || true)"
        if [ -z "$s_json" ] || ! command -v python3 >/dev/null 2>&1; then
            echo '{"stages":[]}'
            exit 0
        fi
        printf '%s' "$s_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(json.dumps({"stages": []})); sys.exit(0)
print(json.dumps({
    "number": d.get("id"),
    "status": d.get("status"),
    "duration": d.get("durationMillis"),
    "stages": [{"name": s.get("name"),
                "status": s.get("status"),
                "duration": s.get("durationMillis")}
               for s in d.get("stages", [])],
}))
' 2>/dev/null || echo '{"stages":[]}'
        exit 0
    fi

    # {0,20} is Jenkins' own range syntax on the tree expression, so it returns
    # twenty builds rather than every build ever and a page that has to trim.
    h_json="$(curl -fsS -g --max-time 8 -u "$AUTH" \
        "${JENKINS_URL}/job/${h_row}/job/deploy-${h_env}/api/json?tree=builds%5Bnumber,timestamp,duration,result%5D%7B0,20%7D" \
        2>/dev/null || true)"
    if [ -z "$h_json" ] || ! command -v python3 >/dev/null 2>&1; then
        echo '{"builds":[],"average":null}'
        exit 0
    fi
    printf '%s' "$h_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(json.dumps({"builds": [], "average": None})); sys.exit(0)

builds = []
for b in data.get("builds", []):
    builds.append({
        "number": b.get("number"),
        "started": b.get("timestamp"),
        "duration": b.get("duration"),
        "result": b.get("result"),
    })

# THE AVERAGE IS OVER SUCCESSFUL BUILDS, when there are any. The owner asked for
# that on 2026-09-10, and he is right about what the number is FOR: it answers
# "how long should a real deploy take", and a run that found nothing to do did
# not do the work.
#
# The argument for keeping NOT_BUILT in, which is why it used to be: on this
# machine most deploys find nothing changed and still spend 40 to 55 seconds
# checking out and comparing, so their length IS the usual wait. It loses to a
# harder fact: a job whose last 20 runs are all NOT_BUILT then has no average
# at all, which was measured on progress-app, 17 of 20.
#
# So: successful builds first, and every finished build as the fallback. avgOf
# says which, so the page can label it rather than implying one and showing the
# other. ABORTED and a build still going are in neither: neither ran its own
# length.
wins = [b["duration"] for b in builds if b["result"] == "SUCCESS" and b["duration"]]
# UNSTABLE counts as failed here: the build ran and did not come out clean,
# which is the case this number is being read for. NOT_BUILT is neither: it
# concluded there was nothing to do.
fails = [b["duration"] for b in builds
         if b["result"] in ("FAILURE", "UNSTABLE") and b["duration"]]
done = [b["duration"] for b in builds
        if b["result"] not in (None, "ABORTED") and b["duration"]]
pool, kind = (wins, "success") if wins else (done, "finished")
avg = int(sum(pool) / len(pool)) if pool else None
# One number per question: how long a real deploy takes, how long a broken one
# takes before it gives up, and how long any finished run takes.
avg_wins = int(sum(wins) / len(wins)) if wins else None
avg_fail = int(sum(fails) / len(fails)) if fails else None
avg_done = int(sum(done) / len(done)) if done else None
print(json.dumps({"builds": builds, "average": avg, "counted": len(pool),
                  "avgOf": kind, "finished": len(done), "wins": len(wins),
                  "fails": len(fails),
                  "avgWins": avg_wins, "avgFail": avg_fail, "avgDone": avg_done}))
' 2>/dev/null || echo '{"builds":[],"average":null}'
    exit 0
fi

out=""
for entry in "${JOBS[@]}"; do
    job="${entry%%:*}"
    _p="${entry#*:}"
    job_path="job/${_p//\//\/job\/}"

    state="$(curl -fsS --max-time 5 -u "$AUTH" \
        "${JENKINS_URL}/${job_path}/api/json?tree=inQueue,lastBuild%5Bnumber,building,result%5D" \
        2>/dev/null || true)"

    running=false
    queued=false
    result=null
    number=null

    case "$state" in
        *'"building":true'*) running=true ;;
    esac
    case "$state" in
        *'"inQueue":true'*)  queued=true ;;
    esac

    # Deliberately not jq: two booleans and a word out of a known response is
    # not worth a dependency the page's own path then relies on.
    r="$(printf '%s' "$state" | sed -n 's/.*"result" *: *"\([A-Z_]*\)".*/\1/p')"
    [ -n "$r" ] && result="\"$r\""

    # The build number, so the page can tell "my job has not started yet" from
    # "my job is over". Without it an idle answer means both.
    n="$(printf '%s' "$state" | sed -n 's/.*"number" *: *\([0-9]\{1,\}\).*/\1/p')"
    [ -n "$n" ] && number="$n"

    [ -n "$out" ] && out="${out},"
    out="${out}\"${job}\":{\"running\":${running},\"queued\":${queued},\"result\":${result},\"number\":${number}}"
done

# -----------------------------------------------------------------------------
# Every site folder, in ONE request.
#
# The page polls this every few seconds while something runs, and there are
# eleven folders with four or five jobs each. Asking per job would be fifty
# round trips per poll, each with its own timeout, on a Pi. Jenkins can return
# the whole tree at once, so it does.
#
# Parsed with python3 rather than sed: this response is nested, and picking
# nested JSON apart with a regex is how a status call starts lying. python3 is
# already a dependency of provision_repo.sh, so it is not a new one. If it is
# missing the sites object comes back empty and the page simply shows no status,
# which is the same as not knowing.
# -----------------------------------------------------------------------------
sites="{}"
tree='jobs[name,jobs[name,color,inQueue,lastBuild[number,building,result,timestamp,duration,estimatedDuration],builds[number,result,timestamp,duration]{0,5}]]'
# -g, and it is the whole reason this ever returned anything. curl reads [ and
# ] as its own globbing syntax, so the unencoded tree expression was rejected
# before a request was made: "curl: (3) bad range in URL position 43". stderr
# went to /dev/null and || true swallowed the exit code, so `sites` was silently
# {} on every call since this block was written, and the page showed no build
# result for any row. Measured 2026-09-09.
all="$(curl -fsS -g --max-time 8 -u "$AUTH" \
    "${JENKINS_URL}/api/json?tree=${tree}" 2>/dev/null || true)"

if [ -n "$all" ] && command -v python3 >/dev/null 2>&1; then
    sites="$(printf '%s' "$all" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("{}"); sys.exit(0)

out = {}
for folder in data.get("jobs", []):
    children = folder.get("jobs")
    # A folder has children; a plain job does not. machine and csharp are
    # folders too, and are skipped: the page asks about sites here.
    if not children or folder.get("name") in ("machine", "csharp"):
        continue
    running = False
    worst = None
    # Per job as well as per folder, added 2026-09-10 for the rerun button: one
    # button per environment needs to know whether THAT environment is building,
    # and a folder-wide "running" would grey all four while one of them runs.
    # Same request, so it costs nothing extra.
    per = {}
    for job in children:
        jrunning = bool(job.get("inQueue") or (job.get("lastBuild") or {}).get("building"))
        if jrunning:
            running = True
        # The last five, oldest last, for the dot strip in the row. Same
        # request again: the tree expression asks for builds{0,5} beside
        # lastBuild, so a page of eleven folders still costs one round trip.
        recent = [{"number": b.get("number"),
                   "result": b.get("result"),
                   "started": b.get("timestamp"),
                   "duration": b.get("duration")}
                  for b in (job.get("builds") or [])]
        lb = job.get("lastBuild") or {}
        r = lb.get("result")
        # When it started and how long it took, which the owner asked for by name
        # twice on 2026-09-10. Both come from the same request, so they are free.
        #
        # duration is 0 WHILE A BUILD RUNS: Jenkins fills it in at the end. The
        # page works the elapsed time out from timestamp itself rather than
        # showing a running build as having taken no time at all.
        per[job.get("name")] = {
            "running": jrunning,
            "result": r,
            "number": lb.get("number"),
            "started": lb.get("timestamp"),
            "duration": lb.get("duration"),
            "estimated": lb.get("estimatedDuration"),
            "recent": recent,
        }
        # FAILURE outranks UNSTABLE outranks SUCCESS, so one red job shows red
        # for the site rather than being hidden by four green ones.
        if r == "FAILURE" or (r == "UNSTABLE" and worst != "FAILURE"):
            worst = r
        elif r and worst is None:
            worst = r
    out[folder["name"]] = {"running": running, "result": worst, "jobs": per}
print(json.dumps(out))
' 2>/dev/null || echo "{}")"
fi
[ -z "$sites" ] && sites="{}"

# -----------------------------------------------------------------------------
# Pending operating system updates, so the page can hide a button that has
# nothing to do.
#
# apt-check reads the package lists apt already refreshed on its own timer, so
# this costs milliseconds and never touches the network. The count is therefore
# as fresh as the last apt update, not as fresh as this second, and that is the
# right trade for something polled from a web page.
#
# known:false when apt-check is not installed. The page shows the button in that
# case: an unknown count must never hide the only way to start an update.
# -----------------------------------------------------------------------------
APT_CHECK="/usr/lib/update-notifier/apt-check"
updates='{"known":false,"count":0,"security":0}'

if [ -x "$APT_CHECK" ]; then
    # It writes "3;1" to stderr, not stdout, and has done for its whole life.
    counts="$("$APT_CHECK" 2>&1 || true)"
    case "$counts" in
        [0-9]*';'[0-9]*)
            updates="{\"known\":true,\"count\":${counts%%;*},\"security\":${counts##*;}}"
            ;;
    esac
fi

# An update that needs a reboot leaves this file; the page swaps its button.
reboot=false
[ -f /var/run/reboot-required ] && reboot=true
updates="${updates%\}},\"reboot\":${reboot}}"

printf '{"jobs":{%s},"sites":%s,"updates":%s}\n' "$out" "$sites" "$updates"
exit 0
