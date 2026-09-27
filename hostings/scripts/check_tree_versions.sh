#!/bin/bash
# =============================================================================
# Which commit is each copy of this repository on the machine actually running?
#
# One question, one script. Written 2026-08-27, after the console clone and the
# pipeline tree were found four commits behind with nothing anywhere saying so.
# They had silently missed a whole session's work, and the only reason it came
# to light was somebody deploying a fix by hand and looking.
#
# The machine holds the repository more than once, and each copy is refreshed by
# a different thing:
#
#   the working clone     a human running git pull
#   the console clone     publish_hostings.sh, on every publish
#   the pipeline tree     add_pipeline_scripts.sh, when somebody remembers
#
# The last one is the trap. It is the tree the sudo'd scripts and every
# Jenkinsfile read, so a change that has not reached it has not taken effect,
# whatever the workspace checkout in the build log says.
#
#   CURRENT     the tree is on the branch tip and holds what the others hold
#   STALE       it holds different content from the reference tree
#   BEHIND      the branch has moved and this tree has not
#   AHEAD       the tree has commits the branch does not (somebody edited in place)
#   DIRTY       tracked files differ from the commit, so the tree is not the commit
#   UNKNOWN     there is no fetched origin ref to compare against
#   UNREADABLE  git could not read this tree, so it was not compared at all
#
# Trees are compared to each other by CONTENT, not by commit SHA. An amended or
# cherry-picked commit holding identical code is not a difference; an edit made
# in place on the right SHA is one, and a SHA cannot see it.
#
# It reads and reports. It never fetches, pulls, resets or writes anything, so
# it is safe to run at any moment, including from a page.
#
# Usage:
#   ./check_tree_versions.sh              print the report
#   TREES_OUT=/tmp/t ./check_tree_versions.sh   also write it machine-readable
#
# TREES_OUT gets one line per tree,
# "STATE PATH SHORTSHA BEHIND AHEAD NEWEST|OLDER CONTENT UNTRACKED", no colour
# and no totals, for a caller that has to act on it rather than read it.
#
# The line is POSITIONAL and only ever grows at the END. A reader must name a
# variable per field it wants: bash gives the last variable in a `read` every
# remaining field, so a caller reading six of eight silently collects the last
# two into its sixth.
#
# Exits 0 whether or not a tree is behind. Being behind is a fact, not a
# failure: this script's whole job is to say so out loud.
# =============================================================================

set -e

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

# The busy indicator. Kill-safe work only: this reads and hashes, it writes
# nothing, so a kill at any frame loses nothing.
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPIN_PID=""
spinner_start() {
    [ "${DEBUG_MODE:-0}" = "1" ] && return 0
    local message="$1"
    (
        local i=0
        while true; do
            printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[i % 10]}" "$message"
            i=$((i + 1))
            sleep 0.2
        done
    ) &
    _SPIN_PID=$!
}
spinner_stop() {
    [ -n "$_SPIN_PID" ] || return 0
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf '\r\033[K'
}

TREES_OUT="${TREES_OUT:-}"

