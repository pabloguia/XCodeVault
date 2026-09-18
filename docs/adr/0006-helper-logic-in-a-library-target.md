# ADR 0006: The privileged helper's logic lives in a library target so it can be tested

- Status: accepted (2026-09-17)
- Date: 2026-09-17, recorded 2026-09-18
- Amends: ADR-0003 (Layout)
- Related safety rules: 3 (allowlisted helper API), 10 (Definition of Done)

## Context

This ADR is written after the fact, and that is itself the finding. The change it records was made
on 2026-09-17; `CLAUDE.md` and `AGENTS.md` were updated for it, and ADR-0003 — the decision that
*owns* the target layout — was not. Two independent review passes found the divergence on
2026-09-18 from opposite directions, one reading `Package.swift` against the ADRs and one reading
the ADRs against the tree. `CLAUDE.md` requires "an ADR for every meaningful architectural choice or
reversal"; nothing mechanical enforces that, and this is what the gap produced.

The change itself was sound and was made for a good reason. The privileged helper originally had two
targets:

- `XCodeVaultHelperProtocol` — the XPC contract, linked by both sides.
- `XCodeVaultHelper` — an `executableTarget` containing the daemon bootstrap **and** all of its
  logic: the allowlisted verbs, the authorization gate, and the path guards.

A security reviewer found that the authorization gate had shipped with a defect in its
`getgrouplist` retry — the second call could never run, because the buffer-growth path was
unreachable as written. A three-line test would have caught it. **No test could reach it**, because
the code lived in an executable target that the test target cannot import. The defect was not
subtle; it was invisible, and it was invisible for a structural reason.

## Decision

Split the daemon's logic out of `main.swift` into a third target, `XCodeVaultHelperCore`, built as a
library so `@testable import` can reach it.

```
XCodeVaultHelperProtocol   the XPC contract; linked by client and daemon
XCodeVaultHelperCore       verbs, authorization gate, path guards — testable
XCodeVaultHelper           executableTarget; bootstrap only (requirement parsing, listener, exit 78)
```

**`XCodeVaultHelperCore` may be depended on by the helper executable and the test target, and by
nothing else** — not the app, not the CLI. Linking the daemon's privileged logic into an
unprivileged process would put its code in an address space the guard was never written for, and
would make the "only two dependents" reading of `Package.swift` false.

## Consequences

- The gate is now tested. `Tests/XCodeVaultCoreTests/HelperAuthorizationTests.swift` drives the
  buffer-growth path the original defect hid in, with the measured capacity table in the source.
- **The invariant is not machine-enforced, and this ADR is the only durable record of it.**
  `scripts/helper-invariants.sh` does not read `Package.swift` at all — it works over a hardcoded
  list of helper directories — so it cannot see the helper target gaining a dependency, and it
  cannot see a fourth target appearing in the closure. That gap is listed in
  `docs/process/KNOWN-ISSUES-AT-PUBLICATION.md`. Until it is closed, the property is held by review.
- Splitting for testability does not by itself deliver testability. The two verbs behind the gate
  — `doCreateVaultDirectory` and `doRemoveRegenerableSystemDirectoryContents` — are `private`, and
  `@testable import` reaches `internal`, not `private`. The refactor moved the code into a testable
  target and then sealed it. The helper-security review of 2026-09-18 confirmed that relaxing them
  to `internal` is safe — `XCodeVaultHelperCore` has exactly two dependents, `internal` is
  module-scoped, and it widens no XPC surface — but noted that `internal` alone is not enough: both
  bodies resolve real absolute system paths, so a test calling them on a developer machine would
  delete the real dyld cache. They need the injected-seam pattern `isAdministrator` already uses.
  Tracked in `KNOWN-ISSUES-AT-PUBLICATION.md`, not silently accepted.
- ADR-0003's Layout section is amended rather than rewritten, so the pre-split description and the
  reason it changed both stay readable.

## Alternatives considered

- **Leave the logic in the executable and test it through the XPC boundary.** Rejected: it requires
  a registered daemon and root, so it could never run in CI, which is exactly the property that let
  the original defect ship.
- **Move the logic into `XCodeVaultCore`.** Rejected: `XCodeVaultCore` is linked by the app and the
  CLI. The privileged verbs would then be compiled into two unprivileged processes, and the "single
  domain layer, no privileged calls" statement in ADR-0003 would stop being true.
