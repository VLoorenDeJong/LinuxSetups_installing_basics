#!/usr/bin/env bash
set -euo pipefail

# Syntax-checks every .sh file in this repo (bash -n / sh -n).
# Runs as the first step of every phase. Stops the phase on any error.
# Self-contained copy of install_scripts/check_shell_syntax_all.sh logic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
else
  # No git metadata (bare copy on the device).
  # Assume the standard layout: <root>/install_scripts/scripts/.
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

# Skip hidden VCS and common virtual env folders.
EXCLUDE_DIRS=(
  "$REPO_ROOT/.git"
  "$REPO_ROOT/.venv"
  "$REPO_ROOT/venv"
)

find_cmd=(find "$REPO_ROOT" -type f -name "*.sh")
for ex in "${EXCLUDE_DIRS[@]}"; do
  find_cmd+=( -not -path "$ex/*" )
done

mapfile -t scripts < <("${find_cmd[@]}" | sort)

if [ "${#scripts[@]}" -eq 0 ]; then
  echo "No shell scripts found under: $REPO_ROOT"
  exit 0
fi

echo "Checking ${#scripts[@]} shell script(s) under: $REPO_ROOT"
echo

ok_count=0
err_count=0
failed_details=()

for f in "${scripts[@]}"; do
  first_line="$(head -n 1 "$f" || true)"

  checker="bash"
  if [[ "$first_line" == *"/sh"* ]] && [[ "$first_line" != *"bash"* ]]; then
    checker="sh"
  fi

  if "$checker" -n "$f"; then
    ok_count=$((ok_count + 1))
  else
    err_count=$((err_count + 1))
    failed_details+=("[$checker] $f")
    printf '\033[31mFAILED\033[0m  [%s] %s\n' "$checker" "$f"
  fi
done

echo ""
if [ "$err_count" -gt 0 ]; then
  echo "Failed files:"
  for entry in "${failed_details[@]}"; do
    echo "  $entry"
  done
fi

echo "Summary: OK=$ok_count ERR=$err_count"

if [ "$err_count" -gt 0 ]; then
  exit 1
fi

exit 0