# What a tree HOLDS, as one short hash, rather than which commit it says it is
# on. Two trees match when this matches.
#
# A commit SHA answers the wrong question. A tree edited in place is on the
# right commit and running different code; a tree rebuilt from an amended or
# cherry-picked commit is on a different commit and running identical code.
# Both were reported wrongly before this existed.
#
# THE FINGERPRINT IS THE FILES ON DISK, not the commit plus a diff. The first
# version hashed `HEAD^{tree}` together with `git diff HEAD`, and that gives
# two answers for one piece of code: content sitting uncommitted hashes one
# way, the identical content committed hashes another. A tree that had just
# committed what another tree still held loose reported as differing, which is
# the exact false STALE the content comparison exists to remove.
#
# Nothing is written to any object store. `git hash-object` computes and
# prints; it does not store without `-w`. That matters because this script is
# read-only by contract and is run against a root-owned pipeline tree by a
# page. It is also why gstack's write-tree approach is not usable here.
#
# A file nothing has touched is not read at all: the index already holds its
# hash, and git diff-files says which files that is not true of. Reading all
# 1548 cost 3 seconds a tree; so did walking them in bash. Both are gone.
#
# What is deliberately NOT in the hash:
#
#   the file MODE      this repository records 100755 on files committed from
#                      Windows and the installer sets sane modes, so 39 files
#                      would differ forever
#   a submodule's own  out of scope here exactly as it is for the DIRTY test.
#   working tree       The recorded gitlink IS hashed, so moving a submodule
#                      pointer moves the fingerprint
#
# hash-object applies the same clean filters git itself would, so two trees
# holding the same logical file agree even if one was checked out with
# different line endings.
#
# A tracked path that is not a regular file on disk hashes as `gone`, so a
# deletion moves the fingerprint instead of being invisible.
#
# A git failure must never become a hash. The pipeline tree is root-owned and
# this runs from a page, so "dubious ownership" is the expected failure, and a
# tree nobody can read must not be reported as a tree that merely differs.
# The function prints nothing and returns 1 in that case.
tree_content_hash() {
    local p="$1"
    local changed lines need vals line path
    local -a want=() out=()

    # Which tracked files differ from the index, answered from git's stat cache
    # rather than by reading them. The index already holds the right hash for
    # every file nothing has touched, so the usual run reads nothing off disk.
    #
    # core.fileMode=false or the 39 files this repository records as 100755
    # would be listed on every run and read for nothing.
    changed="$(git -C "$p" -c core.fileMode=false diff-files --name-only 2>/dev/null)" || return 1

    # ONE awk over the index rather than a bash loop over it. The loop was
    # measured at 2002ms per tree on the machine, 2026-09-12, of which only
    # about 100ms was git: bash walking 1548 entries was the whole cost.
    #
    # Paths are git's own output, quoted where a path needs it, and
    # hash-object --stdin-paths unquotes exactly the same way. So the quoting
    # round-trips and no filename has to be special-cased.
    #
    # A line ending in ":" is one that still needs reading off disk. Nothing
    # else can end that way: every other line carries a 40 character hash.
    lines="$(git -C "$p" ls-files -s 2>/dev/null | awk -v ch="$changed" '
        BEGIN { n = split(ch, c, "\n"); for (i = 1; i <= n; i++) if (c[i] != "") CH[c[i]] = 1 }
        { t = index($0, "\t"); path = substr($0, t + 1)
          # A submodule contributes its recorded pointer. Its own working tree
          # is out of scope here exactly as it is for the DIRTY test.
          if ($1 == "160000" || !(path in CH)) print path ":" $2
          else print path ":" }')"
    [ -n "$lines" ] || return 1

    need="$(printf '%s\n' "$lines" | awk '/:$/ { sub(/:$/, ""); print }')"

    # Only the files that actually changed reach here, so this loop is empty on
    # a clean tree and a handful long on a dirty one.
    if [ -n "$need" ]; then
        vals=""
        while IFS= read -r path; do
            if [ "${path:0:1}" = '"' ]; then
                # git quoted it, so it holds a newline, a quote or a control
                # character. hash-object --stdin-paths would unquote it back
                # correctly, but [ -f ] cannot test it, so it is named rather
                # than guessed at.
                vals+="unhashable"$'\n'
            elif [ -f "$p/$path" ]; then
                want+=("$path")
                vals+=$'\n'
            else
                vals+="gone"$'\n'
            fi
        done <<< "$need"

        if [ "${#want[@]}" -gt 0 ]; then
            local hashed
            hashed="$(printf '%s\n' "${want[@]}" \
                | git -C "$p" hash-object --stdin-paths 2>/dev/null)" || return 1
            # One hash per path or the pairing is wrong, and a wrong pairing is
            # a hash that looks fine and means nothing.
            [ "$(printf '%s\n' "$hashed" | wc -l)" -eq "${#want[@]}" ] || return 1
            vals="$(printf '%s' "$vals" | awk -v h="$hashed" '
                BEGIN { n = split(h, H, "\n"); i = 0 }
                { if ($0 == "") { i++; print H[i] } else print }')"
        fi

        lines="$(printf '%s\n' "$lines" | awk -v v="$vals" '
            BEGIN { n = split(v, V, "\n"); i = 0 }
            /:$/ { i++; print $0 V[i]; next }
            { print }')"
    fi

    printf '%s\n' "$lines" | sha256sum | cut -c1-12
}

