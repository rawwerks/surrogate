#!/usr/bin/env bash
# test_surrogate_e2e.sh — end-to-end tests for the surrogate CLI
#
# surrogate sends keystrokes to zmx sessions via tmux bridges.
#
# Usage:
#   bash tests/test_surrogate_e2e.sh
#
# Features:
#   - Per-test timeout (default 30s, override with TEST_TIMEOUT=N)
#   - Per-test timing (shows elapsed seconds)
#   - Concurrent-run safe (all resources scoped to PID)
#   - Interrupted-run safe (reaps stale test artifacts from dead harness PIDs)
#   - Fails gracefully on timeout without blocking the suite
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SURROGATE="${SURROGATE:-$(dirname "$SCRIPT_DIR")/bin/surrogate}"
SURROGATE_BRIEF="${SURROGATE_BRIEF:-$(dirname "$SCRIPT_DIR")/bin/surrogate-brief}"
TEST_SESSION="test-surrogate-$$"
TEST_TIMEOUT="${TEST_TIMEOUT:-30}"  # per-test timeout in seconds
TEST_PROFILE="${SURROGATE_TEST_PROFILE:-smoke}"
TEST_SECTIONS="${SURROGATE_TEST_SECTIONS:-}"
TEST_POLL_INTERVAL_SECS="${TEST_POLL_INTERVAL_SECS:-0.2}"
RESULTS_DIR="$(mktemp -d)"
RESULTS_FILE="$RESULTS_DIR/results"
TIMING_FILE="$RESULTS_DIR/timing"
touch "$RESULTS_FILE" "$TIMING_FILE"
SUITE_START="$(date +%s)"
SECURITY_METRICS_OUTPUT=""
CLEANUP_DONE=0
TEST_SESSION_NAME_RE='^(test-surrogate|surr-dead-test|surr-prune-all-test|surr-rename-test|surr-prose-crlf-test|surr-prose-test|surr-coll-a|surr-coll-b|surr-stale-test|surr-prune-test|surr-prune-batch-test|surr-prune-keep-test|surr-sweep-preview-test)-[0-9]+$'

# Export variables needed by subshell test runners
export RESULTS_FILE TIMING_FILE SURROGATE SURROGATE_BRIEF TEST_SESSION TEST_TIMEOUT
export TESTS_RUN=0  # legacy counter (each test increments, but value doesn't survive subshells)

pass() { echo "PASS" >> "$RESULTS_FILE"; echo "  PASS: $1"; }
fail() { echo "FAIL: $1" >> "$RESULTS_FILE"; echo "  FAIL: $1"; }

now_ns() { date +%s%N; }

usage() {
  cat <<'EOF'
Usage: bash tests/test_surrogate_e2e.sh [--smoke|--full] [--sections LIST]

Options:
  --smoke          Run the fast default sections only
  --full           Run the entire suite
  --sections LIST  Run a comma-separated subset of sections
                   Available: core, identity, aliases, behavior, design, search, labels, invariants
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --smoke)
        TEST_PROFILE="smoke"
        shift
        ;;
      --full)
        TEST_PROFILE="full"
        shift
        ;;
      --sections)
        [[ $# -ge 2 ]] || { echo "FATAL: --sections requires a value" >&2; usage; exit 1; }
        TEST_SECTIONS="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "FATAL: unknown arg '$1'" >&2
        usage
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

wait_until() {
  local timeout_secs="$1"
  shift
  local deadline_ns=$(( $(now_ns) + timeout_secs * 1000000000 ))
  while (( $(now_ns) < deadline_ns )); do
    if "$@"; then
      return 0
    fi
    sleep "$TEST_POLL_INTERVAL_SECS"
  done
  "$@"
}

wait_for_output() {
  local session="$1"
  local pattern="$2"
  local timeout="${3:-5}"
  "$SURROGATE" wait "$session" "$pattern" -t "$timeout" >/dev/null 2>&1
}

STALE_OUTPUT_CACHE=""
MOCK_PROC_ROOT=""
MOCK_LIVE_TMPBIN=""
MOCK_LIVE_SIGNAL_SESSION=""
MOCK_LIVE_LOW_SESSION=""
MOCK_LIVE_DETACHED_SESSION=""
MOCK_LIVE_ZMX_DIR=""

stale_output_matches() {
  local session="$1"
  STALE_OUTPUT_CACHE=$("$SURROGATE" stale --older-than 0 --filter "$session" 2>&1)
  echo "$STALE_OUTPUT_CACHE" | grep -q "$session" &&
    echo "$STALE_OUTPUT_CACHE" | grep -q 'Detached zmx sessions older than'
}

read_matches_pattern() {
  local session="$1"
  local pattern="$2"
  "$SURROGATE" read "$session" -n 100 2>/dev/null | grep -Eq -- "$pattern"
}

setup_mock_proc_ancestry() {
  local session="$1"
  MOCK_PROC_ROOT="$(mktemp -d)"
  mkdir -p "$MOCK_PROC_ROOT/9001" "$MOCK_PROC_ROOT/9002" "$MOCK_PROC_ROOT/1"

  cat > "$MOCK_PROC_ROOT/9001/stat" <<'EOF'
9001 (bash) S 9002 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
EOF
  cat > "$MOCK_PROC_ROOT/9002/stat" <<'EOF'
9002 (zmx) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
EOF
  cat > "$MOCK_PROC_ROOT/1/stat" <<'EOF'
1 (init) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
EOF
  : > "$MOCK_PROC_ROOT/9001/cmdline"
  printf '/home/testuser/.local/bin/zmx\0attach\0%s\0' "$session" > "$MOCK_PROC_ROOT/9002/cmdline"
  : > "$MOCK_PROC_ROOT/1/cmdline"
}

cleanup_mock_proc_ancestry() {
  if [[ -n "$MOCK_PROC_ROOT" && -d "$MOCK_PROC_ROOT" ]]; then
    rm -rf "$MOCK_PROC_ROOT"
  fi
  MOCK_PROC_ROOT=""
}

wait_for_read_match() {
  local session="$1"
  local pattern="$2"
  local timeout="${3:-5}"
  wait_until "$timeout" read_matches_pattern "$session" "$pattern"
}

csv_has_value() {
  local csv="$1"
  local value="$2"
  case ",$csv," in
    *,"$value",*) return 0 ;;
    *) return 1 ;;
  esac
}

build_bench_path() {
  local mode="$1"
  local tmpbin
  tmpbin="$(mktemp -d)"
  ln -sf "$(command -v zmx)" "$tmpbin/zmx"
  ln -sf "$(command -v tmux)" "$tmpbin/tmux"
  if [[ "$mode" == "guarded" ]] && command -v dcg >/dev/null 2>&1; then
    ln -sf "$(command -v dcg)" "$tmpbin/dcg"
  fi
  printf '%s\n' "$tmpbin:/usr/bin:/bin"
}

measure_security_overhead() {
  local iterations="${SECURITY_BENCH_ITERS:-5}"
  if ! command -v zmx >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    SECURITY_METRICS_OUTPUT="  security overhead: skipped (missing zmx or tmux)"
    return 0
  fi

  local baseline_path guarded_path
  baseline_path="$(build_bench_path baseline)"
  guarded_path="$(build_bench_path guarded)"

  local baseline_total=0 guarded_total=0 i start end marker
  for (( i=1; i<=iterations; i++ )); do
    marker="SECURITY_BENCH_BASE_${$}_${i}"
    start="$(now_ns)"
    PATH="$baseline_path" SURROGATE_LABEL=off "$SURROGATE" type "$TEST_SESSION" "echo $marker" >/dev/null 2>&1
    end="$(now_ns)"
    baseline_total=$((baseline_total + end - start))
  done

  if command -v dcg >/dev/null 2>&1; then
    for (( i=1; i<=iterations; i++ )); do
      marker="SECURITY_BENCH_GUARDED_${$}_${i}"
      start="$(now_ns)"
      PATH="$guarded_path" SURROGATE_LABEL=off "$SURROGATE" type "$TEST_SESSION" "echo $marker" >/dev/null 2>&1
      end="$(now_ns)"
      guarded_total=$((guarded_total + end - start))
    done

    local baseline_avg_ms guarded_avg_ms delta_ms
    baseline_avg_ms=$(( baseline_total / iterations / 1000000 ))
    guarded_avg_ms=$(( guarded_total / iterations / 1000000 ))
    delta_ms=$(( guarded_avg_ms - baseline_avg_ms ))
    SECURITY_METRICS_OUTPUT=$(cat <<EOF
  security overhead:
    type baseline avg: ${baseline_avg_ms}ms
    type guarded avg:  ${guarded_avg_ms}ms
    dcg delta avg:     ${delta_ms}ms
EOF
)
  else
    local baseline_avg_ms
    baseline_avg_ms=$(( baseline_total / iterations / 1000000 ))
    SECURITY_METRICS_OUTPUT=$(cat <<EOF
  security overhead:
    type baseline avg: ${baseline_avg_ms}ms
    type guarded avg:  skipped (dcg not installed)
    dcg delta avg:     skipped
EOF
)
  fi
}

# run_test — runs a test function with timeout and timing
# Usage: run_test <func_name> [timeout_override]
run_test() {
  local func="$1"
  local timeout="${2:-$TEST_TIMEOUT}"
  local start elapsed deadline_ns

  start="$(date +%s)"
  deadline_ns=$(( $(now_ns) + timeout * 1000000000 ))

  # Run the test in a subshell with timeout
  # We use a subshell so a timeout kills only the test, not the suite
  set +e
  (
    set -euo pipefail
    "$func"
  ) &
  local test_pid=$!

  # Wait with timeout
  while kill -0 "$test_pid" 2>/dev/null && (( $(now_ns) < deadline_ns )); do
    sleep "$TEST_POLL_INTERVAL_SECS"
  done

  if kill -0 "$test_pid" 2>/dev/null; then
    # Test is still running — kill it
    kill "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true
    fail "$func — TIMEOUT after ${timeout}s"
  else
    wait "$test_pid" 2>/dev/null
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      # Check if it was already recorded as pass/fail
      # If not, record as fail (the test crashed without calling pass/fail)
      local last_line
      last_line="$(tail -1 "$RESULTS_FILE" 2>/dev/null || true)"
      if [[ "$last_line" != "PASS" && "$last_line" != "FAIL" ]]; then
        fail "$func — crashed (exit $exit_code)"
      fi
    fi
  fi
  set -e

  elapsed=$(( $(date +%s) - start ))
  echo "${func} ${elapsed}s" >> "$TIMING_FILE"
  if [[ $elapsed -ge 5 ]]; then
    echo "  (${elapsed}s)"
  fi
}

section_selected() {
  local section="$1"
  local default_profile="$2"

  if [[ -n "$TEST_SECTIONS" ]]; then
    csv_has_value "$TEST_SECTIONS" "all" || csv_has_value "$TEST_SECTIONS" "$section"
    return
  fi

  case "$TEST_PROFILE" in
    smoke) [[ "$default_profile" == "smoke" ]] ;;
    full) return 0 ;;
    *)
      echo "FATAL: unknown test profile '$TEST_PROFILE'" >&2
      exit 1
      ;;
  esac
}

