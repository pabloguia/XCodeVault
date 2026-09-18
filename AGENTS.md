# XCodeVault — Project Instructions for Codex

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
- `docs/research/FINDINGS-2026-09-05.md` — **read this early.** A sourced desk-research
  pass done before any code, with confidence tags. It corrects several assumptions the
  original brief made. Items tagged GATING/[UNKNOWN] are the research backlog.
- `docs/architecture/HYPOTHESES.md` — the open technical hypotheses (H1–H9) and how each
  is proven or falsified. Do not claim a technique "works" without updating this file.
- `docs/architecture/EXPERIMENTS.md` — the gating experiment protocol (E1–E11). E1 and
  E2 come before any implementation work; either can kill a strategy in an afternoon.
- `docs/architecture/SECURITY_MODEL.md` — privileged-helper threat model and allowlisted API.
- `docs/architecture/MIGRATION_ENGINE.md` — transactional migration state machine and journal.
- `docs/architecture/COMPATIBILITY_MATRIX.md` — macOS/Xcode combinations, evidence, status.
- `docs/process/EXECUTION_PHASES.md` — phased plan (research-first, not GUI-first).
- `docs/process/AGENTIC_ENGINEERING_SETUP.md` — how to bootstrap and evolve
  `.codex/agents/`, `.agents/skills/`, and hooks for this repo.
- `docs/process/PRIOR_ART.md` — notes on `Viniciuscarvalho/mac-ssd-rescue` and other prior art.
- `docs/adr/` — architecture decision records. Add one for every meaningful
  architectural choice or reversal; don't silently overwrite past reasoning.
  ADR-0003 fixes the stack (Swift 6 / SwiftPM, one domain layer); ADR-0004 records the
  E1/E2 outcome (canonical mount demoted to R&D; v1 = accounting + official mechanisms +
  cleanup + disconnect safety).
- `STATUS.md` — current milestone, what is done / in flight / blocked, next three actions.
  Read it first in a new session; update it as you go.
- `docs/process/SESSION-HANDOFF.md` — the distilled version of the above for starting cold:
  reading order, verified machine state, and the recommended next work in priority order. Its
  numbers are point-in-time and say so; re-verify before acting on them.
- `scripts/experiments/` — the experiment harness (`common.sh` header/redaction, `e1`, `e2`,
  `e8`); evidence lands in `docs/research/evidence/`. `.agents/skills/run-experiment` has the
  procedure.

## Layout

`Package.swift` (Swift 6, macOS 14+) · `Sources/XCodeVaultCore` (the only domain layer:
Discovery, Catalog, Scan, Doctor, Report, Support) · `Sources/xcodevaultctl` (CLI) ·
`Tests/XCodeVaultCoreTests` (+ redacted fixtures) · `fixtures/E2Fixture` (experiment fixture)
· `Sources/XCodeVaultHelperProtocol` (the XPC contract) + `Sources/XCodeVaultHelperCore` (the
daemon's logic, in a library so it is testable) + `Sources/XCodeVaultHelper` (root daemon
bootstrap, allowlisted verbs; every change needs the helper-security review) · `Sources/XCodeVault` (SwiftUI app) ·
`Resources/` (Info.plist, launchd plist) · `scripts/bundle-app.sh` / `scripts/release.sh` ·
`packaging/homebrew/` · `.github/workflows/ci.yml` (macos-15 + macos-26) · `.swift-format`
(4-space indent, 160 cols). Build with `swift build`, test with `swift test`.

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
7. `~/Library/Developer` stays a real directory and `~/Library/Developer/DeveloperDiskImages`
   is never a symlink (FB12363725). Do not offer any symlink strategy for
   `~/Library/Developer/CoreSimulator`. The prohibition is unconditional, but note what it
   rests on: the reported same-disk breakage did **not** reproduce (H5/E9). It rests on the
   layout leaving a shadow `CoreSimulator` directory behind, and on one passing configuration
   not being a safety proof.
8. Minimum supported macOS is 14.0 (ADR-0001). Do not add pre-14 compatibility code
   paths, and never a second SMJobBless privileged-helper implementation.
9. Ship in the tier order of ADR-0002: supported Apple mechanisms and disconnect safety
   first; canonical APFS mount only if the gating experiments pass, and labeled
   experimental until the Definition of Done is met.
10. A storage strategy is not "supported" until `docs/architecture/HYPOTHESES.md` and
   `COMPATIBILITY_MATRIX.md` show it meets the Definition of Done in
   `docs/product/NON_GOALS_AND_SAFETY.md`. Until then, label it experimental everywhere
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
