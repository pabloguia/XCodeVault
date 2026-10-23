# OS-level relocation alternatives for simulator runtimes — a complete map (2026-10-22)

Follow-up to `RUNTIMES-IN-PLACE-ON-EXTERNAL-2026-10-22.md`. The question: have filesystem tricks
(symlinks and the like) been exhausted as a way to keep **installed** runtimes on the external drive?

**Answer: no — one branch was closed on evidence that was later retracted, and it is still open.**
Everything else is closed, and this pass adds a reason that closes most of it for good.

Method: the repo's own record (H1, H5, H9, H10, H12, H15, F1, F5, F16), read-only inspection of
the installed CoreSimulator (Xcode 26.5, macOS 26 / Darwin 25.6.0, Intel), and desk research. No
experiment was run; nothing needs `sudo` to reproduce what is below.

## 1. What decides it: `simdiskimaged`'s own sandbox and code

`simdiskimaged` (the root daemon that owns runtime images) embeds its sandbox profile. Read with
`strings` from `CoreSimulator.framework/Versions/A/Resources/bin/simdiskimaged`:

- `(deny default)`, then `file-mount` allowed **only** under
  `/Library/Developer/CoreSimulator/{Images,Volumes,Cryptex/Images,Cryptex/Volumes}/` (plus
  `/AppleInternal/…`).
- The fixed path list otherwise names `/Library/Developer/CoreSimulator/`, the four
  `/System/Library/AssetsV2/com_apple_MobileAsset_*SimulatorRuntime/` stores, `/private/tmp/`, and a
  handful of system paths — **not** `/Volumes`. It also accepts sandbox *extensions*
  (`extension-class "com.apple.app-sandbox.read"`), which is presumably how
  `simctl runtime add ~/Downloads/x.dmg` reads a file from anywhere: the client hands the daemon a
  per-request extension. An extension is not a standing grant, so it cannot back an image the
  daemon re-attaches on its own after a restart. **[INFERRED]**
- The profile carries `;; For resolving symlinks, realpath(3), and equivalents.`, and the code has
  `Cannot mount symlinks` and `Rejecting mount of symlink at '%{public}s' for security`.

Consequences, all **[OBSERVED-BINARY]** (read from the shipping binary; behaviour not exercised):

- **Any symlink is dead** — a symlinked `.dmg`, a symlinked `Images/`, a symlinked `Volumes/`. The
  daemon refuses symlinks by name, and the resolved target would sit outside its sandbox anyway.
- **Repointing `images.plist` at an external path is dead regardless of who can write the plist.**
  On its own profile the daemon cannot read a `/Volumes/...` image, and no client is present to
  hand it an extension when it re-attaches at boot or after a restart. This makes F16
  ("only simdiskimaged can write `images.plist`") moot for relocation — and F16 itself was measured
  on 2026-09-09 from a caller without Full Disk Access, two weeks before H15 showed every refusal in
  that hierarchy was TCC. F16 should be read as "unwritable without FDA", not "unwritable by root".
- **The only shape that survives** is a *real mount* whose mount point is inside one of those
  subpaths: the sandbox checks the path, and a volume mounted at `…/CoreSimulator/Images` has that
  path.

## 2. Why that route was closed, and why the reason no longer holds

H1 (canonical mount) was reframed as "low value" on 2026-09-06 because *every installed-runtime
byte lived in `/System/Library/AssetsV2/…`*, which no mount under `/Library/Developer` captures.
F1 was corrected on 2026-09-08: a runtime installed by **`xcodebuild -importPlatform`** — which is
exactly what XCodeVault's own Runtime Library import does — lives at
`/Library/Developer/CoreSimulator/Images/<UUID>.dmg`. H1's verdict was never revisited.

Measured today on this machine: **all 15.8 GB of installed runtimes are in
`/Library/Developer/CoreSimulator/Images/`** (iOS 26.5, 10.6 GB; watchOS 26.5, 5.2 GB); the three
AssetsV2 stores are 4 KB each.

And the other blocker H1 inherited — "mounting inside CoreSimulator is refused" — was retracted by
H15: with Full Disk Access, root `mkdir`, `rm` and `mount_apfs` all succeed in that hierarchy
(E6c runs 5–7).

So: **a dedicated APFS volume on the external disk, mounted at
`/Library/Developer/CoreSimulator/Images`, is inside the daemon's sandbox, needs no symlink, writes
no pointer, and would hold every runtime the Runtime Library installs.** It is recorded as H20.

Two properties make it more attractive than H1 ever looked:

- **Import becomes a clone, not a copy.** `simctl runtime add` stages through `Images/Inbox`, and
  the daemon logs `Because source is on the same volume as inbox and clones are supported will allow
  a lower free space limit`. With the Runtime Library's `.exportedBundle`s on the *same* APFS volume
  as the mounted `Images/`, import should cost ~0 bytes and ~0 seconds. **[INFERRED from strings]**
- **H6 may not bite.** E2/E14c found the external-device xctest restriction vanished inside a disk
  image even when the image *file* sat on the USB SSD. Runtimes are always attached disk images.
  **[ANALOGY — not measured for runtimes]**

## 3. What it would still have to survive