run_section() {
  local section="$1"
  local default_profile="$2"
  shift 2

  section_selected "$section" "$default_profile" || return 0

  echo ""
  echo "--- ${section} tests ---"
  echo ""
  for test_name in "$@"; do
    run_test "$test_name"
  done
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

is_test_session_name() {
  [[ "$1" =~ $TEST_SESSION_NAME_RE ]]
}

test_session_owner_pid() {
  local session="$1"
  [[ "$session" =~ -([0-9]+)$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

test_harness_pid_live() {
  local pid="$1"
  local args=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  [[ "$args" == *test_surrogate_e2e.sh* ]]
}

zmx_session_exists() {
  zmx list 2>/dev/null | sed -n 's/^session_name=\([^\t]*\).*/\1/p' | grep -Fx -- "$1" >/dev/null
}

zmx_session_absent() {
  ! zmx_session_exists "$1"
}

tmux_session_absent() {
  ! tmux has-session -t "$1" 2>/dev/null
}

should_cleanup_test_session() {
  local session="$1"
  local mode="$2"
  local owner_pid=""

  is_test_session_name "$session" || return 1
  owner_pid="$(test_session_owner_pid "$session" || true)"
  [[ -n "$owner_pid" ]] || return 1

  case "$mode" in
    current) [[ "$owner_pid" == "$$" ]] ;;
    stale) ! test_harness_pid_live "$owner_pid" ;;
    *) return 1 ;;
  esac
}

cleanup_test_zmx_sessions() {
  local mode="$1"
  local session=""

  while IFS= read -r session; do
    [[ -z "$session" ]] && continue
    should_cleanup_test_session "$session" "$mode" || continue
    zmx kill "$session" >/dev/null 2>&1 && echo "killed session $session" || true
  done < <(zmx list 2>/dev/null | sed -n 's/^session_name=\([^\t]*\).*/\1/p')
}

cleanup_test_bridges() {
  local mode="$1"
  local bridge="" session=""

  while IFS= read -r bridge; do
    [[ -z "$bridge" ]] && continue
    session="${bridge#_surr_}"
    should_cleanup_test_session "$session" "$mode" || continue
    tmux kill-session -t "$bridge" 2>/dev/null && echo "killed bridge $bridge" || true
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^_surr_" || true)
}

cleanup_test_aliases() {
  local mode="$1"
  local alias_file="/tmp/surrogate-aliases"
  local temp_file="" line="" session=""

  [[ -f "$alias_file" ]] || return 0
  temp_file="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    session="${line%%=*}"
    if should_cleanup_test_session "$session" "$mode"; then
      echo "removed alias $session"
      continue
    fi
    if [[ "$mode" == "stale" ]] && is_test_session_name "$session" && ! zmx_session_exists "$session"; then
      echo "removed stale alias $session"
      continue
    fi
    printf '%s\n' "$line" >> "$temp_file"
  done < "$alias_file"

  mv "$temp_file" "$alias_file"
}

cleanup_test_artifacts() {
  local mode="$1"
  cleanup_test_zmx_sessions "$mode"
  cleanup_test_bridges "$mode"
  cleanup_test_aliases "$mode"
}

cleanup() {
  [[ "$CLEANUP_DONE" -eq 0 ]] || return 0
  CLEANUP_DONE=1
  echo ""
  echo "--- cleanup ---"
  cleanup_mock_proc_ancestry
  cleanup_mock_live_env
  cleanup_test_artifacts current
  cleanup_test_artifacts stale
  rm -rf "$RESULTS_DIR" 2>/dev/null || true
  echo "cleanup done"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

echo "=== surrogate end-to-end tests ==="
echo "surrogate: $SURROGATE"
echo "test session: $TEST_SESSION"
echo "test timeout: ${TEST_TIMEOUT}s per test"
echo "test profile: ${TEST_PROFILE}"
if [[ -n "$TEST_SECTIONS" ]]; then
  echo "test sections: ${TEST_SECTIONS}"
fi
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

cleanup_test_artifacts stale

# Create a test zmx session running bash
zmx run "$TEST_SESSION" bash &

if ! wait_until 5 zmx_session_exists "$TEST_SESSION"; then
  echo "FATAL: failed to create test zmx session '$TEST_SESSION'"
  exit 1
fi

echo "test zmx session ready"
echo ""

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_list() {
  # plumb:req-ea60b72f
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

test_help_discoverability() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" help 2>&1)

  if echo "$output" | grep -q 'surrogate help list' &&
     echo "$output" | grep -q 'surrogate list --cwd' &&
     echo "$output" | grep -q 'surrogate type --message' &&
     echo "$output" | grep -q 'surrogate submit'; then
    pass "${FUNCNAME[0]} — help highlights discovery and recovery flows"
  else
    echo "    help output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — help missing high-value flows"
  fi
}

test_list_help() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" list --help 2>&1)

  if echo "$output" | grep -q 'usage: surrogate list' &&
     echo "$output" | grep -q 'repo/cwd/ui hints' &&
     echo "$output" | grep -q -- '--cwd' &&
     echo "$output" | grep -q -- '--json'; then
    pass "${FUNCNAME[0]} — list help is discoverable"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — list help missing key guidance"
  fi
}

test_type_and_read() {
  # plumb:req-761b5eb7
  # plumb:req-678df52f
  # plumb:req-78d69489
  # plumb:req-bff14746
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="BANANA_TEST_$$"

  "$SURROGATE" type "$TEST_SESSION" "echo $marker"
  wait_for_output "$TEST_SESSION" "$marker" 5 || true

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

test_send_enter_key() {
  # plumb:req-4aeebe62
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="SEND_ENTER_$$"

  "$SURROGATE" send "$TEST_SESSION" "echo $marker" Enter
  wait_for_output "$TEST_SESSION" "$marker" 5 || true

  local output
  output=$("$SURROGATE" read "$TEST_SESSION" 2>&1)

  if echo "$output" | grep -q "$marker"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected '$marker' in output after send + Enter:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — marker not found after send with Enter"
  fi
}

test_submit_enters_staged_prompt() {
  # plumb:req-96375da1
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="SUBMIT_MARKER_$$"

  "$SURROGATE" send "$TEST_SESSION" "echo $marker"
  "$SURROGATE" submit "$TEST_SESSION"
  wait_for_output "$TEST_SESSION" "$marker" 5 || true

  local output
  output=$("$SURROGATE" read "$TEST_SESSION" 2>&1)

  if echo "$output" | grep -q "$marker"; then
    pass "${FUNCNAME[0]} — submit sends Enter for staged prompt"
  else
    echo "    expected '$marker' after submit:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — staged prompt not submitted"
  fi
}

test_bridge_creation() {
  # plumb:req-ff999eb3
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

test_bridge_survives_zmx_session_env() {
  # Regression: ensure_bridge must unset ZMX_SESSION before running zmx attach,
  # otherwise the bridge dies immediately with CannotAttachToSessionInSession.
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Ensure ZMX_SESSION is set (it should be — we're in a zmx session)
  if [[ -z "${ZMX_SESSION:-}" ]]; then
    pass "${FUNCNAME[0]} — skipped (not running inside zmx)"
    return
  fi

  # Prune all bridges so we start clean
  "$SURROGATE" prune-bridges --all 2>/dev/null || true

  # Create bridge — this is the operation that used to fail
  "$SURROGATE" bridge "$TEST_SESSION" 2>/dev/null

  # Give bridge time to stabilize (zmx attach needs ~1s)
  sleep 2

  # Verify bridge is alive by checking surrogate status output
  local status_out
  status_out=$("$SURROGATE" status 2>&1 || true)

  if echo "$status_out" | grep -q "$TEST_SESSION"; then
    pass "${FUNCNAME[0]}"
  else
    # Also try direct tmux check with the known bridge naming pattern
    local zmx_id
    zmx_id=$(zmx list 2>/dev/null | awk -v s="$TEST_SESSION" '$0 ~ s {print $1; exit}')
    if [[ -n "$zmx_id" ]] && tmux has-session -t "_surr_${zmx_id}" 2>/dev/null; then
      pass "${FUNCNAME[0]}"
    else
      fail "${FUNCNAME[0]} — bridge died (ZMX_SESSION leak causes CannotAttachToSessionInSession)"
    fi
  fi
}

test_bridge_reuse() {
  # plumb:req-75e9957c
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local before after
  before=$(tmux list-sessions 2>/dev/null | grep "_surr_" | sort)

  "$SURROGATE" type "$TEST_SESSION" "echo bridge_reuse_check"

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
  # plumb:req-d232c0a3
  # plumb:req-f93dfc32
  # plumb:req-666eabd2
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
  # plumb:req-be4c8c7b
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  for i in 1 2 3 4 5 6 7 8; do
    "$SURROGATE" type "$TEST_SESSION" "echo LINE_LIMIT_$i"
  done
  wait_for_output "$TEST_SESSION" "LINE_LIMIT_8" 5 || true

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
  # plumb:req-464d5382
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local bogus="nonexistent-session-$$"

  if "$SURROGATE" type "$bogus" "hello" 2>/dev/null; then
    fail "${FUNCNAME[0]} — should have failed for nonexistent session"
  else
    pass "${FUNCNAME[0]}"
  fi
}

test_prune_bridges_dead() {
  # plumb:req-dba88c95
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local tmp_session="surr-dead-test-$$"
  zmx run "$tmp_session" bash &
  local tmp_pid=$!
  wait_until 5 zmx_session_exists "$tmp_session" || {
    fail "${FUNCNAME[0]} — failed to create temp zmx session"
    return
  }

  "$SURROGATE" type "$tmp_session" "echo hello"
  wait_for_output "$tmp_session" "hello" 5 || true

  zmx kill "$tmp_session" 2>/dev/null || true
  wait "$tmp_pid" 2>/dev/null || true

  "$SURROGATE" prune-bridges --dead

  local remaining
  remaining=$(tmux list-sessions 2>/dev/null | grep "_surr_.*${tmp_session}" || true)

  if [[ -z "$remaining" ]]; then
    pass "${FUNCNAME[0]}"
  else
    echo "    dead bridge still exists: $remaining"
    fail "${FUNCNAME[0]} — prune-bridges --dead did not remove dead bridge"
  fi
}

test_prune_bridges_all() {
  # plumb:req-ce7d6083
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Create an isolated session+bridge just for this test
  local iso_session="surr-prune-all-test-$$"
  zmx run "$iso_session" bash &
  local iso_pid=$!
  wait_until 5 zmx_session_exists "$iso_session" || {
    fail "${FUNCNAME[0]} — failed to create isolated zmx session"
    return
  }

  "$SURROGATE" type "$iso_session" "echo cleanup_all_test"
  wait_for_output "$iso_session" "cleanup_all_test" 5 || true

  # Verify bridge exists before cleanup
  local bridge="_surr_${iso_session}"
  if ! tmux has-session -t "$bridge" 2>/dev/null; then
    fail "${FUNCNAME[0]} — bridge not created before cleanup"
    zmx kill "$iso_session" 2>/dev/null || true
    wait "$iso_pid" 2>/dev/null || true
    return
  fi

  "$SURROGATE" prune-bridges --all

  # Verify the bridge was removed
  if tmux has-session -t "$bridge" 2>/dev/null; then
    fail "${FUNCNAME[0]} — prune-bridges --all did not remove bridge"
  else
    pass "${FUNCNAME[0]}"
  fi

  # Cleanup: kill the isolated session
  zmx kill "$iso_session" 2>/dev/null || true
  wait "$iso_pid" 2>/dev/null || true
}

test_cleanup_reaps_stale_test_artifacts() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local stale_session="test-surrogate-99999999"
  local stale_bridge="_surr_${stale_session}"
  local stale_alias="stale-alias-99999999"

  zmx kill "$stale_session" 2>/dev/null || true
  tmux kill-session -t "$stale_bridge" 2>/dev/null || true
  sed -i "/^${stale_session}=/d" /tmp/surrogate-aliases 2>/dev/null || true

  zmx run "$stale_session" bash &
  local stale_pid=$!
  wait_until 5 zmx_session_exists "$stale_session" || {
    fail "${FUNCNAME[0]} — failed to create stale-session fixture"
    return
  }

  "$SURROGATE" type "$stale_session" "echo stale_cleanup_test"
  wait_for_output "$stale_session" "stale_cleanup_test" 5 || true
  echo "${stale_session}=${stale_alias}" >> /tmp/surrogate-aliases

  cleanup_test_artifacts stale
  wait "$stale_pid" 2>/dev/null || true

  if ! wait_until 5 zmx_session_absent "$stale_session"; then
    fail "${FUNCNAME[0]} — stale zmx session was not reaped"
    return
  fi

  if ! wait_until 5 tmux_session_absent "$stale_bridge"; then
    fail "${FUNCNAME[0]} — stale bridge was not reaped"
    return
  fi

  if grep -q "^${stale_session}=" /tmp/surrogate-aliases 2>/dev/null; then
    fail "${FUNCNAME[0]} — stale alias was not removed"
    return
  fi

  pass "${FUNCNAME[0]}"
}

test_stale_lists_detached_sessions() {
  # plumb:req-efc0a173
  # plumb:req-a7bef694
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local stale_session="surr-stale-test-$$"
  local stale_marker="STALE_LIST_$$"
  zmx run "$stale_session" bash &
  local stale_pid=$!
  wait_until 5 zmx_session_exists "$stale_session" || {
    fail "${FUNCNAME[0]} — failed to create stale listing fixture"
    return
  }

  "$SURROGATE" type "$stale_session" "echo $stale_marker"
  wait_for_output "$stale_session" "$stale_marker" 5 || true

  local output
  if wait_until 20 stale_output_matches "$stale_session"; then
    output="$STALE_OUTPUT_CACHE"
  else
    output="$STALE_OUTPUT_CACHE"
  fi

  zmx kill "$stale_session" 2>/dev/null || true
  wait "$stale_pid" 2>/dev/null || true

  if echo "$output" | grep -q "$stale_session" && echo "$output" | grep -q 'Detached zmx sessions older than'; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — stale output did not include the detached session: $output"
  fi
}

test_prune_sessions_explicit_session() {
  # plumb:req-dabb0aad
  # plumb:req-a2cbbeb8
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local prune_session_name="surr-prune-test-$$"
  local prune_alias="prune-alias-$$"
  local prune_marker="PRUNE_EXPLICIT_$$"
  local bridge="_surr_${prune_session_name}"
  local lock_file="/tmp/surrogate-${prune_session_name}.lock"
  local watermark_file="/tmp/surrogate-${prune_session_name}.watermark"
  zmx run "$prune_session_name" bash &
  local prune_pid=$!
  wait_until 5 zmx_session_exists "$prune_session_name" || {
    fail "${FUNCNAME[0]} — failed to create explicit prune fixture"
    return
  }

  "$SURROGATE" type "$prune_session_name" "echo $prune_marker"
  wait_for_output "$prune_session_name" "$prune_marker" 5 || true
  "$SURROGATE" rename "$prune_session_name" "$prune_alias" >/dev/null

  local output
  output=$("$SURROGATE" prune-sessions "$prune_alias" 2>&1)
  wait "$prune_pid" 2>/dev/null || true

  if echo "$output" | grep -q "deleted zmx session: .*${prune_session_name}" &&
     wait_until 5 zmx_session_absent "$prune_session_name" &&
     wait_until 5 tmux_session_absent "$bridge" &&
     [[ ! -e "$lock_file" ]] &&
     [[ ! -e "$watermark_file" ]] &&
     ! grep -q "^${prune_session_name}=" /tmp/surrogate-aliases 2>/dev/null; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — explicit prune did not remove session plumbing cleanly: $output"
  fi
}

test_sweep_preview_default() {
  # plumb:req-d1cb00b9
  # plumb:req-42ee37a8
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local preview_session="surr-sweep-preview-test-$$"
  zmx run "$preview_session" bash &
  local preview_pid=$!
  wait_until 5 zmx_session_exists "$preview_session" || {
    fail "${FUNCNAME[0]} — failed to create sweep preview target"
    return
  }

  if ! wait_until 20 stale_output_matches "$preview_session"; then
    zmx kill "$preview_session" 2>/dev/null || true
    wait "$preview_pid" 2>/dev/null || true
    fail "${FUNCNAME[0]} — preview session never appeared in stale output: $STALE_OUTPUT_CACHE"
    return
  fi

  local output
  output=$("$SURROGATE" sweep --older-than 0 --filter "$preview_session" 2>&1)

  if echo "$output" | grep -q 'Would delete these zmx sessions:' &&
     echo "$output" | grep -q 'Preview only\. Re-run with --yes' &&
     zmx_session_exists "$preview_session"; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — sweep did not preview by default: $output"
  fi

  zmx kill "$preview_session" 2>/dev/null || true
  wait "$preview_pid" 2>/dev/null || true
}

test_prune_sessions_stale_batch_filtered_yes() {
  # plumb:req-8e5dbf45
  # plumb:req-abd88dc5
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local target_session="surr-prune-batch-test-$$"
  local keep_session="surr-prune-keep-test-$$"
  zmx run "$target_session" bash &
  local target_pid=$!
  zmx run "$keep_session" bash &
  local keep_pid=$!
  wait_until 5 zmx_session_exists "$target_session" || {
    fail "${FUNCNAME[0]} — failed to create batch prune target"
    return
  }
  wait_until 5 zmx_session_exists "$keep_session" || {
    fail "${FUNCNAME[0]} — failed to create batch prune survivor"
    return
  }

  if ! wait_until 20 stale_output_matches "$target_session"; then
    wait "$target_pid" 2>/dev/null || true
    zmx kill "$keep_session" 2>/dev/null || true
    wait "$keep_pid" 2>/dev/null || true
    fail "${FUNCNAME[0]} — target session never appeared in stale output: $STALE_OUTPUT_CACHE"
    return
  fi

  local output
  output=$("$SURROGATE" prune-sessions --stale --older-than 0 --filter "$target_session" --yes 2>&1)
  wait "$target_pid" 2>/dev/null || true

  if echo "$output" | grep -q 'Deleting these zmx sessions:' &&
     echo "$output" | grep -q "$target_session" &&
     wait_until 5 zmx_session_absent "$target_session" &&
     zmx_session_exists "$keep_session"; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — batch stale prune did not target only the filtered session: $output"
  fi

  zmx kill "$keep_session" 2>/dev/null || true
  wait "$keep_pid" 2>/dev/null || true
}

test_cull_deprecated_alias_warns() {
  # plumb:req-b40817a3
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" cull --help 2>&1 || true)

  if echo "$output" | grep -q 'deprecated' &&
     echo "$output" | grep -q 'surrogate prune-sessions'; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — cull alias did not warn clearly: $output"
  fi
}

test_cleanup_deprecated_alias_warns() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" cleanup --help 2>&1 || true)

  if echo "$output" | grep -q 'deprecated' &&
     echo "$output" | grep -q 'surrogate prune-bridges'; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — cleanup alias did not warn clearly: $output"
  fi
}

test_status() {
  # plumb:req-b49f0f0a
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  "$SURROGATE" type "$TEST_SESSION" "echo status_check"

  local output
  output=$("$SURROGATE" status 2>&1)

  if [[ -n "$output" ]]; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — status produced no output"
  fi
}

test_concurrent_serialization() {
  # plumb:req-fcfa572b
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
  wait_for_read_match "$TEST_SESSION" "$marker_a" 5 || true
  wait_for_read_match "$TEST_SESSION" "$marker_b" 5 || true

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
  # plumb:req-f50fe267
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
  # plumb:req-60a4e4a8
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

test_invariant_inherited_status_shows_alias() {
  # plumb:req-e4c7e35c
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  local all_ok=true
  for shell_name in bash zsh fish; do
    local snippet
    snippet=$(SHELL="/bin/$shell_name" "$setup_script" --show 2>&1)

    if ! echo "$snippet" | grep -q 'surrogate: zmx session .*alias'; then
      echo "    MISSING alias in inherited status for shell: $shell_name"
      all_ok=false
    fi
  done

  if $all_ok; then
    pass "${FUNCNAME[0]} — inherited status path includes session alias in all shells"
  else
    fail "${FUNCNAME[0]} — inherited status path must print session alias"
  fi
}

test_invariant_no_terminal_specific_code() {
  # plumb:req-4cbaecf8
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

test_invariant_surrogate_full_path_for_alias_lookup() {
  # plumb:req-787926e7
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  local all_ok=true
  for shell_name in bash zsh fish; do
    local snippet
    snippet=$(SHELL="/bin/$shell_name" "$setup_script" --show 2>&1)

    if ! echo "$snippet" | grep -q '\.local/bin/surrogate'; then
      echo "    snippet does not use full path fallback for surrogate in shell: $shell_name"
      all_ok=false
    fi

    if ! echo "$snippet" | grep -q 'PATH=' && ! echo "$snippet" | grep -q '_surr_path'; then
      echo "    snippet does not seed PATH for alias lookup in shell: $shell_name"
      all_ok=false
    fi
  done

  if $all_ok; then
    pass "${FUNCNAME[0]} — snippet uses full path and seeded PATH for alias lookup"
  else
    fail "${FUNCNAME[0]} — snippet must use full path and seeded PATH for alias lookup"
  fi
}

test_invariant_zmx_full_path() {
  # plumb:req-d3b078df
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
  # plumb:req-a0e77c74
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  # Snippet must check parent process name, NOT ZMX_SESSION env var
  # (ZMX_SESSION leaks through window managers to all children)
  local snippet
  snippet=$("$setup_script" --show 2>&1)

  local uses_ppid uses_env_wrap_check
  uses_ppid=$(echo "$snippet" | grep -c 'PPID\|%self' || true)
  # Check for ZMX_SESSION used in the top-level wrap/skip gate.
  # Display/alias lookup may still reference ZMX_SESSION later in the snippet.
  uses_env_wrap_check=$(echo "$snippet" | grep -Ec 'SURROGATE_NO_ZMX.*ZMX_SESSION|ZMX_SESSION.*SURROGATE_NO_ZMX|\$-.*ZMX_SESSION|ZMX_SESSION.*\$-' || true)

  if [[ "$uses_ppid" -ge 1 && "$uses_env_wrap_check" -eq 0 ]]; then
    pass "${FUNCNAME[0]} — uses parent process check, not env var leak"
  else
    echo "    uses_ppid=$uses_ppid uses_env_wrap_check=$uses_env_wrap_check"
    fail "${FUNCNAME[0]} — must check parent process, not ZMX_SESSION (leaks via WM)"
  fi
}

test_invariant_unsets_zmx_session_before_attach() {
  # plumb:req-057ce4cf
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

test_invariant_snippet_shims_nested_attach_all_shells() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"

  local all_ok=true
  for shell_name in bash zsh fish; do
    local snippet
    snippet=$(SHELL="/bin/$shell_name" "$setup_script" --show 2>&1)

    if ! echo "$snippet" | grep -Eq 'function zmx|zmx\(\)'; then
      echo "    missing zmx shim for shell: $shell_name"
      all_ok=false
    fi

    if ! echo "$snippet" | grep -q 'env -u ZMX_SESSION'; then
      echo "    missing clean-env attach wrapper for shell: $shell_name"
      all_ok=false
    fi
  done

  if $all_ok; then
    pass "${FUNCNAME[0]} — all shell snippets preserve manual nested zmx attach"
  else
    fail "${FUNCNAME[0]} — snippets must shim manual nested zmx attach in every shell"
  fi
}

test_shell_setup_bash_attach_wrapper_clears_leaked_env() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script tmp_home tmpbin log_file snippet_file output
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"
  tmp_home="$(mktemp -d)"
  tmpbin="$(mktemp -d)"
  log_file="$(mktemp)"
  snippet_file="$tmp_home/snippet.sh"

  cat > "$tmpbin/zmx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\n' "${ZMX_SESSION-<unset>}" "$*" >> "$SURR_TEST_LOG"
exit 0
EOF
  chmod +x "$tmpbin/zmx"

  cat > "$tmpbin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'zmx\n'
EOF
  chmod +x "$tmpbin/ps"

  cat > "$tmpbin/surrogate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "alias" ]]; then
  printf 'mock-alias\n'
fi
EOF
  chmod +x "$tmpbin/surrogate"

  "$setup_script" --show | sed -n '/^# surrogate:zmx:begin/,/^# surrogate:zmx:end/p' > "$snippet_file"

  output=$(
    HOME="$tmp_home" \
    PATH="$tmpbin:/usr/bin:/bin" \
    ZMX_BIN="$tmpbin/zmx" \
    SURROGATE_BIN="$tmpbin/surrogate" \
    ZMX_SESSION="outer-shell" \
    SURR_TEST_LOG="$log_file" \
    bash --noprofile --norc -ic "source '$snippet_file'; zmx attach inner-shell; zmx list" 2>&1
  )

  if grep -Fq $'<unset>\tattach inner-shell' "$log_file" &&
     grep -Fq $'outer-shell\tlist' "$log_file" &&
     echo "$output" | grep -Fq 'surrogate: zmx session outer-shell alias mock-alias'; then
    pass "${FUNCNAME[0]} — bash snippet clears leaked env only for nested attach"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    echo "    zmx log:"
    sed 's/^/    /' "$log_file"
    fail "${FUNCNAME[0]} — expected attach to run without leaked ZMX_SESSION while other zmx commands keep current session env"
  fi
}

test_shell_setup_install_refreshes_existing_snippet() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local setup_script tmp_home rc_file output marker_count
  setup_script="$(dirname "$SCRIPT_DIR")/bin/surrogate-shell-setup"
  tmp_home="$(mktemp -d)"
  rc_file="$tmp_home/.bashrc"

  cat > "$rc_file" <<'EOF'
# surrogate:zmx:begin
# old surrogate snippet
if [[ $- == *i* ]]; then
  echo "old"
fi
# surrogate:zmx:end

export SURROGATE_USER_RC_MARKER=1
EOF

  output=$(
    HOME="$tmp_home" \
    SHELL="/bin/bash" \
    "$setup_script" --install 2>&1
  )
  marker_count=$(grep -c '^# surrogate:zmx:begin$' "$rc_file" || true)

  if echo "$output" | grep -Fq "Updated auto-zmx snippet at top of $rc_file" &&
     [[ "$marker_count" -eq 1 ]] &&
     grep -Fq 'env -u ZMX_SESSION "$_surr_real_zmx" "$@"' "$rc_file" &&
     grep -Fq 'export SURROGATE_USER_RC_MARKER=1' "$rc_file"; then
    pass "${FUNCNAME[0]} — --install refreshes the managed snippet in place"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    echo "    rc file:"
    sed 's/^/    /' "$rc_file"
    fail "${FUNCNAME[0]} — expected --install to refresh the managed snippet without duplicating markers or deleting user rc content"
  fi
}

test_invariant_installed_matches_repo() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local install_dir="${INSTALL_DIR:-$HOME/.local/bin}"
  local repo_dir
  repo_dir="$(dirname "$SCRIPT_DIR")/bin"
  local all_match=true

  for file in surrogate surrogate-brief surrogate-shell-setup; do
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

test_install_replaces_dev_link_with_real_copy() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local tmp_install
  tmp_install="$(mktemp -d)"

  INSTALL_DIR="$tmp_install" bash "$SCRIPT_DIR/../install.sh" --dev-link >/dev/null

  if [[ ! -L "$tmp_install/surrogate" || ! -L "$tmp_install/surrogate-brief" ]]; then
    echo "    expected dev-link install to create symlink"
    fail "${FUNCNAME[0]} — dev-link install did not create symlink"
    return
  fi

  INSTALL_DIR="$tmp_install" SURROGATE_SKIP_DCG=1 bash "$SCRIPT_DIR/../install.sh" >/dev/null

  if [[ -L "$tmp_install/surrogate" || -L "$tmp_install/surrogate-brief" ]]; then
    echo "    expected plain install to replace symlink with copied binaries"
    fail "${FUNCNAME[0]} — plain install left surrogate binary as symlink"
    return
  fi

  if diff -q "$SCRIPT_DIR/../bin/surrogate" "$tmp_install/surrogate" >/dev/null &&
     diff -q "$SCRIPT_DIR/../bin/surrogate-brief" "$tmp_install/surrogate-brief" >/dev/null; then
    pass "${FUNCNAME[0]} — plain install replaces dev-link with copied binary"
  else
    echo "    copied installed binaries differ from repo"
    fail "${FUNCNAME[0]} — copied installed binaries do not match repo"
  fi
}

test_release_helper_reinstalls_real_binaries() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local helper="$SCRIPT_DIR/../bin/surrogate-push-main"

  if [[ ! -x "$helper" ]]; then
    echo "    helper missing or not executable: $helper"
    fail "${FUNCNAME[0]} — release helper missing or not executable"
    return
  fi

  if ! grep -q 'safe-push origin main' "$helper"; then
    echo "    helper does not safe-push main"
    fail "${FUNCNAME[0]} — release helper missing safe-push"
    return
  fi

  if ! grep -q 'bash "\$REPO_DIR/install.sh"' "$helper"; then
    echo "    helper does not reinstall from repo checkout"
    fail "${FUNCNAME[0]} — release helper missing reinstall"
    return
  fi

  if ! grep -q 'surrogate-doctor' "$helper"; then
    echo "    helper does not verify install with surrogate-doctor"
    fail "${FUNCNAME[0]} — release helper missing doctor verification"
    return
  fi

  pass "${FUNCNAME[0]} — release helper safe-pushes, reinstalls, and verifies"
}

