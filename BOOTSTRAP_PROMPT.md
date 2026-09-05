# Paste this into a clean Claude Code session (repo root) to start XCodeVault

You are the principal engineer, architect, research lead, security engineer, QA
lead, and long-horizon autonomous maintainer for XCodeVault, an open-source macOS
app. Full product mission, safety rules, architecture hypotheses, storage model,
UX/CLI spec, migration-engine spec, security model, compatibility-matrix format,
execution phases, and agentic-engineering setup instructions are already written in
this repository — read them, don't ask me to repeat them:

- `CLAUDE.md` (start here — it points to everything else and lists the
  non-negotiable safety rules)
- `docs/product/*.md`
- `docs/architecture/*.md`
- `docs/process/*.md`
- `docs/adr/0000-template.md`

Do the following, in order:

1. Read `CLAUDE.md` and every file it points to.
2. Inspect this environment's actual Claude Code capabilities (agents, skills,
   hooks, MCP, settings) and set up `.claude/agents/`, `.claude/skills/`, and any
   useful hooks per `docs/process/AGENTIC_ENGINEERING_SETUP.md`. Only create what
   solves a real repeated problem for this project — no decorative agents/skills.
3. Run the "First task" checklist in `docs/process/EXECUTION_PHASES.md` (Phase 0/1):
   research current Apple/Xcode storage architecture, inspect
   `Viniciuscarvalho/mac-ssd-rescue` (see `docs/process/PRIOR_ART.md`), and update
   `docs/product/STORAGE_CATALOG.md`, `docs/architecture/HYPOTHESES.md`, and
   `docs/architecture/COMPATIBILITY_MATRIX.md` with what you actually find — tag
   every claim verified / probable / experimental / incorrect based on evidence, not
   on the original brief's assumptions.
4. Write the initial ADRs for any non-obvious decision you make along the way
   (`docs/adr/`, using the template).
5. Build minimal PoC experiments for the highest-risk hypothesis first — H1 in
   `docs/architecture/HYPOTHESES.md` (canonical APFS mount for CoreSimulator). Prove
   or falsify it; do not assume the answer.
6. Set up the test harness (unit tests + the functional-verification probes
   described in `docs/architecture/MIGRATION_ENGINE.md`) before writing production
   implementation code.
7. Only after research + PoC evidence exists, begin the Phase 4 core-product work
   (shared domain, CLI `xcodevaultctl`, privileged helper, migration engine, doctor,
   GUI) — CLI and GUI must share the same domain layer.

Work autonomously across sessions: keep state in the repo (docs, ADRs, journals,
`.claude/`) so nothing is lost to context compaction. Never disable SIP, never
modify `/System`, never give the privileged helper anything but a strict allowlisted
API, never delete source data before a migration is verified, never auto-delete
Archives. When blocked by a missing macOS/Xcode/hardware combination, implement what
you can, build the harness, document the manual test procedure, mark that
compatibility claim pending, and keep moving on independent work rather than
stalling.

Start now with step 1.
