#!/usr/bin/env bash
# test_surrogate_live_semantics.sh — real-session tests for `live` filtering
# and the `ACTIVE` time column.
#
# These tests drive *actual* detached zmx sessions (not mocks) and assert on
# surrogate's live/active output. They exist because the prior mock-based
# tests were not catching two real-world bugs:
#
#   1. `surrogate live --all` excluded detached-but-live agent sessions
#      because the upstream filter required clients > 0.
#   2. The `ACTIVE` column always showed ~0s because it was computed from
#      the zmx log-file mtime, which is bumped by every zmx client
#      connect/disconnect (including surrogate's own polling queries).
#
# If any of these assertions regress, the default `surrogate live` view
# will again go silent on real live agents.

# NOTE: deliberately NOT setting `errexit` — individual tests must be allowed
# to `grep` for patterns that may not match and still continue running, so
# that a single failing assertion does not short-circuit the rest of the
# suite. `pipefail` is kept so genuine transport breakage is still caught.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SURROGATE="${SURROGATE:-$REPO_DIR/bin/surrogate}"
export SURROGATE

# shellcheck source=lib/real_session.sh
source "$SCRIPT_DIR/lib/real_session.sh"

RESULTS=()
FAILED=0

pass() { echo "  PASS: $1"; RESULTS+=("PASS: $1"); }
fail() { echo "  FAIL: $1"; RESULTS+=("FAIL: $1"); FAILED=$(( FAILED + 1 )); }

require_bin() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || {
    echo "FATAL: required binary '$bin' not found" >&2
    exit 1
  }
}

require_bin zmx
require_bin tmux
require_bin jq
[[ -x "$SURROGATE" ]] || { echo "FATAL: surrogate not executable at $SURROGATE" >&2; exit 1; }

# Extract last_active_seconds for a specific session from `surrogate active`
# JSON. Must use a JSON-aware parser — the output is one long line containing
# every session, so text-based regex extraction will greedily hit an
# unrelated entry and silently lie about the value.
session_idle_seconds() {
  local json="$1" session="$2"
  printf '%s' "$json" \
    | jq -r --arg s "$session" \
      '.sessions[] | select(.session == $s) | .last_active_seconds' \
    | head -1
}

real_session_init

# ---------------------------------------------------------------------------
# Bug anchor 1: detached live PID must appear in `surrogate live --all`
# ---------------------------------------------------------------------------
test_live_all_includes_detached_live_pid() {
  echo "=== test: ${FUNCNAME[0]} ==="
  local session output
  session="$(real_session_spawn detached)"

  # `zmx run <name> <cmd> &` intentionally does not attach a client, so this
  # session has clients=0 from the start. If surrogate's live filter is
  # correct, it must still appear in `live --all`.
  output="$("$SURROGATE" live --all --recent 5000 2>&1 || true)"

  if printf '%s\n' "$output" | grep -Fq "$session"; then
    pass "${FUNCNAME[0]} — detached live-PID session visible in live --all"
  else
    echo "    surrogate live --all output (session expected: $session):"
    printf '%s\n' "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — detached live-PID session missing from live --all"
  fi

  real_session_kill "$session"
}

# ---------------------------------------------------------------------------
# Bug anchor 2: ACTIVE column must reflect real pane activity, not log mtime.
#
# We spawn a detached idle bash, wait IDLE_SECS without writing, and require
# `surrogate active --all --json` to report last_active_seconds >= IDLE_SECS.
# The old log-mtime path would return 0s or near-0s regardless of how long
# the pane had been idle, because every `zmx list` polls the socket and
# bumps the log mtime.
# ---------------------------------------------------------------------------
test_active_time_reports_idle_after_silence() {
  echo "=== test: ${FUNCNAME[0]} ==="
  local session output idle_reported
  local IDLE_SECS=6

  session="$(real_session_spawn idle)"

  # Warm the cache: first call establishes the baseline activity snapshot.
  "$SURROGATE" active --all --recent 5000 --json >/dev/null 2>&1 || true

  sleep "$IDLE_SECS"

  output="$("$SURROGATE" active --all --recent 5000 --json 2>&1 || true)"
  idle_reported="$(session_idle_seconds "$output" "$session")"

  if [[ -z "$idle_reported" || "$idle_reported" == "null" ]]; then
    echo "    could not extract last_active_seconds for $session"
    fail "${FUNCNAME[0]} — session missing from active --all --json"
  elif (( idle_reported + 1 >= IDLE_SECS )); then
    pass "${FUNCNAME[0]} — idle session reported ${idle_reported}s (expected >= ${IDLE_SECS}s)"
  else
    fail "${FUNCNAME[0]} — idle session reported ${idle_reported}s but slept ${IDLE_SECS}s; ACTIVE column is lying"
  fi

  real_session_kill "$session"
}

