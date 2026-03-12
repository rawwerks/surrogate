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

This installs `surrogate`, `surrogate-brief`, `surrogate-shell-setup`, and `surrogate-doctor` to `~/.local/bin/`. `surrogate-brief` is optional and only used for OpenRouter-backed remote summaries; core `surrogate` session control does not require any API key. It also tries to install [dcg](https://github.com/Dicklesworthstone/destructive_command_guard) by default as a recommended safety guard. If dcg install fails, surrogate still installs and works.

For contributors working from a checkout, use dev-link mode so the installed CLI never drifts from the repo:

```bash
bash install.sh --dev-link
```

This symlinks the installed binaries to the current checkout instead of copying them.

When publishing to `main`, use the helper below instead of `safe-push` directly:

```bash
bash bin/surrogate-push-main
```

It safe-pushes `main`, converts any repo dev-links back to real copied binaries, reinstalls, and runs `surrogate-doctor`.

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

- `type` normalizes embedded newlines to spaces and must actually submit, not just stage text in the target input
- `type`, `send`, and `submit` reject self-targeting and tell you the current alias/session
- `cull` rejects the current live session and any attached session with clients still present
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
surrogate help list                      # discoverable list help + flags
surrogate list                           # fast alias + full name view
surrogate list --cwd                     # repo, cwd, and shell/agent hint
surrogate list --json                    # machine-readable repo/cwd/ui metadata
```

### Search all sessions

```bash
surrogate find "auth error"             # search last 200 lines of every session
surrogate find "TODO" -n 500 -C 3       # deeper search with context lines
```

### Show sessions with snippets

```bash
surrogate who                            # newest 20 first: age, ui, session, repo, last visible line
surrogate who --recent 20                # show the 20 most recent sessions
surrogate who --recent 2h                # only sessions seen in the last 2 hours
surrogate who --project surrogate        # filter by visible repo basename hint
surrogate who --cwd /home/raw/Documents/GitHub/surrogate
surrogate who --json                     # machine-readable output for agents/scripts
surrogate who -n 20                      # inspect more recent history for snippet/hints
```

`--project`, `--cwd`, and the shell-vs-agent UI hint are deterministic visibility hints derived from recent visible output. They are convenient hints, not authoritative process introspection.

### Show attached sessions

```bash
surrogate active                         # only sessions with clients attached
surrogate active --all                   # include non-empty detached sessions
```

### Remote operator briefs with OpenRouter

This path is optional and requires an OpenRouter API key. Core `surrogate` usage remains local and has no API cost.

If `OPENROUTER_API_KEY` is set, you can summarize active windows with one API call per zmx session. By default it uses model `z-ai/glm-4.7` with preferred provider `cerebras`.

Recommended entrypoint:

```bash
surrogate brief --recent 15
surrogate brief 15
surrogate brief silly-pixel
```

`surrogate brief` reuses the existing activity-ranked session selection logic from `surrogate active --recent ...`, so it filters by recent activity, not recent spawn time.

Lower-level helper:

```bash
surrogate-brief                          # all attached sessions, 500 lines each
surrogate-brief glossy-hedgehog          # one session by alias
surrogate-brief -n 800 --max-completion-tokens 1800 silly-pixel
surrogate-brief --openrouter-model openai/gpt-4.1-mini --inference-provider openai silly-pixel
surrogate-brief --show-config
```

Each session summary includes:
- `STATUS`
- `LAST COMPLETED`
- `PROPOSED NEXT STEPS`
- `USER INPUT NEEDED`
- `BLOCKERS`

Defaults:
- Scrollback window: `500` lines
- Completion budget: `1200` tokens per session
- OpenRouter model: `z-ai/glm-4.7`
- Preferred inference provider: `cerebras`

Config file:

```bash
mkdir -p ~/.config/surrogate
cp surrogate-brief.conf.example ~/.config/surrogate/brief.conf
```

CLI flags override config values.

If the key is missing, `surrogate-brief` prints the exact setup steps needed to enable it.

### Show stale detached sessions

```bash
surrogate stale                          # oldest detached sessions older than 24h
surrogate stale --older-than 72          # oldest detached sessions older than 72h
surrogate stale --older-than 24 --filter "2026-03-08"
surrogate stale --older-than 24 --limit 20
```

`stale` is ordered oldest-first.

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

### Cull stale or explicit sessions

`zmx` remains the source of truth. `surrogate cull` delegates the kill to `zmx kill`, then removes surrogate’s bridge/alias/lock/watermark plumbing for that session.

```bash
surrogate cull sleepy-otter
surrogate cull --stale --older-than 48
surrogate cull --stale --older-than 24 --filter "2026-03-08" --dry-run
surrogate cull --stale --older-than 24 --limit 10
```

Batch stale culls are ordered oldest-first.

### Type text + Enter

The most common operation. Types literal text and presses Enter.

```bash
surrogate type <session> "echo hello world"
```

`type` auto-handles long prose by flattening embedded newlines into spaces and submitting once. A successful `type` means the text was actually submitted, not just left sitting in the target input buffer.

Default `type` is now shell-safe:

- if the target looks like a shell, surrogate suppresses the `[SURROGATE ...]` prose prefix so commands still execute normally
- after submission, surrogate checks fresh shell output and warns on immediate failures like `command not found` or syntax errors
- the warning points you to `surrogate read <session> -n 40`

For agent-to-agent prose, use the explicit message mode:

```bash
surrogate type --message <session> "Long conversational prompt..."
```

`--message` requires an agent-like target and refuses shell or unknown contexts. Use it when you want safer long-form prose delivery into a coding-agent TUI.

The submit pause is configurable:

```bash
SURROGATE_TYPE_ENTER_DELAY_SECS=0.02 surrogate type my-session "hello"
```

If a prompt is visibly staged and just needs the missing Enter, the obvious repair path is:

```bash
surrogate submit my-session
```

If the target resolves to your current live zmx session, surrogate refuses and tells you who you are instead of typing into itself.

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

Bridge cleanup only touches tmux plumbing. Session culling uses `zmx kill` and is handled separately by `surrogate cull`.

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
surrogate submit my-session                     # submit staged prompt
```

### Self-target guard

Surrogate refuses to type into the current live session. If you are unsure which session you are in:

```bash
surrogate whoami
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
| **Inherited status shows alias** | When a shell starts inside an existing zmx session, the startup line includes both the zmx session name and the surrogate alias when lookup succeeds |
| **All shells supported** | bash, zsh, and fish snippets all have both wrap and inherit code paths |
| **Terminal-agnostic** | Zero references to specific terminal emulators in snippets or CLI |
| **Full path to zmx** | Snippet uses `$HOME/.local/bin/zmx`, not `command -v zmx` (PATH isn't set when rc files run) |
| **Full path to surrogate** | Snippet uses `$HOME/.local/bin/surrogate` for inherited-session alias lookup, not `command -v surrogate`, and seeds a minimal `PATH` so lookup works before shell init finishes |
| **Parent process check** | Double-wrap prevention checks parent process name (`ps -o comm= -p $PPID`), not `$ZMX_SESSION` env var (which leaks through window managers to all children) |
| **Deterministic aliases** | Every session gets a collision-free adjective-noun alias derived from its name via `cksum` — no state files, no config |
| **Deterministic search** | `find`, `who`, `active`, `peek` use only rg/grep + zmx + tmux — no provider-specific parsing or ML |
| **Input validation** | All numeric flags (`-n`, `-C`, `-t`) reject non-integer values before reaching internal commands |
| **Security floor** | `type` normalizes embedded newlines to spaces and must actually submit, self-targeted `type`/`send`/`submit` are rejected with identity context, `send` rejects `C-c`/`C-d`/`C-z`, and DCG denials block `type` when DCG is installed |
| **Security overhead tracked** | The test harness reports baseline vs guarded `type` latency as a metric, not a pass/fail gate |
| **Audit trail** | `type` and `send` append JSONL audit records for both allowed and blocked actions |

## Tests

```bash
bash tests/test_surrogate_e2e.sh         # fast smoke suite (default)
bash tests/test_surrogate_e2e.sh --full  # complete suite
```

The default smoke run covers the core end-to-end paths and safety regressions quickly. Use `--full` for the complete functional and invariant suite.

## Uninstall

```bash
# Remove shell snippet
surrogate-shell-setup --uninstall

# Remove binaries
rm ~/.local/bin/surrogate ~/.local/bin/surrogate-brief ~/.local/bin/surrogate-shell-setup
```
