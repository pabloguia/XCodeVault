# Agentic Engineering Setup (for Claude Code, in this repo)

This repo is meant to be developed long-horizon, across many Claude Code sessions,
some of which will hit context compaction. State must live in the repo (docs, ADRs,
journals, `.claude/`), not in any one conversation.

## Do this at session start, before heavy implementation

1. Check what Claude Code version/capabilities are actually available in the current
   environment (agents, skills, hooks, MCP, settings) — don't assume conventions from
   memory; verify against the current docs/behavior.
2. Look at what already exists under `.claude/` in this repo (agents, skills, hooks,
   settings) before adding more. Evolve, don't duplicate.
3. Create `.claude/agents/` subagents only for roles that solve a *repeated* context
   or quality problem — not for decoration. Good candidates given this project's
   shape (illustrative, not mandatory — merge/split/rename/remove as the project's
   actual needs become clear):
   - Apple storage / CoreSimulator-CoreDevice researcher (owns `HYPOTHESES.md` and
     `COMPATIBILITY_MATRIX.md` updates)
   - macOS filesystem/mount engineer (owns canonical-mount PoCs)
   - Privileged-helper security reviewer (reviews every helper change — must not be
     the same agent/session that wrote the change)
   - Migration-safety reviewer (reviews anything touching the migration engine
     against `NON_GOALS_AND_SAFETY.md` and `MIGRATION_ENGINE.md`)
   - Compatibility test runner (executes the matrix, records evidence)
   - Release engineer
   - Documentation maintainer (keeps `docs/` and README in sync with actual behavior)
4. Create `.claude/skills/` for recurring workflows, e.g.: Apple/Xcode compatibility
   research procedure; adding a new storage-catalog category; implementing a new
   migration strategy; migration-safety review checklist; privileged-helper review
   checklist; running the compatibility matrix; release preparation; issue triage;
   post-architecture-change doc sync. Keep each skill's SKILL.md concise; put
   detailed scripts/references in supporting files under the skill's folder.
5. Use hooks for deterministic enforcement where it beats relying on a reviewer
   remembering: formatting, static analysis, running tests, forbidden-operation
   detection (e.g. grep-based check that no new code calls an unscoped `rm`/`mount`
   from the privileged-helper target), doc-consistency checks.
6. Use worktrees (or equivalent isolation) for parallel implementation work that
   could otherwise conflict — e.g. running a PoC experiment alongside unrelated
   product-code changes.

## Ongoing discipline

- Every meaningful architecture decision or reversal gets an ADR
  (`docs/adr/`, template at `0000-template.md`). Don't silently overwrite past
  reasoning — supersede it explicitly.
- Every hypothesis status change goes through `HYPOTHESES.md` +
  `COMPATIBILITY_MATRIX.md`, with evidence, not just a claim in a commit message or
  chat.
- If an assumption from the original product brief turns out wrong (Apple changed
  behavior, a better supported API exists, an agent/skill is no longer earning its
  keep), change it and record why — don't preserve a bad initial design out of
  inertia.
- Keep the repo buildable at every commit; run tests continuously; commit logical,
  reviewed increments rather than large unreviewed dumps.


## Observations from the first implementation session (2026-09-06)

- Project-level `.claude/agents/*.md` are picked up at session start; agents created mid-session
  are not offered to the Agent tool until the next session. Until then, dispatch a
  `general-purpose` agent with the agent file's instructions pasted in — that is how the M2/M3
  migration-safety and helper-security reviews were run.
- Writing files through shell heredocs bypasses the `Edit|Write` hooks. When a file under
  `Sources/XCodeVaultHelper*` is produced that way, run `.claude/hooks/helper-guard.sh`
  manually (see the M3 commit) — or use the Write tool.
- Long experiments (E2 ≈ 15 min) should run in the background with output redirected to a
  file; the evidence file name must include the case list when a subset is run, or a rerun
  overwrites the full-run evidence (fixed in `e2-external-xctest.sh`).
