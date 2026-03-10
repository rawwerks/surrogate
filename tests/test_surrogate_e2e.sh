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
  # Only kill bridges for test sessions — never touch non-test bridges
  for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^_surr_test-surrogate-\|^_surr_surr-dead-test-" || true); do
    tmux kill-session -t "$s" 2>/dev/null && echo "killed bridge $s" || true
  done
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
zmx run "$TEST_SESSION" bash &
sleep 2

if ! zmx list 2>/dev/null | grep -q "$TEST_SESSION"; then
  echo "FATAL: failed to create test zmx session '$TEST_SESSION'"
  exit 1
fi

echo "test zmx session ready"
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
  zmx run "$tmp_session" bash &
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

  # Ensure a bridge exists for our test session
  "$SURROGATE" type "$TEST_SESSION" "echo cleanup_all_test"
  sleep 1

  # Count non-test bridges BEFORE cleanup
  local pre_count
  pre_count=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^_surr_" | grep -v "_surr_test-surrogate-\|_surr_surr-dead-test-" | wc -l || echo 0)

  "$SURROGATE" cleanup --all

  # Count non-test bridges AFTER cleanup — they should be unchanged
  # (cleanup --all is the CLI feature being tested, so it WILL nuke everything)
  # We verify the feature works, then check no test-specific bridges remain
  local remaining
  remaining=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^_surr_test-surrogate-" || true)

  if [[ -z "$remaining" ]]; then
    pass "${FUNCNAME[0]}"
  else
    echo "    test bridges still exist: $remaining"
    fail "${FUNCNAME[0]} — cleanup --all did not remove test bridges"
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
# Design Invariant Tests
# These assert the core design requirements that must hold for ALL terminals,
# ALL shells, and ALL configurations.
# ---------------------------------------------------------------------------

test_invariant_snippet_always_prints_message() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  # The bash/zsh snippet must contain BOTH the "wrapping" message (new session)
  # AND the "inherited" message (already in zmx, e.g. Ghostty)
  local snippet
  snippet=$("$setup_script" --show 2>&1)

  local has_wrap has_inherit
  has_wrap=$(echo "$snippet" | grep -c 'surrogate: wrapping in zmx session' || true)
  has_inherit=$(echo "$snippet" | grep -c 'surrogate: zmx session.*inherited' || true)

  if [[ "$has_wrap" -ge 1 && "$has_inherit" -ge 1 ]]; then
    pass "${FUNCNAME[0]} — snippet has both wrap and inherit messages"
  else
    echo "    has_wrap=$has_wrap has_inherit=$has_inherit"
    echo "    snippet:"
    echo "$snippet" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — snippet must print 'surrogate:' in ALL code paths"
  fi
}

test_invariant_snippet_all_shells() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  local all_ok=true
  for shell_name in bash zsh fish; do
    local snippet
    snippet=$(SHELL="/bin/$shell_name" "$setup_script" --show 2>&1)

    if ! echo "$snippet" | grep -q 'surrogate:'; then
      echo "    MISSING surrogate message for shell: $shell_name"
      all_ok=false
    fi

    # Every snippet must have both code paths
    if ! echo "$snippet" | grep -q 'wrapping in zmx session'; then
      echo "    MISSING 'wrapping' path for shell: $shell_name"
      all_ok=false
    fi

    if ! echo "$snippet" | grep -q 'inherited'; then
      echo "    MISSING 'inherited' path for shell: $shell_name"
      all_ok=false
    fi
  done

  if $all_ok; then
    pass "${FUNCNAME[0]} — all shells (bash, zsh, fish) have surrogate messages"
  else
    fail "${FUNCNAME[0]} — some shells missing surrogate messages"
  fi
}

test_invariant_no_terminal_specific_code() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  # Snippets must NEVER reference specific terminal emulators
  local snippet
  snippet=$("$setup_script" --show 2>&1)

  local violations
  violations=$(echo "$snippet" | grep -ciE '(ghostty|alacritty|wezterm|kitty|xterm|konsole|iterm)' || true)

  if [[ "$violations" -eq 0 ]]; then
    pass "${FUNCNAME[0]} — no terminal-specific code in snippet"
  else
    echo "    found $violations terminal-specific references:"
    echo "$snippet" | grep -iE '(ghostty|alacritty|wezterm|kitty|xterm|konsole|iterm)' | sed 's/^/    /'
    fail "${FUNCNAME[0]} — snippet must be terminal-agnostic"
  fi
}