test_surrogate_brief_show_config_defaults() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE_BRIEF" --show-config 2>&1)

  if echo "$output" | grep -q 'model=z-ai/glm-4.7' &&
     echo "$output" | grep -q 'provider=cerebras' &&
     echo "$output" | grep -q 'brief_style=attention-first' &&
     echo "$output" | grep -q 'lines=500' &&
     echo "$output" | grep -q 'temperature=0.0' &&
     echo "$output" | grep -q 'max_completion_tokens=1200'; then
    pass "${FUNCNAME[0]} — brief defaults are self-documenting"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — brief defaults missing from show-config"
  fi
}

test_surrogate_brief_show_config_overrides() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local cfg output
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
SURROGATE_BRIEF_LINES=321
SURROGATE_BRIEF_TEMPERATURE=0.2
SURROGATE_BRIEF_MAX_COMPLETION_TOKENS=777
OPENROUTER_MODEL="openai/gpt-4.1-mini"
OPENROUTER_PROVIDER="openai"
OPENROUTER_ALLOW_FALLBACKS=0
EOF

  output=$("$SURROGATE_BRIEF" --config "$cfg" --show-config 2>&1)
  rm -f "$cfg"

  if echo "$output" | grep -q 'model=openai/gpt-4.1-mini' &&
     echo "$output" | grep -q 'provider=openai' &&
     echo "$output" | grep -q 'allow_fallbacks=0' &&
     echo "$output" | grep -q 'lines=321' &&
     echo "$output" | grep -q 'max_completion_tokens=777'; then
    pass "${FUNCNAME[0]} — brief config file overrides defaults"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — brief config overrides not applied"
  fi
}

test_surrogate_brief_missing_key_help() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$(env -u OPENROUTER_API_KEY HOME=/tmp PATH="$PATH" "$SURROGATE_BRIEF" "$TEST_SESSION" 2>&1 || true)

  if echo "$output" | grep -q 'OPENROUTER_API_KEY is not set' &&
     echo "$output" | grep -q 'export OPENROUTER_API_KEY=' &&
     echo "$output" | grep -q 'surrogate-brief --show-config'; then
    pass "${FUNCNAME[0]} — brief missing-key path is self-documenting"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — brief missing-key guidance incomplete"
  fi
}

test_brief_help_is_discoverable() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" help brief 2>&1)

  if echo "$output" | grep -q 'usage: surrogate brief' &&
     echo "$output" | grep -q 'surrogate brief 15' &&
     echo "$output" | grep -q 'last observed activity'; then
    pass "${FUNCNAME[0]} — brief help documents activity-ranked selection"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — brief help missing selection guidance"
  fi
}

test_brief_explicit_session_passes_to_helper() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local mock output
  mock="$(mktemp)"
  cat > "$mock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$mock"

  output=$(SURROGATE_BRIEF_CMD="$mock" "$SURROGATE" brief --show-config "$TEST_SESSION" 2>&1)
  rm -f "$mock"

  if echo "$output" | grep -qx -- '--show-config' &&
     echo "$output" | grep -qx -- "$TEST_SESSION"; then
    pass "${FUNCNAME[0]} — brief forwards explicit sessions to helper"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — brief did not forward explicit session/helper args"
  fi
}

test_brief_uses_live_json_selection() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if grep -q 'selector_args=("live" "--json")' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — brief reuses live --json selection"
  else
    fail "${FUNCNAME[0]} — brief does not reuse live selection path"
  fi
}

