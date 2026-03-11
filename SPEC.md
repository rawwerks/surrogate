# Surrogate: Specification

**Version:** 1.0.0  **Purpose:** This document is the authoritative spec for the surrogate CLI tool. It describes what surrogate must do — agents, tests, and docs must conform to this.

## Overview

Surrogate is a bash CLI tool that provides programmatic keystroke injection and session search for zmx terminal sessions. It enables AI agents and scripts to type into any terminal application (Claude Code, vim, REPL, etc.) running inside a zmx session.

The architecture has a strict layering: zmx is the source of truth for all sessions. tmux is invisible plumbing used only for keystroke injection via ephemeral "bridge" sessions. The user never interacts with tmux directly.

All search and filter commands must be fully deterministic — same inputs produce same outputs. There must be no agent-type detection, no heuristics, and no machine learning. Search uses rg (ripgrep) when available, falling back to grep -E.

### Design Principles

- **zmx is source of truth.** All session state comes from zmx. tmux bridges are disposable.
- **Deterministic over smart.** Agents are non-deterministic; the tools they use must be the opposite. Every command produces predictable, reproducible output from the same inputs.
- **Deterministic safety floor.** Surrogate must provide a built-in, deterministic safety floor of its own. Safety must not depend entirely on optional external tooling or agent judgment.
- **Zero agent-specific dependencies.** Surrogate must never parse or depend on the UI format of any specific agent (Claude Code, Codex, Gemini, Pi). Agent detection would create fragile coupling.
- **Minimal dependencies.** Only zmx, tmux, and standard Unix tools (grep, sed, tail, stat). rg is preferred but optional.
- **Ambient convenience, narrow authority.** Surrogate is ambiently available across sessions, but some actions are intentionally outside its authority surface. If an operation falls outside that surface, the human must take over directly.

## Security Model

This section defines the surrogate v0 security model. It is intentionally narrow, deterministic, and easy to review. Tests must cover every rule in this section.

### Goal

Surrogate is the deterministic counterweight to non-deterministic agents. It must stay small, explicit, and mechanically predictable. The security model must reduce the risk of agent misuse without turning surrogate into a general authorization framework.

### Layers

Surrogate safety has two layers:

1. **Structural guardrails owned by surrogate.** These are deterministic capability boundaries enforced by surrogate itself and they apply whether or not optional safety tools are installed.
2. **Content scanning from optional tools.** External tools such as DCG may add deeper command scanning, but surrogate must not treat them as its only safety boundary.

### Built-In Structural Guardrails

The following rules are part of surrogate itself and must apply even when DCG is absent:

1. The `type` command must normalize embedded newlines to spaces and submit once. A successful `type` must mean the prompt was actually submitted to the target application, not merely staged in the input field.
2. The `type` delivery path must include a configurable fixed submit pause with a sensible default so Enter lands reliably in agent TUIs without introducing heuristics.
3. If `type` transport fails after staging text, surrogate must provide one obvious repair path that agents can invoke directly.
4. The `send` command must reject dangerous control keys: `C-c`, `C-d`, and `C-z`.
5. Surrogate must not implement an ambient or inherited bypass mechanism such as a global "disable guards" environment variable.
6. Surrogate must not implement a persistent unsafe mode.

These rules define the minimum safety floor. Opting out of optional tools must never disable them.

### Optional DCG Integration

DCG is a highly recommended but technically optional dependency.

If DCG is installed:

1. Surrogate may scan command-like payloads before injection.
2. A DCG denial must block the surrogate action.
3. Surrogate must not expose an in-band self-bypass path for a DCG denial.

If DCG is absent:

1. Surrogate must continue to function.
2. The built-in structural guardrails remain in force.

Opting out of DCG means "less protection," not "no protection."

### Security Overhead Metric

Security hardening must be tracked with a latency metric, not only pass/fail behavior.

The test harness must report a non-blocking security-overhead metric for the hot path by measuring:

1. baseline `type` latency without DCG in `PATH`
2. guarded `type` latency with DCG available and allowing the payload
3. the delta between those two measurements