# The trees this machine is known to hold, and who refreshes each one. A path
# that does not exist is skipped in silence: not every machine has all three,
# and a box without Jenkins has no pipeline tree to be behind.
#
# Deliberately a list here rather than a config key. It is a property of how the
# machine is built, not of what it hosts, and hostings.conf is the second.
TREES=()
# The working clone: any git clone in a home directory that holds a config.
for _clone in /home/*/*/; do
    _clone="${_clone%/}"
    [ -d "$_clone/.git" ] && [ -d "$_clone/backup_config" ] && TREES+=("$_clone|working clone|git pull")
done
TREES+=(
    "/usr/local/lib/linuxbasics|pipeline tree|add_pipeline_scripts.sh"
)

BEHIND_LIST=()
DIRTY_LIST=()
UNREADABLE_LIST=()
ROWS=()
CHECKED=0

# The trees are read before anything is printed, and fingerprinting three of
# them takes a second or two. Silence that long over SSH reads as stuck. The
# report below is the line that outlives the spinner.
spinner_start "Reading the repository trees..."
for entry in "${TREES[@]}"; do
    IFS='|' read -r path label refresher <<< "$entry"

    [ -d "$path/.git" ] || continue
    CHECKED=$((CHECKED + 1))

    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    head="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    full="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo unknown)"
    when="$(git -C "$path" log -1 --format=%ct HEAD 2>/dev/null || echo 0)"

    # Against the remote-tracking ref as it was last fetched, which can only
    # understate how far behind a tree is. That is not good enough on its own:
    # a tree nobody fetches reports CURRENT forever, and the pipeline tree is
    # exactly that. The trees are compared to each other below, which needs no
    # network and catches the case this script was written for.
    upstream="origin/$branch"
    if git -C "$path" rev-parse --verify --quiet "$upstream" >/dev/null 2>&1; then
        behind="$(git -C "$path" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)"
        ahead="$(git -C "$path" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)"
    else
        behind=0
        ahead=0
        upstream=""
    fi

    # DIRTY is a different question from the fingerprint and keeps its own
    # test: does this tree hold anything that is in no commit? Content only,
    # because this repository records 100755 on files committed from Windows
    # and the installer sets sane modes on the machine, so a mode test would
    # cry wolf on 39 files on every single run. Submodule working trees are
    # ignored for the same reason.
    dirty=0
    readable=1
    content=""
    untracked=0
    if ! git -C "$path" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        readable=0
    else
        diff_text="$(git -C "$path" -c core.fileMode=false diff HEAD --ignore-submodules=dirty 2>/dev/null || true)"
        [ -z "$diff_text" ] || dirty=1

        # The fingerprint. A tree git cannot read gets no hash at all rather
        # than a hash of nothing, which would read as "differs" instead of
        # "could not be compared".
        content="$(tree_content_hash "$path")" || content=""
        [ -n "$content" ] || readable=0

        # Files present and in no commit. Reported, never escalated: the working
        # clone legitimately carries session notes that are not committed yet,
        # so a yellow line here would fire on every single run. It is cyan
        # because it is worth knowing and is not always wrong.
        #
        # -z and counting NULs, because a filename may contain a newline and
        # wc -l would count that file twice.
        untracked="$(git -C "$path" ls-files --others --exclude-standard -z 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ')"
        [ -n "$untracked" ] || untracked=0
    fi

    if [ "$readable" = "0" ]; then
        state="UNREADABLE"
        UNREADABLE_LIST+=("$path|$label")
    elif [ "$dirty" = "1" ]; then
        state="DIRTY"
        DIRTY_LIST+=("$path")
    elif [ -z "$upstream" ]; then
        state="UNKNOWN"
    elif [ "$behind" -gt 0 ]; then
        state="BEHIND"
        BEHIND_LIST+=("$path|$label|$refresher|$behind")
    elif [ "$ahead" -gt 0 ]; then
        state="AHEAD"
    else
        state="CURRENT"
    fi

    ROWS+=("$state|$path|$label|$head|$branch|$behind|$ahead|$full|$when|$refresher|$content|$untracked|$dirty")
