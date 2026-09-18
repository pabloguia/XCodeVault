# Execution Phases

Research-first, not GUI-first. Don't rigidly follow phase order if evidence shows a
better one, but keep the research-before-build discipline — never skip straight to
polished GUI implementation.

## Phase 0 — Repository & agentic engineering environment
Inspect repo/environment; establish this doc set (done as of the initial bootstrap);
set up `.claude/agents/`, `.claude/skills/`, hooks per
`AGENTIC_ENGINEERING_SETUP.md`; establish coding/testing/documentation conventions.

## Phase 0.5 — Gating experiments (NEW — do this before Phase 2, and E1/E2 before anything else)

Run `../architecture/EXPERIMENTS.md`. E1 (is the path even mountable / rootless?) and
E2 (does the external-volume sandbox restriction follow the device or the path?) can
each kill or reshape the canonical-mount strategy in an afternoon. Running them first
avoids building on a hypothesis that a single command would have falsified. Record
results in the matrix, update hypothesis statuses, write ADRs for anything that
changes a decision.

## Phase 1 — Storage archaeology
Map Apple developer storage across supported Xcode/macOS generations; inspect
`mac-ssd-rescue` as prior art (`PRIOR_ART.md`); populate `STORAGE_CATALOG.md` with
every discovered category and an initial strategy classification (mark unverified
strategies clearly).

## Phase 2 — Proofs of concept
Storage scanner; Xcode discovery; external-volume discovery; DerivedData native
relocation; granular user-directory relocation; canonical-APFS-mount experiment
(H1); Runtime Library download/import experiment; transactional-migration
experiment. Each PoC should produce evidence for `HYPOTHESES.md` /
`COMPATIBILITY_MATRIX.md`, not just working code.

## Phase 3 — Compatibility lab
Validate hypotheses on representative macOS/Xcode combinations; document failures as
rigorously as successes; turn results into version-aware rules in the storage catalog.

## Phase 4 — Core product
Shared domain packages; CLI (`xcodevaultctl`); privileged helper; migration engine;
doctor subsystem; GUI (calls the same domain layer as the CLI).

Build in the tier order set by `../adr/0002-strategy-tiers-and-canonical-mount-as-rnd.md`:
supported mechanisms first (Xcode Locations, `-exportPath`/`-importPlatform` Runtime
Library, `-architectureVariant arm64`, `simctl runtime delete`, cleanup), then the
disconnect-safety subsystem, then — only if the gating experiments passed — the
experimental canonical mount. FSKit stays an R&D track.

## Phase 5 — Hardening
Failure injection; external-drive removal tests; crash recovery tests;
security/privilege review; compatibility tests; performance tests.

## Phase 6 — Release
Developer ID signing; notarization; packaging; GitHub Releases; optional Homebrew
Cask; documentation; reproducible release process where possible.

## First task (what to do at session start)

1. Inspect environment and repository.
2. Initialize/refresh the project's Claude Code agentic structure
   (`AGENTIC_ENGINEERING_SETUP.md`).
3. Read `../research/FINDINGS-2026-09-05.md` first — a desk-research pass already
   exists. Extend and correct it; do not redo it from scratch. Anything marked
   [UNKNOWN] or GATING there is your research backlog.
4. Inspect `Viniciuscarvalho/mac-ssd-rescue` as prior art.
5. Build/refine the storage map and compatibility model.
6. Tag each assumption in this doc set as verified / probable / experimental /
   incorrect, based on actual findings — update the docs, don't just note it in chat.
7. Write the initial ADRs for any non-obvious choice made along the way.
8. Build minimal PoC experiments for the highest-risk hypotheses (H1 first).
9. Establish tests (unit + the functional-verification probes from
   `MIGRATION_ENGINE.md`).
10. Only then begin production implementation.

The most important early question: can modern CoreSimulator storage be safely and
transparently placed on an external APFS volume mounted at a canonical
`/Library/Developer/CoreSimulator...` path, while preserving simulator operation,
Xcode builds, multi-Xcode compatibility, reboot behavior, and physical-device
debugging (H1)? Prove or falsify it; don't assume the answer.

## How each phase is built

Ship each phase as working, tested, committed code before starting the next. Prefer vertical slices
over horizontal layers — a thin path that actually runs beats four half-built tiers. The phase
ordering above says *what* comes first and why; this says how to build whatever is current.

_(Rehoused from `BOOTSTRAP_PROMPT.md` during the 2026-09-18 pre-publication review, before that
completed brief was deleted. It was the only copy.)_
