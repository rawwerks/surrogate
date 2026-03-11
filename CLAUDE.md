<!-- plumb:start -->
## aPlumb (Spec/Test/Code Sync)

This project uses aPlumb to keep the spec, tests, and code in sync.
Mode: **agent-managed**

- **Spec:** SPEC.md
- **Tests:** tests/
- **Decision log:** `.aplumb/decisions/`
- **CLI:** `aplumb` (or `plumb` for backwards compat)

### When working in this project:

- Run `aplumb status` before beginning work to understand current alignment.
- Run `aplumb diff` before committing to preview what aPlumb will capture.
- Commits are **non-blocking** — the agent-managed hook captures decisions and
  auto-reviews them. The commit always proceeds.
- Run `aplumb review` to see agent-reviewed decisions. The human owner can
  override any decision at any time.
- Use `aplumb coverage` to identify what needs to be implemented or tested next.
- Never edit files in `.aplumb/decisions/` directly.
- Treat the spec markdown files as the source of truth for intended behavior.
  aPlumb will keep them updated as decisions are approved.
- For detailed agent workflow guidance: `aplumb skill-path` prints the path to
  the aplumb skill file. Install it in your agent's skill system if supported.
<!-- plumb:end -->

## Surrogate Project Rules

### Backpressure Harness

Every change must keep these in sync. If you change one, update the others:

| Artifact | File | Role |
|----------|------|------|
| **Spec** | `SPEC.md` | Source of truth for behavior |
| **Tests** | `tests/test_surrogate_e2e.sh` | Verify spec is implemented |
| **Code** | `bin/surrogate` | Implementation |
| **Skill** | `SKILL.md` | Teaches agents how to use surrogate |
| **Docs** | `README.md` | Teaches humans how to install/use |

**Before starting work:**
```bash
aplumb status          # see drift
aplumb coverage        # see gaps
```

**Before finishing work:**
```bash
bash tests/test_surrogate_e2e.sh   # all tests pass
bash install.sh                     # deployed binary matches repo
aplumb status                       # no new drift introduced
```

**When publishing to `main`:**
```bash
bash bin/surrogate-push-main       # safe-push + real reinstall + doctor
```

### Design Constraints

- **Deterministic only.** No heuristics, no agent-type detection, no ML.
- **zmx is source of truth.** tmux bridges are disposable plumbing.
- **rg preferred, grep fallback.** No other search dependencies.
- **All numeric flags validated.** `require_int` before passing to internal tools.
- **Terminal-agnostic.** Zero references to specific terminal emulators.