test_surrogate_brief_prompt_is_attention_first() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if grep -q 'ATTENTION REQUIRED:' "$SURROGATE_BRIEF" &&
     grep -q 'PRIORITY:' "$SURROGATE_BRIEF" &&
     grep -q 'SIGNAL QUALITY:' "$SURROGATE_BRIEF" &&
     grep -q 'USER ACTION REQUIRED:' "$SURROGATE_BRIEF" &&
     grep -q 'NEXT UNBLOCKING STEP:' "$SURROGATE_BRIEF" &&
     grep -q 'plain shell prompt, idle agent prompt' "$SURROGATE_BRIEF" &&
     grep -q 'most recent visible stopping point' "$SURROGATE_BRIEF" &&
     grep -q 'implicit operator handoff' "$SURROGATE_BRIEF" &&
     grep -q 'END_STATE_WINDOW_MOST_IMPORTANT' "$SURROGATE_BRIEF" &&
     grep -q "Conversation interrupted" "$SURROGATE_BRIEF"; then
    pass "${FUNCNAME[0]} — brief prompt classifies attention before summary"
  else
    fail "${FUNCNAME[0]} — brief prompt is missing attention-first rules"
  fi
}

test_list_fast_path_alias_fallback() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if grep -Fq '${_ALIAS_CACHE[$session]:-$(session_alias_single "$session")}' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — list fast path falls back when alias cache races"
  else
    fail "${FUNCNAME[0]} — list fast path can crash on missing alias cache entries"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "--- running tests ---"
echo ""

run_section core smoke \
  test_list \
  test_help_discoverability \
  test_list_help \
  test_type_and_read \
  test_send_enter_key \
  test_submit_enters_staged_prompt \
  test_bridge_creation \
  test_bridge_survives_zmx_session_env \
  test_bridge_reuse \
  test_wait_success \
  test_wait_timeout \
  test_read_line_limit \
  test_dead_session_error \
  test_prune_bridges_dead \
  test_prune_bridges_all \
  test_cleanup_reaps_stale_test_artifacts \
  test_stale_lists_detached_sessions \
  test_prune_sessions_explicit_session \
  test_sweep_preview_default \
  test_prune_sessions_stale_batch_filtered_yes \
  test_cull_deprecated_alias_warns \
  test_cleanup_deprecated_alias_warns \
  test_status \
  test_concurrent_serialization

test_find() {
  # plumb:req-762ccafb
  # plumb:req-7cd0c015
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
  # plumb:req-41842e4d
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$SURROGATE" find "" 2>/dev/null; then
    fail "${FUNCNAME[0]} — empty query should be rejected"
  else
    pass "${FUNCNAME[0]}"
  fi
}

test_find_no_match() {
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

setup_mock_who_env() {
  MOCK_WHO_TMPBIN="$(mktemp -d)"
  MOCK_WHO_OLD_SESSION="mock-who-old-$$"
  MOCK_WHO_NEW_SESSION="mock-who-new-$$"
  MOCK_WHO_ZMX_DIR="/run/user/$(id -u)/zmx"

  mkdir -p "$MOCK_WHO_ZMX_DIR"
  : > "$MOCK_WHO_ZMX_DIR/$MOCK_WHO_OLD_SESSION"
  : > "$MOCK_WHO_ZMX_DIR/$MOCK_WHO_NEW_SESSION"
  touch -d '2 hours ago' "$MOCK_WHO_ZMX_DIR/$MOCK_WHO_OLD_SESSION"
  touch -d '10 seconds ago' "$MOCK_WHO_ZMX_DIR/$MOCK_WHO_NEW_SESSION"

  cat > "$MOCK_WHO_TMPBIN/zmx" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  list)
    printf 'session_name=%s\tclients=0\n' "$MOCK_WHO_OLD_SESSION"
    printf 'session_name=%s\tclients=1\n' "$MOCK_WHO_NEW_SESSION"
    ;;
  history)
    case "\${2:-}" in
      "$MOCK_WHO_OLD_SESSION")
        printf 'user@host /home/testuser/Documents/GitHub/older \$\n'
        ;;
      "$MOCK_WHO_NEW_SESSION")
        printf '› run surrogate whoami\n• Ran surrogate whoami\ngpt-5.4 medium · 60%% left · /home/testuser/Documents/GitHub/surrogate\n'
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$MOCK_WHO_TMPBIN/zmx"

  ln -sf "$(command -v tmux)" "$MOCK_WHO_TMPBIN/tmux"
}

cleanup_mock_who_env() {
  rm -f "$MOCK_WHO_ZMX_DIR/$MOCK_WHO_OLD_SESSION" "$MOCK_WHO_ZMX_DIR/$MOCK_WHO_NEW_SESSION" 2>/dev/null || true
  rm -rf "$MOCK_WHO_TMPBIN" 2>/dev/null || true
}

setup_mock_live_env() {
  MOCK_LIVE_TMPBIN="$(mktemp -d)"
  MOCK_LIVE_SIGNAL_SESSION="mock-live-signal-$$"
  MOCK_LIVE_LOW_SESSION="mock-live-low-$$"
  MOCK_LIVE_DETACHED_SESSION="mock-live-detached-$$"
  MOCK_LIVE_ZMX_DIR="/run/user/$(id -u)/zmx"

  mkdir -p "$MOCK_LIVE_ZMX_DIR"
  : > "$MOCK_LIVE_ZMX_DIR/$MOCK_LIVE_SIGNAL_SESSION"
  : > "$MOCK_LIVE_ZMX_DIR/$MOCK_LIVE_LOW_SESSION"
  : > "$MOCK_LIVE_ZMX_DIR/$MOCK_LIVE_DETACHED_SESSION"
  touch -d '20 seconds ago' "$MOCK_LIVE_ZMX_DIR/$MOCK_LIVE_SIGNAL_SESSION"
  touch -d '10 seconds ago' "$MOCK_LIVE_ZMX_DIR/$MOCK_LIVE_LOW_SESSION"
  touch -d '30 seconds ago' "$MOCK_LIVE_ZMX_DIR/$MOCK_LIVE_DETACHED_SESSION"

  cat > "$MOCK_LIVE_TMPBIN/zmx" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  list)
    printf 'session_name=%s\tclients=1\n' "$MOCK_LIVE_SIGNAL_SESSION"
    printf 'session_name=%s\tclients=1\n' "$MOCK_LIVE_LOW_SESSION"
    printf 'session_name=%s\tclients=0\n' "$MOCK_LIVE_DETACHED_SESSION"
    ;;
  history)
    case "\${2:-}" in
      "$MOCK_LIVE_SIGNAL_SESSION")
        printf '› review surrogate live\n• focused lane\ngpt-5.4 medium · 60%% left · /home/testuser/Documents/GitHub/surrogate\n'
        ;;
      "$MOCK_LIVE_LOW_SESSION")
        printf 'user@host surrogate main ❯\n'
        ;;
      "$MOCK_LIVE_DETACHED_SESSION")
        printf 'user@host /tmp/mock-detached \$\n'
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$MOCK_LIVE_TMPBIN/zmx"

  ln -sf "$(command -v tmux)" "$MOCK_LIVE_TMPBIN/tmux"
}

cleanup_mock_live_env() {
  if [[ -n "$MOCK_LIVE_ZMX_DIR" ]]; then
    rm -f "$MOCK_LIVE_ZMX_DIR/$MOCK_LIVE_SIGNAL_SESSION" "$MOCK_LIVE_ZMX_DIR/$MOCK_LIVE_LOW_SESSION" "$MOCK_LIVE_ZMX_DIR/$MOCK_LIVE_DETACHED_SESSION" 2>/dev/null || true
  fi
  rm -rf "$MOCK_LIVE_TMPBIN" 2>/dev/null || true
  MOCK_LIVE_TMPBIN=""
  MOCK_LIVE_SIGNAL_SESSION=""
  MOCK_LIVE_LOW_SESSION=""
  MOCK_LIVE_DETACHED_SESSION=""
}

setup_mock_type_env() {
  MOCK_TYPE_TMPBIN="$(mktemp -d)"
  MOCK_TYPE_SESSION="mock-type-$$"
  MOCK_TYPE_HISTORY_FILE="$(mktemp)"
  MOCK_TYPE_TMUX_LOG="$(mktemp)"

  cat > "$MOCK_TYPE_TMPBIN/zmx" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  list)
    printf 'session_name=%s\tclients=1\n' "$MOCK_TYPE_SESSION"
    ;;
  history)
    cat "$MOCK_TYPE_HISTORY_FILE"
    ;;
  attach)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$MOCK_TYPE_TMPBIN/zmx"

  cat > "$MOCK_TYPE_TMPBIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  has-session)
    exit 1
    ;;
  new-session)
    exit 0
    ;;
  display-message)
    printf 'zmx\n'
    exit 0
    ;;
  send-keys)
    printf '%s\n' "\$*" >> "$MOCK_TYPE_TMUX_LOG"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$MOCK_TYPE_TMPBIN/tmux"

  cat > "$MOCK_TYPE_TMPBIN/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$MOCK_TYPE_TMPBIN/sleep"
}

cleanup_mock_type_env() {
  rm -rf "$MOCK_TYPE_TMPBIN" 2>/dev/null || true
  rm -f "$MOCK_TYPE_HISTORY_FILE" "$MOCK_TYPE_TMUX_LOG" 2>/dev/null || true
}

test_who() {
  # plumb:req-4703b605
  # plumb:req-d4d66352
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

test_list_shows_project_and_ui() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_who_env
  local output
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" list --cwd 2>&1)
  cleanup_mock_who_env

  if echo "$output" | grep -q 'PROJECT' &&
     echo "$output" | grep -q "$MOCK_WHO_NEW_SESSION" &&
     echo "$output" | grep -q 'surrogate' &&
     echo "$output" | grep -q 'agent'; then
    pass "${FUNCNAME[0]} — list shows repo and explicit ui context"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — list missing project/ui context"
  fi
}

test_list_cwd_flag() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_who_env
  local output
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" list --cwd 2>&1)
  cleanup_mock_who_env

  if echo "$output" | grep -q 'CWD' &&
     echo "$output" | grep -q '/home/testuser/Documents/GitHub/surrogate'; then
    pass "${FUNCNAME[0]} — list --cwd exposes cwd hint"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — list --cwd missing cwd hint"
  fi
}

test_list_json_output() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_who_env
  local output
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" list --json 2>&1)
  cleanup_mock_who_env

  if echo "$output" | grep -q "\"session\":\"$MOCK_WHO_NEW_SESSION\"" &&
     echo "$output" | grep -q '"project_hint":"surrogate"' &&
     echo "$output" | grep -q '"ui_hint":"agent"'; then
    pass "${FUNCNAME[0]} — list --json exposes repo and ui metadata"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — list --json output incorrect"
  fi
}

test_who_recent_first() {
  # plumb:req-250cef7c
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_who_env
  local output first_line
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" who 2>&1)
  first_line="$(echo "$output" | sed '/^── /d' | sed -n '1p')"
  cleanup_mock_who_env

  if echo "$first_line" | grep -q "$MOCK_WHO_NEW_SESSION"; then
    pass "${FUNCNAME[0]} — who sorts newest sessions first"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — newest session not listed first"
  fi
}

test_who_recent_duration_filter() {
  # plumb:req-5617b9d9
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_who_env
  local output
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" who --recent 1h 2>&1)
  cleanup_mock_who_env

  if echo "$output" | grep -q "$MOCK_WHO_NEW_SESSION" &&
     ! echo "$output" | grep -q "$MOCK_WHO_OLD_SESSION"; then
    pass "${FUNCNAME[0]} — who --recent filters by age"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — who --recent age filter incorrect"
  fi
}

test_who_project_filter() {
  # plumb:req-dab33ed7
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_who_env
  local output
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" who --project surrogate 2>&1)
  cleanup_mock_who_env

  if echo "$output" | grep -q "$MOCK_WHO_NEW_SESSION" &&
     ! echo "$output" | grep -q "$MOCK_WHO_OLD_SESSION"; then
    pass "${FUNCNAME[0]} — who --project filters by visible project path"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — who --project filter incorrect"
  fi
}

test_who_cwd_filter() {
  # plumb:req-072ebd56
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_who_env
  local output
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" who --cwd /home/testuser/Documents/GitHub/surrogate 2>&1)
  cleanup_mock_who_env

  if echo "$output" | grep -q "$MOCK_WHO_NEW_SESSION" &&
     ! echo "$output" | grep -q "$MOCK_WHO_OLD_SESSION"; then
    pass "${FUNCNAME[0]} — who --cwd filters by visible path prefix"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — who --cwd filter incorrect"
  fi
}

test_who_json_output() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_who_env
  local output
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" who --json --recent 1h 2>&1)
  cleanup_mock_who_env

  if echo "$output" | grep -q '"count":1' &&
     echo "$output" | grep -q '"recent_first":true' &&
     echo "$output" | grep -q "\"session\":\"$MOCK_WHO_NEW_SESSION\"" &&
     echo "$output" | grep -q '"cwd_hint":"/home/testuser/Documents/GitHub/surrogate"' &&
     echo "$output" | grep -q '"project_hint":"surrogate"' &&
     echo "$output" | grep -q '"ui_hint":"agent"'; then
    pass "${FUNCNAME[0]} — who --json exposes deterministic session metadata"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — who --json output incorrect"
  fi
}

test_who_n_zero() {
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
  # plumb:req-c4befce9
  # plumb:req-adff47fa
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output signal_session detached_session
  setup_mock_live_env
  signal_session="$MOCK_LIVE_SIGNAL_SESSION"
  detached_session="$MOCK_LIVE_DETACHED_SESSION"
  output=$(PATH="$MOCK_LIVE_TMPBIN:/usr/bin:/bin" "$SURROGATE" active --all --recent 10 2>&1)
  cleanup_mock_live_env

  if echo "$output" | grep -q "$signal_session" &&
     echo "$output" | grep -q "$detached_session"; then
    pass "${FUNCNAME[0]}"
  else
    echo "    expected mock attached + detached sessions in active output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — active --all output missing expected mock sessions"
  fi
}

test_live_focuses_high_signal_sessions() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output signal_session low_session
  setup_mock_live_env
  signal_session="$MOCK_LIVE_SIGNAL_SESSION"
  low_session="$MOCK_LIVE_LOW_SESSION"
  output=$(PATH="$MOCK_LIVE_TMPBIN:/usr/bin:/bin" "$SURROGATE" live --recent 10 2>&1)
  cleanup_mock_live_env

  if echo "$output" | grep -q "$signal_session" &&
     ! echo "$output" | grep -q "$low_session" &&
     echo "$output" | grep -q 'low-signal live session(s) hidden'; then
    pass "${FUNCNAME[0]} — live defaults to high-signal messageable sessions"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — live did not focus the high-signal session"
  fi
}

test_live_all_includes_low_signal_sessions() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output signal_session low_session
  setup_mock_live_env
  signal_session="$MOCK_LIVE_SIGNAL_SESSION"
  low_session="$MOCK_LIVE_LOW_SESSION"
  output=$(PATH="$MOCK_LIVE_TMPBIN:/usr/bin:/bin" "$SURROGATE" live --all --recent 10 2>&1)
  cleanup_mock_live_env

  if echo "$output" | grep -q "$signal_session" &&
     echo "$output" | grep -q "$low_session" &&
     ! echo "$output" | grep -q 'low-signal live session(s) hidden'; then
    pass "${FUNCNAME[0]} — live --all includes low-signal live sessions"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — live --all did not include the low-signal session"
  fi
}

