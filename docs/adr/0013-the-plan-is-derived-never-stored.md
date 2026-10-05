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
   and Archives locations, the runtimes the WHOLE journal shows parked (`ParkedRuntimes`: never History's windowed rows,
   an import cancels an offload, a runtime the scan shows installed again is not parked) and the doctor's findings. Nothing about the Plan is written to
   disk; a step is done because the state shows it done (a vault registered, Xcode's location on the vault, bytes on the
   vault and none left here, a completed runtime offload in the journal, a clean health read).
2. **The Plan runs nothing.** Every step or item has at most one `PlanAction`, and every case opens an existing sheet or
   screen: Drives, the preparation sheet, Use This Drive, the Run sheet for a plan row, a Save Space view, Health. Each
   keeps its own review and confirmation. No step starts the next one.
3. **The Plan never proposes an erase, and cannot be made to open one.** The prepare step offers only the drive's
   recommended option (an added APFS volume, which erases nothing). A drive whose options all erase data, or need the
   ownership setting, gets "choose in Drives" instead. The app opens a preparation from the Plan only when
   `drive.isRecommended(option)` holds (anything else falls back to Drives), and a preparation sheet opened from the Plan
   lists only options that erase nothing and refuses to switch to one (`nonErasingOnly`). Erasing is possible from the
   Drives screen only (R7-C fix round, safety F5 and F6).
4. **The numbers are honest about what each button does.** Each item is counted once (`SavingsCalculator.countedOnceBucket`),
   from the same scan as the Overview; Archives are never in the delete outcome (rule 5). Where one button does not free
   the bytes, the item is split: moving DerivedData's location sends new builds to the drive (0 GB), and the DerivedData
   already on this Mac is its own item, freed only by deleting it (safety F2, quality I1). Data the user made — simulator
   devices — is never "rebuilt on demand": it is its own outcome, tagged, and its bytes are not in the "up to" headline but
   on a line of their own, as on the Overview card (safety F1).
5. **An unusable vault says why** (safety F4): shadow data at its mount point (rule 6, with the size, pointing to Health),
   a different volume where it should be (pointing to Drives), or not connected.

## Consequences

- The Plan cannot be wrong about the past; it can only be as stale as the last refresh, and it refreshes with the
  scan, the drive list and the journal.
- A done step that the state cannot show — a move done by hand to a place the app does not recognize as the vault —
  appears as not done. That is the honest answer; the Plan does not trust a tick it did not see.
- There is no "skip this step" and no saved progress. If a user wants a different path, the other screens are unchanged.
- The step-to-sheet mapping is the whole of what the Plan can reach, so it is tested explicitly (`PlanBuilderTests`,
  and `AppModel.planTarget` / `performPlanAction` in `R7CAppTests`, including forged options and a vault that vanishes
  between the plan and the sheet).
- The Storage chart counts DerivedData under Run Externally (its primary bucket); the Plan shows the same bytes as
  "Deleted here, rebuilt on demand", because that is what frees them. The totals agree; the outcome differs on purpose.

## Evidence

- `Tests/XCodeVaultCoreTests/PlanBuilderTests.swift` — the states from fixtures (no drive, a case-sensitive drive like
  the user's, a plain drive, an erase-only drive, a good vault, everything done).