done
spinner_stop

# -----------------------------------------------------------------------------
# The trees against each other.
#
# This is the check that would have caught the real thing. On 2026-08-27 the
# console clone and the pipeline tree sat four commits behind the working clone
# and every one of them reported CURRENT, because a tree nobody fetches has a
# remote-tracking ref that is exactly as stale as the tree.
#
# Comparing the trees to each other needs no network and cannot go stale: if one
# copy of the repository on this machine is newer than another, somebody is
# running old code, whatever any origin ref says.
# -----------------------------------------------------------------------------
#
# A DIRTY tree can never be the reference, whatever its commit date. Its content
# hash carries an edit that is in no commit, so electing it sends the operator
# to refresh two CORRECT trees from the one that is wrong. Unreadable trees are
# out for the same reason: they have no content to compare against.
#
# Two passes, so "all three are dirty" still gets a reference rather than none.
NEWEST_TS=0
NEWEST_CONTENT=""
NEWEST_PATH=""
for pass in clean any; do
    [ -n "$NEWEST_CONTENT" ] && break
    for row in "${ROWS[@]}"; do
        IFS='|' read -r state path label head branch behind ahead full when refresher content untracked dirty <<< "$row"
        [ -n "$content" ] || continue
        [ "$pass" = "clean" ] && [ "$dirty" = "1" ] && continue
        [ "$when" -gt "$NEWEST_TS" ] 2>/dev/null || continue
        NEWEST_TS="$when"
        NEWEST_CONTENT="$content"
        NEWEST_PATH="$path"
    done
done

# The content-differs upgrade happens HERE, once, and is written back into the
# row. It used to happen in the display loop only, so TREES_OUT wrote CURRENT
# for a tree the report printed as STALE and a caller reading field 1 was told
# the opposite of what the operator was reading on screen.
STALE_LIST=()
UPGRADED=()
for row in "${ROWS[@]}"; do
    IFS='|' read -r state path label head branch behind ahead full when refresher content untracked dirty <<< "$row"
    # By content, not by commit. A tree rebuilt from an amended commit holds
    # identical code and is not stale; a tree on the right commit with an edit
    # in place is stale and its SHA says otherwise.
    if [ -n "$content" ] && [ -n "$NEWEST_CONTENT" ] && [ "$content" != "$NEWEST_CONTENT" ]; then
        # A tree older than another tree is not current, whatever its own stale
        # origin ref believes. Say so in the state, not only in a trailing note:
        # green text with a warning arrow after it reads as green.
        [ "$state" = "CURRENT" ] && state="STALE"
        [ "$full" = "unknown" ] || STALE_LIST+=("$path|$label|$refresher|$head")
    fi
    UPGRADED+=("$state|$path|$label|$head|$branch|$behind|$ahead|$full|$when|$refresher|$content|$untracked|$dirty")
done
ROWS=("${UPGRADED[@]}")

# =============================================================================
# Report
# =============================================================================
print_header "Repository trees on this machine"

if [ "$CHECKED" = "0" ]; then
    print_info "No repository tree found at any known path, so nothing was checked."
    exit 0
fi