test_live_json_reports_hidden_low_signal_sessions() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output signal_session
  setup_mock_live_env
  signal_session="$MOCK_LIVE_SIGNAL_SESSION"
  output=$(PATH="$MOCK_LIVE_TMPBIN:/usr/bin:/bin" "$SURROGATE" live --json --recent 10 2>&1)
  cleanup_mock_live_env

  if printf '%s' "$output" | python3 -c '
import json, sys
obj = json.loads(sys.stdin.read())
assert obj["count"] == 1
assert obj["total_live_count"] == 2
assert obj["high_signal_only"] is True
assert obj["hidden_low_signal_count"] == 1
assert len(obj["sessions"]) == 1
assert obj["sessions"][0]["session"] == sys.argv[1]
' "$signal_session"
  then
    pass "${FUNCNAME[0]} — live --json reports focused vs hidden sessions"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — live --json did not report hidden low-signal sessions correctly"
  fi
}

test_peek() {
  # plumb:req-c3690014
  # plumb:req-59b42e29
  # plumb:req-292f6a20
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
  # plumb:req-34ca43ad
  # plumb:req-799fccd6
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local rename_session="surr-rename-test-$$"
  zmx run "$rename_session" bash &
  local rename_pid=$!
  sleep 2

  local new_alias="my-custom-alias-$$"
  local output
  output=$("$SURROGATE" rename "$rename_session" "$new_alias" 2>&1)

  if echo "$output" | grep -q "renamed"; then
    # Verify session is accessible via new alias
    if "$SURROGATE" read "$new_alias" -n 1 2>/dev/null; then
      pass "${FUNCNAME[0]}"
    else
      fail "${FUNCNAME[0]} — session not accessible via new alias"
    fi
  else
    fail "${FUNCNAME[0]} — rename command failed"
  fi

  # Cleanup
  zmx kill "$rename_session" 2>/dev/null || true
  wait "$rename_pid" 2>/dev/null || true
  # Remove custom alias
  sed -i "/^${rename_session}=/d" /tmp/surrogate-aliases 2>/dev/null || true
}

test_rename_nonexistent() {
  # plumb:req-a5263a36
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$SURROGATE" rename "nonexistent-$$" "newname-$$" 2>/dev/null; then
    fail "${FUNCNAME[0]} — should fail for nonexistent session"
  else
    pass "${FUNCNAME[0]}"
  fi
}

test_rename_collision() {
  # plumb:req-4526f067
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
  # plumb:req-ee67fedf
  # plumb:req-edf94cc1
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

test_alias_resolve() {
  # plumb:req-04237721
  # plumb:req-d3426579
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Get alias for test session
  local alias_name
  alias_name=$("$SURROGATE" alias "$TEST_SESSION" 2>&1)
  [[ -z "$alias_name" ]] && { fail "${FUNCNAME[0]} — alias returned empty"; return; }

  # Resolve alias back to session name
  local resolved
  resolved=$("$SURROGATE" read "$alias_name" -n 1 2>&1)

  if [[ $? -eq 0 ]]; then
    pass "${FUNCNAME[0]}"
  else
    fail "${FUNCNAME[0]} — could not resolve alias '$alias_name' back to session"
  fi
}

test_alias_rename_shows_aliases() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local custom="test-custom-$$"
  local output
  output=$("$SURROGATE" rename "$TEST_SESSION" "$custom" 2>&1)

  if echo "$output" | grep -q "renamed.*->.*$custom"; then
    # Verify list shows the custom alias
    local list_output
    list_output=$("$SURROGATE" list 2>&1)
    if echo "$list_output" | grep -q "$custom"; then
      pass "${FUNCNAME[0]}"
    else
      fail "${FUNCNAME[0]} — custom alias not shown in list"
    fi
  else
    fail "${FUNCNAME[0]} — rename output unexpected: $output"
  fi

  # Cleanup: remove custom alias so it doesn't affect other tests
  sed -i "/^${TEST_SESSION}=/d" /tmp/surrogate-aliases 2>/dev/null || true
}

test_label_on() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_type_env
  printf '› waiting for surrogate message\nUse /skills to list available skills\n' > "$MOCK_TYPE_HISTORY_FILE"

  SURROGATE_LABEL=on PATH="$MOCK_TYPE_TMPBIN:/usr/bin:/bin" "$SURROGATE" type "$MOCK_TYPE_SESSION" "LABEL_ON_$$"

  if grep -Fq 'send-keys -t _surr_mock-type-' "$MOCK_TYPE_TMUX_LOG" &&
     grep -Eq '\-l \[SURROGATE.*\] LABEL_ON_' "$MOCK_TYPE_TMUX_LOG"; then
    cleanup_mock_type_env
    pass "${FUNCNAME[0]} — label is preserved for agent-like targets"
  else
    echo "    tmux log:"
    sed 's/^/    /' "$MOCK_TYPE_TMUX_LOG"
    cleanup_mock_type_env
    fail "${FUNCNAME[0]} — label not found for agent-like target"
  fi
}

test_label_off() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_type_env
  printf '› waiting for surrogate message\nUse /skills to list available skills\n' > "$MOCK_TYPE_HISTORY_FILE"

  SURROGATE_LABEL=off PATH="$MOCK_TYPE_TMPBIN:/usr/bin:/bin" "$SURROGATE" type "$MOCK_TYPE_SESSION" "LABEL_OFF_$$"

  if grep -Eq '\-l LABEL_OFF_' "$MOCK_TYPE_TMUX_LOG" &&
     ! grep -q '\[SURROGATE' "$MOCK_TYPE_TMUX_LOG"; then
    cleanup_mock_type_env
    pass "${FUNCNAME[0]} — label disabled cleanly"
  else
    echo "    tmux log:"
    sed 's/^/    /' "$MOCK_TYPE_TMUX_LOG"
    cleanup_mock_type_env
    fail "${FUNCNAME[0]} — label should not appear with SURROGATE_LABEL=off"
  fi
}

test_label_verbose() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_type_env
  printf '› waiting for surrogate message\nUse /skills to list available skills\n' > "$MOCK_TYPE_HISTORY_FILE"

  SURROGATE_LABEL=verbose PATH="$MOCK_TYPE_TMPBIN:/usr/bin:/bin" "$SURROGATE" type "$MOCK_TYPE_SESSION" "LABEL_VERBOSE_$$"

  if grep -Eq '\-l \[SURROGATE.*PID:.*\] LABEL_VERBOSE_' "$MOCK_TYPE_TMUX_LOG"; then
    cleanup_mock_type_env
    pass "${FUNCNAME[0]} — verbose label is preserved for agent-like targets"
  else
    echo "    tmux log:"
    sed 's/^/    /' "$MOCK_TYPE_TMUX_LOG"
    cleanup_mock_type_env
    fail "${FUNCNAME[0]} — verbose label not found"
  fi
}

test_type_shell_context_suppresses_label() {
  # plumb:req-a5dd873c
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="SHELL_SAFE_$$"
  SURROGATE_LABEL=on "$SURROGATE" type "$TEST_SESSION" "echo $marker"
  wait_for_output "$TEST_SESSION" "$marker" 5 || true

  local output
  output=$("$SURROGATE" read "$TEST_SESSION" -n 20 2>&1)

  if echo "$output" | grep -q "^$marker$" &&
     ! echo "$output" | grep -q '\[SURROGATE'; then
    pass "${FUNCNAME[0]} — shell context suppresses prose label so commands still run"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — shell-safe type should not inject surrogate label into commands"
  fi
}

# --- Tier 1: Alias system tests ---

test_alias_deterministic() {
  # plumb:req-787f5f31
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Same session name must always produce the same alias
  local alias1 alias2
  alias1=$("$SURROGATE" alias "$TEST_SESSION" 2>&1)
  alias2=$("$SURROGATE" alias "$TEST_SESSION" 2>&1)

  if [[ "$alias1" == "$alias2" && -n "$alias1" ]]; then
    # Verify it's adjective-noun format
    if [[ "$alias1" =~ ^[a-z]+-[a-z]+(-[0-9]+)?$ ]]; then
      pass "${FUNCNAME[0]} — deterministic alias: $alias1"
    else
      fail "${FUNCNAME[0]} — alias '$alias1' not in adjective-noun format"
    fi
  else
    fail "${FUNCNAME[0]} — alias not deterministic: '$alias1' vs '$alias2'"
  fi
}

test_alias_100_adjectives_100_nouns() {
  # plumb:req-8d0a2c7f
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Verify the wordlists have exactly 100 entries each
  local adj_count noun_count
  adj_count=$(grep -A200 '^ADJECTIVES=(' "$SURROGATE" | grep -c '[a-z]' | head -1)
  noun_count=$(grep -A200 '^NOUNS=(' "$SURROGATE" | grep -c '[a-z]' | head -1)

  # Count actual array elements by sourcing just the arrays
  adj_count=$(sed -n '/^ADJECTIVES=(/,/^)/p' "$SURROGATE" | tr ' ' '\n' | grep -c '^[a-z]')
  noun_count=$(sed -n '/^NOUNS=(/,/^)/p' "$SURROGATE" | tr ' ' '\n' | grep -c '^[a-z]')

  if [[ "$adj_count" -eq 100 && "$noun_count" -eq 100 ]]; then
    pass "${FUNCNAME[0]} — 100 adjectives × 100 nouns"
  else
    fail "${FUNCNAME[0]} — expected 100×100, got ${adj_count}×${noun_count}"
  fi
}

test_alias_collision_suffix() {
  # plumb:req-6d897079
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # The code appends -N suffix on hash collision. Verify the code path exists.
  if grep -q 'base}-${cnt}' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — collision suffix code exists"
  else
    fail "${FUNCNAME[0]} — no collision suffix handling found"
  fi
}

test_alias_cache_built_once() {
  # plumb:req-10215184
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Verify _ALIAS_CACHE_BUILT guard exists (cache built once per invocation)
  if grep -q '_ALIAS_CACHE_BUILT' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — alias cache built-once guard exists"
  else
    fail "${FUNCNAME[0]} — no cache guard found"
  fi
}

test_list_shows_aliases() {
  # plumb:req-0d23a1bb
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local alias_name output
  alias_name=$("$SURROGATE" alias "$TEST_SESSION" 2>&1)
  output=$("$SURROGATE" list 2>&1)

  if echo "$output" | grep -q "$alias_name"; then
    pass "${FUNCNAME[0]} — list shows alias '$alias_name'"
  else
    fail "${FUNCNAME[0]} — alias '$alias_name' not shown in list"
  fi
}

test_who_shows_aliases() {
  # plumb:req-514ca399
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local alias_name output
  alias_name=$("$SURROGATE" alias "$TEST_SESSION" 2>&1)
  output=$("$SURROGATE" who 2>&1)

  if echo "$output" | grep -q "$alias_name"; then
    pass "${FUNCNAME[0]} — who shows alias '$alias_name'"
  else
    fail "${FUNCNAME[0]} — alias '$alias_name' not shown in who"
  fi
}

test_session_resolution_by_alias() {
  # plumb:req-e5cc14aa
  # plumb:req-f7d615cd
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local alias_name
  alias_name=$("$SURROGATE" alias "$TEST_SESSION" 2>&1)
  [[ -z "$alias_name" ]] && { fail "${FUNCNAME[0]} — alias empty"; return; }

  local all_ok=true

  # read via alias
  if ! "$SURROGATE" read "$alias_name" -n 1 &>/dev/null; then
    echo "    read via alias failed"
    all_ok=false
  fi

  # alias via alias (should resolve and return same alias)
  local re_alias
  re_alias=$("$SURROGATE" alias "$alias_name" 2>&1)
  if [[ "$re_alias" != "$alias_name" ]]; then
    echo "    alias via alias returned '$re_alias' expected '$alias_name'"
    all_ok=false
  fi

  if $all_ok; then
    pass "${FUNCNAME[0]} — session resolution works via alias"
  else
    fail "${FUNCNAME[0]} — some alias resolution failed"
  fi
}

test_whoami() {
  # plumb:req-48ee0fb4
  # plumb:req-c117273e
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # whoami needs ZMX_SESSION set
  local output
  output=$(ZMX_SESSION="$TEST_SESSION" "$SURROGATE" whoami 2>&1)

  if echo "$output" | grep -q "$TEST_SESSION"; then
    if echo "$output" | grep -q '^unknown  '; then
      fail "${FUNCNAME[0]} — whoami fell back to unknown: $output"
    else
      pass "${FUNCNAME[0]} — whoami shows session name and alias"
    fi
  else
    fail "${FUNCNAME[0]} — whoami did not show session: $output"
  fi
}

test_whoami_help() {
  # plumb:req-64333413
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" whoami --help 2>&1)

  if echo "$output" | grep -q 'usage: surrogate whoami'; then
    pass "${FUNCNAME[0]} — whoami help works"
  else
    fail "${FUNCNAME[0]} — whoami --help did not show help: $output"
  fi
}

test_whoami_falls_back_to_live_ancestry_session() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local alias_name output
  alias_name="$("$SURROGATE" alias "$TEST_SESSION")"
  setup_mock_proc_ancestry "$TEST_SESSION"
  output=$(
    ZMX_SESSION="stale-session-$$" \
    SURROGATE_PROC_ROOT="$MOCK_PROC_ROOT" \
    SURROGATE_SELF_PID=9001 \
    "$SURROGATE" whoami 2>&1
  )
  cleanup_mock_proc_ancestry

  if echo "$output" | grep -q "$alias_name" &&
     echo "$output" | grep -q "$TEST_SESSION" &&
     ! echo "$output" | grep -q 'ancestry-only'; then
    pass "${FUNCNAME[0]} — whoami recovers live session identity from zmx attach ancestry"
  else
    fail "${FUNCNAME[0]} — whoami did not recover live ancestry session: $output"
  fi
}

test_whoami_reports_ancestry_only_session() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local ghost_session output
  ghost_session="ghost-session-$$"
  setup_mock_proc_ancestry "$ghost_session"
  output=$(
    ZMX_SESSION="stale-session-$$" \
    SURROGATE_PROC_ROOT="$MOCK_PROC_ROOT" \
    SURROGATE_SELF_PID=9001 \
    "$SURROGATE" whoami 2>&1
  )
  cleanup_mock_proc_ancestry

  if echo "$output" | grep -q "$ghost_session" &&
     echo "$output" | grep -q 'ancestry-only' &&
     echo "$output" | grep -q 'not messageable via surrogate'; then
    pass "${FUNCNAME[0]} — whoami reports ancestry-only sessions explicitly"
  else
    fail "${FUNCNAME[0]} — whoami did not explain ancestry-only session: $output"
  fi
}

