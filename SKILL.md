---
name: surrogate
description: "Send keystrokes to any terminal app via zmx sessions. Use when you need to type into TUI apps, talk to other agents, or drive interactive programs programmatically."
---

# Surrogate

Surrogate enables programmatic keystroke injection into any terminal application running in a zmx session. It uses tmux internally as a bridge. The chain: tmux send-keys -> tmux pane (zmx attach) -> zmx IPC -> PTY -> target app.

An AI agent uses surrogate to act as a "surrogate user" -- typing into TUI apps like Claude Code, vim, python REPL, htop, etc.

## Quick Reference

### Discover sessions

```bash
surrogate list
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
surrogate who [-n LINES]
# Age, session name, last visible line from each session
surrogate who
surrogate who -n 20   # sniff last 20 lines for snippet
```

### Show attached sessions

```bash
surrogate active [--all]
# Default: only sessions with clients attached
surrogate active
surrogate active --all   # include non-empty detached sessions
```

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

### Type text + Enter (most common)

```bash
surrogate type <session> "some text"
```

### Send special keys (tmux send-keys syntax)

```bash
surrogate send <session> <keys...>
```

### Read recent output

```bash
surrogate read <session> [-n N]
```

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
surrogate cleanup          # remove bridges for dead zmx sessions
surrogate cleanup --all    # remove ALL bridges
```

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

### Self-talk (agent sends input to its own session)

```bash
# Must use delayed send since agent can't type while generating
nohup bash -c 'sleep 10 && surrogate type MY_SESSION "banana"' &
```

### Inter-agent communication

```bash
# Find which session is working on shoulder
surrogate find "shoulder" -n 50
# Or peek at all sessions mentioning it
surrogate peek --filter "shoulder"
# Send them a prompt
surrogate type 2026-03-10_09-48-54_EDT-4054495 "Please review my changes"
```

## Special Keys Reference

Since `surrogate send` passes through to tmux send-keys:

| Key | Description |
|-----|-------------|
| `Enter` | Enter key |
| `Escape` | Escape key |
| `C-c` | Ctrl+C |
| `C-d` | Ctrl+D (EOF) |
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
- The "strange loop" -- talking to yourself

## When NOT to Use Surrogate

- For non-interactive commands -- just use Bash tool directly
- For file I/O -- use Read/Write/Edit tools
- When you have a proper API -- prefer APIs over keystroke injection
- For sending messages between agents -- prefer Agent Mail for structured communication. Use surrogate only when you need to type into the agent's actual TUI.

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
