# Surrogate

Programmatic keystroke injection for any terminal application, via [zmx](https://github.com/neurosnap/zmx) sessions.

Type into Claude Code, vim, REPL — anything running in a terminal — from scripts, AI agents, or other programs.

![Surrogate](surrogate.webp)

## WARNING!!!

> [!CAUTION]
> This tool is really dangerous. This is the YOLO mode of all YOLO modes. You could really get pwned.
> Any process or agent that can run `surrogate type` can inject keystrokes into any zmx terminal session on the machine.

## Motivation

1. tmux is powerful and amazing and my agents love it. I hate using tmux.
2. I want to be able to walk away from my computer, and have a surrogate inject messages into my terminal sessions (specifically coding agent TUIs).
3. zmx is very slick but doesn't have a way to inject keys.

## How it works

```
surrogate type <session> "banana"
    └── tmux send-keys (proper key events)
            └── tmux pane (zmx attach bridge)
                    └── zmx IPC → PTY master
                            └── your app receives keystrokes
```

zmx is the source of truth for sessions. tmux is invisible plumbing. You use whatever terminal emulator you want (Ghostty, WezTerm, Alacritty, kitty, xterm).

## Install

One-liner:

```bash
git clone https://github.com/rawwerks/surrogate.git && cd surrogate && bash install.sh && surrogate-shell-setup --install && surrogate-doctor
```

Or step by step:

```bash
git clone https://github.com/rawwerks/surrogate.git
cd surrogate
bash install.sh
surrogate-shell-setup --install
surrogate-doctor
```

This installs `surrogate`, `surrogate-shell-setup`, and `surrogate-doctor` to `~/.local/bin/`. It also tries to install [dcg](https://github.com/Dicklesworthstone/destructive_command_guard) by default as a recommended safety guard. If dcg install fails, surrogate still installs and works.

For contributors working from a checkout, use dev-link mode so the installed CLI never drifts from the repo:

```bash
bash install.sh --dev-link
```

This symlinks the installed binaries to the current checkout instead of copying them.

### Agent skill (for Claude Code)

To teach Claude Code how to use surrogate, install the skill:

```bash
ln -s ~/Documents/GitHub/surrogate/SKILL.md ~/.claude/skills/surrogate.md
```

Agents will then know how to discover zmx sessions, inject keystrokes, read output, and wait for patterns.

### Dependencies

- [zmx](https://github.com/neurosnap/zmx) — session persistence
- [tmux](https://github.com/tmux/tmux) — used internally for keystroke injection

### Recommended safety dependency

- [dcg](https://github.com/Dicklesworthstone/destructive_command_guard) — Destructive Command Guard for blocking dangerous commands before they execute

`bash install.sh` will try to install dcg automatically. This is strongly recommended but technically optional: surrogate still works without dcg.

To skip dcg auto-install:

```bash
SURROGATE_SKIP_DCG=1 bash install.sh
```

## Security Model

Surrogate stays ambiently available, but it no longer treats that as unlimited authority.

- Surrogate enforces a built-in deterministic safety floor of its own.
- DCG is an optional second layer for content scanning, not the only guardrail.
- Some actions are intentionally outside Surrogate's authority surface and require direct human control.

Current built-in structural guardrails:

- `type` normalizes embedded newlines to spaces and submits once
- `send` rejects `C-c`, `C-d`, and `C-z`
- there is no global "disable guards" switch
- there is no persistent unsafe mode

If DCG is installed, `type` also scans command-like payloads and blocks on DCG denials. On this machine, the current measured overhead is about `9ms` average added latency on `surrogate type`.

Surrogate also writes a deterministic audit trail for `type` and `send` actions:

- default path: `/tmp/surrogate-audit.jsonl`
- override path: `SURROGATE_AUDIT_FILE=/path/to/file.jsonl`
- both allowed and blocked actions are logged

### Auto-wrap all terminals in zmx

By default, surrogate can only talk to apps running inside zmx sessions. To make **every** new terminal window a zmx session automatically:

```bash
surrogate-shell-setup --install
```

This prepends a small snippet to your shell rc file (`.bashrc`, `.zshrc`, or `config.fish`). It:
- Wraps each new interactive shell in `zmx attach <unique-name>`
- Won't double-wrap (checks parent process name via `$PPID`, not env vars which leak through window managers)
- Always prints a `surrogate:` status line, regardless of terminal app
- Can be opted out per-session with `SURROGATE_NO_ZMX=1`
- Can be removed cleanly with `surrogate-shell-setup --uninstall`

If your terminal already launches zmx (e.g., Ghostty with a custom command), the snippet detects the zmx parent process and prints the status line without double-wrapping.

**Preview before installing:**
```bash
surrogate-shell-setup --show
```

**Check if installed:**
```bash
surrogate-shell-setup --check
```

## Session Aliases

Every session gets a deterministic adjective-noun alias derived from its name — no config, no state files. Aliases never collide.

```bash
surrogate list
# shiny-dolphin      2026-03-08_20-44-12_EDT-539343
# robo-quokka        2026-03-09_13-53-24_EDT-2132820
# whimsy-capybara    2026-03-09_13-28-42_EDT-1872169

surrogate type shiny-dolphin "hello"     # same as using the full timestamp
surrogate alias 2026-03-08_20-44-12_EDT-539343   # → shiny-dolphin
```

All commands that take a `<session>` argument accept either the full zmx name or the alias.

## Usage

### List available sessions

```bash
surrogate list                           # shows alias + full name
```

### Search all sessions

```bash
surrogate find "auth error"             # search last 200 lines of every session
surrogate find "TODO" -n 500 -C 3       # deeper search with context lines
```

### Show sessions with snippets

```bash
surrogate who                            # age, session name, last visible line
surrogate who -n 20                      # sniff last 20 lines for snippet
```

### Show attached sessions

```bash
surrogate active                         # only sessions with clients attached
surrogate active --all                   # include non-empty detached sessions
```

### Batch read all sessions

```bash
surrogate peek                           # last 5 lines from every session
surrogate peek --filter "shoulder"       # only sessions matching pattern
surrogate peek -n 2 --filter "error"
```

### Rename a session

```bash
surrogate rename <old-session> <new-name>
```

### Type text + Enter

The most common operation. Types literal text and presses Enter.

```bash
surrogate type <session> "echo hello world"
```

`type` auto-handles long prose by flattening embedded newlines into spaces and submitting once. This keeps long messages ergonomic without turning one `type` call into multiple submits.

### Send special keys

Full tmux `send-keys` syntax for low-risk keys such as `Enter`, `Escape`, arrows, and text literals.

```bash
surrogate send <session> "banana" Enter
surrogate send <session> Escape ":wq" Enter     # vim save+quit
surrogate send <session> Up Up Enter             # repeat 2 commands ago
```

Dangerous control keys `C-c`, `C-d`, and `C-z` are reserved for direct human control and are rejected by surrogate.

### Read output

```bash
surrogate read <session>            # last 20 lines
surrogate read <session> -n 50      # last 50 lines
```

### Wait for pattern

Waits for a regex pattern to appear in **new** output (after the last send/type). Useful for automation loops.

```bash
surrogate type my-session "make test"
surrogate wait my-session "PASS|FAIL" -t 60     # wait up to 60s
```

### Bridge management

Surrogate creates ephemeral tmux "bridge" sessions behind the scenes. You rarely need to manage them, but:

```bash
surrogate bridge <session>      # pre-warm a bridge
surrogate status                # show all bridges and health
surrogate cleanup               # remove bridges for dead zmx sessions
surrogate cleanup --all         # remove all bridges
```

## Special keys reference

| Key | Description |
|-----|-------------|
| `Enter` | Enter/Return |
| `Escape` | Escape |
| `C-u` | Ctrl+U (clear line) |
| `C-l` | Ctrl+L (clear screen) |
| `Tab` | Tab |
| `Up` `Down` `Left` `Right` | Arrow keys |
| `BSpace` | Backspace |
| `Space` | Explicit space |

Full list: `man tmux` → KEYS section.

## Examples

### Send a prompt to Claude Code

```bash
surrogate type robo-quokka "explain the auth module"
surrogate wait robo-quokka "●" -t 60
sleep 10
surrogate read robo-quokka -n 100
```

### Drive vim

```bash
surrogate send my-session "vim main.go" Enter
sleep 1
surrogate send my-session "i"                   # insert mode
surrogate send my-session "// TODO: fix this"
surrogate send my-session Escape ":wq" Enter    # save and quit
```

### Agent self-talk (strange loop)

An AI agent can send input to its own session — but must delay it since it can't type while generating:

```bash
nohup bash -c 'sleep 10 && surrogate type MY_SESSION "banana"' &
```

### Automation loop

```bash
SESSION="my-dev-session"
surrogate type "$SESSION" "make build"
if surrogate wait "$SESSION" "error" -t 30 2>/dev/null; then
  echo "Build failed"
  surrogate read "$SESSION" -n 30
else
  echo "Build succeeded"
fi
```

## Design Invariants

These are enforced by automated tests and must hold for every change:

| Invariant | Description |
|-----------|-------------|
| **Always prints status** | Every terminal session prints `surrogate:` on startup, whether zmx was wrapped by the snippet or inherited from the terminal emulator |
| **All shells supported** | bash, zsh, and fish snippets all have both wrap and inherit code paths |
| **Terminal-agnostic** | Zero references to specific terminal emulators in snippets or CLI |
| **Full path to zmx** | Snippet uses `$HOME/.local/bin/zmx`, not `command -v zmx` (PATH isn't set when rc files run) |
| **Parent process check** | Double-wrap prevention checks parent process name (`ps -o comm= -p $PPID`), not `$ZMX_SESSION` env var (which leaks through window managers to all children) |
| **Deterministic aliases** | Every session gets a collision-free adjective-noun alias derived from its name via `cksum` — no state files, no config |
| **Deterministic search** | `find`, `who`, `active`, `peek` use only rg/grep + zmx + tmux — no heuristics, no agent-type guessing |
| **Input validation** | All numeric flags (`-n`, `-C`, `-t`) reject non-integer values before reaching internal commands |
| **Security floor** | `type` normalizes embedded newlines to spaces and submits once, `send` rejects `C-c`/`C-d`/`C-z`, and DCG denials block `type` when DCG is installed |
| **Security overhead tracked** | The test harness reports baseline vs guarded `type` latency as a metric, not a pass/fail gate |
| **Audit trail** | `type` and `send` append JSONL audit records for both allowed and blocked actions |

## Tests

```bash
bash tests/test_surrogate_e2e.sh
```

End-to-end tests: functional tests (list, type, send, read, wait, find, who, active, peek, rename, bridge creation/reuse, cleanup, status, concurrent serialization, input validation, error handling) + design invariant tests.

## Uninstall

```bash
# Remove shell snippet
surrogate-shell-setup --uninstall

# Remove binaries
rm ~/.local/bin/surrogate ~/.local/bin/surrogate-shell-setup
```
