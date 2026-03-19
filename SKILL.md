---
name: surrogate
description: "Send keystrokes to any terminal app via zmx sessions. Use when you need to type into TUI apps, talk to other agents, or drive interactive programs programmatically."
---

# Surrogate

Surrogate enables programmatic keystroke injection into any terminal application running in a zmx session. It uses tmux internally as a bridge. The chain: tmux send-keys -> tmux pane (zmx attach) -> zmx IPC -> PTY -> target app.

An AI agent uses surrogate to act as a "surrogate user" -- typing into TUI apps like Claude Code, vim, python REPL, htop, etc.

## Security Model

Surrogate is intentionally deterministic and does not offer unlimited authority just because it is ambiently available.

- Built-in structural guardrails apply even if DCG is not installed.
- DCG is an optional second layer for content scanning.
- Some actions are reserved for direct human control rather than surrogate automation.

Current built-in guardrails:

- `surrogate type` normalizes embedded newlines to spaces and must actually submit, not just stage text
- `surrogate type`, `surrogate send`, and `surrogate submit` reject self-targeting and tell you the current alias/session
- `surrogate prune-sessions` rejects the current live session and any attached session with clients still present
- `surrogate send` rejects `C-c`, `C-d`, and `C-z`
- there is no global guard-disable mode
- there is no persistent unsafe mode

If DCG is installed, `surrogate type` may also be blocked by DCG for destructive command-like payloads.

Surrogate also writes JSONL audit records for `type` and `send` actions. By default this goes to `/tmp/surrogate-audit.jsonl`, and it can be overridden with `SURROGATE_AUDIT_FILE`.

## Session Aliases

Every session gets a deterministic adjective-noun alias (e.g. `shiny-dolphin`, `robo-quokka`). Aliases are derived from the session name via hash — no state, no config. They never collide.

All commands that take a `<session>` argument accept either the full zmx name or the alias:

```bash
surrogate type shiny-dolphin "hello"              # alias
surrogate type 2026-03-08_20-44-12_EDT-539343 "hello"  # full name — same thing
surrogate alias 2026-03-08_20-44-12_EDT-539343    # → shiny-dolphin
```

## Quick Reference

### Discover sessions

```bash
surrogate help list
surrogate list
# Fast alias + full session name for every session
surrogate list --cwd
# Adds repo, cwd, and ui_hint (shell/agent/unknown)
surrogate list --json
# Machine-readable repo/cwd/ui metadata
```

### Search across all sessions

```bash
surrogate find <query> [-n LINES] [-C CONTEXT]
# Search last 200 lines of every session (rg, falls back to grep)
surrogate find "auth error"
surrogate find "TODO" -n 500 -C 3
```

### Show all sessions with snippets

```bash
surrogate who [-n LINES] [--recent N|2h] [--project NAME] [--cwd PATH] [--json]
# Newest 20 first by default, with age, ui_hint, session name, repo, and optional filters
surrogate who
surrogate who --recent 20
surrogate who --project surrogate
surrogate who --cwd ~/Documents/GitHub/surrogate
surrogate who --json
surrogate who -n 20   # inspect more history for snippet and path hints
```

`ui_hint` is deterministic and generic: `shell`, `agent`, or `unknown`. It is derived from visible output only.

### Show attached sessions

```bash
surrogate active [--all]
# Default: only sessions with clients attached
surrogate active
surrogate active --all   # include non-empty detached sessions
```

### Show live, messageable sessions with less noise

```bash
surrogate live
surrogate live --here
surrogate live --all
surrogate live --json
```

`surrogate live` is the low-noise operator view. It only shows sessions that are currently messageable, ranks them by recent visible activity, and hides low-signal shell-prompt lanes by default when they have no visible repo or cwd hint. Use `--all` when you want the full live set.

### Show stale detached sessions

```bash
surrogate stale [--older-than HOURS] [--filter PATTERN]
surrogate stale
surrogate stale --older-than 72
surrogate stale --older-than 24 --limit 20
```

`stale` returns the oldest matching detached sessions first.

### Batch read all sessions

```bash
surrogate peek [-n LINES] [--filter PATTERN]
# Last 5 lines from every session, optionally filtered
surrogate peek
surrogate peek --filter "shoulder"
surrogate peek -n 2 --filter "error"
```

### Rename a session

```bash
surrogate rename <old-session> <new-name>
```

### Show alias for a session

```bash
surrogate alias <session>
```

### Review and prune zmx sessions

`zmx` is still the source of truth. `surrogate prune-sessions` kills the zmx session and then cleans surrogate’s own bridge/alias/lock/watermark state. Batch stale pruning previews by default. Add `--yes` to execute.

```bash
surrogate stale --older-than 48
surrogate sweep --older-than 48
surrogate prune-sessions <session>...
surrogate prune-sessions --stale [--older-than HOURS] [--filter PATTERN] [--dry-run|--yes]
surrogate prune-sessions --stale --older-than 24 --limit 10 --yes
```

### Type text + Enter (most common)

```bash
surrogate type <session> "some text"
# <session> can be an alias: surrogate type robo-quokka "some text"
```

`type` auto-normalizes long prose by flattening embedded newlines to spaces and then submitting once. This is meant for conversational prompts, not scripts. A successful `type` should correspond to an actual submitted prompt, not staged input.

Default `type` is shell-safe. If the target looks like a shell, Surrogate suppresses the prose prefix so commands still execute normally, then warns if the shell immediately reports `command not found` or a syntax error.

For long conversational prompts into agent TUIs, use message mode:

