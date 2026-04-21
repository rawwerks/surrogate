#!/usr/bin/env bash
# test_surrogate_command_coverage.sh — derive the command matrix from
# `surrogate help` and assert every command has at least one test that
# invokes it somewhere under tests/.
#
# This is an on-policy harness: when a new subcommand is added, this test
# fails until a test exists that exercises it. The intent is to catch
# coverage drift at commit time, not at bug time.
#
# Coverage heuristic: a command is "covered" if `$SURROGATE <cmd>` (via
# either literal "$SURROGATE" or "$("SURROGATE")" style invocations)
# appears anywhere in the existing tests/ tree outside this file itself.
# That is intentionally loose — the goal is not to measure test quality,
# only to make the coverage gap impossible to miss.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SURROGATE="${SURROGATE:-$REPO_DIR/bin/surrogate}"

[[ -x "$SURROGATE" ]] || { echo "FATAL: surrogate not executable at $SURROGATE" >&2; exit 1; }

# Commands are intentionally excluded from the coverage requirement.
# "cleanup" and "cull" are deprecated aliases that already have dedicated
# deprecation-warning tests; we allow-list them explicitly so the matrix
# does not require new tests for vestigial surface area.
declare -A ALLOWLIST=(
  [help]=1
  [-h]=1
  [--help]=1
)

# Extract the command list from the "Commands:" section of the help output.
extract_commands() {
  "$SURROGATE" 2>&1 \
    | awk '
      /^Commands:/ { in_cmds = 1; next }
      in_cmds && /^[A-Z]/ { in_cmds = 0 }
      in_cmds && /^  [a-z]/ {
        # First whitespace-delimited token on the line is the command name.
        # Example line: "  list  [-n LINES] [--bare] [--json]"
        sub(/^  */, "")
        sub(/ .*$/, "")
        if ($0 != "") print $0
      }
    ' \
    | sort -u
}

# Return 0 if $cmd appears to be exercised by any test file.
command_covered() {
  local cmd="$1" match
  # Any of: `surrogate <cmd>`, `"$SURROGATE" <cmd>`, `$SURROGATE <cmd>`.
  # Keep this forgiving; false positives are cheaper than false negatives
  # for a coverage gate.
  match="$(grep -RE \
    "\"\\\$SURROGATE\"[[:space:]]+$cmd([[:space:]]|$)|\\\$SURROGATE[[:space:]]+$cmd([[:space:]]|$)|surrogate[[:space:]]+$cmd([[:space:]]|$)" \
    "$SCRIPT_DIR" \
    --include='test_*.sh' \
    --exclude="$(basename "$0")" \
    -l 2>/dev/null || true)"
  [[ -n "$match" ]]
}

echo "=== surrogate command coverage matrix ==="
echo

cmds=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  cmds+=("$line")
done < <(extract_commands)

if [[ ${#cmds[@]} -eq 0 ]]; then
  echo "FATAL: could not extract any commands from '$SURROGATE' help output" >&2
  exit 2
fi

echo "commands discovered: ${#cmds[@]}"
printf '  %s\n' "${cmds[@]}"
echo

missing=()
for cmd in "${cmds[@]}"; do
  [[ -n "${ALLOWLIST[$cmd]:-}" ]] && continue
  if ! command_covered "$cmd"; then
    missing+=("$cmd")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "PASS: every surrogate subcommand has at least one test invocation"
  exit 0
fi

echo "FAIL: ${#missing[@]} command(s) without any test coverage:"
printf '  %s\n' "${missing[@]}"
echo
echo "Add a test invocation under tests/test_*.sh for each command listed above,"
echo "or update the ALLOWLIST in $(basename "$0") if the command is intentionally"
echo "deprecated and already covered by a dedicated deprecation-warning test."
exit 1
