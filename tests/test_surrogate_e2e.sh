#!/usr/bin/env bash
# test_surrogate_e2e.sh — end-to-end tests for the surrogate CLI
#
# surrogate sends keystrokes to zmx sessions via tmux bridges.
#
# Usage:
#   bash tests/test_surrogate_e2e.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SURROGATE="${SURROGATE:-$(dirname "$SCRIPT_DIR")/bin/surrogate}"
TEST_SESSION="test-surrogate-$$"
PASS=0
FAIL=0
TESTS_RUN=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

cleanup() {
  echo ""
  echo "--- cleanup ---"
  zmx kill "$TEST_SESSION" 2>/dev/null || true
  "$SURROGATE" cleanup --all 2>/dev/null || true
  echo "cleanup done"
}
trap cleanup EXIT

echo "=== surrogate end-to-end tests ==="
echo "surrogate: $SURROGATE"
echo "test session: $TEST_SESSION"
echo ""

# Preflight
if [[ ! -x "$SURROGATE" ]]; then
  echo "FATAL: surrogate not found at $SURROGATE"
  exit 1
fi

if ! command -v zmx &>/dev/null; then
  echo "FATAL: zmx not found in PATH"
  exit 1
fi

# Create a test zmx session running bash
zmx attach "$TEST_SESSION" bash &
ZMX_PID=$!
sleep 2

if ! zmx list 2>/dev/null | grep -q "$TEST_SESSION"; then
  echo "FATAL: failed to create test zmx session '$TEST_SESSION'"
  exit 1
fi

echo "test zmx session ready (pid $ZMX_PID)"
echo ""

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_list() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" list 2>&1)

  if echo "$output" | grep -q "$TEST_SESSION"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    surrogate list output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — test session not found in list output"
  fi
}

test_type_and_read() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="BANANA_TEST_$$"

  "$SURROGATE" type "$TEST_SESSION" "echo $marker"
  sleep 1

  local output
  output=$("$SURROGATE" read "$TEST_SESSION" 2>&1)

  if echo "$output" | grep -q "$marker"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected '$marker' in read output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — marker not found in output"
  fi
}

test_send_special_keys() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="INTERRUPTED_$$"

  "$SURROGATE" send "$TEST_SESSION" "echo $marker && sleep 999" Enter
  sleep 0.5
  "$SURROGATE" send "$TEST_SESSION" C-c
  sleep 1

  local output
  output=$("$SURROGATE" read "$TEST_SESSION" 2>&1)

  if echo "$output" | grep -q "$marker"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected '$marker' in output after send + C-c:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — marker not found after send with special keys"
  fi
}

test_bridge_creation() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local bridges
  bridges=$(tmux list-sessions 2>/dev/null | grep "_surr_" || true)

  if [[ -n "$bridges" ]]; then
    pass "${FUNCNAME[0]}"
  else
    echo "    no _surr_* tmux sessions found"
    fail "${FUNCNAME[0]} — bridge session not created"
  fi
}

test_bridge_reuse() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local before after
  before=$(tmux list-sessions 2>/dev/null | grep "_surr_" | sort)

  "$SURROGATE" type "$TEST_SESSION" "echo bridge_reuse_check"
  sleep 1

  after=$(tmux list-sessions 2>/dev/null | grep "_surr_" | sort)

  if [[ "$before" == "$after" ]]; then
    pass "${FUNCNAME[0]}"
  else
    echo "    before: $before"
    echo "    after:  $after"
    fail "${FUNCNAME[0]} — bridge sessions changed (not reused)"
  fi
}

test_wait_success() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="WAIT_DONE_$$"

  "$SURROGATE" type "$TEST_SESSION" "sleep 2 && echo $marker"

  if "$SURROGATE" wait "$TEST_SESSION" "$marker" -t 5; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — wait did not detect pattern within timeout"
  fi
}

test_wait_timeout() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$SURROGATE" wait "$TEST_SESSION" "NEVERGONNAHAPPEN_$$" -t 2 2>/dev/null; then
    fail "${FUNCNAME[0]} — wait should have timed out but succeeded"
  else
    pass "${FUNCNAME[0]}"
  fi
}

