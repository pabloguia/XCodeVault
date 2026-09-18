# ADR 0001: Minimum supported macOS is 14.0 (Sonoma), not 10.13

- Status: accepted (2026-09-17)
- The original status read "proposed (accept after the team confirms no Ventura/Monterey user
  need)". There is no team, so that condition could never be met, while the floor shipped,
  `Package.swift` declares `.macOS(.v14)`, CI runs macos-15 and macos-26, and safety rule 8 of
  `CLAUDE.md` calls it non-negotiable. A decision the code has implemented is not proposed.
- Date: 2026-09-05
- Related hypothesis: none — this is a platform decision, evidence in
  `../research/FINDINGS-2026-09-05.md` §F8

## Context

The original brief targeted a "legacy compatibility tier: approximately macOS 10.13+"
alongside a modern tier. Desk research says that is not defensible:

- **App Store Connect has required builds made with Xcode 26 since 2026-04-28, and
  Xcode 26 requires macOS 15.6.** Any developer still shipping is already on 15.6+.
- macOS 13 is the API floor where the whole modern security stack arrives at once:
  `SMAppService.daemon` (SMJobBless is deprecated as of 13),
  `NSXPCConnection.setCodeSigningRequirement`, and a SwiftUI that can carry a real Mac
  settings/table UI.
- Below 13 we would ship a **second product**: a parallel SMJobBless implementation
  with its own installer/updater/uninstaller plus hand-rolled audit-token validation —
  in the exact component where a bug is a local root escalation (cf. CVE-2025-65842).
- **We could not test it.** GitHub-hosted `macos-13` runners are gone (fully
  unsupported 2025-12-04) and `macos-14` goes fully unsupported 2026-11-02. Only
  `macos-15` and `macos-26` remain. Shipping untested privileged filesystem code that
  moves users' data is the worst available trade.
- macOS 10.13 predates APFS volume groups and firmlinks entirely; the mount semantics
  this project depends on differ meaningfully across those generations.

## Decision

Minimum deployment target **macOS 14.0**. Primary development and CI targets:
**macOS 15 and macOS 26**. macOS 13.0 was recorded here as an acceptable fallback floor if user
research later showed a meaningful Ventura population, on the grounds that it would cost "no
additional API work, only testing". **That is no longer true, and the sentence is kept rather than
deleted so the correction is visible.** The GUI now depends on three macOS 14.0-only APIs —
`@Observable` and `@Bindable` (Observation) and `ContentUnavailableView` — each load-bearing in
`Sources/XCodeVault/XCodeVaultApp.swift`. A 13.0 floor today costs migrating `AppModel` back to
`ObservableObject`/`@Published`, replacing `@Bindable`, and hand-rolling three empty-state views.
Safety rule 8 is the stricter statement and governs: 14.0 is the floor, and this ADR does not
authorise going below it.

## Consequences

- Excludes Macs that topped out at Monterey and developers deliberately staying on old
  Xcode. That cohort is real and is arguably among the most disk-constrained. We are
  choosing not to serve them with the privileged product.
- Mitigation: offer that cohort a **read-only diagnostic mode** (or a documented shell
  script) that reports reclaimable space without privileged relocation. Zero helper
  code, zero root risk, and it keeps "I'm on Monterey and out of disk" out of the
  issue tracker as a support burden.
- One helper implementation, one installer, one XPC validation path, all CI-testable.

## Evidence

`../research/FINDINGS-2026-09-05.md` §F7, §F8 — Apple release notes and upcoming
requirements; `actions/runner-images` deprecation issues #13046 and #13518; Apple DTS
threads 725811 and 773573.
