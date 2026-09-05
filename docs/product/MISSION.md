# Mission

## Problem

Xcode and Apple developer tooling consume tens to hundreds of GB of internal SSD
through Simulator runtimes, CoreSimulator data, DerivedData, indexes, build products,
Archives, device support/symbols, DeveloperDiskImage/CoreDevice data, SPM caches,
logs, previews, doc caches, downloadable platform components, and more.

## Goal

Transparently externalize every storage category that can be *safely* externalized;
use official Xcode/macOS configuration mechanisms first; provide managed cold storage
and cleanup where relocation isn't appropriate; clearly label Apple-managed or
non-relocatable data that must stay local. The user should be able to keep using
Xcode, Simulator, xcodebuild, simctl, devicectl, and third-party tools normally.

## Explicit non-goal

We do **not** assume every byte can or should move. A category with no verified-safe
strategy stays local and is reported honestly, not force-fit into a risky strategy to
maximize reclaimed space. See `NON_GOALS_AND_SAFETY.md`.

## Target users

Individual iOS/macOS developers and teams whose internal SSD is squeezed by Xcode,
including those running multiple Xcode versions side by side, working across
Intel/Apple Silicon, and/or supporting older Macs.

## Compatibility tiers

- **Legacy tier**: macOS ~10.13+ (subject to revision as research on old Xcode/macOS
  behavior progresses — record findings in `COMPATIBILITY_MATRIX.md`).
- **Modern tier**: current macOS/Xcode generations.

If one binary can't reasonably serve both, prefer a shared core with separate
legacy/modern build targets over compromising the modern architecture. Don't assume
SwiftUI-only; evaluate AppKit if it's what legacy support needs. Isolate
compatibility-sensitive code (e.g. privileged-helper registration) behind protocols.

## Operational profiles (see UX_AND_CLI.md for detail)

- **Safe** — official configuration, supported cleanup, cold storage only.
- **Transparent** — adds validated filesystem relocation/mounting strategies.
- **Expert** — detailed CoreSimulator/CoreDevice/runtime diagnostics; still refuses
  unsafe protected-system modifications.

## Prior art

`Viniciuscarvalho/mac-ssd-rescue` is the closest prior art (rsync + symlink of
user-level `~/Library/Developer/...` directories). Study it, don't copy its
architecture wholesale — see `docs/process/PRIOR_ART.md` for what to reuse vs. rethink.
