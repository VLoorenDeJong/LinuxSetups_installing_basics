#!/usr/bin/env bash
# =============================================================================
# GitHub, as the verbs repo_host.sh promises. The SERVICE file.
#
# Everything GitHub-shaped lives here: the REST paths, the HTTP codes, the
# field names. A caller sees none of it. Another forge is a sibling of this
# file, `repo_host_forgejo.sh`, and one config value.
#
# The calls go through github_api.sh, which is the transport and owns the auth:
# it derives the owner from the path and mints a token per installation. This
# file adds no credential handling of its own and must never grow any.
#
# WHAT IT DELIBERATELY DOES NOT DO. Creating under a PERSONAL account needs a
# PAT, which github_api.sh does not carry, and handing a token to git for a
# push needs the token itself, which it will never hand out. Both stay in
# provision_repo.sh with their reasons written beside them. An interface that
# pretended to cover them would be lying about what a swap costs.
# =============================================================================

_rh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RH_API=""
for _c in "$_rh_dir/github_api.sh" \
          /usr/local/lib/linuxbasics/hostings/scripts/github_api.sh; do
    [ -f "$_c" ] && { RH_API="$_c"; break; }
done

RH_CRED=""
for _c in "$_rh_dir/git_credential_github_app.sh" \
          /usr/local/lib/linuxbasics/hostings/scripts/git_credential_github_app.sh; do
    [ -f "$_c" ] && { RH_CRED="!bash '$_c'"; break; }
done

# GIT, AUTHENTICATED, without the caller knowing how.
#
# Seven scripts each wrote this three-line wrapper themselves: publish_hostings,
# publish_smb, seed_site_index, seed_app_project, list_repo_branches,
# read_appsettings and add_pipeline_scripts. That is seven places to get
# credential.useHttpPath wrong, and useHttpPath is not cosmetic: without it the
# helper is told the HOST only, so every github.com URL looks the same and a
# submodule under a different owner gets the parent's token.
#
# The token never reaches the argument list. Anything on this machine can read
# /proc/<pid>/cmdline while git runs, so the helper writes it to stdout over a
# pipe and git asks for it.
repo_git() {
    git -c credential.helper= \
        -c credential.helper="$RH_CRED" \
        -c credential.useHttpPath=true \
        "$@"
}

# THE ESCAPE HATCH, and it is narrow on purpose. publish_smb.sh has to run git
# as ANOTHER USER through runuser, so it cannot call repo_git: a shell function
# does not survive into that process. REPO_GIT_CRED is the helper spec on its
# own, for that case and no other.
#
# It is still not a credential: it is the instruction that makes git ask the
# helper, and the helper is what holds the token. Prefer repo_git everywhere
# git runs as this user.
REPO_GIT_CRED="$RH_CRED"

# An SSH remote cannot carry a token. Four callers rewrote git@host:owner/name
# into https://github.com/owner/name with a sed of their own, which is the
# forge's hostname written into a caller by hand.
#
# Printed, never written into .git/config: a machine whose remote is still
# git@ keeps working, and nothing about the clone changes.
repo_https_url() {
    local u="${1:-}"
    case "$u" in
        git@*:*)   printf 'https://github.com/%s' "$(printf '%s' "$u" | sed -E 's#^[^:]+:##')" ;;
        https://*) printf '%s' "$u" ;;
        *)         return 1 ;;
    esac
}

_rh() { SITES_CONF="${SITES_CONF:-}" bash "$RH_API" "$@" 2>/dev/null || true; }
_rh_json() { python3 -c "$1" 2>/dev/null || true; }

repo_host_ready() { [ -n "$RH_API" ]; }

# IS THIS REPOSITORY THERE.
#
#   0   it is
#   1   it is not. The host said so plainly
#   2   could not tell, and "<reason><TAB><the host's own code>" is printed
#
# Three answers and not two, because absent and unreadable look identical from
# a caller's side and creating on top of the second makes a duplicate. The
# reason is a WORD rather than an HTTP code: a caller reasoning about 401 is a
# caller that knows it is talking to a web API.
repo_exists() {
    local code
    code="$(_rh --status GET "/repos/$1/$2")"
    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        401) printf 'denied\t%s' "$code"; return 2 ;;
        403) printf 'forbidden\t%s' "$code"; return 2 ;;
        000) printf 'unreachable\t%s' "$code"; return 2 ;;
        *)   printf 'error\t%s' "$code"; return 2 ;;
    esac
}