for row in "${ROWS[@]}"; do
    IFS='|' read -r state path label head branch behind ahead full when refresher content untracked dirty <<< "$row"
    mark=""
    # The state was already upgraded above; this only adds the pointer at
    # which tree it differs from.
    [ -n "$content" ] && [ -n "$NEWEST_CONTENT" ] && [ "$content" != "$NEWEST_CONTENT" ] \
        && mark="  <- DIFFERS FROM $NEWEST_PATH"
    case "$state" in
        UNREADABLE) printf "\033[31m%-10s %-40s %s  %s, git cannot read it here%s\033[0m\n" \
                     "$state" "$path" "$head" "$label" "$mark" ;;
        CURRENT) printf "\033[32m%-10s %-40s %s  %s%s\033[0m\n" "$state" "$path" "$head" "$label" "$mark" ;;
        STALE)   printf "\033[33m%-10s %-40s %s  %s%s\033[0m\n" "$state" "$path" "$head" "$label" "$mark" ;;
        BEHIND)  printf "\033[33m%-10s %-40s %s  %s, %s commit(s) behind %s%s\033[0m\n" \
                     "$state" "$path" "$head" "$label" "$behind" "$branch" "$mark" ;;
        AHEAD)   printf "\033[33m%-10s %-40s %s  %s, %s commit(s) the branch does not have%s\033[0m\n" \
                     "$state" "$path" "$head" "$label" "$ahead" "$mark" ;;
        DIRTY)   printf "\033[31m%-10s %-40s %s  %s, tracked content differs from the commit%s\033[0m\n" \
                     "$state" "$path" "$head" "$label" "$mark" ;;
        *)       printf "\033[36m%-10s %-40s %s  %s, no %s to compare against%s\033[0m\n" \
                     "$state" "$path" "$head" "$label" "origin/$branch" "$mark" ;;
    esac
done

echo ""

for row in "${ROWS[@]}"; do
    IFS='|' read -r state path label head branch behind ahead full when refresher content untracked dirty <<< "$row"
    [ "$untracked" = "0" ] && continue
    print_info "$path holds $untracked file(s) in no commit. List them with: git -C $path status --short --untracked-files=all"
done

if [ ${#STALE_LIST[@]} -eq 0 ] && [ ${#BEHIND_LIST[@]} -eq 0 ] && [ ${#DIRTY_LIST[@]} -eq 0 ] \
   && [ ${#UNREADABLE_LIST[@]} -eq 0 ]; then
    print_success "Every tree holds the same content, and none is behind its branch."
else
    for u in "${UNREADABLE_LIST[@]}"; do
        IFS='|' read -r path label <<< "$u"
        print_action "The $label at $path could not be read by git, so it was not compared. Run this check as the user that owns it."
    done
    # The trees disagreeing is the finding that needs no network to trust, so it
    # is said first and loudest.
    for s in "${STALE_LIST[@]}"; do
        IFS='|' read -r path label refresher head <<< "$s"
        print_action "The $label on $head does not hold what $NEWEST_PATH holds. Refresh it with: $refresher"
    done
    for b in "${BEHIND_LIST[@]}"; do
        IFS='|' read -r path label refresher behind <<< "$b"
        print_action "The $label is $behind behind its last fetched branch. Refresh it with: $refresher"
    done
    for d in "${DIRTY_LIST[@]}"; do
        print_action "$d has content edited in place. What it runs is not in git."
    done
fi

# Two comparisons with different trust. Say which is which, so nobody reads
# CURRENT as proof a tree matches GitHub.
print_status "Trees compared to each other exactly. Compared to origin only as far as each tree last fetched."

if [ -n "$TREES_OUT" ]; then
    : > "$TREES_OUT"
    for row in "${ROWS[@]}"; do
        IFS='|' read -r state path label head branch behind ahead full when refresher content untracked dirty <<< "$row"
        # An empty field would shift every field after it for a positional
        # reader, so a tree with no content hash writes "-" in both columns
        # rather than nothing.
        if [ -z "$content" ]; then
            oldest="-"
            content="-"
        elif [ "$content" = "$NEWEST_CONTENT" ]; then
            oldest=NEWEST
        else
            oldest=OLDER
        fi
        printf '%s %s %s %s %s %s %s %s\n' \
            "$state" "$path" "$head" "$behind" "$ahead" "$oldest" "$content" "$untracked" >> "$TREES_OUT"
    done
fi

exit 0
