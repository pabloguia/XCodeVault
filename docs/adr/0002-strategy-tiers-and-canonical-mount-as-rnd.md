# ADR 0002: Ship supported mechanisms + disconnect safety first; canonical mount is R&D

- Status: proposed
- Date: 2026-09-05
- Related hypotheses: H1, H5, H6, H7

## Context

The original brief made "canonical APFS mount for CoreSimulator" the headline
capability. Research (`../research/FINDINGS-2026-09-05.md`) shows:

- The bytes are mostly **not** under the assumed path — they are in the cryptex bundle
  store and in `/System/Library/AssetsV2/...MobileAsset_iOSSimulatorRuntime` (F1).
- Runtimes are **sealed, hash-verified, mounted images** managed by `simdiskimaged`,
  with nested mounts inside the very directory we would mount over; Apple DTS says not
  to manage those mount points manually (F1).
- **Symlinking `~/Library/Developer/CoreSimulator` breaks the Simulator even on the
  same disk** (F3, H5) — so the "safe fallback" the prior art uses is not safe either.
- **Apple's own supported DerivedData relocation already breaks `xctest` on external
  volumes** (F4) — and whether that is device-based or path-based is unknown (H6).
- Every mature tool in this space deletes; none relocates. The gap is real, and the
  reason it exists is that the substrate is hostile (F9).
- Apple's supported surface is richer than the brief assumed: `-exportPath` +
  `-importPlatform` makes the external Runtime Library **officially supported**, and
  `-architectureVariant arm64` is free savings (F2, H4).

## Decision

Order the product by evidence, not by ambition:

- **Tier 1 (v1 headline, supported):** drive Apple's own mechanisms completely and well
  — DerivedData / Archives / Compilation Cache locations, `-exportPath` +
  `-importPlatform` external Runtime Library with `-architectureVariant arm64`,
  `simctl runtime delete`, `~/Library/Developer/Packages/`, and honest cleanup of
  regenerable data. Nobody packages this today.
- **Tier 1b (v1 differentiator):** own the **disconnected-drive problem** — mount-state
  verification, shadow-data detection, refusal to operate under ambiguity, verified
  restore. This is the entire missing half of the prior art and is what makes this a
  tool rather than a script.
- **Tier 2 (experimental, opt-in, gated on E1/E2/E4/E6):** canonical APFS mount. Ship
  only if the gating experiments pass, and label it experimental until the full
  Definition of Done is met.
- **Tier 3 (R&D track):** FSKit passthrough (macOS 26+) — first-party, kextless,
  SIP-compatible; the right long-term mechanism, blocked today on an approval-gated
  entitlement, manual user enablement, missing xattr support in the sample, and
  unmeasured performance (H7).
- **Excluded outright:** whole-tree symlinks, `mount_nullfs` (needs SIP off), macFUSE
  (needs a kext / Reduced Security), symlinking CoreSimulator (H5), APFS firmlinks (no
  API), hard links (can't cross volumes), Finder aliases (invisible to POSIX).

## Consequences

- v1 ships something honest and useful even if H1 is falsified — the project does not
  hinge on the riskiest hypothesis.
- We must be explicit in the UI that some categories are **delete-only** and some
  (sealed runtimes) are neither relocatable nor casually deletable. Honest scoping is a
  feature here, not an apology.
- The `canonicalMount` strategy in the storage catalog stays defined but unshipped
  until evidence exists.

## Evidence

`../research/FINDINGS-2026-09-05.md` F1–F5, F9; `../architecture/EXPERIMENTS.md`
E1, E2, E4, E6, E9.