# yes or no. Printed rather than returned, because an empty answer and a "no"
# are different things and an exit code cannot say which.
repo_is_private() {
    _rh GET "/repos/$1/$2" \
        | _rh_json 'import json,sys; d=json.load(sys.stdin); print("" if "private" not in d else ("yes" if d["private"] else "no"))'
}

# Prints the HTTPS clone URL. The row is cloned by Jenkins over HTTPS, so an
# ssh_url here produces a row that looks perfect and a deploy that cannot clone.
repo_create() {
    local owner="$1" name="$2" private="$3" description="${4:-}" path body out code
    case "$owner" in "") return 1 ;; esac
    path="/orgs/$owner/repos"
    body="$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"private":sys.argv[2]=="yes","auto_init":False,"description":sys.argv[3]}))' \
            "$name" "$private" "$description")"
    out="$(_rh --with-code POST "$path" "$body")"
    code="$(printf '%s' "$out" | tail -n1)"
    [ "$code" = "201" ] || { printf '%s' "$code"; return 1; }
    printf '%s' "$out" | sed '$d' | _rh_json 'import json,sys; print(json.load(sys.stdin).get("clone_url",""))'
}

repo_delete() {
    local code
    code="$(_rh --status DELETE "/repos/$1/$2")"
    [ "$code" = "204" ] || { printf '%s' "$code"; return 1; }
}

# Archived means readable and frozen. Every forge worth swapping to has it
# (GitLab, Forgejo, Gitea), which is why it earns a verb rather than a raw
# PATCH at the call site: it is the reversible half of repo_delete, and the
# console offers both.
repo_archive() {
    local code
    code="$(_rh --status PATCH "/repos/$1/$2" '{"archived":true}')"
    [ "$code" = "200" ] || { printf '%s' "$code"; return 1; }
}

repo_set_private() {
    local want=false
    [ "$3" = "yes" ] && want=true
    _rh PATCH "/repos/$1/$2" "{\"private\":$want}" >/dev/null
}

repo_default_branch() {
    _rh GET "/repos/$1/$2" | _rh_json 'import json,sys; print(json.load(sys.stdin).get("default_branch","") or "")'
}

repo_set_default_branch() {
    _rh PATCH "/repos/$1/$2" \
        "$(python3 -c 'import json,sys; print(json.dumps({"default_branch":sys.argv[1]}))' "$3")" >/dev/null
}

repo_branches() {
    _rh GET "/repos/$1/$2/branches?per_page=100" \
        | _rh_json 'import json,sys; [print(b.get("name","")) for b in json.load(sys.stdin)]'
}

repo_branch_sha() {
    _rh GET "/repos/$1/$2/git/ref/heads/$3" \
        | _rh_json 'import json,sys; print(json.load(sys.stdin).get("object",{}).get("sha",""))'
}

repo_create_branch() {
    _rh POST "/repos/$1/$2/git/refs" \
        "$(python3 -c 'import json,sys; print(json.dumps({"ref":"refs/heads/"+sys.argv[1],"sha":sys.argv[2]}))' "$3" "$4")" >/dev/null
}

repo_delete_branch() {
    local code
    code="$(_rh --status DELETE "/repos/$1/$2/git/refs/heads/$3")"
    [ "$code" = "204" ] || { printf '%s' "$code"; return 1; }
}

repo_clone_url() { printf 'https://github.com/%s/%s.git' "$1" "$2"; }

# Every repository this account's installation can see, "owner/name" per line.
#
# --paged prints one BODY per page and GitHub pretty-prints them, so the pages
# arrive as several concatenated JSON objects spread over many lines. raw_decode
# walks them; a line-at-a-time parser silently found nothing, which reads as
# "the account has no repositories".
repo_list() {
    _rh --owner "$1" --paged GET /installation/repositories | _rh_json '
import json, sys
text = sys.stdin.read()
dec = json.JSONDecoder()
i, n = 0, len(text)
while i < n:
    while i < n and text[i].isspace():
        i += 1
    if i >= n:
        break
    try:
        obj, i = dec.raw_decode(text, i)
    except ValueError:
        break
    for r in obj.get("repositories", []):
        print(r.get("full_name", ""))'
}
