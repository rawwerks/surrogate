<!-- plumb:start -->
## aPlumb (Spec/Test/Code Sync)

This project uses aPlumb to keep the spec, tests, and code in sync.
Mode: **agent-managed**

- **Spec:** SPEC.md
- **Tests:** tests/
- **Decision log:** `.plumb/decisions/`
- **CLI:** `aplumb` (or `plumb` for backwards compat)

### When working in this project:

- Run `aplumb status` before beginning work to understand current alignment.
- Run `aplumb diff` before committing to preview what aPlumb will capture.
- Commits are **non-blocking** — the agent-managed hook captures decisions and
  auto-reviews them. The commit always proceeds.
- Run `aplumb review` to see agent-reviewed decisions. The human owner can
  override any decision at any time.
- Use `aplumb coverage` to identify what needs to be implemented or tested next.
- Never edit files in `.plumb/decisions/` directly.
- Treat the spec markdown files as the source of truth for intended behavior.
  aPlumb will keep them updated as decisions are approved.
- For detailed agent workflow guidance: `aplumb skill-path` prints the path to
  the aplumb skill file. Install it in your agent's skill system if supported.
<!-- plumb:end -->