This metric is for observability and regression tracking. It is not a release-blocking threshold in v0.

### Audit Logging

Surrogate must produce a deterministic audit trail for guarded actions.

The audit log requirements for v0 are:

1. `type` and `send` actions must append a JSON Lines entry to an audit log file.
2. The audit log must include both allowed and blocked actions.
3. Each audit record must include at least:
   - timestamp
   - action (`type` or `send`)
   - target session
   - target alias
   - decision (`allow` or `deny`)
   - detail payload or key sequence
   - actor session when available
   - actor alias when available
   - repo name
   - work ID when provided
   - intent reason when provided
4. The default audit log path must be `/tmp/surrogate-audit.jsonl`.
5. The audit log path must be overrideable via `SURROGATE_AUDIT_FILE`.
6. `SURROGATE_WORK_ID` may annotate audit records with a causal work identifier.
7. `SURROGATE_REASON` may annotate audit records with an intent reason.

Audit logging is for observability and incident review. It must not change command behavior except for writing the log entry.

### Authority Boundary

Surrogate may support routine remote-hands actions such as reading session output, searching session history, typing plain text, and other low-risk deterministic helpers.

The following categories are reserved for direct human control rather than surrogate automation:

- self-bypass or global guard disable mechanisms
- persistent unsafe mode or inherited unsafe state
- high-risk actions whose only approval path is the same agent-controlled terminal channel

If an action is outside surrogate's authority surface, the correct path is direct human control, not a more elaborate in-band override.

---

## Commands

### list

The `list` command must print all zmx sessions by delegating directly to `zmx list`.

### send

The `send` command must accept a session name and one or more tmux send-keys arguments. It must create a bridge lazily if one does not exist, update the watermark for wait tracking, and serialize concurrent sends via flock.

### type

The `type` command must accept a session name and a text string. It must type the literal text followed by Enter. A successful `type` must correspond to an actual submission, not a staged-but-unentered prompt. The delivery path must remain deterministic and include any fixed submit pause needed to make Enter land reliably in agent TUIs. The submit pause must be configurable with a sensible default. If transport fails after the text may already be staged, the error must point to a single obvious recovery command. It must create a bridge lazily, update the watermark, and serialize via flock.

The `submit` command must accept a session name (or alias) and press Enter for a staged prompt. It exists as the deterministic one-command repair path if a prompt is visibly staged and needs to be submitted.

### read

The `read` command must accept a session name and an optional `-n LINES` flag (default 20). It must output the last N lines from the session's zmx history. The `-n` flag must be validated as a non-negative integer.

### wait

The `wait` command must accept a session name, a regex pattern, and an optional `-t TIMEOUT` flag in seconds (default 30). It must watch for the pattern in new output produced after the last send/type watermark. It must exit 0 on match and exit 1 on timeout. The `-t` flag must be validated as a non-negative integer.

### find

The `find` command must accept a query string and optional `-n LINES` (default 200) and `-C CONTEXT` (default 1) flags. It must search the last N lines of every zmx session for the query pattern, case-insensitively. It must use rg if available, falling back to grep -E. An empty query must be rejected with an error. Output must be grouped by session with a match count in each header. A summary of total matching sessions must be printed at the end. Both `-n` and `-C` must be validated as non-negative integers.

### who

The `who` command must accept an optional `-n LINES` flag (default 10) controlling how many history lines to check for the snippet. It must print every session with its age (derived from zmx socket modification time), session name, and last visible non-blank line. Attached sessions (clients > 0) must be marked with `*`. The total session count must be printed at the end. The `-n` flag must be validated as a non-negative integer.

### active

The `active` command must accept an optional `--all` flag. By default, it must show only sessions with attached clients (clients > 0). With `--all`, it must also include detached sessions that have non-empty history.

### peek

The `peek` command must accept optional `-n LINES` (default 5) and `--filter PATTERN` flags. It must print the last N non-blank lines from every session. If `--filter` is provided, only sessions whose output matches the pattern must be shown. The total count of peeked sessions must be printed at the end. The `-n` flag must be validated as a non-negative integer.

