# ADR 0019: Installed simulator runtimes served from the drive (H20) — what, if anything, the product does with E20

- Status: **proposed** (2026-10-26) — the decision is the operator's (STATUS "Next three actions", item 1). Written so
  it can be accepted as one of the options below, not to pre-empt that choice.
- Date: 2026-10-26
- Related: H20 and E20 (`docs/architecture/HYPOTHESES.md`, every "E20 …" entry of `COMPATIBILITY_MATRIX.md`),
  `docs/research/RUNTIMES-IN-PLACE-ON-EXTERNAL-2026-10-22.md`, `docs/research/OS-LEVEL-RELOCATION-ALTERNATIVES-2026-10-22.md`,
  ADR-0002 (tier order), ADR-0004 (canonical mount demoted to R&D), ADR-0014/0016 (the helper), rules 6 and 9.

## Context

E20 measured, on one machine (Intel, macOS 26.7.1, Xcode 26.5, USB), what happens when a dedicated APFS volume on the
external drive is mounted at `/Library/Developer/CoreSimulator/Images`, the store `simdiskimaged` serves
`-importPlatform`-installed runtimes from. Every arm ran; the results that bear on a product:

| What | Result | Consequence |
|---|---|---|
| Stage and exercise (arms 1–2) | PASS: runtimes `Ready` + `Verified` from the drive, a device boots, restore is byte-exact | the mechanism works |
| Install / import while mounted (arm 3) | works only with a DiskArbitration mount; a full copy through the internal `Cryptex/Images/Inbox`, not a clone (falsified for this layout, this machine) | no speed win; each install needs one image's worth of free internal space |
| Boot with the drive (arm 5) | PASS with a standing `/etc/fstab` entry | — |
| Boot without the drive (arm 5) | ABSENT and safe | — |
| Hot-plug with the standing `fstab` mount | **SHADOW** | rule 6: an automatic mount is ruled out |
| Pull the drive, idle and with a booted device (arm 4b) | survivable, but CoreSimulator silently falls back to the internal copy | the internal copy must be kept, so no internal space is saved while it is |

H20 is **probable, experimental**: one machine, no Apple Silicon, no Xcode GUI, no long-running use.

The table's last row is the one that decides the value. The point of moving runtimes is internal space. While the
internal copy has to stay for a pulled drive to be survivable, the feature saves nothing; removing it makes a pulled drive
a failure in the middle of a test run, which the supported Runtime Library flow (export to the vault, import back on
demand; E8/E11) does not have.

## Options

**A. Not now.** Record E20 as a measured mechanism and stop. The Runtime Library stays the product's runtime story. A
second machine is not scheduled. Cost: nothing. Risk: none. Revisit if Apple changes `simdiskimaged`'s store handling or
an operator reports a workflow the Runtime Library cannot serve.

**B. An explicit, experimental "serve runtimes from this drive" mount.** Only on the user's request, never at boot or on
plug (the SHADOW result), through DiskArbitration (arm 3), only with every runtime detached first (no booted device, no
`simdiskimaged` image attached), with the internal store kept and verified byte-for-byte against the drive before and
after (arm 4b). New helper verb(s) under ADR-0014's rules and a helper-security review; labeled experimental everywhere
(rule 10). Value: possibly the speed of booting from a fast drive (unmeasured by E20), not space. Gate before any code: the same arms on Apple Silicon.

**C. B plus dropping the internal copy.** The only option that saves space. Contradicts arm 4b's finding and rule 6 as
measured: a pulled drive would leave CoreSimulator with nothing to fall back to. Not proposable on current evidence.

## Recommendation (for the operator's decision)

**A.** B costs a new privileged verb, a review cycle and a second machine to deliver something that saves no space,
which is the product's mission; C is unsafe on the evidence. A keeps E20's result on record (HYPOTHESES, the matrix,
this ADR) so the question is not re-opened from scratch.

## If accepted

- As A: change Status to `accepted (date)`; H20 stays **probable, experimental, not pursued**; STATUS's "Next three
  actions" drops item 1; ADR-0004's demotion of the canonical mount stands unchanged for this path too.
- As B: Status `accepted`, and the Apple Silicon run of E20 becomes the gating item; nothing is built before it passes.
