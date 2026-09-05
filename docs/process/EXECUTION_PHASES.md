# Execution Phases

Research-first, not GUI-first. Don't rigidly follow phase order if evidence shows a
better one, but keep the research-before-build discipline — never skip straight to
polished GUI implementation.

## Phase 0 — Repository & agentic engineering environment
Inspect repo/environment; establish this doc set (done as of the initial bootstrap);
set up `.claude/agents/`, `.claude/skills/`, hooks per
`AGENTIC_ENGINEERING_SETUP.md`; establish coding/testing/documentation conventions.

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
3. Fresh research pass on current Apple/Xcode storage architecture.
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
