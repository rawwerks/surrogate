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

This installs `surrogate`, `surrogate-shell-setup`, and `surrogate-doctor` to `~/.local/bin/`, then configures your shell for auto-zmx and verifies the installation.

### Agent skill (for Claude Code)

To teach Claude Code how to use surrogate, install the skill:

```bash
ln -s ~/Documents/GitHub/surrogate/SKILL.md ~/.claude/skills/surrogate.md
```

Agents will then know how to discover zmx sessions, inject keystrokes, read output, and wait for patterns.

### Dependencies

- [zmx](https://github.com/neurosnap/zmx) — session persistence
- [tmux](https://github.com/tmux/tmux) — used internally for keystroke injection

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

## Usage

### List available sessions

```bash
surrogate list
```

### Type text + Enter

The most common operation. Types literal text and presses Enter.

```bash
surrogate type <session> "echo hello world"
```

### Send special keys

Full tmux `send-keys` syntax — Enter, Escape, Ctrl combos, arrow keys, etc.

```bash
surrogate send <session> "banana" Enter
surrogate send <session> C-c                    # Ctrl+C
surrogate send <session> Escape ":wq" Enter     # vim save+quit
surrogate send <session> Up Up Enter             # repeat 2 commands ago
```

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
| `C-c` | Ctrl+C |
| `C-d` | Ctrl+D (EOF) |
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
surrogate type 2026-03-10_09-48-54_EDT-4054495 "explain the auth module"
surrogate wait 2026-03-10_09-48-54_EDT-4054495 "●" -t 60
sleep 10
surrogate read 2026-03-10_09-48-54_EDT-4054495 -n 100
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

## Tests

```bash
bash tests/test_surrogate_e2e.sh
```

19 end-to-end tests: 13 functional tests (list, type, send, read, wait, bridge creation/reuse, cleanup, status, concurrent serialization, error handling) + 6 design invariant tests.

## Uninstall

```bash
# Remove shell snippet
surrogate-shell-setup --uninstall

# Remove binaries
rm ~/.local/bin/surrogate ~/.local/bin/surrogate-shell-setup
```