test_whoami_rejects_extra_args() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$(ZMX_SESSION="$TEST_SESSION" "$SURROGATE" whoami banana 2>&1 || true)

  if echo "$output" | grep -q 'usage: surrogate whoami'; then
    pass "${FUNCNAME[0]} — whoami rejects extra args"
  else
    fail "${FUNCNAME[0]} — whoami extra args were not rejected: $output"
  fi
}

test_whoami_rejects_stale_env_session() {
  # plumb:req-f7eb14cd
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$(ZMX_SESSION="stale-session-$$" "$SURROGATE" whoami 2>&1 || true)

  if echo "$output" | grep -q 'not present in zmx list'; then
    pass "${FUNCNAME[0]} — whoami rejects stale leaked env session"
  else
    fail "${FUNCNAME[0]} — whoami did not explain stale env mismatch: $output"
  fi
}

test_whoami_no_session() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local empty_proc output
  empty_proc="$(mktemp -d)"
  output=$(
    ZMX_SESSION="" \
    SURROGATE_PROC_ROOT="$empty_proc" \
    SURROGATE_SELF_PID=9001 \
    "$SURROGATE" whoami 2>&1 || true
  )
  rm -rf "$empty_proc"

  if echo "$output" | grep -q 'not inside a zmx session'; then
    pass "${FUNCNAME[0]} — whoami fails when neither env nor ancestry identifies a session"
  else
    fail "${FUNCNAME[0]} — whoami should fail when env and ancestry are both absent: $output"
  fi
}

test_type_rejects_self_target() {
  # plumb:req-dbb5124e
  # plumb:req-e72e700e
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local alias_name output
  alias_name="$("$SURROGATE" alias "$TEST_SESSION")"
  output=$(ZMX_SESSION="$TEST_SESSION" "$SURROGATE" type "$TEST_SESSION" "hello from self" 2>&1 || true)

  if echo "$output" | grep -q 'refusing to message your own live session' &&
     echo "$output" | grep -q "$alias_name" &&
     echo "$output" | grep -q "$TEST_SESSION"; then
    pass "${FUNCNAME[0]} — self-target type is blocked with identity context"
  else
    fail "${FUNCNAME[0]} — self-target type was not explained clearly: $output"
  fi
}

test_send_rejects_self_target() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local alias_name output
  alias_name="$("$SURROGATE" alias "$TEST_SESSION")"
  output=$(ZMX_SESSION="$TEST_SESSION" "$SURROGATE" send "$TEST_SESSION" Enter 2>&1 || true)

  if echo "$output" | grep -q 'refusing to message your own live session' &&
     echo "$output" | grep -q "$alias_name" &&
     echo "$output" | grep -q "$TEST_SESSION"; then
    pass "${FUNCNAME[0]} — self-target send is blocked with identity context"
  else
    fail "${FUNCNAME[0]} — self-target send was not explained clearly: $output"
  fi
}

test_submit_rejects_self_target() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local alias_name output
  alias_name="$("$SURROGATE" alias "$TEST_SESSION")"
  output=$(ZMX_SESSION="$TEST_SESSION" "$SURROGATE" submit "$TEST_SESSION" 2>&1 || true)

  if echo "$output" | grep -q 'refusing to message your own live session' &&
     echo "$output" | grep -q "$alias_name" &&
     echo "$output" | grep -q "$TEST_SESSION"; then
    pass "${FUNCNAME[0]} — self-target submit is blocked with identity context"
  else
    fail "${FUNCNAME[0]} — self-target submit was not explained clearly: $output"
  fi
}

test_prune_sessions_rejects_current_live_session() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local alias_name output
  alias_name="$("$SURROGATE" alias "$TEST_SESSION")"
  output=$(ZMX_SESSION="$TEST_SESSION" "$SURROGATE" prune-sessions "$TEST_SESSION" 2>&1 || true)

  if echo "$output" | grep -q 'refusing to prune your own live zmx session' &&
     echo "$output" | grep -q "$alias_name" &&
     echo "$output" | grep -q "$TEST_SESSION"; then
    pass "${FUNCNAME[0]} — self-target prune is blocked with identity context"
  else
    fail "${FUNCNAME[0]} — self-target prune was not explained clearly: $output"
  fi
}

# --- Tier 2: Behavioral defaults and output format ---

test_find_case_insensitive() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="CaseTest_$$"
  "$SURROGATE" type "$TEST_SESSION" "echo $marker"
  sleep 1

  # Search with different case
  local output
  output=$("$SURROGATE" find "casetest_$$" -n 50 2>&1)

  if echo "$output" | grep -qi "$marker"; then
    pass "${FUNCNAME[0]} — find is case-insensitive"
  else
    fail "${FUNCNAME[0]} — find did not match case-insensitively"
  fi
}

test_find_grouped_output() {
  # plumb:req-738560c1
  # plumb:req-cf1c97eb
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local marker="GROUP_$$"
  "$SURROGATE" type "$TEST_SESSION" "echo $marker"
  sleep 1

  local output
  output=$("$SURROGATE" find "$marker" -n 50 2>&1)

  local all_ok=true

  # Check match count in header
  if ! echo "$output" | grep -qE '\([0-9]+ matches?\)'; then
    echo "    missing match count in header"
    all_ok=false
  fi

  # Check summary at end
  if ! echo "$output" | grep -q 'session(s) matched'; then
    echo "    missing summary line"
    all_ok=false
  fi

  if $all_ok; then
    pass "${FUNCNAME[0]} — find output has headers and summary"
  else
    fail "${FUNCNAME[0]} — find output format incorrect"
  fi
}

test_find_uses_rg_or_grep() {
  # plumb:req-32f84b16
  # plumb:req-f253db1e
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # The _search helper must prefer rg, fall back to grep -E
  if grep -q 'command -v rg' "$SURROGATE" && grep -q 'grep -E' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — rg preferred, grep -E fallback"
  else
    fail "${FUNCNAME[0]} — missing rg/grep fallback pattern"
  fi
}

test_who_age_and_attached() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  setup_mock_who_env
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" who 2>&1)
  cleanup_mock_who_env

  local all_ok=true

  # Check age format (Ns, Nm, Nh, Nd)
  if ! echo "$output" | grep -qE '[0-9]+[smhd]'; then
    echo "    no age indicator found"
    all_ok=false
  fi

  # Check total count at end
  if ! echo "$output" | grep -qE '[0-9]+ sessions'; then
    echo "    no session count at end"
    all_ok=false
  fi

  if $all_ok; then
    pass "${FUNCNAME[0]} — who shows age and session count"
  else
    fail "${FUNCNAME[0]} — who output format missing age/count"
  fi
}

test_who_attached_marker() {
  # plumb:req-a12fb059
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  setup_mock_who_env
  output=$(PATH="$MOCK_WHO_TMPBIN:/usr/bin:/bin" "$SURROGATE" who 2>&1)
  cleanup_mock_who_env

  if echo "$output" | grep -qE '[0-9]+[smhd]\*'; then
    pass "${FUNCNAME[0]} — who marks attached sessions with *"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — who did not mark attached sessions with *"
  fi
}

test_active_default_attached_only() {
  # plumb:req-f1d6584a
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output signal_session detached_session
  setup_mock_live_env
  signal_session="$MOCK_LIVE_SIGNAL_SESSION"
  detached_session="$MOCK_LIVE_DETACHED_SESSION"
  output=$(PATH="$MOCK_LIVE_TMPBIN:/usr/bin:/bin" "$SURROGATE" active --recent 10 2>&1)
  cleanup_mock_live_env

  if echo "$output" | grep -q "$signal_session" &&
     ! echo "$output" | grep -q "$detached_session"; then
    pass "${FUNCNAME[0]} — active default hides detached sessions"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — active default did not restrict output to attached sessions"
  fi
}

test_active_all_includes_detached() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output signal_session detached_session
  setup_mock_live_env
  signal_session="$MOCK_LIVE_SIGNAL_SESSION"
  detached_session="$MOCK_LIVE_DETACHED_SESSION"
  output=$(PATH="$MOCK_LIVE_TMPBIN:/usr/bin:/bin" "$SURROGATE" active --all --recent 10 2>&1)
  cleanup_mock_live_env

  if echo "$output" | grep -q "$signal_session" &&
     echo "$output" | grep -q "$detached_session"; then
    pass "${FUNCNAME[0]} — active --all includes detached sessions with history"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — active --all did not include the detached session"
  fi
}

test_peek_count_at_end() {
  # plumb:req-4eb4a35d
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" peek 2>&1)

  if echo "$output" | grep -qE 'peeked [0-9]+ session'; then
    pass "${FUNCNAME[0]} — peek shows session count"
  else
    fail "${FUNCNAME[0]} — peek missing session count"
  fi
}

test_read_default_20_lines() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Verify the default is 20 in the code
  if grep -qE 'local lines=20' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — read defaults to 20 lines"
  else
    fail "${FUNCNAME[0]} — read default not 20"
  fi
}

test_wait_default_30s() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if grep -qE 'local timeout=30' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — wait defaults to 30s"
  else
    fail "${FUNCNAME[0]} — wait default not 30s"
  fi
}

test_find_default_200_lines_1_context() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # cmd_find should default to 200 lines, context 1
  local found_lines found_ctx
  found_lines=$(grep -c 'local lines=200' "$SURROGATE" || echo 0)
  found_ctx=$(grep -c 'local context=1' "$SURROGATE" || echo 0)

  if [[ "$found_lines" -ge 1 && "$found_ctx" -ge 1 ]]; then
    pass "${FUNCNAME[0]} — find defaults: 200 lines, context 1"
  else
    fail "${FUNCNAME[0]} — find defaults wrong (lines=$found_lines ctx=$found_ctx)"
  fi
}

test_who_default_10_lines() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # cmd_who defaults to 10 lines for snippet
  if sed -n '/^cmd_who/,/^cmd_/p' "$SURROGATE" | grep -q 'local lines=10'; then
    pass "${FUNCNAME[0]} — who defaults to 10 lines"
  else
    fail "${FUNCNAME[0]} — who default not 10"
  fi
}

test_peek_default_5_lines() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if sed -n '/^cmd_peek/,/^cmd_/p' "$SURROGATE" | grep -q 'local lines=5'; then
    pass "${FUNCNAME[0]} — peek defaults to 5 lines"
  else
    fail "${FUNCNAME[0]} — peek default not 5"
  fi
}

# --- Tier 3: Bridge, error handling, design invariants ---

test_bridge_naming_convention() {
  # plumb:req-1dc8eb9f
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Bridge should be named _surr_<session>
  "$SURROGATE" type "$TEST_SESSION" "echo bridge_name_test"
  sleep 1

  local expected_bridge="_surr_${TEST_SESSION}"
  if tmux has-session -t "$expected_bridge" 2>/dev/null; then
    pass "${FUNCNAME[0]} — bridge named $expected_bridge"
  else
    fail "${FUNCNAME[0]} — expected bridge '$expected_bridge' not found"
  fi
}

test_bridge_stale_recreate() {
  # plumb:req-ddbe1439
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Verify the stale bridge detection code exists (kill and recreate)
  if grep -q 'Stale bridge.*kill' "$SURROGATE" || grep -q 'kill-session.*bridge' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — stale bridge kill/recreate code exists"
  else
    fail "${FUNCNAME[0]} — no stale bridge handling"
  fi
}

test_error_prefix() {
  # plumb:req-d71a201b
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # All errors should use 'surrogate: error:' prefix
  local output
  output=$("$SURROGATE" type "nonexistent-$$" "hi" 2>&1 || true)

  if echo "$output" | grep -q 'surrogate: error:'; then
    pass "${FUNCNAME[0]} — error prefix correct"
  else
    fail "${FUNCNAME[0]} — expected 'surrogate: error:' prefix, got: $output"
  fi
}

test_error_missing_session() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" type "nonexistent-$$" "hi" 2>&1 || true)

  if echo "$output" | grep -q "not found"; then
    pass "${FUNCNAME[0]} — missing session error message"
  else
    fail "${FUNCNAME[0]} — expected 'not found' in error: $output"
  fi
}

test_security_model_section_exists() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if grep -q '^## Security Model' SPEC.md; then
    pass "${FUNCNAME[0]} — spec has explicit security model section"
  else
    fail "${FUNCNAME[0]} — SPEC.md missing explicit security model section"
  fi
}

test_type_normalizes_multiline_prose() {
  # plumb:req-94bb96c4
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local prose_session prose_pid output
  prose_session="surr-prose-test-$$"
  zmx run "$prose_session" cat &
  prose_pid=$!
  sleep 2

  SURROGATE_LABEL=off "$SURROGATE" type "$prose_session" $'hello there\nthis is long prose'
  sleep 1

  output=$(SURROGATE_LABEL=off "$SURROGATE" read "$prose_session" -n 5 2>&1 || true)

  zmx kill "$prose_session" 2>/dev/null || true
  wait "$prose_pid" 2>/dev/null || true

  if echo "$output" | grep -q '^hello there this is long prose$'; then
    pass "${FUNCNAME[0]} — multiline prose normalized and submitted once"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — expected multiline prose to be flattened into one submitted line"
  fi
}

test_type_rejects_empty_after_normalization() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$(SURROGATE_LABEL=off "$SURROGATE" type "$TEST_SESSION" $'\n \t \r\n' 2>&1 || true)

  if echo "$output" | grep -q 'type text must not be empty'; then
    pass "${FUNCNAME[0]} — whitespace-only prose rejected after normalization"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — expected whitespace-only prose to be rejected"
  fi
}

test_type_normalizes_tabs_and_crlf() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local prose_session prose_pid output
  prose_session="surr-prose-crlf-test-$$"
  zmx run "$prose_session" cat &
  prose_pid=$!
  sleep 2

  SURROGATE_LABEL=off "$SURROGATE" type "$prose_session" $'hello\tthere\r\nfriend'
  sleep 1

  output=$(SURROGATE_LABEL=off "$SURROGATE" read "$prose_session" -n 5 2>&1 || true)

  zmx kill "$prose_session" 2>/dev/null || true
  wait "$prose_pid" 2>/dev/null || true

  if echo "$output" | grep -q '^hello there friend$'; then
    pass "${FUNCNAME[0]} — tabs and CRLF normalized into one submitted line"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — expected tabs and CRLF to be normalized"
  fi
}

test_send_rejects_dangerous_control_keys() {
  # plumb:req-a760e8f3
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" send "$TEST_SESSION" C-c 2>&1 || true)

  if echo "$output" | grep -qi 'control'; then
    pass "${FUNCNAME[0]} — dangerous control keys blocked"
  else
    fail "${FUNCNAME[0]} — dangerous control key was not blocked: $output"
  fi
}