```bash
surrogate type --message <session> "Please review the patch plan above."
```

`--message` is safer than plain `type` for prose because it requires an `agent` ui_hint and refuses `shell` or `unknown` targets.

If the target TUI needs a slightly different cadence, `type` uses an adaptive submit pause by default (`0.1s + 0.001s/char`, capped at `2.0s`). You can override it with `SURROGATE_TYPE_ENTER_DELAY_SECS`, which accepts only `adaptive` or a numeric seconds value.

If text is visibly staged and only the missing Enter is needed, use:

```bash
surrogate submit my-session
```

### Send special keys (tmux send-keys syntax)

```bash
surrogate send <session> <keys...>
```

Use `send` for low-risk key events like `Enter`, `Escape`, arrows, and text literals. Do not rely on surrogate for `C-c`, `C-d`, or `C-z` — those are intentionally blocked.

### Read recent output

```bash
surrogate read <session> [-n N]
```

### Optional remote operator briefs

If `OPENROUTER_API_KEY` is configured, you can triage and summarize where sessions left off with one OpenRouter call per zmx session:

```bash
surrogate brief --recent 15
surrogate brief 15
surrogate brief shiny-dolphin
surrogate-brief shiny-dolphin
surrogate-brief --show-config
surrogate-brief --openrouter-model openai/gpt-4.1-mini --inference-provider openai shiny-dolphin
```

`surrogate brief` reuses `surrogate live --json`, so the default brief targets the same high-signal, messageable sessions shown by `surrogate live`. Add `--all` if you want briefs for every live messageable session, including low-signal shell lanes. Each brief now classifies `ATTENTION REQUIRED`, `PRIORITY`, and `SIGNAL QUALITY` before summarizing status and next steps, so idle shell prompts get demoted instead of looking urgent. It should also treat implicit operator handoff as meaningful when a lane stops at interrupted work, parked troubleshooting, or a human decision boundary even without an explicit ask, and it should weight the end-state tail more heavily than an earlier milestone. This path is optional and separate from core surrogate usage. If the key is missing, `surrogate-brief` prints the setup steps needed to enable it.

### Wait for pattern in output

```bash
surrogate wait <session> <pattern> [-t SEC]
```

### Pre-warm a bridge

```bash
surrogate bridge <session>
```

### Clean up dead bridges

```bash
surrogate prune-bridges          # remove bridges for dead zmx sessions
surrogate prune-bridges --all    # remove ALL bridges
```

`surrogate cull` and `surrogate cleanup` still work as deprecated aliases, but primary docs should use `prune-sessions`, `prune-bridges`, and `sweep`.

Bridge cleanup does not remove zmx sessions. Use `surrogate prune-sessions` or `surrogate sweep` for that.

### Show bridge health

```bash
surrogate status
```

## Common Patterns

### Send and wait for response

```bash
surrogate type my-session "explain this function"
surrogate wait my-session "●" -t 60  # Wait for Claude to start responding
sleep 5  # Let it finish
output=$(surrogate read my-session -n 50)
```

### Drive vim

```bash
surrogate send my-session "vim main.go" Enter
sleep 1
surrogate send my-session "i"  # Insert mode
surrogate send my-session "// new comment" Escape ":wq" Enter
```

### Self-target guard

Surrogate refuses to send input to the current live session. If you need to confirm where you are, ask first:

```bash
surrogate whoami
```

If `ZMX_SESSION` is stale but the current process ancestry still includes `zmx attach <session>`, `surrogate whoami` reports that lane as `ancestry-only` and tells you it is not messageable via surrogate right now.

### Inter-agent communication

```bash
# Find which session is working on shoulder
surrogate find "shoulder" -n 50
# Or peek at all sessions mentioning it
surrogate peek --filter "shoulder"
# Send them a prompt
surrogate type elfin-squid "Please review my changes"
```

## Special Keys Reference

Since `surrogate send` passes through to tmux send-keys:

| Key | Description |
|-----|-------------|
| `Enter` | Enter key |
| `Escape` | Escape key |
| `C-u` | Ctrl+U (clear line) |
| `C-l` | Ctrl+L (clear screen) |
| `Tab` | Tab key |
| `Up`, `Down`, `Left`, `Right` | Arrow keys |
| `BSpace` | Backspace |
| `Space` | Space (use when you need explicit space) |

## When to Use Surrogate

- Sending input to TUI applications (Claude Code, vim, python, etc.)
- Communicating with other AI agents running in terminal sessions
- Automating interactive terminal workflows
- Testing TUI applications end-to-end

## When NOT to Use Surrogate

- For non-interactive commands -- just use Bash tool directly
- For file I/O -- use Read/Write/Edit tools
- When you have a proper API -- prefer APIs over keystroke injection
- For sending messages between agents -- prefer Agent Mail for structured communication. Use surrogate only when you need to type into the agent's actual TUI.
- For your current live session -- surrogate rejects self-targeting; use `surrogate whoami` if the agent seems confused about its identity.

## Setup

For users who want ALL new terminals to automatically be zmx sessions (enabling surrogate for everything):

```bash
surrogate-shell-setup --install
```

This prepends a snippet to the shell rc file that:
- Wraps new interactive shells in `zmx attach <unique-name>`
- Won't double-wrap (checks parent process name via `$PPID`, not env vars)
- Always prints a `surrogate:` status line regardless of terminal app
- Supports bash, zsh, and fish

## Dependencies

- **zmx** -- session persistence (source of truth for sessions)
- **tmux** -- internal keystroke bridge (users don't interact with tmux directly)
