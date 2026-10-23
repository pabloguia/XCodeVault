# Can a simulator runtime run *in place* from an external drive? (2026-10-22)

Desk research plus a read-only look at this machine. No experiment was run; nothing here
changes a hypothesis status. Confidence tags follow FINDINGS-2026-09-05.

## The question

A claim found in the wild: "the runtime of the OS that is current for the installed Xcode
(e.g. iOS 27 for Xcode 27) has to live on the internal disk, but older runtimes can run from an
external drive." If true, users could keep older runtimes on the vault and use them without the
export → offload → import round trip the Runtime Library does today.

## Answer

**For every runtime Xcode 26/27 supports in the disk-image format, no — and the version (new or
old) is not what decides it. The packaging format is.** The claim is a conflation of two true
statements:

1. **Old runtimes used a different format.** Up to iOS 15 / tvOS 15 / watchOS 8, a runtime was a
   plain directory bundle (`iOS 15.x.simruntime`) installed by a `.pkg` into
   `…/CoreSimulator/Profiles/Runtimes`. From iOS 16 (Xcode 14) runtimes are signed disk images
   that `simdiskimaged` owns, stages into an internal store and mounts under
   `/Library/Developer/CoreSimulator/Volumes` ([macops](https://macops.ca/xcode-14-new-platforms-packaging-format/));
   `simctl runtime add` only accepts 2022-and-later platforms. **[COMMUNITY, consistent]**
   Only the bundle format is even a candidate for "use it from wherever it sits" — `simctl help
   create` still documents a path form (`"/Volumes/path/to/Runtimes/watchOS 3.2.simruntime"`,
   F19), and that example is from the bundle era.
2. **The newest platform is mandatory, the older ones are optional.** Xcode requires the platform
   matching its SDK to be installed to build for that platform; older runtimes are extras. So
   "the latest must be local" is true, but "the others may be external" only means "the others
   may be *removed*" — which is what the Runtime Library already does. **[INFERRED]**

## Why disk-image runtimes cannot be used in place (what this repo already measured)

| Route | Result | Where |
|---|---|---|
| Copy the image to the vault, keep it valid | seal survives byte-identical relocation; attaches `sealed` from USB | H9 / E4a ✅ |
| Point CoreSimulator at that copy (`images.plist`) | unwritable even for root; only `simdiskimaged` writes it | H9 / E4b / F16 ❌ |
| `simctl runtime add <image on vault>` | stages (copies) into the internal store by design | H10 ❌ |
| Mount the vault over `…/CoreSimulator/Images` or `/Volumes` (the sparse-bundle gist) | canonical mount; demoted to R&D; refusals there are TCC | H1 / ADR-0004 / H15 |
| FSKit passthrough | mechanism documented, delivery broken + entitlement | H7 |
| Keep devices external instead | device creation refused on the external volume | H12 falsified |

On this machine (2026-10-22, Xcode 26.5, Intel): both installed runtimes are `kind: Disk Image`,
`signatureState: Verified`, path `/Library/Developer/CoreSimulator/Images/<UUID>.dmg`, and there is
no `Profiles/Runtimes` directory at all. There is nothing in the bundle format to keep external.

## Where the window is, and how small it is

Apple's support table ([Xcode SDKs and system requirements](https://developer.apple.com/support/xcode/)):

| Xcode | Simulators supported |
|---|---|
| 26 – 26.5 | iOS 15 or later, tvOS 15+, watchOS 8+ |
| 27 – 27.2 | **iOS 17 or later**, tvOS 17+, watchOS 10+ |

So the bundle format — the only one with a plausible in-place story — covers **iOS 15 / tvOS 15 /
watchOS 8 under Xcode 26.x and nothing at all under Xcode 27.** iOS 15 and watchOS 8 simulators are
also listed as unsupported on macOS 14. Even inside that window, two independent barriers remain
unmeasured: whether `simctl create … <path>.simruntime` accepts an unregistered external bundle
(H13 / E16), and whether a simulator can execute from a removable volume at all (H6 — the same
removability gate that blocks xctest bundles on the vault).

## Recommendation

- **Do not build a feature on "run older runtimes from the drive".** For Xcode 27 it addresses no
  runtime; for Xcode 26 it addresses one legacy version per platform, behind two open barriers.
- **The supported path is the Runtime Library and making it cheap**: keep the `.exportedBundle`s on
  the vault, keep installed only what the current work needs, and make import fast and
  automatic (devices come back from `Unavailable` by themselves — F13). Measured cost: import
  peaks at ~0.9× the image size internally and is a copy, not a re-download (E8/E11).
- **E16 stays worth running once, but scoped to its real target**: a legacy iOS 15 bundle on the
  vault, unregistered, used via `simctl --set <scratch> create … <path>`, with internal free space
  as the discriminator (H13). A disk-image runtime is not a valid E16 subject: its identifier is
  already registered, so a path would just resolve to the internal copy.

## Sources

- Apple, [SDKs and system requirements](https://developer.apple.com/support/xcode/) (fetched 2026-10-22)
- [Xcode 14's new simulator platforms packaging format](https://macops.ca/xcode-14-new-platforms-packaging-format/)
- [actions/runner-images#8402](https://github.com/actions/runner-images/issues/8402) — `xcodes runtimes`, legacy vs. image runtimes on CI
- [Gist: mount sparse bundles over CoreSimulator Images/Volumes](https://gist.github.com/niteshpurohit/8453bade166b8a83470ae516c3673a77) — the H1 approach, community
- [Apple forums 739175: how `simctl runtime add` works](https://developer.apple.com/forums/thread/739175)
- This repo: HYPOTHESES H1, H6, H7, H9, H10, H12, H13, H15; FINDINGS F13, F16, F19