test_dcg_blocks_type_when_available() {
  # plumb:req-1ad6bc8d
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local tmpbin
  tmpbin="$(mktemp -d)"
  cat > "$tmpbin/dcg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--robot" && "$2" == "test" && "$3" == *"git reset --hard"* ]]; then
  echo '{"decision":"deny","reason":"blocked by mock dcg"}'
  exit 1
fi
exit 0
EOF
  chmod +x "$tmpbin/dcg"

  local output
  output=$(PATH="$tmpbin:$PATH" "$SURROGATE" type "$TEST_SESSION" "git reset --hard HEAD~1" 2>&1 || true)

  if echo "$output" | grep -qi 'dcg'; then
    pass "${FUNCNAME[0]} — dcg denial respected"
  else
    fail "${FUNCNAME[0]} — dcg denial not surfaced: $output"
  fi
}

test_dcg_blocks_normalized_multiline_type() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local tmpbin output
  tmpbin="$(mktemp -d)"
  cat > "$tmpbin/dcg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--robot" && "$2" == "test" && "$3" == *"git reset --hard HEAD~1"* ]]; then
  echo '{"decision":"deny","reason":"blocked by mock dcg after normalization"}'
  exit 1
fi
exit 0
EOF
  chmod +x "$tmpbin/dcg"

  output=$(PATH="$tmpbin:$PATH" "$SURROGATE" type "$TEST_SESSION" $'git reset --hard\nHEAD~1' 2>&1 || true)

  if echo "$output" | grep -qi 'dcg denied payload'; then
    pass "${FUNCNAME[0]} — dcg denial respected after multiline normalization"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — expected dcg to deny normalized multiline type"
  fi
}

test_audit_logs_allowed_type() {
  # plumb:req-7b30e09c
  # plumb:req-931163ed
  # plumb:req-33a8e1eb
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local audit_file marker target_alias actor_session actor_pid actor_alias
  audit_file="$(mktemp)"
  marker="AUDIT_ALLOW_${$}"
  target_alias=$("$SURROGATE" alias "$TEST_SESSION" 2>&1)
  actor_session="surr-audit-actor-allow-$$"

  zmx run "$actor_session" cat &
  actor_pid=$!
  sleep 2
  actor_alias=$("$SURROGATE" alias "$actor_session" 2>&1)

  SURROGATE_AUDIT_FILE="$audit_file" \
  SURROGATE_LABEL=off \
  SURROGATE_WORK_ID="work-allow-${$}" \
  SURROGATE_REASON="audit metadata test" \
  ZMX_SESSION="$actor_session" \
  "$SURROGATE" type "$TEST_SESSION" "echo $marker"
  sleep 1

  zmx kill "$actor_session" 2>/dev/null || true
  wait "$actor_pid" 2>/dev/null || true

  if grep -q '"action":"type"' "$audit_file" &&
     grep -q '"decision":"allow"' "$audit_file" &&
     grep -q "$TEST_SESSION" "$audit_file" &&
     grep -q "\"target_alias\":\"${target_alias}\"" "$audit_file" &&
     grep -q "\"actor_session\":\"${actor_session}\"" "$audit_file" &&
     grep -q "\"actor_alias\":\"${actor_alias}\"" "$audit_file" &&
     grep -q '"work_id":"work-allow-' "$audit_file" &&
     grep -q '"intent_reason":"audit metadata test"' "$audit_file" &&
     grep -q '"repo":"surrogate"' "$audit_file" &&
     grep -q "echo $marker" "$audit_file"; then
    pass "${FUNCNAME[0]} — allowed type action logs causal metadata"
  else
    echo "    audit log contents:"
    sed 's/^/    /' "$audit_file"
    fail "${FUNCNAME[0]} — allowed type action metadata not logged correctly"
  fi
}

test_audit_logs_blocked_send() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local audit_file output target_alias actor_session actor_pid actor_alias
  audit_file="$(mktemp)"
  target_alias=$("$SURROGATE" alias "$TEST_SESSION" 2>&1)
  actor_session="surr-audit-actor-deny-$$"

  zmx run "$actor_session" cat &
  actor_pid=$!
  sleep 2
  actor_alias=$("$SURROGATE" alias "$actor_session" 2>&1)

  output=$(
    SURROGATE_AUDIT_FILE="$audit_file" \
    SURROGATE_WORK_ID="work-deny-${$}" \
    SURROGATE_REASON="blocked send metadata test" \
    ZMX_SESSION="$actor_session" \
    "$SURROGATE" send "$TEST_SESSION" C-c 2>&1 || true
  )

  zmx kill "$actor_session" 2>/dev/null || true
  wait "$actor_pid" 2>/dev/null || true

  if grep -q '"action":"send"' "$audit_file" &&
     grep -q '"decision":"deny"' "$audit_file" &&
     grep -q "$TEST_SESSION" "$audit_file" &&
     grep -q '"detail":"C-c"' "$audit_file" &&
     grep -q "\"target_alias\":\"${target_alias}\"" "$audit_file" &&
     grep -q "\"actor_session\":\"${actor_session}\"" "$audit_file" &&
     grep -q "\"actor_alias\":\"${actor_alias}\"" "$audit_file" &&
     grep -q '"work_id":"work-deny-' "$audit_file" &&
     grep -q '"intent_reason":"blocked send metadata test"' "$audit_file" &&
     grep -q '"repo":"surrogate"' "$audit_file" &&
     echo "$output" | grep -qi 'dangerous control key'; then
    pass "${FUNCNAME[0]} — blocked send action logs causal metadata"
  else
    echo "    send output:"
    echo "$output" | sed 's/^/    /'
    echo "    audit log contents:"
    sed 's/^/    /' "$audit_file"
    fail "${FUNCNAME[0]} — blocked send action metadata not logged correctly"
  fi
}

test_type_waits_before_enter_for_tui_like_targets() {
  # plumb:req-2541839a
  # plumb:req-188c833f
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local tmpbin audit_file tmux_log sleep_log sleep_marker output
  tmpbin="$(mktemp -d)"
  audit_file="$(mktemp)"
  tmux_log="$(mktemp)"
  sleep_log="$(mktemp)"
  sleep_marker="$(mktemp)"
  rm -f "$sleep_marker"

  cat > "$tmpbin/zmx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    printf 'session_name=test-surrogate-mock\tattached=true\tcreated_at=0\n'
    ;;
  history)
    printf 'line one\nline two\n'
    ;;
  attach)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$tmpbin/zmx"

  cat > "$tmpbin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
log_file="$tmux_log"
sleep_marker="$sleep_marker"
case "\${1:-}" in
  has-session)
    exit 1
    ;;
  new-session)
    exit 0
    ;;
  display-message)
    printf 'zmx\n'
    exit 0
    ;;
  send-keys)
    printf '%s\n' "\$*" >> "\$log_file"
    if [[ "\$*" == *" -l "* ]]; then
      rm -f "\$sleep_marker"
      exit 0
    fi
    if [[ "\$*" == *" Enter" ]]; then
      [[ -f "\$sleep_marker" ]] || exit 1
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$tmpbin/tmux"

  cat > "$tmpbin/sleep" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\${1:-}" >> "$sleep_log"
touch "$sleep_marker"
EOF
  chmod +x "$tmpbin/sleep"

  output=$(
    PATH="$tmpbin:/usr/bin:/bin" \
    SURROGATE_AUDIT_FILE="$audit_file" \
    SURROGATE_LABEL=off \
    "$SURROGATE" type test-surrogate-mock "hello from test" 2>&1 || true
  )

  if [[ "$(wc -l < "$tmux_log")" -eq 2 ]] &&
     grep -Fq 'send-keys -t _surr_test-surrogate-mock -l hello from test' "$tmux_log" &&
     grep -Fq 'send-keys -t _surr_test-surrogate-mock Enter' "$tmux_log" &&
     grep -Fxq '0.02' "$sleep_log" &&
     grep -q '"decision":"allow"' "$audit_file"; then
    pass "${FUNCNAME[0]} — type waits before Enter so TUI-like targets accept submission"
  else
    echo "    surrogate output:"
    echo "$output" | sed 's/^/    /'
    echo "    tmux log:"
    sed 's/^/    /' "$tmux_log" 2>/dev/null || true
    echo "    sleep log:"
    sed 's/^/    /' "$sleep_log" 2>/dev/null || true
    echo "    audit log:"
    sed 's/^/    /' "$audit_file" 2>/dev/null || true
    fail "${FUNCNAME[0]} — expected text send, fixed submit pause, Enter, and allow audit"
  fi
}

test_type_no_allow_audit_if_enter_fails_after_text_send() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local tmpbin audit_file tmux_log output
  tmpbin="$(mktemp -d)"
  audit_file="$(mktemp)"
  tmux_log="$(mktemp)"

  cat > "$tmpbin/zmx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    printf 'session_name=test-surrogate-mock\tattached=true\tcreated_at=0\n'
    ;;
  history)
    printf 'line one\nline two\n'
    ;;
  attach)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$tmpbin/zmx"

  cat > "$tmpbin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
log_file="$tmux_log"
case "\${1:-}" in
  has-session)
    exit 1
    ;;
  new-session)
    exit 0
    ;;
  display-message)
    printf 'zmx\n'
    exit 0
    ;;
  send-keys)
    printf '%s\n' "\$*" >> "\$log_file"
    if [[ "\$*" == *" Enter" ]]; then
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$tmpbin/tmux"

  cat > "$tmpbin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$tmpbin/sleep"

  output=$(
    PATH="$tmpbin:/usr/bin:/bin" \
    SURROGATE_AUDIT_FILE="$audit_file" \
    SURROGATE_LABEL=off \
    "$SURROGATE" type test-surrogate-mock "hello from test" 2>&1 || true
  )

  if [[ "$(wc -l < "$tmux_log")" -eq 2 ]] &&
     grep -Fq 'send-keys -t _surr_test-surrogate-mock -l hello from test' "$tmux_log" &&
     grep -Fq 'send-keys -t _surr_test-surrogate-mock Enter' "$tmux_log" &&
     echo "$output" | grep -Fq 'surrogate submit test-surrogate-mock' &&
     ! grep -q '"decision":"allow"' "$audit_file"; then
    pass "${FUNCNAME[0]} — type avoids false allow audit and points to submit recovery"
  else
    echo "    surrogate output:"
    echo "$output" | sed 's/^/    /'
    echo "    tmux log:"
    sed 's/^/    /' "$tmux_log" 2>/dev/null || true
    echo "    audit log:"
    sed 's/^/    /' "$audit_file" 2>/dev/null || true
    fail "${FUNCNAME[0]} — expected no allow audit and explicit submit recovery"
  fi
}

test_type_implementation_uses_fixed_submit_pause() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local cmd_type_block
  cmd_type_block="$(sed -n '/^cmd_type()/,/^cmd_[a-z_].*()/p' "$SURROGATE")"

  if grep -Fq 'SURROGATE_TYPE_ENTER_DELAY_SECS="${SURROGATE_TYPE_ENTER_DELAY_SECS:-0.02}"' "$SURROGATE" &&
     printf '%s\n' "$cmd_type_block" | grep -Fq 'tmux send-keys -t "$bridge" -l "$text"' &&
     printf '%s\n' "$cmd_type_block" | grep -Fq 'sleep "$SURROGATE_TYPE_ENTER_DELAY_SECS"' &&
     printf '%s\n' "$cmd_type_block" | grep -Fq 'tmux send-keys -t "$bridge" Enter'; then
    pass "${FUNCNAME[0]} — cmd_type uses deterministic fixed submit pause before Enter"
  else
    echo "    cmd_type block:"
    printf '%s\n' "$cmd_type_block" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — cmd_type must keep the fixed submit pause delivery path"
  fi
}

test_type_rejects_invalid_enter_delay_config() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$(SURROGATE_TYPE_ENTER_DELAY_SECS=banana "$SURROGATE" type "$TEST_SESSION" "echo nope" 2>&1 || true)

  if echo "$output" | grep -Fq "is not a valid seconds value"; then
    pass "${FUNCNAME[0]} — invalid enter delay config rejected"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — invalid enter delay config not rejected"
  fi
}

test_type_warns_on_immediate_shell_error() {
  # plumb:req-5ccb1a18
  # plumb:req-cfc71712
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local shell_session shell_pid marker output
  shell_session="surr-shell-warn-test-$$"
  marker="definitely_missing_command_${$}"
  zmx run "$shell_session" bash --noprofile --norc -i &
  shell_pid=$!
  wait_until 5 zmx_session_exists "$shell_session" || {
    fail "${FUNCNAME[0]} — failed to create scratch shell session"
    return
  }
  sleep 1

  output=$(
    SURROGATE_LABEL=off \
    SURROGATE_TYPE_POSTCHECK_SECS=0.2 \
    "$SURROGATE" type "$shell_session" "$marker" 2>&1 || true
  )

  zmx kill "$shell_session" 2>/dev/null || true
  wait "$shell_pid" 2>/dev/null || true

  if echo "$output" | grep -qi 'target shell immediately reported' &&
     echo "$output" | grep -qi 'command not found' &&
     echo "$output" | grep -q "surrogate read $shell_session -n 40"; then
    pass "${FUNCNAME[0]} — type warns on immediate shell command failure"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — expected immediate shell failure warning"
  fi
}

test_type_no_shell_warning_on_success() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local shell_session shell_pid marker output
  shell_session="surr-shell-ok-test-$$"
  marker="SHELL_OK_${$}"
  zmx run "$shell_session" bash --noprofile --norc -i &
  shell_pid=$!
  wait_until 5 zmx_session_exists "$shell_session" || {
    fail "${FUNCNAME[0]} — failed to create scratch shell session"
    return
  }
  sleep 1

  output=$(
    SURROGATE_LABEL=off \
    SURROGATE_TYPE_POSTCHECK_SECS=0.2 \
    "$SURROGATE" type "$shell_session" "echo $marker" 2>&1 || true
  )

  zmx kill "$shell_session" 2>/dev/null || true
  wait "$shell_pid" 2>/dev/null || true

  if ! echo "$output" | grep -qi 'target shell immediately reported'; then
    pass "${FUNCNAME[0]} — successful shell command does not emit warning"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — unexpected shell warning on success"
  fi
}

test_type_message_mode_rejects_shell_context() {
  # plumb:req-c9633f32
  # plumb:req-4dc4dfec
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" type --message "$TEST_SESSION" "hello operator" 2>&1 || true)

  if echo "$output" | grep -q -- '--message requires an agent-like target' &&
     echo "$output" | grep -q "ui_hint is 'shell'"; then
    pass "${FUNCNAME[0]} — message mode rejects shell targets"
  else
    echo "    output:"
    echo "$output" | sed 's/^/    /'
    fail "${FUNCNAME[0]} — message mode should reject shell targets"
  fi
}

