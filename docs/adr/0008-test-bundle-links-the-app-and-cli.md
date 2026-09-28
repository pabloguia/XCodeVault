# ADR 0008: The test bundle links the app and the CLI; the app reaches the outside world through one value

- Status: accepted (2026-09-28)
- Date: 2026-09-28
- Related: ADR-0003 (one domain layer; SwiftPM), ADR-0007 (permissions at need). Issue #30 (the helper has
  never run live). Operator decision 2026-09-28: raise the coverage of new code with tests, not by excluding
  the app from the measurement.

## Context

SonarQube Cloud grades each push on the coverage of the lines it changed (`scripts/sonar-verify.sh`, the
quality gate, threshold 80%). The pushes of deliverables 3 and 4 of the permissions plan failed it: 78.0% and
71.9%. Recomputing deliverable 4's figure line by line with `git blame` on the CI's own report showed where it
came from: of its new lines in files the report contains, 274 of 296 were covered (92.6%); the rest were in
`Sources/XCodeVault` and `Sources/xcodevaultctl`, which the report does not contain at all.

The test bundle linked only the library targets, so the two executables produced no coverage rows, and the
server counts a file absent from the report as uncovered — measured on 2026-09-20 and recorded in
`.github/workflows/sonar.yml`. The app's logic (`AppModel`: the scan, the permissions, the approval wait, the
root actions, the clean) was therefore untested by construction, and its approval-wait rules were held only
by tests that read the source as text.

SwiftPM lets a test target depend on an executable target and `@testable import` it (the executable's entry
point is renamed for the test build). A probe measured it on 2026-09-28: the bundle builds, and a SwiftUI
view's `body` runs inside an `NSHostingView` that has no window.

## Decision

- `XCodeVaultCoreTests` depends on `XCodeVault` and `xcodevaultctl`, so their code has coverage rows and can
  be tested in process.
- `AppModel` takes an `AppEnvironment`: the survey, the Full Disk Access probe, the helper, the approval flow,
  the action runner, the clean and the URL opener. The app uses `.live`. The tests this decision adds pass fakes:
  none scans this Mac or writes to its journal, launchd or System Settings. Two of them read live state on
  purpose: one runs the Full Disk Access probe against `.live`, and one runs `xcodevaultctl permissions`, which
  asks launchd for the helper's status. The real scan stays in `refresh()`, run when the environment has no
  survey.
- `HelperClient` reaches launchd through an internal `Daemon` value (status, register, unregister, open
  Settings). The public initialiser installs `.live`; only the internal one, used by tests, takes another.
  `LiveHelper` takes its client in an internal initialiser.
- The views that deliverables 3 and 4 added are rendered off screen in each state those deliverables added.

## Consequences

- The approval-wait rules are behaviour tests now; the source-text pins they replace are gone.
- Every file of the two executables now has coverage rows, including the older views and commands that no test
  reaches, so the project's overall coverage figure changes meaning: it now measures those files instead of
  having the server add them as uncovered.
- Code only the live app runs stays uncovered: the real scan in `refresh()`, the `.live` clean and URL-opener
  closures, the `.live` launchd registration closures (#30), and the contents of sheets and dialogs, which
  render only when presented in a window. Nothing is excluded from the measurement to hide them.
- The helper's own executable (`Sources/XCodeVaultHelper/main.swift`) is still not linked; its logic is in
  `XCodeVaultHelperCore` (ADR-0006).
- `scripts/helper-invariants.sh` names the lines on which `LiveHelper.swift` may name the client's type; the
  new initialiser is one of them.
- A test gives every runner it runs a temporary journal, and builds the live runner without running it: a run
  falls back to the real journal whenever the runner's first check regresses, which is what a mutant of that
  check does. The migration-safety review found two such runs, both in this change and both fixed before it
  landed. A static audit of every call in `Tests/` to the seven APIs whose journal defaults to the real one
  found no other direct call; it cannot see a call made through a closure or a wrapper, which is how it
  missed the one the review found in `AppModelTests`.

## Evidence

- Deliverable 4's Sonar run (e930f19): `new_coverage is 71.9, threshold LT 80`; the CI converter reported 45
  files, 5369/6144 lines covered.
- The blame-based recomputation and the probe are in STATUS.md, 2026-09-28, "Coverage of the app and the CLI".
