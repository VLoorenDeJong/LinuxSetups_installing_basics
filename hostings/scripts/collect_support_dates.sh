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
# End-of-support dates for everything this machine runs or builds, so the
# console can mark what is about to lose, or has lost, its security patches.
#
# The maker's own data wherever a maker publishes it:
#   .NET                 Microsoft's release metadata
#   Ubuntu               Canonical's distro-info file, on this machine
#   PHP, Python, Java    the apt archive they were installed from: a package
#                        from Ubuntu's main is patched until Ubuntu's date, one
#                        from universe has no such promise without Ubuntu Pro
#   Node.js              the Node.js release schedule
# endoflife.date only where no maker publishes data a machine can read:
#   Angular, Vue, React, Svelte. Each line names its source.
#
# Writes, atomically, both read by hosting_status.sh:
#   support.tsv        product  cycle  eol-date|-  eol:yes|no  source
#   host-packages.tsv  name  version  component  eol-date|-
# A source that cannot be reached keeps its lines from the last good run.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️  %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

OUT_DIR="${SUPPORT_DIR:-/var/lib/linuxbasics}"
SUPPORT="$OUT_DIR/support.tsv"
HOSTPKG="$OUT_DIR/host-packages.tsv"
TAB=$'\t'

MS_URL="https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json"
NODE_URL="https://raw.githubusercontent.com/nodejs/Release/main/schedule.json"
EOLD_URL="https://endoflife.date/api/v1/products"
UBUNTU_CSV="/usr/share/distro-info/ubuntu.csv"

# --- Pre-flight ---------------------------------------------------------------
ERRORS=()
[ "$EUID" -eq 0 ] || ERRORS+=("This needs root: it writes $OUT_DIR. Run: sudo bash $0")
command -v curl >/dev/null 2>&1 || ERRORS+=("curl is missing: sudo apt-get install -y curl")
command -v jq   >/dev/null 2>&1 || ERRORS+=("jq is missing: sudo apt-get install -y jq")
[ -r "$UBUNTU_CSV" ] || ERRORS+=("No $UBUNTU_CSV: sudo apt-get install -y distro-info-data")
if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

print_header "Support dates"
mkdir -p "$OUT_DIR"
NEW="$(mktemp)"; HOSTNEW="$(mktemp)"
trap 'rm -f "$NEW" "$HOSTNEW"' EXIT
FAILED=()

fetch() { curl -fsSL --max-time 15 "$1" 2>/dev/null; }

# Lines for one product from the last good file, when its source is down now.
keep_old() {
    [ -r "$SUPPORT" ] && grep "^$1$TAB" "$SUPPORT" >> "$NEW" || true
    FAILED+=("$1")
}

# --- .NET: Microsoft ----------------------------------------------------------
if json="$(fetch "$MS_URL")" && [ -n "$json" ]; then
    printf '%s' "$json" | jq -r --arg src "Microsoft" '
        ."releases-index"[]
        | select(."eol-date" != null)
        | ["dotnet", (."channel-version" | split(".")[0]), ."eol-date",
           (if ."support-phase" == "eol" then "yes" else "no" end), $src] | @tsv' >> "$NEW"
else
    keep_old dotnet
fi

# --- Ubuntu: Canonical, read from this machine --------------------------------
# Columns: version,codename,series,created,release,eol,eol-server,eol-esm,...
TODAY="$(date +%F)"
awk -F, -v t="$TODAY" -v OFS="\t" 'NR > 1 && $6 != "" {
        v = $1; sub(/ LTS$/, "", v)
        print "ubuntu", v, $6, ($6 <= t ? "yes" : "no"), "Canonical"
    }' "$UBUNTU_CSV" >> "$NEW"
. /etc/os-release
UBUNTU_EOL="$(awk -F, -v v="$VERSION_ID" '{x = $1; sub(/ LTS$/, "", x)} x == v {print $6}' "$UBUNTU_CSV")"

# --- Node.js: its release schedule --------------------------------------------
if json="$(fetch "$NODE_URL")" && [ -n "$json" ]; then
    printf '%s' "$json" | jq -r --arg t "$TODAY" '
        to_entries[]
        | select(.key | test("^v[0-9]+$"))
        | ["nodejs", (.key | ltrimstr("v")), .value.end,
           (if .value.end <= $t then "yes" else "no" end), "Node.js"] | @tsv' >> "$NEW"
else
    keep_old nodejs
fi

# --- Frameworks: endoflife.date, the only source a machine can read -----------
for p in angular vue react svelte; do
    if json="$(fetch "$EOLD_URL/$p")" && [ -n "$json" ]; then
        printf '%s' "$json" | jq -r --arg p "$p" '
            .result.releases[]
            | [$p, .name, (.eolFrom // "-"),
               (if .isEol then "yes" else "no" end), "endoflife.date"] | @tsv' >> "$NEW"
    else
        keep_old "$p"
    fi
done

# --- Host packages: which archive each came from ------------------------------
# main is Canonical's to patch until Ubuntu's date; universe is community-kept.
printf 'ubuntu\t%s\tmain\t%s\n' "$VERSION_ID" "${UBUNTU_EOL:--}" >> "$HOSTNEW"
for spec in "php:php[0-9.]*" "python:python3.[0-9]*" "java:openjdk-[0-9]*-jre-headless"; do
    name="${spec%%:*}"; pattern="${spec#*:}"
    pkg="$(dpkg-query -W -f='${Package} ${Status}\n' "$pattern" 2>/dev/null \
        | awk '$NF == "installed" && $1 ~ /^(php[0-9.]+|python3\.[0-9]+|openjdk-[0-9]+-jre-headless)$/ {print $1}' \
        | sort -V | tail -1)"
    [ -n "$pkg" ] || continue
    ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
    comp="$(apt-cache policy "$pkg" 2>/dev/null | awk '/\*\*\*/ {getline; print $3; exit}' | awk -F/ '{print $NF}')"
    eol="-"; [ "$comp" = "main" ] && eol="${UBUNTU_EOL:--}"
    printf '%s\t%s\t%s\t%s\n' "$name" "${ver%%[-+~]*}" "${comp:-unknown}" "$eol" >> "$HOSTNEW"
done

chmod 0644 "$NEW" "$HOSTNEW"
mv -f "$NEW" "$SUPPORT"
mv -f "$HOSTNEW" "$HOSTPKG"
trap - EXIT

print_success "$(wc -l < "$SUPPORT") support lines in $SUPPORT"
print_success "$(wc -l < "$HOSTPKG") host packages in $HOSTPKG"
if [ ${#FAILED[@]} -gt 0 ]; then
    print_warning "Not reachable, last run's dates kept: ${FAILED[*]}"
    exit 1
fi
