#!/usr/bin/env bash
# tests/lib/real_session.sh — helpers for tests that drive real zmx sessions.
#
# The existing e2e suite already spawns real zmx sessions via `zmx run`. This
# library consolidates that pattern so new test files can drive real sessions
# without duplicating setup/cleanup logic. It is *pure real-session* — no
# mocking of zmx, no intercepted PATH. Use this for tests that must exercise
# the actual zmx socket, log, and activity surface.
#
# Naming convention: every session spawned by this library is named
# "surr-rs-<prefix>-<pid>-<slot>". The trailing "-<pid>" lets the existing
# TEST_SESSION_NAME_RE-style cleanup in test_surrogate_e2e.sh also reap
# orphaned real sessions on stale harness PIDs, and the "surr-rs-" root
# keeps these visually distinct from the older test artifacts.
#
# Public API:
#   real_session_init                       one-time; idempotent
#   real_session_spawn <prefix> [cmd...]    returns the full session name on stdout
#   real_session_kill <name>                kill one real-session and its bridge
#   real_session_cleanup_all                kill every session this harness owns
#   real_session_touch <name>               force a small pane write (for activity tests)

# NOTE: This library is sourced. Do not set errexit here — many callers
# run assertions that tolerate individual grep/awk failures and must keep
# going. Sourcing scripts can opt into strict modes themselves.
set -o nounset
set -o pipefail

: "${SURROGATE:?SURROGATE must point to the surrogate binary under test}"

REAL_SESSION_NAME_RE='^surr-rs-[a-z0-9]+-[0-9]+-[0-9]+$'
_REAL_SESSION_SLOT=0
_REAL_SESSION_OWNER_PID="$$"
_REAL_SESSION_SPAWNED=()

real_session_init() {
  command -v zmx >/dev/null 2>&1 || {
    echo "real_session: zmx not found in PATH" >&2
    return 1
  }
  command -v tmux >/dev/null 2>&1 || {
    echo "real_session: tmux not found in PATH" >&2
    return 1
  }
  trap real_session_cleanup_all EXIT INT TERM
}

real_session_name() {
  local prefix="$1"
  _REAL_SESSION_SLOT=$(( _REAL_SESSION_SLOT + 1 ))
  printf 'surr-rs-%s-%d-%d\n' "$prefix" "$_REAL_SESSION_OWNER_PID" "$_REAL_SESSION_SLOT"
}

real_session_exists() {
  zmx list 2>/dev/null | sed -n 's/^session_name=\([^\t]*\).*/\1/p' | grep -Fx -- "$1" >/dev/null
}

real_session_wait_until() {
  local timeout_secs="$1"; shift
  local deadline=$(( $(date +%s) + timeout_secs ))
  while (( $(date +%s) < deadline )); do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  "$@"
}

# real_session_spawn <prefix> [cmd...]
# If no cmd is given, spawns an idle `bash --noprofile --norc` that stays alive
# indefinitely waiting for input. Prints the full session name on stdout.
real_session_spawn() {
  local prefix="$1"; shift
  local session
  session="$(real_session_name "$prefix")"

  # Redirect zmx's stdin/stdout/stderr to /dev/null: the caller invokes us
  # via command substitution ($(real_session_spawn ...)) to capture the
  # session name, and bash blocks on the command-sub pipe until every
  # writer closes it. A backgrounded `zmx run` inherits those fds and
  # keeps them open indefinitely, so we detach explicitly.
  if [[ $# -eq 0 ]]; then
    zmx run "$session" bash --noprofile --norc </dev/null >/dev/null 2>&1 &
  else
    zmx run "$session" "$@" </dev/null >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true

  if ! real_session_wait_until 5 real_session_exists "$session"; then
    echo "real_session: failed to create zmx session '$session'" >&2
    return 1
  fi

  _REAL_SESSION_SPAWNED+=("$session")
  printf '%s\n' "$session"
}

real_session_kill() {
  local session="$1"
  zmx kill "$session" >/dev/null 2>&1 || true
  tmux kill-session -t "_surr_${session}" 2>/dev/null || true
}

real_session_cleanup_all() {
  local session
  for session in "${_REAL_SESSION_SPAWNED[@]:-}"; do
    [[ -z "$session" ]] && continue
    real_session_kill "$session"
  done
  _REAL_SESSION_SPAWNED=()
}

# Drive a visible content change into the session so activity-freshness
# tests can distinguish "pane changed N seconds ago" from "pane never
# changed." We specifically avoid keystrokes like Space+BSpace — those
# are erased by the terminal before `zmx history` sees them, because
# zmx snapshots rendered screen state, not raw pty bytes. Enter appends
# a fresh prompt line, which is always detectable.
real_session_touch() {
  local session="$1"
  "$SURROGATE" send "$session" Enter >/dev/null 2>&1 || true
}
