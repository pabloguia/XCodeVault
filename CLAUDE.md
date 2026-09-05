# XCodeVault — Project Instructions for Claude Code

XCodeVault is an open-source macOS app that safely relocates Apple developer tooling
storage (Simulator runtimes, CoreSimulator, DerivedData, device support, caches,
archives, etc.) to external storage while keeping Xcode/Simulator/xcodebuild/simctl/
devicectl working transparently.

This file is the always-loaded entry point. Everything else lives in `docs/` — read
the relevant doc before acting on that area. Do not duplicate their content here; keep
this file short and update it only when a pointer or non-negotiable changes.

## Read before acting

- `docs/product/MISSION.md` — what we're building and for whom, in scope / out of scope.
- `docs/product/NON_GOALS_AND_SAFETY.md` — the non-negotiable safety rules. Read this
  before writing any code that touches mounts, deletion, or the privileged helper.
- `docs/product/STORAGE_CATALOG.md` — the data model for storage categories and strategies.
- `docs/product/UX_AND_CLI.md` — GUI/CLI UX spec, `xcodevaultctl` command surface.
- `docs/architecture/HYPOTHESES.md` — the open technical hypotheses and how each is
  proven or falsified. Do not claim a technique "works" without updating this file.
- `docs/architecture/SECURITY_MODEL.md` — privileged-helper threat model and allowlisted API.
- `docs/architecture/MIGRATION_ENGINE.md` — transactional migration state machine and journal.
- `docs/architecture/COMPATIBILITY_MATRIX.md` — macOS/Xcode combinations, evidence, status.
- `docs/process/EXECUTION_PHASES.md` — phased plan (research-first, not GUI-first).
- `docs/process/AGENTIC_ENGINEERING_SETUP.md` — how to bootstrap and evolve
  `.claude/agents/`, `.claude/skills/`, and hooks for this repo.
- `docs/process/PRIOR_ART.md` — notes on `Viniciuscarvalho/mac-ssd-rescue` and other prior art.
- `docs/adr/` — architecture decision records. Add one for every meaningful
  architectural choice or reversal; don't silently overwrite past reasoning.

## Non-negotiable safety rules (also in NON_GOALS_AND_SAFETY.md — kept here because they must never be missed)

1. Never disable SIP, and never instruct a user to. Never require SIP-off for the
   normal product flow.
2. Never modify `/System`.
3. The privileged helper exposes a strict allowlisted API only — no arbitrary shell,
   no arbitrary paths from the client, no generic `rm`/`mv`/`mount`.
4. Never delete source data before a migration is verified as complete and reversible.
5. Never auto-delete Archives or other non-regenerable artifacts without explicit user intent.
6. Treat a disconnected/reconnected external volume as a first-class failure mode —
   never silently allow shadow/duplicate data to form.
7. A storage strategy is not "supported" until `docs/architecture/HYPOTHESES.md` and
   `COMPATIBILITY_MATRIX.md` show it meets the Definition of Done in
   `docs/process/EXECUTION_PHASES.md`. Until then, label it experimental everywhere
   (code comments, CLI help text, UI, docs).

## Working style

- Research before implementing. Prefer official Apple mechanisms over filesystem tricks.
- Never turn an unverified forum workaround into product behavior without reproducing
  it yourself and recording the evidence.
- Read existing code/docs before changing them. Keep the repo buildable; run tests
  continuously. Commit logical, reviewed increments.
- When blocked by missing hardware/macOS/Xcode combos: implement what you can, build
  the test harness, document the manual test procedure, mark the compatibility claim
  "pending," and keep moving on independent work instead of stalling the whole project.
- Update docs/agents/skills/ADRs as understanding evolves. Do not preserve a design
  choice from the original brief once evidence contradicts it — record why in an ADR.
