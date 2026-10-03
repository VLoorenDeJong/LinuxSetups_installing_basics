#!/usr/bin/env bash
set -e

# =============================================================================
# Which framework a website checkout was built with, as "<product> <version>",
# or nothing for a plain site. The product names match collect_support_dates.sh.
#
# The installed copy under node_modules first: that is what the build used. The
# range in package.json only when nothing is installed, with ^ and ~ removed.
#
# Usage: site_framework.sh <checkout>
# =============================================================================

SRC="${1:-}"
[ -f "$SRC/package.json" ] || exit 0

for spec in "angular:@angular/core" "vue:vue" "svelte:svelte" "react:react"; do
    product="${spec%%:*}"; pkg="${spec#*:}"
    ver="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
        "$SRC/node_modules/$pkg/package.json" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
    if [ -z "$ver" ]; then
        ver="$(grep -oE "\"$pkg\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$SRC/package.json" \
            | head -1 | sed -E 's/.*:[[:space:]]*"[^0-9]*([0-9][^"]*)"/\1/')"
    fi
    # "latest", "workspace:*" and "^18 || ^19" name no version, so nothing is said.
    ver="${ver%% *}"
    if [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.]+)?$ ]]; then
        printf '%s %s\n' "$product" "$ver"
        exit 0
    fi
    [ -n "$ver" ] && exit 0
done