# ---------------------------------------------------------------------------
# Bug anchor 3: ACTIVE time must reset after a real pane write.
#
# Spawn, idle, then touch the pane with a harmless keystroke, then assert
# the reported idle time is now small.
# ---------------------------------------------------------------------------
test_active_time_resets_after_write() {
  echo "=== test: ${FUNCNAME[0]} ==="
  local session output idle_reported
  local IDLE_SECS=5
  local FRESH_CEILING=3

  session="$(real_session_spawn fresh)"

  # Warm cache and let some idle time accrue.
  "$SURROGATE" active --all --recent 5000 --json >/dev/null 2>&1 || true
  sleep "$IDLE_SECS"

  # Write to the pane; this must flip the ACTIVE timer back near zero.
  real_session_touch "$session"
  sleep 1

  output="$("$SURROGATE" active --all --recent 5000 --json 2>&1 || true)"
  idle_reported="$(session_idle_seconds "$output" "$session")"

  if [[ -z "$idle_reported" || "$idle_reported" == "null" ]]; then
    echo "    could not extract last_active_seconds for $session"
    fail "${FUNCNAME[0]} — session missing from active --all --json"
  elif (( idle_reported <= FRESH_CEILING )); then
    pass "${FUNCNAME[0]} — fresh session reported ${idle_reported}s (expected <= ${FRESH_CEILING}s)"
  else
    fail "${FUNCNAME[0]} — fresh session reported ${idle_reported}s; ACTIVE column is not detecting pane writes"
  fi

  real_session_kill "$session"
}

# ---------------------------------------------------------------------------
# Default-view noise filter: a detached zmx running plain bash (no agent TUI,
# no project hint) must NOT appear in bare `surrogate live` — it's noise.
# It must still appear in `surrogate live --all`.
#
# This is the "no reap needed" invariant: when an agent session's primary
# process exits and drops back to a shell prompt, it self-hides from the
# default view without any manual cleanup.
# ---------------------------------------------------------------------------
test_live_default_hides_bare_shell_noise() {
  echo "=== test: ${FUNCNAME[0]} ==="
  local session output_default output_all
  session="$(real_session_spawn noise)"

  # Give the pane a moment to render the initial shell prompt so the
  # ui_hint classifier can see it.
  sleep 1

  output_default="$("$SURROGATE" live --recent 5000 2>&1 || true)"
  output_all="$("$SURROGATE" live --all --recent 5000 2>&1 || true)"

  local appears_default=0 appears_all=0
  printf '%s\n' "$output_default" | grep -Fq "$session" && appears_default=1
  printf '%s\n' "$output_all" | grep -Fq "$session" && appears_all=1

  if (( appears_default == 0 && appears_all == 1 )); then
    pass "${FUNCNAME[0]} — bare-shell noise hidden from default but visible with --all"
  else
    echo "    appears_default=$appears_default appears_all=$appears_all (expected 0 / 1)"
    echo "    live default:"
    printf '%s\n' "$output_default" | sed 's/^/    /'
    echo "    live --all:"
    printf '%s\n' "$output_all" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — noise-filter invariant broken (expected hidden default, visible --all)"
  fi

  real_session_kill "$session"
}

# ---------------------------------------------------------------------------
# Bug anchor 4: `surrogate prime --json` must emit valid JSON.
#
# Regression: the identity fields were double-wrapped in quotes
# (`"session":""foo""`) because pre-quoted strings were passed to
# `json_or_null`, which already wraps non-empty input in quotes. Any
# consumer that piped prime output into jq would fail to parse.
# ---------------------------------------------------------------------------
test_prime_json_is_valid() {
  echo "=== test: ${FUNCNAME[0]} ==="
  local output
  output="$("$SURROGATE" prime --json 2>&1 || true)"

  if printf '%s' "$output" | jq -e '.identity and (.sessions | type == "array")' >/dev/null 2>&1; then
    pass "${FUNCNAME[0]} — prime --json parses and has identity+sessions"
  else
    echo "    prime --json output (first 400 bytes):"
    printf '%s' "$output" | head -c 400 | sed 's/^/    /'
    echo
    fail "${FUNCNAME[0]} — prime --json emits invalid JSON"
  fi
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
echo "=== surrogate live/active real-session tests ==="
echo

test_live_all_includes_detached_live_pid
test_active_time_reports_idle_after_silence
test_active_time_resets_after_write
test_live_default_hides_bare_shell_noise
test_prime_json_is_valid

echo
echo "=== summary ==="
for line in "${RESULTS[@]}"; do echo "  $line"; done
echo "  ${#RESULTS[@]} test(s), $FAILED failed"

exit "$FAILED"
