# ADR 0011: The app runs the savings commands it used to only copy (R3)

- Status: accepted
- Date: 2026-10-04
- Supersedes: the "no GUI writer" clause of spec 2026-10-03 §6.4 (`docs/superpowers/specs/2026-10-03-savings-visibility-i18n-identity-design.md`)
- Related hypothesis (if any): none new; every strategy keeps the status `HYPOTHESES.md` and `COMPATIBILITY_MATRIX.md` give it

## Context

Spec 2026-10-03 §6.4 gave Park and Run externally a **Copy command** button per row and said GUI execution of
`externalize`, `runtime offload` and `locations set-*` "is a follow-up that needs its own spec and the migration-safety
review; this design does not add a GUI writer". On 2026-10-04 the user asked for the follow-up, in their words: "the
commands have a 'Copy command' button; I want them to run from the interface, with a progress bar and the command's
log." The brief they approved is `.superpowers/sdd/r3/brief.md`.

Every Core operation involved already existed, was journaled and needed no root. What the app lacked was the CLI's
glue (volume discovery, the selected Xcode, the `--yes` and `--i-…` gates as explicit confirmations) and any way to
watch a command while it runs: `ProcessCommandRunner` blocks and returns the output at the end.

## Decision

1. **Run…** sits beside **Copy command** on six rows: Park's Archives (`externalize`) and runtimes (`runtime offload`),
   Run externally's DerivedData and Archives (`locations set-*`) and Runtime Library (`runtime export`), and the Delete
   view's runtime row (`runtime delete`). Simulator devices stay copy-only. Copy stays everywhere.
2. One sheet per operation: a review (Core's preflight or plan, its warnings, its blockers, which disable the confirm
   button), a confirm button whose title is the exact action, then a running state with a stage line, a progress bar and
   the live log, then the result. The layout follows the independent HIG review's §4
   (`.superpowers/sdd/hig/report.md`) except where it conflicts with the safety rules (below).
3. **Observation only, and no new parameter on any existing Core operation.** Core gains `StreamingCommandRunner` —
   configured exactly as `ProcessCommandRunner`, result built from the whole of each pipe, each line also handed to an
   observer — and `ObservingCommandRunner`, a decorator. They reach the operations the way every runner already does:
   as the `runner` the operation is constructed with. `MigrationEngine` takes no observer; the copy-to-verify stage is
   read from `ditto`'s exit line in the log (`OperationStage.after`), so no caller-supplied code runs inside a migration.
   Tests show a run through an observing runner journals and returns exactly what a plain run does.
4. **Rule 4 and 5 hold.** Run on Archives copies and verifies and keeps the source. Only after a verified copy does the
   sheet offer **Remove Original…**, a separate step behind the checkbox "I confirm deleting non-regenerable data
   (Archives)" and a confirmation; the checkbox's value is what `removeSource(confirmNonRegenerable:)` receives, and that
   function re-verifies first. There is no cancel during copy, verify or remove; export has none either this round.
5. One operation at a time (`AppModel.operationSheet`). Quitting while one runs asks first; closing the window does not
   interrupt it, because the model lives in the app delegate.
6. A migration the journal shows interrupted puts a banner on Park, Run externally and History with the exact recovery
   commands (`migration status`, then `resume` or `abort` as Core accepts at that phase). The app does not resume or
   abort this round.
7. Rule 10: every strategy keeps its label. The sheet shows the experimental badge in its title where the row is
   experimental; nothing here makes a strategy supported.

## Consequences

- The app can now change the user's machine through the same Core paths the CLI uses, so every such change is
  journaled the same way and shows in History.
- What the CLI decided from flags, the app decides from choices; those decisions are `AppModel` methods with tests over
  fakes (`R3RunInAppTests`). The live glue (`LiveOperations`) is thin, and its two non-Core decisions — the tests-risk
  checkbox and "export the installer first" — are tested functions.
- The live log is kept to 5,000 lines in memory; the whole log goes to a file in the temporary folder.
- Not done this round: restore from the vault, resume/abort in the GUI, cancelling an export, simulator devices.
- The migration-safety review is required before merge (the controller dispatches it).

## Evidence

- User decision: `.superpowers/sdd/r3/brief.md` (approved 2026-10-04).
- `Tests/XCodeVaultCoreTests/R3StreamingTests.swift` (the runners return and journal the same), `R3RunInAppTests.swift`.