test_read_line_limit() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  for i in 1 2 3 4 5 6 7 8; do
    "$SURROGATE" type "$TEST_SESSION" "echo LINE_LIMIT_$i"
  done
  sleep 1

  local output line_count
  output=$("$SURROGATE" read "$TEST_SESSION" -n 3 2>&1)
  line_count=$(echo "$output" | wc -l)

  if [[ "$line_count" -le 3 ]]; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected <= 3 lines, got $line_count"
    fail "${FUNCNAME[0]} — read -n 3 returned too many lines"
  fi
}

test_dead_session_error() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local bogus="nonexistent-session-$$"

  if "$SURROGATE" type "$bogus" "hello" 2>/dev/null; then
    fail "${FUNCNAME[0]} — should have failed for nonexistent session"
  else
    pass "${FUNCNAME[0]}"
  fi
}

test_cleanup_dead() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local tmp_session="surr-dead-test-$$"
  zmx attach "$tmp_session" bash &
  local tmp_pid=$!
  sleep 2

  "$SURROGATE" type "$tmp_session" "echo hello"
  sleep 1

  zmx kill "$tmp_session" 2>/dev/null || true
  wait "$tmp_pid" 2>/dev/null || true
  sleep 1

  "$SURROGATE" cleanup --dead

  local remaining
  remaining=$(tmux list-sessions 2>/dev/null | grep "_surr_.*${tmp_session}" || true)

  if [[ -z "$remaining" ]]; then
    pass "${FUNCNAME[0]}"
  else
    echo "    dead bridge still exists: $remaining"
    fail "${FUNCNAME[0]} — cleanup --dead did not remove dead bridge"
  fi
}

test_cleanup_all() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  "$SURROGATE" type "$TEST_SESSION" "echo cleanup_all_test"
  sleep 1

  "$SURROGATE" cleanup --all

  local remaining
  remaining=$(tmux list-sessions 2>/dev/null | grep "_surr_" || true)

  if [[ -z "$remaining" ]]; then
    pass "${FUNCNAME[0]}"
  else
    echo "    bridges still exist: $remaining"
    fail "${FUNCNAME[0]} — cleanup --all did not remove all bridges"
  fi
}

test_status() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  "$SURROGATE" type "$TEST_SESSION" "echo status_check"
  sleep 1

  local output
  output=$("$SURROGATE" status 2>&1)

  if [[ -n "$output" ]]; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — status produced no output"
  fi
}

test_concurrent_serialization() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker_a="CONCURRENT_A_$$"
  local marker_b="CONCURRENT_B_$$"

  "$SURROGATE" type "$TEST_SESSION" "echo $marker_a" &
  local pid_a=$!
  "$SURROGATE" type "$TEST_SESSION" "echo $marker_b" &
  local pid_b=$!

  wait "$pid_a" 2>/dev/null
  wait "$pid_b" 2>/dev/null
  sleep 2

  local output
  output=$("$SURROGATE" read "$TEST_SESSION" 2>&1)

  local found_a=false found_b=false
  echo "$output" | grep -q "$marker_a" && found_a=true
  echo "$output" | grep -q "$marker_b" && found_b=true

  if $found_a && $found_b; then
    pass "${FUNCNAME[0]}"
  else
    echo "    found_a=$found_a found_b=$found_b"
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — concurrent sends did not both appear in output"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "--- running tests ---"
echo ""

test_list
test_type_and_read
test_send_special_keys
test_bridge_creation
test_bridge_reuse
test_wait_success
test_wait_timeout
test_read_line_limit
test_dead_session_error
test_cleanup_dead
test_cleanup_all
test_status
test_concurrent_serialization

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== results ==="
echo "  tests run: $TESTS_RUN"
echo "  passed:    $PASS"
echo "  failed:    $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL: $FAIL test(s) failed"
  exit 1
else
  echo "ALL TESTS PASSED"
  exit 0
fi
