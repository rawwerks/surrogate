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
RESULTS_DIR="$(mktemp -d)"
RESULTS_FILE="$RESULTS_DIR/results"
touch "$RESULTS_FILE"
TESTS_RUN=0  # legacy counter, summary uses RESULTS_FILE

pass() { echo "PASS" >> "$RESULTS_FILE"; echo "  PASS: $1"; }
fail() { echo "FAIL" >> "$RESULTS_FILE"; echo "  FAIL: $1"; }

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
  rm -rf "$RESULTS_DIR" 2>/dev/null || true
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
  # plumb:req-43c3eed5
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
  # plumb:req-77cf38f4
  # plumb:req-29b6b22a
  # plumb:req-f6a28ee7
  # plumb:req-c210345d
  # plumb:req-da49d759
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
  # plumb:req-2335dd45
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
  # plumb:req-b6f97f4e
  # plumb:req-5b4577ce
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
  # plumb:req-ae4fb35e
  # plumb:req-19170671
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
  # plumb:req-4c7c7e3b
  # plumb:req-997f73d2
  # plumb:req-c53cf3b7
  # plumb:req-4ecc2ef6
  # plumb:req-2c9db8fd
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
  # plumb:req-8f64803b
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$SURROGATE" wait "$TEST_SESSION" "NEVERGONNAHAPPEN_$$" -t 2 2>/dev/null; then
    fail "${FUNCNAME[0]} — wait should have timed out but succeeded"
  else
    pass "${FUNCNAME[0]}"
  fi
}