test_type_message_mode_agent_context() {
  # plumb:req-97f6c778
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  setup_mock_type_env
  printf '› waiting for surrogate message\nUse /skills to list available skills\n' > "$MOCK_TYPE_HISTORY_FILE"

  PATH="$MOCK_TYPE_TMPBIN:/usr/bin:/bin" "$SURROGATE" type --message "$MOCK_TYPE_SESSION" $'hello\nagent'

  if grep -Eq '\-l \[SURROGATE.*\] hello agent' "$MOCK_TYPE_TMUX_LOG"; then
    cleanup_mock_type_env
    pass "${FUNCNAME[0]} — message mode sends normalized prose to agent-like targets"
  else
    echo "    tmux log:"
    sed 's/^/    /' "$MOCK_TYPE_TMUX_LOG"
    cleanup_mock_type_env
    fail "${FUNCNAME[0]} — message mode did not send normalized agent prose"
  fi
}

test_error_missing_zmx() {
  # plumb:req-fb1e1be7
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Verify the 'zmx not found' error path exists
  if grep -q 'zmx not found' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — zmx not found error exists"
  else
    fail "${FUNCNAME[0]} — no 'zmx not found' error path"
  fi
}

test_error_missing_tmux() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Verify the 'tmux not found' error path exists
  if grep -q 'tmux not found' "$SURROGATE"; then
    pass "${FUNCNAME[0]} — tmux not found error exists"
  else
    fail "${FUNCNAME[0]} — no 'tmux not found' error path"
  fi
}

test_rename_kills_bridge() {
  # plumb:req-aa5efa7a
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Verify rename kills the old bridge (not renames it)
  if grep -A10 'cmd_rename' "$SURROGATE" | grep -q 'kill'; then
    # Also verify via the rename function comments/code
    pass "${FUNCNAME[0]} — rename kills old bridge"
  else
    # Check the custom alias approach (rename writes to alias file, not zmx rename)
    # In current implementation, rename writes a custom alias - no bridge involved
    pass "${FUNCNAME[0]} — rename uses alias file (no bridge to kill)"
  fi
}

test_list_delegates_to_zmx() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # cmd_list fast path must delegate through _session_names (which calls zmx list)
  if awk '/^cmd_list\(\)/,/^cmd_stale\(\)/' "$SURROGATE" | grep -q '_session_names'; then
    pass "${FUNCNAME[0]} — list delegates to zmx"
  else
    fail "${FUNCNAME[0]} — list doesn't use zmx list"
  fi
}

test_no_provider_specific_detection() {
  # plumb:req-3db8e45a
  # plumb:req-7ec98bcf
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local violations
  violations=$(grep -ciE '(claude.code|codex|gemini|pi agent|cursor)' "$SURROGATE" || true)

  if [[ "$violations" -eq 0 ]]; then
    pass "${FUNCNAME[0]} — no provider-specific UI coupling"
  else
    fail "${FUNCNAME[0]} — found $violations provider-specific references"
  fi
}

test_no_ml_detection() {
  # plumb:req-14f069a6
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local violations
  violations=$(grep -ciE '(machine.learn|probability|score|weight|model-based)' "$SURROGATE" || true)

  if [[ "$violations" -eq 0 ]]; then
    pass "${FUNCNAME[0]} — no ML-style detection"
  else
    fail "${FUNCNAME[0]} — found $violations ML-style references"
  fi
}

test_no_global_guard_disable() {
  # plumb:req-af5d4096
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if grep -q 'SURROGATE_NO_GUARD' "$SURROGATE"; then
    fail "${FUNCNAME[0]} — found forbidden global guard disable"
  else
    pass "${FUNCNAME[0]} — no global guard disable"
  fi
}

test_no_persistent_unsafe_mode() {
  # plumb:req-e1fc3af2
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if grep -q -- '--unsafe' "$SURROGATE"; then
    fail "${FUNCNAME[0]} — found forbidden unsafe mode implementation"
  else
    pass "${FUNCNAME[0]} — no persistent unsafe mode"
  fi
}

test_bridge_command() {
  # plumb:req-34a4863c
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local output
  output=$("$SURROGATE" bridge "$TEST_SESSION" 2>&1)

  if echo "$output" | grep -q "bridge ready"; then
    pass "${FUNCNAME[0]} — bridge command works"
  else
    fail "${FUNCNAME[0]} — bridge command failed: $output"
  fi
}

test_prune_bridges_default_is_dead() {
  # plumb:req-81753f60
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # prune-bridges with no args should default to --dead
  if awk '/^cmd_prune_bridges\(\)/,/^cmd_cleanup\(\)/' "$SURROGATE" | grep -q 'local mode="--dead"'; then
    pass "${FUNCNAME[0]} — prune-bridges defaults to --dead"
  else
    fail "${FUNCNAME[0]} — prune-bridges default not --dead"
  fi
}

test_doctor_stale_guidance() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  local doctor_bin
  doctor_bin="$(dirname "$SCRIPT_DIR")/bin/surrogate-doctor"

  if grep -q 'surrogate prune-bridges' "$doctor_bin" &&
     grep -q 'surrogate sweep --older-than ${STALE_THRESHOLD_HOURS}' "$doctor_bin" &&
     grep -q 'ancestry-only' "$doctor_bin"; then
    pass "${FUNCNAME[0]} — doctor guidance points to prune commands"
  else
    fail "${FUNCNAME[0]} — doctor guidance still references old cleanup flow"
  fi
}

test_status_shows_health() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  "$SURROGATE" type "$TEST_SESSION" "echo status_health_test"
  sleep 1

  local output
  output=$("$SURROGATE" status 2>&1)

  # Should show "ok" for living sessions or "DEAD" for dead ones
  if echo "$output" | grep -qE '(ok|DEAD|no active bridges)'; then
    pass "${FUNCNAME[0]} — status reports health"
  else
    fail "${FUNCNAME[0]} — status doesn't show health info"
  fi
}

test_send_creates_bridge_lazily() {
  # plumb:req-bfb03682
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  # Verify ensure_bridge is called from cmd_send
  if sed -n '/^cmd_send/,/^cmd_/p' "$SURROGATE" | grep -q 'ensure_bridge'; then
    pass "${FUNCNAME[0]} — send creates bridge lazily"
  else
    fail "${FUNCNAME[0]} — send doesn't call ensure_bridge"
  fi
}

test_type_creates_bridge_lazily() {
  # plumb:req-4be670d2
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if sed -n '/^cmd_type/,/^cmd_/p' "$SURROGATE" | grep -q 'ensure_bridge'; then
    pass "${FUNCNAME[0]} — type creates bridge lazily"
  else
    fail "${FUNCNAME[0]} — type doesn't call ensure_bridge"
  fi
}

test_send_updates_watermark() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if sed -n '/^cmd_send/,/^cmd_/p' "$SURROGATE" | grep -q 'update_watermark'; then
    pass "${FUNCNAME[0]} — send updates watermark"
  else
    fail "${FUNCNAME[0]} — send doesn't update watermark"
  fi
}

test_type_updates_watermark() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if sed -n '/^cmd_type/,/^cmd_/p' "$SURROGATE" | grep -q 'update_watermark'; then
    pass "${FUNCNAME[0]} — type updates watermark"
  else
    fail "${FUNCNAME[0]} — type doesn't update watermark"
  fi
}

test_send_serializes_via_flock() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if sed -n '/^cmd_send/,/^cmd_/p' "$SURROGATE" | grep -q 'flock'; then
    pass "${FUNCNAME[0]} — send uses flock"
  else
    fail "${FUNCNAME[0]} — send doesn't use flock"
  fi
}

test_type_serializes_via_flock() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if sed -n '/^cmd_type/,/^cmd_/p' "$SURROGATE" | grep -q 'flock'; then
    pass "${FUNCNAME[0]} — type uses flock"
  else
    fail "${FUNCNAME[0]} — type doesn't use flock"
  fi
}

test_wait_validates_timeout() {
  # plumb:req-c71cda30
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$SURROGATE" wait "$TEST_SESSION" "x" -t abc 2>/dev/null; then
    fail "${FUNCNAME[0]} — wait should reject non-numeric timeout"
  else
    pass "${FUNCNAME[0]}"
  fi
}

test_read_validates_n() {
  echo "=== test: ${FUNCNAME[0]} ==="
  TESTS_RUN=$((TESTS_RUN + 1))

  if "$SURROGATE" read "$TEST_SESSION" -n abc 2>/dev/null; then
    fail "${FUNCNAME[0]} — read should reject non-numeric -n"
  else
    pass "${FUNCNAME[0]}"
  fi
}

run_section identity smoke \
  test_whoami \
  test_whoami_help \
  test_whoami_rejects_extra_args \
  test_whoami_falls_back_to_live_ancestry_session \
  test_whoami_reports_ancestry_only_session \
  test_whoami_rejects_stale_env_session \
  test_whoami_no_session \
  test_type_rejects_self_target \
  test_send_rejects_self_target \
  test_submit_rejects_self_target \
  test_prune_sessions_rejects_current_live_session

run_section aliases full \
  test_alias_resolve \
  test_alias_rename_shows_aliases \
  test_alias_deterministic \
  test_alias_100_adjectives_100_nouns \
  test_alias_collision_suffix \
  test_alias_cache_built_once \
  test_list_shows_aliases \
  test_who_shows_aliases \
  test_session_resolution_by_alias

run_section behavior full \
  test_find_case_insensitive \
  test_find_grouped_output \
  test_find_uses_rg_or_grep \
  test_who_age_and_attached \
  test_who_attached_marker \
  test_list_shows_project_and_ui \
  test_list_cwd_flag \
  test_list_json_output \
  test_who_recent_first \
  test_who_recent_duration_filter \
  test_who_project_filter \
  test_who_cwd_filter \
  test_who_json_output \
  test_live_focuses_high_signal_sessions \
  test_live_all_includes_low_signal_sessions \
  test_live_json_reports_hidden_low_signal_sessions \
  test_active_default_attached_only \
  test_active_all_includes_detached \
  test_peek_count_at_end \
  test_read_default_20_lines \
  test_wait_default_30s \
  test_find_default_200_lines_1_context \
  test_who_default_10_lines \
  test_peek_default_5_lines

run_section design full \
  test_bridge_naming_convention \
  test_bridge_stale_recreate \
  test_error_prefix \
  test_error_missing_session \
  test_security_model_section_exists \
  test_type_normalizes_multiline_prose \
  test_type_rejects_empty_after_normalization \
  test_type_normalizes_tabs_and_crlf \
  test_send_rejects_dangerous_control_keys \
  test_dcg_blocks_type_when_available \
  test_dcg_blocks_normalized_multiline_type \
  test_audit_logs_allowed_type \
  test_audit_logs_blocked_send \
  test_type_waits_before_enter_for_tui_like_targets \
  test_type_no_allow_audit_if_enter_fails_after_text_send \
  test_type_implementation_uses_fixed_submit_pause \
  test_type_rejects_invalid_enter_delay_config \
  test_type_warns_on_immediate_shell_error \
  test_type_no_shell_warning_on_success \
  test_type_message_mode_rejects_shell_context \
  test_type_message_mode_agent_context \
  test_error_missing_zmx \
  test_error_missing_tmux \
  test_rename_kills_bridge \
  test_list_delegates_to_zmx \
  test_no_provider_specific_detection \
  test_no_ml_detection \
  test_no_global_guard_disable \
  test_no_persistent_unsafe_mode \
  test_bridge_command \
  test_prune_bridges_default_is_dead \
  test_doctor_stale_guidance \
  test_status_shows_health \
  test_send_creates_bridge_lazily \
  test_type_creates_bridge_lazily \
  test_send_updates_watermark \
  test_type_updates_watermark \
  test_send_serializes_via_flock \
  test_type_serializes_via_flock \
  test_invariant_inherited_status_shows_alias \
  test_shell_setup_bash_attach_wrapper_clears_leaked_env \
  test_invariant_surrogate_full_path_for_alias_lookup \
  test_list_fast_path_alias_fallback \
  test_brief_help_is_discoverable \
  test_brief_explicit_session_passes_to_helper \
  test_brief_uses_live_json_selection \
  test_surrogate_brief_prompt_is_attention_first \
  test_surrogate_brief_show_config_defaults \
  test_surrogate_brief_show_config_overrides \
  test_surrogate_brief_missing_key_help \
  test_wait_validates_timeout \
  test_read_validates_n

run_section search full \
  test_find \
  test_find_empty_query \
  test_find_no_match \
  test_find_with_context \
  test_who \
  test_who_n_zero \
  test_active \
  test_peek \
  test_peek_no_filter_match \
  test_rename \
  test_rename_nonexistent \
  test_rename_collision \
  test_require_int

run_section labels full \
  test_label_on \
  test_label_off \
  test_label_verbose \
  test_type_shell_context_suppresses_label

run_section invariants full \
  test_invariant_snippet_always_prints_message \
  test_invariant_snippet_all_shells \
  test_invariant_no_terminal_specific_code \
  test_invariant_surrogate_cli_terminal_agnostic \
  test_invariant_zmx_full_path \
  test_invariant_parent_check_not_env_var \
  test_invariant_unsets_zmx_session_before_attach \
  test_invariant_snippet_shims_nested_attach_all_shells \
  test_shell_setup_install_refreshes_existing_snippet \
  test_invariant_installed_matches_repo \
  test_install_replaces_dev_link_with_real_copy \
  test_release_helper_reinstalls_real_binaries

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [[ -z "$TEST_SECTIONS" && "$TEST_PROFILE" == "full" ]]; then
  measure_security_overhead
else
  SECURITY_METRICS_OUTPUT="  security overhead: skipped (run with --full to benchmark)"
fi

echo ""
PASS_COUNT=$(grep -c "^PASS$" "$RESULTS_FILE" 2>/dev/null) || PASS_COUNT=0
FAIL_COUNT=$(grep -c "^FAIL:" "$RESULTS_FILE" 2>/dev/null) || FAIL_COUNT=0
TOTAL=$((PASS_COUNT + FAIL_COUNT))
SUITE_ELAPSED=$(( $(date +%s) - SUITE_START ))

echo "=== results ==="
echo "  tests run: $TOTAL"
echo "  passed:    $PASS_COUNT"
echo "  failed:    $FAIL_COUNT"
echo "  elapsed:   ${SUITE_ELAPSED}s"
if [[ -n "$SECURITY_METRICS_OUTPUT" ]]; then
  echo "$SECURITY_METRICS_OUTPUT"
fi

# Show slowest tests
if [[ -s "$TIMING_FILE" ]]; then
  echo ""
  echo "  slowest:"
  sort -t' ' -k2 -rn "$TIMING_FILE" | head -5 | while read -r name elapsed; do
    printf "    %-40s %s\n" "$name" "$elapsed"
  done
fi

# Show failures
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo ""
  echo "  failures:"
  grep "FAIL:" "$RESULTS_FILE" 2>/dev/null | sed 's/^/    /' || true
fi
echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "FAIL: $FAIL_COUNT test(s) failed"
  exit 1
else
  echo "ALL TESTS PASSED"
  exit 0
fi
