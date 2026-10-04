# ADR 0013: The guided Plan is derived, never stored (R7-C)

- Status: accepted (the steps that prepare a drive or run a command keep their **experimental** labels, CLAUDE.md rule 10)
- Date: 2026-10-04
- Related hypothesis: none (the Plan adds no storage technique; it orders the existing ones)
- Brief: `.superpowers/sdd/r7/brief-c.md`

## Context

On 2026-10-04 the user asked for a step-by-step to the best solution: prepare the drive, create the specific volume,
move what can be moved, with a forecast of the space recovered, and clear about what is a temporary copy and what runs
from the device. Every one of those actions already existed (R3 Run sheets, R6 drive preparation and Use This Drive,
R7-A's new-volume flow), each with its own review and confirmation. What was missing was the order, and one place that
says what is left.

A plan could be stored — a checklist the user ticks, or a wizard that remembers its position — or derived each time
from what the app already reads. A stored plan drifts: a drive is unplugged, a folder is moved by hand, an operation is
run from the CLI, and the checklist still says what it said. A wizard that runs its steps in sequence would also chain
destructive operations, which ADR-0012 and rule 6 forbid (a drive can disappear between two steps).

## Decision

1. **The Plan is a pure function** in Core: `PlanBuilder.plan(report:drives:vaults:locations:history:findings:)`. Its
   inputs are the scan, the drives as `DriveEvaluation` assessed them, the vault registry's checks, Xcode's DerivedData
   and Archives locations, the journal's History rows and the doctor's findings. Nothing about the Plan is written to
   disk; a step is done because the state shows it done (a vault registered, Xcode's location on the vault, bytes on the
   vault and none left here, a completed runtime offload in the journal, a clean health read).
2. **The Plan runs nothing.** Every step or item has at most one `PlanAction`, and every case opens an existing sheet or
   screen: Drives, the preparation sheet, Use This Drive, the Run sheet for a plan row, a Save Space view, Health. Each
   keeps its own review and confirmation. No step starts the next one.
3. **The Plan never proposes an erase.** The prepare step offers only the drive's recommended option (an added APFS
   volume, which erases nothing). A drive whose options all erase data, or need the ownership setting, gets "choose in
   Drives" instead.
4. **The numbers are the Overview's numbers.** Each item is counted once, in its primary bucket
   (`SavingsCalculator.countedOnceBucket`), from the same scan; Archives are never in the delete outcome (rule 5).

## Consequences

- The Plan cannot be wrong about the past; it can only be as stale as the last refresh, and it refreshes with the
  scan, the drive list and the journal.
- A done step that the state cannot show — a move done by hand to a place the app does not recognize as the vault —
  appears as not done. That is the honest answer; the Plan does not trust a tick it did not see.
- There is no "skip this step" and no saved progress. If a user wants a different path, the other screens are unchanged.
- The step-to-sheet mapping is the whole of what the Plan can reach, so it is tested explicitly (`PlanBuilderTests`,
  and `AppModel.performPlanAction` in the app tests).

## Evidence

- `Tests/XCodeVaultCoreTests/PlanBuilderTests.swift` — the states from fixtures (no drive, a case-sensitive drive like
  the user's, a plain drive, an erase-only drive, a good vault, everything done).