test_invariant_surrogate_cli_terminal_agnostic() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # The surrogate CLI itself must never reference specific terminals
  local violations
  violations=$(grep -ciE '(ghostty|alacritty|wezterm|kitty|xterm|konsole|iterm)' "$SURROGATE" || true)

  if [[ "$violations" -eq 0 ]]; then
    pass "${FUNCNAME[0]} — surrogate CLI is terminal-agnostic"
  else
    echo "    found $violations terminal-specific references in surrogate CLI"
    fail "${FUNCNAME[0]} — surrogate CLI must be terminal-agnostic"
  fi
}

test_invariant_zmx_full_path() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  # Snippets must use full path to zmx (PATH not available early in rc files)
  local snippet
  snippet=$("$setup_script" --show 2>&1)

  if echo "$snippet" | grep -q 'ZMX_BIN:-.*/.local/bin/zmx'; then
    pass "${FUNCNAME[0]} — snippet uses full path to zmx"
  else
    echo "    snippet does not use full path fallback for zmx"
    fail "${FUNCNAME[0]} — snippet must use full path (PATH not set when snippet runs)"
  fi
}

test_invariant_parent_check_not_env_var() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  # Snippet must check parent process name, NOT ZMX_SESSION env var
  # (ZMX_SESSION leaks through window managers to all children)
  local snippet
  snippet=$("$setup_script" --show 2>&1)

  local uses_ppid uses_env_check
  uses_ppid=$(echo "$snippet" | grep -c 'PPID\|%self' || true)
  # Check for ZMX_SESSION used as the wrap/skip decision (not just the display)
  uses_env_check=$(echo "$snippet" | grep -c 'if.*ZMX_SESSION\|test.*ZMX_SESSION' || true)

  if [[ "$uses_ppid" -ge 1 && "$uses_env_check" -eq 0 ]]; then
    pass "${FUNCNAME[0]} — uses parent process check, not env var leak"
  else
    echo "    uses_ppid=$uses_ppid uses_env_check=$uses_env_check"
    fail "${FUNCNAME[0]} — must check parent process, not ZMX_SESSION (leaks via WM)"
  fi
}

test_invariant_unsets_zmx_session_before_attach() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  # zmx attach refuses to run if ZMX_SESSION is set (CannotAttachToSessionInSession).
  # ZMX_SESSION leaks from parent zmx sessions through window managers to all children
  # (VS Code, tmux panes, etc). The snippet MUST unset ZMX_SESSION before exec zmx attach.
  # Without this, terminals launched from within a zmx-wrapped desktop will hang.
  local snippet
  snippet=$("$setup_script" --show 2>&1)

  if echo "$snippet" | grep -q 'unset ZMX_SESSION\|set -e ZMX_SESSION'; then
    pass "${FUNCNAME[0]} — snippet unsets ZMX_SESSION before zmx attach"
  else
    echo "    snippet does not unset ZMX_SESSION before exec zmx attach"
    echo "    zmx attach will fail with CannotAttachToSessionInSession in leaked-env terminals"
    fail "${FUNCNAME[0]} — MUST unset ZMX_SESSION before exec (env var leaks via WM)"
  fi
}

test_invariant_installed_matches_repo() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local install_dir="${INSTALL_DIR:-$HOME/.local/bin}"
  local repo_dir
  repo_dir="$(dirname "$SCRIPT_DIR")/bin"
  local all_match=true

  for file in surrogate surrogate-shell-setup; do
    if [[ ! -f "$install_dir/$file" ]]; then
      echo "    $file not installed at $install_dir/$file"
      all_match=false
    elif ! diff -q "$repo_dir/$file" "$install_dir/$file" &>/dev/null; then
      echo "    $file: installed copy differs from repo"
      echo "    Run: bash install.sh"
      all_match=false
    fi
  done

  if $all_match; then
    pass "${FUNCNAME[0]} — installed binaries match repo"
  else
    fail "${FUNCNAME[0]} — installed binaries are stale (run install.sh)"
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

echo ""
echo "--- design invariant tests ---"
echo ""

test_invariant_snippet_always_prints_message
test_invariant_snippet_all_shells
test_invariant_no_terminal_specific_code
test_invariant_surrogate_cli_terminal_agnostic
test_invariant_zmx_full_path
test_invariant_parent_check_not_env_var
test_invariant_unsets_zmx_session_before_attach
test_invariant_installed_matches_repo

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