### rename

The `rename` command must accept a source session name and a target name. It must rename the zmx socket file (the source of truth). It must kill any existing bridge for the old name — bridges hold a stale `zmx attach` command and must not be renamed. A fresh bridge will be created lazily on the next send/type. Watermark and lock files must be renamed. The command must reject if the source session does not exist. The command must reject if the target name already exists.

### alias

The `alias` command must accept a session name (or alias) and print its deterministic alias. The alias must be computed from the session name using a hash function, selecting one adjective and one noun from built-in wordlists (100 adjectives × 100 nouns = 10,000 combinations). The alias must be deterministic — the same session name must always produce the same alias. On hash collision, a numeric suffix must be appended. The alias cache must be built once per invocation and shared across all commands.

### whoami

The `whoami` command must print the alias and zmx session name of the current surrogate session (the zmx session this terminal is running in). It must detect the current session by checking the zmx environment or parent process. It must support `-h`/`--help` and reject extra positional arguments with `usage: surrogate whoami`. For a live current session, it must deterministically compute the alias rather than printing `unknown`. If `ZMX_SESSION` is set but not present in `zmx list`, `whoami` must reject it explicitly as a stale or leaked environment value instead of treating it as a live session.

### Session Resolution

All commands that accept a session name must also accept an alias. Session resolution must first check if the argument is a known alias and resolve it to the actual session name. If not an alias, it must be treated as a literal session name. This applies to: send, type, read, wait, bridge, rename, and alias commands.

### list (alias display)

The `list` command must include the deterministic alias for each session alongside its zmx session name.

### who (alias display)

The `who` command must include the alias for each session in its output.

### bridge

The `bridge` command must pre-create a tmux bridge session for a zmx session.

### cleanup

The `cleanup` command must accept `--dead` (default) or `--all`. With `--dead`, it must remove bridge sessions whose corresponding zmx session no longer exists. With `--all`, it must remove all bridge sessions.

### status

The `status` command must list all bridge sessions and report their health — "ok" if the zmx session exists, "DEAD" if it does not.

---

## Bridges

A bridge is a tmux session named `_surr_<zmx-session>` that runs `zmx attach <session>`. Bridges must be created lazily on first send/type to a session. Bridges must be reused on subsequent operations — verified by checking the tmux session exists and its pane command is running. Stale bridges must be killed and recreated. Concurrent access to a bridge must be serialized via flock. Bridges are ephemeral and disposable — they can be killed at any time and will be recreated on demand.

---

## Input Validation

All numeric flags (`-n`, `-C`, `-t`) must be validated as non-negative integers before being passed to internal commands like `tail` or `grep`. Invalid values must produce a clear error message (`'<value>' is not a valid number`) and exit 1. This prevents leaking internal tool errors (e.g., 76 `tail: invalid number` messages) to the user.

---

## Error Handling

All errors must go to stderr with the prefix `surrogate: error:`. Missing sessions must produce `session '<name>' not found`. Missing dependencies must produce `zmx not found` or `tmux not found`. All error paths must exit 1.

---

## Shell Integration (surrogate-shell-setup)

The shell setup script must generate a snippet that wraps new interactive shells in zmx sessions. The snippet must always print a `surrogate:` status line on startup, in both the "wrapping" path (new zmx session created) and the "inherited" path (already inside zmx, e.g., from terminal emulator). The snippet must support bash, zsh, and fish. The snippet must use the full path to zmx (`$HOME/.local/bin/zmx`), not `command -v zmx`, because PATH is not reliably set when rc files run. Double-wrap prevention must check the parent process name via `$PPID`, not the `ZMX_SESSION` environment variable, because `ZMX_SESSION` leaks through window managers to all child processes. The snippet must unset `ZMX_SESSION` before exec to prevent zmx's CannotAttachToSessionInSession error. The snippet must contain zero references to specific terminal emulators (Ghostty, Alacritty, WezTerm, kitty, xterm, etc.).