test_read_line_limit() {
  # plumb:req-52cee173
  # plumb:req-201cbd97
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
  # plumb:req-fd5d8f2f
  # plumb:req-0748d740
  # plumb:req-f63f502d
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
  # plumb:req-23993d75
  # plumb:req-3bb77a03
  # plumb:req-129f015a
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
  # plumb:req-231e031f
  # plumb:req-be66a1c3
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
  # plumb:req-3a11209c
  # plumb:req-a727036c
  # plumb:req-04b8212d
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
  # plumb:req-271825d3
  # plumb:req-29465905
  # plumb:req-934a7095
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
  # plumb:req-ca2be6e0
  # plumb:req-d1726bef
  # plumb:req-a64328f9
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
  # plumb:req-5523d6ad
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
  # plumb:req-eb9fb624
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
  # plumb:req-bef8d006
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
  # plumb:req-5ad4c151
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
  # plumb:req-51b97d09
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
  # plumb:req-d2c194b8
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
echo "--- alias + search tests ---"
echo ""

test_find() {
  # plumb:req-c789f866
  # plumb:req-24a68c42
  # plumb:req-720a5bc2
  # plumb:req-cfd97f85
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="FIND_ME_$$"
  "$SURROGATE" type "$TEST_SESSION" "echo $marker"
  sleep 1

  local output
  output=$("$SURROGATE" find "$marker" -n 50 2>&1)

  if echo "$output" | grep -q "$marker"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected '$marker' in find output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — marker not found in find output"
  fi
}

test_find_empty_query() {
  # plumb:req-4b5c0133
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$SURROGATE" find "" 2>/dev/null; then
    fail "${FUNCNAME[0]} — empty query should be rejected"
  else
    pass "${FUNCNAME[0]}"
  fi
}

test_find_no_match() {
  # plumb:req-16dd55a0
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" find "XYZZY_NEVER_MATCH_$$" 2>&1)

  if echo "$output" | grep -q "no matches"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected 'no matches' message:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — should report no matches"
  fi
}

test_find_with_context() {
  # plumb:req-095a3f96
  # plumb:req-c38efd2f
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="CONTEXT_TEST_$$"
  "$SURROGATE" type "$TEST_SESSION" "echo BEFORE_$marker"
  "$SURROGATE" type "$TEST_SESSION" "echo $marker"
  "$SURROGATE" type "$TEST_SESSION" "echo AFTER_$marker"
  sleep 1

  local output
  output=$("$SURROGATE" find "$marker" -n 50 -C 1 2>&1)

  if echo "$output" | grep -q "$marker"; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — context search failed"
  fi
}

test_who() {
  # plumb:req-851ca449
  # plumb:req-251007fd
  # plumb:req-6a20e804
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" who 2>&1)

  if echo "$output" | grep -q "$TEST_SESSION"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected test session in who output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — test session not in who output"
  fi
}

test_who_n_zero() {
  # plumb:req-40defb6c
  # plumb:req-4e55b856
  # plumb:req-0e241e62
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" who -n 0 2>&1)

  # Should list sessions but with empty snippets
  if echo "$output" | grep -q "$TEST_SESSION"; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — who -n 0 should still list sessions"
  fi
}

test_active() {
  # plumb:req-82e691b5
  # plumb:req-295cf791
  # plumb:req-55b5dea2
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" active --all 2>&1)

  if echo "$output" | grep -q "$TEST_SESSION"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected test session in active output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — test session not in active --all output"
  fi
}

test_peek() {
  # plumb:req-47c3463d
  # plumb:req-4ef11b15
  # plumb:req-a02e09c7
  # plumb:req-7fcde33b
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="PEEK_ME_$$"
  "$SURROGATE" type "$TEST_SESSION" "echo $marker"
  sleep 1

  local output
  output=$("$SURROGATE" peek --filter "$marker" 2>&1)

  if echo "$output" | grep -q "$marker"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected '$marker' in peek output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — marker not found in peek output"
  fi
}

test_peek_no_filter_match() {
  # plumb:req-53a2ec07
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" peek --filter "XYZZY_NEVER_$$" 2>&1)

  if echo "$output" | grep -q "peeked 0 session"; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — should report 0 sessions peeked"
  fi
}

test_rename() {
  # plumb:req-5ee05e33
  # plumb:req-62eb9d36
  # plumb:req-a6498a94
  # plumb:req-56aebe04
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local rename_session="surr-rename-test-$$"
  zmx run "$rename_session" bash &
  local rename_pid=$!
  sleep 2

  local new_name="surr-renamed-$$"
  local output
  output=$("$SURROGATE" rename "$rename_session" "$new_name" 2>&1)

  if echo "$output" | grep -q "renamed"; then
    # Verify new name exists and old doesn't
    if "$SURROGATE" read "$new_name" -n 1 2>/dev/null; then
      pass "${FUNCNAME[0]}"
    else
      fail "${FUNCNAME[0]} — renamed session not accessible"
    fi
  else
    fail "${FUNCNAME[0]} — rename command failed"
  fi

  # Cleanup
  zmx kill "$new_name" 2>/dev/null || true
  wait "$rename_pid" 2>/dev/null || true
}

test_rename_nonexistent() {
  # plumb:req-db99d33a
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$SURROGATE" rename "nonexistent-$$" "newname-$$" 2>/dev/null; then
    fail "${FUNCNAME[0]} — should fail for nonexistent session"
  else
    pass "${FUNCNAME[0]}"
  fi
}

test_rename_collision() {
  # plumb:req-9b0bac5e
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Create two sessions, try to rename one to the other's name
  local coll_a="surr-coll-a-$$"
  local coll_b="surr-coll-b-$$"
  zmx run "$coll_a" bash &
  local pid_a=$!
  zmx run "$coll_b" bash &
  local pid_b=$!
  sleep 2

  if "$SURROGATE" rename "$coll_a" "$coll_b" 2>/dev/null; then
    fail "${FUNCNAME[0]} — should fail when target exists"
  else
    pass "${FUNCNAME[0]}"
  fi

  # Cleanup
  zmx kill "$coll_a" 2>/dev/null || true
  zmx kill "$coll_b" 2>/dev/null || true
  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true
}

test_require_int() {
  # plumb:req-45a5c9ee
  # plumb:req-41dfdd81
  # plumb:req-73e7db09
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local all_ok=true

  # Non-numeric -n should fail
  if "$SURROGATE" find "test" -n abc 2>/dev/null; then
    echo "    find -n abc should have failed"
    all_ok=false
  fi

  if "$SURROGATE" read "$TEST_SESSION" -n xyz 2>/dev/null; then
    echo "    read -n xyz should have failed"
    all_ok=false
  fi

  if "$SURROGATE" who -n foo 2>/dev/null; then
    echo "    who -n foo should have failed"
    all_ok=false
  fi

  if "$SURROGATE" peek -n bar 2>/dev/null; then
    echo "    peek -n bar should have failed"
    all_ok=false
  fi

  if "$SURROGATE" find "test" -C baz 2>/dev/null; then
    echo "    find -C baz should have failed"
    all_ok=false
  fi

  if $all_ok; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — some non-numeric args were not rejected"
  fi
}

# Alias tests that need TEST_SESSION (write operations)
test_alias_resolve
test_alias_rename_shows_aliases

# Search/filter tests
test_find
test_find_empty_query
test_find_no_match
test_find_with_context
test_who
test_who_n_zero
test_active
test_peek
test_peek_no_filter_match
test_rename
test_rename_nonexistent
test_rename_collision
test_require_int

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
PASS_COUNT=$(grep -c PASS "$RESULTS_FILE" 2>/dev/null || echo 0)
FAIL_COUNT=$(grep -c FAIL "$RESULTS_FILE" 2>/dev/null || echo 0)
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "=== results ==="
echo "  tests run: $TOTAL"
echo "  passed:    $PASS_COUNT"
echo "  failed:    $FAIL_COUNT"
echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "FAIL: $FAIL_COUNT test(s) failed"
  exit 1
else
  echo "ALL TESTS PASSED"
  exit 0
fi