| Risk | Why it matters | How E20 measures it |
|---|---|---|
| **Disconnect (rule 6)** | the internal `Images/` stub reappears empty; simdiskimaged may write a fresh `images.plist` there — shadow data — and attached runtime volumes lose their backing file under booted simulators | unmount, then trigger a scan; hash/list the stub; never with a booted device first |
| **Mount ordering at boot** | if simdiskimaged scans before the mount, it sees an empty store (`ScheduleFullScanAndMountReprocessingOrphans` exists for orphans) | reboot arm, read `simctl runtime list` before and after the mount |
| **Ownership** | external APFS defaults to `noowners`; the store is `root:admin` with root-owned `images.plist` | needs `owners` — the helper already turns ownership on (H18) |
| **TCC posture of a launchd daemon** | H15 proved FDA'd *Terminal*; the helper's posture is unmeasured | first gate of E20 |
| **Whole-store granularity** | one mount moves *all* runtimes; you cannot keep the newest internal and the rest external with one APFS mount | accept it, or test a subdirectory mount + plist entry (F16 re-test with FDA) |
| **DiskArbitration quirk** | E6c: DA refuses a previously-mounted volume at a chosen mount point; `mount_apfs` does not | use `mount_apfs`, as E6c did |
| **Updates** | Xcode/macOS updates may migrate, relocate (`RelocateRuntimeImage` is a daemon op) or rescan | re-run after each update; experimental label until the DoD |

## 4. Everything else, closed

| Candidate | Verdict | Reason |
|---|---|---|
| Symlink a `.dmg`, `Images/`, `Volumes/` | ❌ | refused by simdiskimaged code + sandbox (§1) |
| Symlink `~/Library/Developer/CoreSimulator` | ❌ | CLAUDE.md rule 7; also H5 shadow-directory finding |
| `images.plist` → `/Volumes/…` | ❌ | `/Volumes` is outside the daemon's standing sandbox grants (§1) |
| `simctl runtime add` from the drive | ❌ copies | stages into the store (H10) — **unless** the store itself is on the drive (H20) |
| Hard links, `clonefile` | ❌ | cannot cross volumes; APFS has no directory hard links (F5) |
| Firmlinks, `/etc/synthetic.conf` | ❌ | no third-party API; synthetic.conf is root-level only (F5) |
| `mount_nullfs` | ❌ | not shipped: `/sbin` has no `mount_nullfs` on this machine (F5 said it needs SIP+AMFI off) |
| macFUSE + bindfs (kext) | ❌ | kext → Reduced Security on Apple silicon (F5) |
| macFUSE 5 FSKit backend + bindfs | ⚠️ R&D | kextless (`-obackend=fskit`), but third-party, new, and a root daemon must accept a FUSE mount under its store; strictly worse than mounting the APFS volume directly |
| FSKit passthrough (own module) | ⚠️ R&D | H7: entitlement + platform reliability |
| Loopback NFS (`nfsd` + `mount_nfs` at `Images/`) | ⚠️ inferior | no kext, both binaries ship; but needs nfsd with FDA, NFSv3 drops xattrs, stale-handle hangs on disconnect — and buys only "bind a subfolder", which a dedicated APFS volume makes unnecessary |
| Fusion/CoreStorage across internal+external | ❌ | the whole system volume would depend on the drive |
| Legacy bundle runtimes via `Profiles/Runtimes` mount | ⚠️ tiny | simdiskimaged scans legacy bundles there; covers iOS 15 under Xcode 26 only |
| Device data on the drive | ❌ | H12 falsified (device creation refused on the external volume) |

## 5. Recommendation

**Update 2026-10-23: E20 ran and passed** — runtimes were served from the external volume mounted at
`Images` and a simulator booted from them (H20 probable, one machine). The open arms below still gate any product use.


Run **E20** before anything else touches this question. It is the only open route, it is cheap to
kill, and its first gates need no product code. If it passes, it is still a canonical mount: per
ADR-0002/0004 and rule 10 it ships, if ever, as **experimental**, behind the helper's allowlist,
with disconnect safety as a precondition — not as a default.

## Sources

- `simdiskimaged` and `CoreSimulator.framework` strings, Xcode 26.5 (17F42), read 2026-10-22
- [macFUSE 5.2.0 release notes](https://newreleases.io/project/github/macfuse/macfuse/release/macfuse-5.2.0), [macFUSE 5.5.0](https://newreleases.io/project/github/macfuse/macfuse/release/macfuse-5.5.0), [rclone forum: macFUSE FSKit backend](https://forum.rclone.org/t/macfuse-fskit-backend/53037)
- [FreeBSD mount_nullfs(8)](https://man.freebsd.org/mount_nullfs/8); rclone `nfsmount` (localhost NFS as a FUSE-less mount on macOS)
- [Gist: sparse bundles mounted over CoreSimulator `Images`/`Volumes`](https://gist.github.com/niteshpurohit/8453bade166b8a83470ae516c3673a77) — the only public attempt at this shape; unverified, community
- This repo: H1, H5, H6, H7, H9, H10, H12, H15, H17, H18; F1 (corrected), F5, F16; E2, E6c, E14c
