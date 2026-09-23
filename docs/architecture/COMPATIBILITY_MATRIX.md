# Compatibility Matrix

Evidence ledger, not a table of boolean claims. One entry per (macOS version/build,
Xcode version/build, architecture, storage-category strategy) combination actually
tested. Do not list untested combinations as if they were verified — omit them, or
list as "pending."

Scope is bounded by ADR-0001 (minimum macOS 14). Do not spend testing capacity below
that floor, and do not invent impossible OS/Xcode pairs.

Combinations to prioritize:

| Priority | macOS | Xcode | Arch | Why |
|---|---|---|---|---|
| P0 | 26 (current) | 26.x | Apple Silicon | Where nearly all active developers are; CI runner `macos-26` exists |
| P0 | 15.6+ | 26.x | Apple Silicon | Minimum combination that can still ship to the App Store; CI runner `macos-15` exists |
| P1 | 15.6+ | 26.x | Intel | Last Intel-capable generation; different APFS/mount behavior is plausible |
| P1 | 14.5+ | 16.x | Apple Silicon | The declared floor — must be exercised at least manually; no CI runner after 2026-11-02 |
| P2 | 27 (when released) | 27.x betas | Apple Silicon | Forward-looking regression watch |

Anything below macOS 14 is **out of scope** — pre-14 users get, at most, the read-only
diagnostic mode (ADR-0001), which needs no matrix entry beyond "reports only, changes
nothing."

Because `macos-13` runners are gone and `macos-14` goes fully unsupported 2026-11-02,
the macOS 14 row is **manual-only** from November 2026. Mark those entries
"pending — manual" until someone runs them on real hardware and records the output.

## Entry template

```
### <category/strategy> — macOS <version/build> · Xcode <version/build> · <arch>

- Date tested:
- Hypothesis reference: H#
- Test performed: (scan / relocate / mount / functional probe / crash-inject / ...)
- Result: pass / fail / partial
- Evidence: (log excerpt, command output, or link to test artifact in repo)
- Functional checks: simulator boot / xcodebuild / physical device (mark N/A if not applicable)
- Verdict: verified / probable / falsified / experimental
- Notes:
```

## CI vs. manual

For combinations that cannot run in CI (old macOS/Xcode, physical hardware),
maintain an explicit manual test protocol document alongside this matrix and mark
those entries "pending — manual" until someone actually runs and records the result.


---

## Entries

### E1 mountability / SIP status — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-06
- Hypothesis reference: H1, H8
- Test performed: read-only discovery (`scripts/experiments/e1-mountability.sh`)
- Result: **pass** — path not SIP-protected (no restricted flag, no rootless xattr,
  `rootless.conf` covers only `/System/Developer`); two nested runtime mounts already present
  under `Volumes/`; `Cryptex/Images/bundle` empty; all runtime bytes in
  `/System/Library/AssetsV2`. **Mount half (run by the user with sudo, 2026-09-07 00:30 UTC):**
  `diskutil mount -mountPoint /Library/Developer/xcv-probe /dev/disk9s1` succeeded on a scratch
  APFS image; write worked; unmount left an empty local directory; `rmdir` clean. The mount came
  up `noowners` (files shown as `_unknown:_unknown`) — the F5 ownership hazard is real and any
  future mount must use `owners`/`diskutil enableOwnership`.
- Evidence: `../research/evidence/e1-macos26.6.2-25G83-xcode26.5-x86_64.txt` (read-only half),
  `../research/evidence/e1b-mount-macos26.6.2-25G83-xcode26.5-x86_64.txt` (mount half)
- Functional checks: N/A
- Verdict: **H8 verified** on this combination; H1 stays demoted (ADR-0004) because nothing
  worth mounting lives under the path on Xcode 26.
- Notes: manual completion procedure: `hdiutil create -size 2g -fs APFS -type SPARSE /tmp/xcv.sparseimage`,
  `hdiutil attach -nomount /tmp/xcv.sparseimage`, `sudo mkdir /Library/Developer/xcv-probe`,
  `sudo diskutil mount -mountPoint /Library/Developer/xcv-probe <diskNsM>`, verify with
  `mount | grep xcv-probe`, then `sudo diskutil unmount /Library/Developer/xcv-probe` and
  `sudo rmdir /Library/Developer/xcv-probe`. Never mount over the real `CoreSimulator` path.

### E2 external-volume xctest restriction — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-06
- Hypothesis reference: H6 (and H1's DerivedData argument)
- Test performed: `scripts/experiments/e2-external-xctest.sh` with `fixtures/E2Fixture`
  (dynamic library + XCTest bundle), `xcodebuild test -destination platform=macOS
  -derivedDataPath …` and `swift test --scratch-path …` on eight locations.
- Result: **fail on the physical USB APFS SSD** (under `/Volumes` and via an internal symlink):
  `xctest … Failed to create a bundle instance representing '…/E2LibTests.xctest'`;
  **pass** on the internal disk and on every APFS disk image (case-insensitive and
  case-sensitive, at `/Volumes` and at `$HOME/...`, hidden `.TemporaryItems/…` path, attached
  with `-owners on`, and with the image file itself stored on the USB SSD). `swift test`
  passed everywhere, including on the USB SSD. Nine cases total, two runs.
- Evidence: `../research/evidence/e2-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Functional checks: xcodebuild ✓ (the probe itself); simulator N/A; physical device N/A
- Verdict: H6 **probable, device-based**. DerivedData-on-external is `nativeConfiguration`
  with a mandatory pre-action warning; canonical mount gains no advantage for this category.
- Notes: only one physical device tested (USB, Case-sensitive APFS, owners enabled,
  DiskArbitration External/Fixed). Unified-log queries (TCC subsystem, sandboxd, kernel deny,
  xctest process) during the failing run returned nothing — mechanism unnamed. Pending:
  Thunderbolt NVMe, Apple Silicon, the Xcode IDE runner, a second physical device.

### E8 official mechanisms feature detection — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-06
- Hypothesis reference: H4
- Test performed: `scripts/experiments/e8-feature-detect.sh` (help-text parsing, `-showComponent`,
  `defaults read` of the Locations keys). Also exercised by `xcodevaultctl xcode list`.
- Result: pass — all documented flags present (`-downloadPlatform/-downloadAllPlatforms` with
  `-exportPath -buildVersion -architectureVariant`, `-importPlatform`, `-downloadComponent/
  -importComponent -importPath/-deleteComponent/-showComponent`, `-checkForNewerComponents`,
  `-prepareDeviceSupport`); `simctl runtime add/delete/unmount/verify/match`.
  `-showComponent metalToolchain -json` → `status: uninstalled`.
- Evidence: `../research/evidence/e8-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Functional checks: N/A (no download performed — 3.7 GB free on the test Mac)
- Verdict: H4 probable (flag surface verified; export/import round trip pending)
- Notes: `IDECustomDerivedDataLocation` unset on this machine → write-test pending — manual.

### E8b IDECustomDerivedDataLocation honoured by xcodebuild — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-06
- Hypothesis reference: H4
- Test performed: `scripts/experiments/e8b-derived-data-key.sh` — reversible write-test: set the
  key to a scratch directory, `xcodebuild build` the E2 fixture, inspect, delete the key.
- Result: **pass.** With the key unset the build lands in `~/Library/Developer/Xcode/DerivedData/E2Fixture-<hash>`;
  with the key set, xcodebuild creates `ModuleCache.noindex`, `CompilationCache.noindex`,
  `SDKStatCaches.noindex` and `E2Fixture-<hash>` under the custom path; an explicit
  `-derivedDataPath` still overrides it. Key restored to unset afterwards.
- Evidence: `../research/evidence/e8b-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Functional checks: xcodebuild ✓
- Verdict: `derivedData` / `nativeConfiguration` **probable** (mechanism verified; the
  Definition of Done still needs the E2 warning path, Xcode-IDE agreement after relaunch, and a
  second macOS/Xcode combination). Note: the Xcode 26 *compilation cache* lives inside
  DerivedData (`CompilationCache.noindex`) by default, so it moves with it.
- Notes: Archives key (`IDECustomDistributionArchivesLocation` or `IDEArchivePathOverride`)
  not yet write-tested — `xcodevaultctl locations` treats it as read-only until then.

### Xcode Locations keys (E8c) — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-06
- Hypothesis reference: H4
- Test performed: `strings` over IDEFoundation/IDEKit/DVTFoundation to enumerate real key
  names, then `xcodebuild -Key=value` probes on a throwaway package (no defaults written).
  Report: `../research/LOCATIONS-KEYS-2026-09-06.md`.
- Result: pass — `IDECustomDerivedDataLocation` (absolute = Custom; relative = "Relative to
  project", tilde expanded), `IDECustomDistributionArchivesLocation` (`xcodebuild archive`
  lands under `<root>/YYYY-MM-DD/`), `IDECustomCompilationCacheLocation` (Xcode 26;
  swiftc receives `-cas-path <root>/builtin`), `IDEBuildLocationStyle` ∈ Unique/Shared/Custom/
  DeterminedByTargets, `IDECustomBuildLocationType`, `IDECustomBuildProductsPath`,
  `IDECustomBuildIntermediatesPath`, `IDESharedBuildFolderName`. `IDEDerivedDataPathOverride` /
  `IDEArchivePathOverride` are per-invocation only. Xcode 26 also has
  `IDEDerivedDataDisappeared*` keys — it detects a vanished DerivedData folder itself.
- Evidence: `../research/LOCATIONS-KEYS-2026-09-06.md` (§2 raw strings, §3 probes)
- Functional checks: xcodebuild ✓ (build, archive, compilation cache)
- Verdict: `archives` / `nativeConfiguration` **probable**; compilation cache **experimental**
  (Xcode 26 only, size-key unit unknown). Xcode 16 agreement is inferred from unchanged key
  names — mark pending until a macOS 15 / Xcode 16 run records it (CI `macos-15` job can).
- Notes: XCodeVault writes absolute POSIX paths only, via `defaults`, with Xcode closed.

### E8 behavioural (export) + E11 staging — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-06
- Hypothesis reference: H4 (Runtime Library), E11 (staging space)
- Test performed: `scripts/experiments/e11-staging-monitor.sh tvOS <USB dir>` — real
  `xcodebuild -downloadPlatform tvOS -exportPath` through `xcodevaultctl runtime export`, with
  internal free space sampled every 5 s; then `xcodevaultctl runtime delete` of the result.
- Result: **pass with a behavioural surprise** — the export downloads (5.03 GB), **installs the
  runtime internally** (tvOS 26.5 Ready, 4.9 GB in `…AssetsV2/com_apple_MobileAsset_appleTVOSSimulatorRuntime`),
  then writes `appletvsimulator_26.5_23L470.exportedBundle/Restore/AppleTVOSSimulatorRuntime_Cryptex.dmg`
  to the external directory. Peak internal consumption during the run: **6.96 GB** (≈1.4× the
  image); nothing user-visible in any Inbox. `runtime delete` freed the store; the auto-created
  tvOS devices became unavailable and were removed with `simctl delete unavailable` (doctor flagged them).
- Evidence: `../research/evidence/e11-tvOS-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Functional checks: xcodebuild ✓ (export), simctl ✓ (registry showed the runtime Ready), boot N/A
- Verdict: Runtime Library **probable** with corrected semantics: export = install + copy out;
  offload (delete after export) is mandatory to reclaim internal space. Import half recorded
  separately below when run.
- Notes: single platform (tvOS, smallest); the "~40 GB" community figure was not reproduced for
  a 5 GB image. Re-run for iOS (10.6 GB) once ≥ 20 GB are free.

### E6 software variant — vault volume force-unmounted mid-migration — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-06 (four runs; run 4 is the clean pass)
- Hypothesis reference: H3 (disconnect / shadow data), disconnect-safety Definition of Done items 2–4
- Test performed: `scripts/experiments/e6-software-unmount.sh /Volumes/<usb> 2500` — real USB APFS
  volume registered as a vault; `externalize --apply` of a 2.5 GB Archives fixture; `diskutil
  unmount force` after ~750 MB written; remount; abort; full externalize → remove source → restore
  round trip with a clean unmount in between.
- Result: **pass** — failure is clean and journaled, source never touched, no shadow directory
  left at `/Volumes/<name>` (macOS removes the mount point on force unmount), volume returns at
  the same path, vault identity re-verified by UUID + sentinel, leftover partial copy detected and
  removable, restore refused while absent and verified after remount (quarantine xattr + symlink
  preserved).
- Evidence: `../research/evidence/e6-software-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Functional checks: N/A (data-only category)
- Verdict: Archives cold storage **probable**; disconnect handling **probable**. Physical yank,
  reboot mid-migration and a second macOS/Xcode combination still needed for the DoD.
- Notes: found and fixed the "failed op leaves an unremovable partial copy" gap during the run.

### E8 import half — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-07 (retry after the 2026-09-06 environmental fail below)
- Hypothesis reference: H4, E11
- Test performed: `scripts/experiments/e8c-import-roundtrip.sh` — `xcodevaultctl runtime import`
  invokes `xcodebuild -importPlatform <dmg>` with the direct path to
  `Restore/AppleTVOSSimulatorRuntime_Cryptex.dmg` (`RuntimeOperations.importRuntime`); this is
  the only argument form tried and it worked first time, so the bundle-directory and `simctl
  runtime add` fallbacks were not needed. Re-exported the tvOS installer to the USB volume,
  offloaded it, then imported; 26.5 GB free internally (well above the preflight requirement).
- Result: **pass.** Peak internal staging consumption: 4.807 GB for a 4.906 GB image (≈0.98×,
  vs. 5.8 GB/≈1.18× observed on 2026-09-06). `simctl runtime list -j` showed `signatureState:
  Verified`, `state: Ready`; `simctl runtime verify` reported "Signature verified, signature is
  valid." (exit 0).
- Functional checks (all exit 0): create `Apple TV` device → `boot` → `bootstatus -b` reached
  terminal `Booted` state → `shutdown` → `delete` device → `runtime delete` → `simctl delete
  unavailable`. Machine returned to only iOS 26.5 + watchOS 26.5, 0 unavailable devices, no
  runtime/device `doctor` findings. This run left **no stranded file** in
  `Cryptex/Images/Inbox` (unlike the 2026-09-06 export below), so no reboot was needed.
- Evidence: `../research/evidence/e8c-import-macos26.6.2-25G83-xcode26.5-x86_64.txt`,
  `../research/evidence/e11-tvOS-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Verdict: import mechanism **verified** end-to-end (import + functional boot probe) on this
  machine. The `runtime import` preflight's old 2×+3GB rule was materially too conservative
  (≈12.8 GB required for a peak that was actually ≈4.8–5.8 GB); tightened to 1.5×+2GB
  required / 2×+2GB warn (`RuntimeOperations.preflightImport`,
  `M2Tests.testImportPreflightEnforcesStagingSpace`).

#### 2026-09-06 attempt (environmental fail, superseded by the pass above)

- Test performed: same script, 10.3 GB free internally.
- Result: **fail (environmental, informative)** — 5.8 GB consumed internally in 20 s, then
  `SimDiskImageError 14 "Cannot copy the image because the disk is almost full"`; space released.
  A 5.02 GB stranded download left in `Cryptex/Images/Inbox` by the earlier export (flagged by
  `doctor`, root needed to remove) had eaten the headroom.
- Evidence: `../research/evidence/e8c-import-*.txt`, `../research/evidence/e11-import-*.txt`
  (superseded — filenames were later overwritten by the 2026-09-07 run's evidence of the same name).
- Functional checks: not reached.

### E8 import — larger image (iOS, real in-use devices) — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-08
- Hypothesis reference: H4, E11
- Test performed: same export → offload → import → functional-probe pattern as the tvOS E8c
  run, but against the machine's real, already-installed iOS 26.5 runtime (10.35 GB) — the
  runtime the user's own MySmokeiOS project actively uses — run manually (not via
  `e8c-import-roundtrip.sh`, which is tvOS-hardcoded and unconditionally deletes the runtime +
  runs `simctl delete unavailable` at the end; both are wrong for a runtime that must stay
  installed). Two real devices were present and in use: `iPhone 17 Pro Max` (booted, gracefully
  shut down first) and `iPhone SE (3rd generation)` (shutdown). A throwaway `xcv-probe-ios`
  device (distinct name, not touching the real ones) was used for the boot probe; no blanket
  `simctl delete unavailable` was ever run.
- Result: **pass.**
  - Export: peak internal consumption **1 MB** — since iOS 26.5 was already installed,
    `-downloadPlatform iOS -exportPath` just copied the sealed image out; no re-download,
    no install, no Inbox residue. This differs from the tvOS case (which needed a fresh
    download+install) and refines H4: export cost depends on whether the platform is already
    installed.
  - Offload: freed the runtime (`Total Disk Images: 1`); both real devices moved to
    `Unavailable: com.apple.CoreSimulator.SimRuntime.iOS-26-5` — listed, not deleted, UDIDs
    unchanged.
  - Import: peak **10.110 GB for a 10.35 GB image (≈1.0×)** — consistent with the tvOS
    ≈0.98–1.18× range, confirming the tightened preflight formula
    (`RuntimeOperations.preflightImport`, 1.5×+2GB) holds for a much larger image too; no code
    change needed. `simctl runtime verify`: "Signature verified, signature is valid."
  - **Both real devices returned to normal `Shutdown` state automatically** once the
    same-version runtime was reimported — no manual recreation, no data loss, despite the
    runtime getting a new internal identifier (`90F2566D…` → `34AF883C…`). CoreSimulator
    rebinds existing devices by OS version, not by the ephemeral runtime UUID.
  - Functional probe: throwaway device created, booted (`simctl list devices` confirmed
    `Booted`), shut down, deleted — all exit 0. **Gotcha:** `simctl bootstatus -b` itself hung
    reporting a non-terminal `Data Migration` status for several minutes after the device had
    actually finished booting; worked around by polling `simctl list devices` state directly
    instead of trusting `bootstatus`'s own termination. Not a runtime/import defect — `simctl
    bootstatus` is not used anywhere in product code (`Sources/`), only in the experiment
    scripts, so this doesn't affect `xcodevaultctl` itself.
- Evidence: `../research/evidence/e11-iOS-macos26.6.2-25G83-xcode26.5-x86_64.txt`,
  `../research/evidence/e11-import-iOSSimulatorRuntime_Cryptex-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Verdict: import mechanism **verified safe against a large, real, in-use runtime, on this
  machine** — the offload→import round trip did not lose devices or data even when the runtime
  being cycled is the one actively backing the user's own development devices.
  <!-- Rescoped under issue #20. This read "verified safe against a large, real, in-use runtime"
       unqualified, and closed with "Confirms the preflight formula generalizes beyond the single
       tvOS data point". Two data points on one machine is not generalization, and the adjacent
       entry at the 2026-09-06 import above scopes the same class of claim to "on this machine".
       The formula being right twice here is what the evidence carries; whether it holds elsewhere
       is what a second machine would answer. -->
  The preflight formula held for a second runtime family (iOS as well as tvOS) on this machine.
  Whether it generalizes to other hardware is **not** established by n=2 on one host; see
  `CONTRIBUTING.md` for what a second machine would settle.

### E7 shadow-data defense — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-07
- Hypothesis reference: H3
- Test performed: user set up `/Library/Developer/xcv-probe` as `root:wheel`, mode `0500`,
  `chflags uchg` (per `../process/MANUAL_TEST_PROTOCOL.md` E7, manual sudo steps — not run by
  the agent). Agent then: (1) ran `xcodevaultctl scan`/`doctor` to see whether the `fts`-based
  disk-usage walker chokes on a permission-denied subdirectory of `/Library/Developer`; (2)
  scaffolded a disposable macOS tool project (xcodegen) outside the repo and ran
  `xcodebuild build -derivedDataPath /Library/Developer/xcv-probe/dd` (an unwritable path)
  under a live `log stream` capture, isolated from the global `IDECustomDerivedDataLocation`
  default since a real build (another project) was running concurrently.
- Result: **pass — the defense does not crash Xcode.**
  - `scan`/`doctor`: exit 0, no crash, no hang; neither mentions `xcv-probe` — the `fts` walker
    silently skips permission-denied subdirectories (a visibility gap: this defense wouldn't be
    self-reporting via `doctor`, but it also doesn't break the tool).
  - `xcodebuild build`: failed cleanly — `Couldn't create workspace arena folder
    '/Library/Developer/xcv-probe/dd': You don't have permission to save the file "dd" in the
    folder "xcv-probe".`, `** BUILD FAILED **`, exit 65. `log stream` captured only
    `IDELogStore`-level permission errors (log level "critical", not a crash) leading up to the
    failure; no SIGSEGV/SIGABRT/fatal-error lines, no lingering/zombie processes, `xcv-probe`
    itself unchanged (`root:wheel`, `0500`, `uchg`) after the attempt.
- Evidence: **a session transcript, not an evidence file.** No `.txt` was written and no script
  exists for E7; the observation was recorded here and in `HYPOTHESES.md` H3 directly, on the
  grounds that the experiment was "informative, low-priority".
  <!-- Named plainly under issue #20. This document's own header calls it an evidence ledger, and
       a row whose evidence is a transcript that no longer exists in reviewable form is a row that
       cannot be checked by anyone but the person who ran it. Left in place rather than deleted —
       evidence is append-only here — but the verdict below is scoped to match what a transcript
       can support. Writing `scripts/experiments/e7-shadow-data-defense.sh` and re-running it is
       what would upgrade this row; see CONTRIBUTING.md. -->
- Verdict: **unreproducible as recorded.** For this failure shape (a build tool asked to create a
  derived-data directory under a locked path), the shadow-data defense was *observed* to fail
  loudly without crashing or corrupting state — but with no script and no evidence file, this row
  rests on one person's transcript and cannot be re-run. Treat it as a note, not as a verified
  compatibility claim, and do not cite it as evidence that a change is safe.
  Not tested: the Xcode.app GUI (only the `xcodebuild` CLI was exercised, deliberately, to avoid
  touching the concurrently-running build's global Locations default), and the
  `VaultVerifier` sentinel-file check (no vault was pointed at the probe path). Still low
  priority — only relevant if a canonical-mount strategy is revived per ADR-0004.

### E9 CoreSimulator symlink — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-08
- Hypothesis reference: H5 (and, opportunistically, the FB12363725 half of H2)
- Test performed: per `../process/RUNBOOK-E9-symlink-coresimulator.md`, run on the user's own
  account with explicit authorization (no scratch account, no `sudo` — none was needed).
  `~/Library/Developer/CoreSimulator` (9.1 GB) was renamed to `~/CoreSimulator-real` and
  replaced by a symlink to it on the same internal volume — a rename, never a copy or a delete.
  Then: device registry check before and after a forced `CoreSimulatorService` restart; a
  throwaway `xcv-e9-probe` (`iPhone 17 Pro`, iOS 26.5) created and booted; the three Files-app
  operations from the report driven through the real Simulator GUI; a disposable xcodegen iOS
  app built, installed, launched and made to write into its container; a read-only `devicectl`
  check; then the mandatory restore.
- Result: **the reported failure did not reproduce.** All three Files-app operations succeeded,
  each confirmed on disk through the symlink — `File Provider Storage/untitled folder`,
  `IMG_0002.JPG` (2,567,402 bytes, via Share > Save to Files), and
  `Downloads/e9-safari-download.zip` (Safari download). The share sheet opened normally.
  `xcodebuild build` → `simctl install` → `launch` all exit 0 (`** BUILD SUCCEEDED **`), and the
  app wrote `e9-write-test.txt` (11 bytes) into its own container without crashing. The device
  registry listed all devices correctly both before and after killing `CoreSimulatorService`.
  A debug guest `log stream` (845,711 lines) showed subsystems resolving through the symlink and
  succeeding; no sandbox denials, no FileProvider errors — the only `Operation not permitted`
  lines were ordinary `runningboardd`/`memorystatus_control` Simulator noise.
- Restore: mandatory step ran and passed. `~/Library/Developer/CoreSimulator` is a real
  directory again (9.1 GB, original mtime), `~/CoreSimulator-real` is gone, and the three real
  devices returned with their original UUIDs — `iPhone 17 Pro Max`, `iPhone SE (3rd generation)`,
  `Apple Watch Ultra 3 (49mm)` — with runtimes unchanged and 0 unavailable devices. `doctor`
  reported only the two pre-existing findings (low internal free space; `mac-ssd-rescue` data on
  `/Volumes/<vault>`), neither caused by this run.
- Evidence: `../research/evidence/e9-symlink-coresimulator-macos26.6.2-25G83-xcode26.5-x86_64.txt`
  (scripted steps plus a manually written section for the GUI pass).
- Verdict: H5 **not reproduced here** — but deliberately *not* promoted to "symlink is safe".
  See `HYPOTHESES.md` H5 for why one passing configuration is not a safety proof, and note that
  `CLAUDE.md` rule 7 and ADR-0004 are unchanged: the product still ships no symlink strategy for
  CoreSimulator. Not tested: the `~/Library/Developer`-wide symlink that FB12363725 actually
  requires (forbidden by rule 7), the Xcode.app GUI, Apple Silicon, and iCloud-Drive-signed-in
  configurations. Useful negative evidence for the narrow case: both paired physical devices
  stayed `available (paired)` in `devicectl` with only `CoreSimulator` symlinked.
- Method caveat worth carrying forward: the first synthetic tap on each new Simulator UI state is
  consumed as a window-focus click. The first "New Folder" tap produced nothing and looked like a
  reproduction of the bug; repeating the identical tap created the folder. A less careful run
  would have recorded a false positive for H5.
- **Secondary finding (product-relevant): the symlink leaves a shadow directory behind.** After a
  restore that verified clean, `~/CoreSimulator-real` was found recreated minutes later with an
  empty `Devices/` — CoreSimulator had cached the *resolved* target path (visible earlier in the
  run, where `simctl get_app_container` returned a `~/CoreSimulator-real/...` path) and its
  restarted service recreated the skeleton there. Empty and harmless here, and removed with
  `rmdir` after confirming the real directory still held all three device UUIDs. It is a concrete
  instance of the rule-6 shadow/duplicate failure mode with no external volume involved. The
  `doctor` rule it suggested is now implemented as `shadow-coresimulator`
  (`Doctor.checkShadowCoreSimulatorRoots`): `.error` when the shadow set holds devices or a
  `device_set.plist`, `.warning` for an empty skeleton, detection only. Running it against this
  machine also surfaced a pre-existing case the mac-ssd-rescue rule only saw the parent of:
  `/Volumes/<vault>/mac-ssd-rescue/CoreSimulator/Devices` holds duplicates of all three real
  device UUIDs plus a `device_set.plist`.

### E12 case-sensitive APFS — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-08
- Gates: the `VolumeQualification` case-sensitivity warning (not a hypothesis — this was an
  untested assumption in shipped code)
- Test performed: `scripts/experiments/e12-case-sensitivity.sh` on a disposable `hdiutil`
  case-sensitive APFS sparse image (no sudo; the user's drive untouched). Control first — wrote
  `probe.txt` and `PROBE.txt` to both volumes to prove they differ. Then (A) a full `swift build`
  of this repo with `--scratch-path` on the case-sensitive volume, which also clones dependency
  source into `checkouts/`; (B) an `xcodebuild -derivedDataPath` iOS build with source left on the
  internal case-insensitive volume.
- Result: **both pass.** Control confirmed the difference — the two names coexist on the
  case-sensitive volume and collapse to one file (content `upper`, the second write) on the
  internal one. (A) `Build complete!`, `swift-argument-parser` source cloned onto the volume, and
  the produced `xcodevaultctl` binary runs (`0.1.0-dev`). (B) `** BUILD SUCCEEDED **`, `.app`
  produced on the volume. 203 MB + 139 MB written.
- Incidental: the sparse image mounts `noowners`, and `xcodevaultctl volumes` correctly reports it
  `unsuitable` with the ownership blocker — a free end-to-end check of the F5 qualification logic.
- Evidence: `../research/evidence/e12-case-sensitivity-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Verdict: the warning was over-broad and is now narrowed to what was measured. Build output and
  SwiftPM checkouts work; the residual risk is source that refers to a file by the wrong case,
  which is invisible on the internal volume and a build error on a case-sensitive one. **Not
  tested:** CocoaPods, Carthage, projects with Objective-C bridging headers, frameworks that ship
  case-colliding filenames, and CoreSimulator device data (which has no relocation strategy at all
  under rule 7, so it is moot).

### Pending — manual (procedures in `../process/MANUAL_TEST_PROTOCOL.md`)

| Experiment | Gates | Status |
|---|---|---|
| E6 surprise removal | H3, disconnect safety DoD | software variant done (see entry above); physical yank pending — manual |
| E6b mount stub at a cache path | H14, issue #24's premise | **pending — manual**, needs `sudo` and a yankable drive. Runbook: `docs/process/RUNBOOK-E6b-disconnect.md`; script: `scripts/experiments/e6b-mount-stub-reappearance.sh`. Distinct from E6 above: that measures a vault volume under `/Volumes`, this measures a mount at `/Library/Developer/CoreSimulator/Caches/dyld` |
| E7 shadow-data defense | H3 | **done (2026-09-07)** — see entry below; does not crash Xcode; low priority after ADR-0004 |
| E8 export/import round trip | H4 | **done** — export (2026-09-06) + import with functional boot probe (2026-09-07) both pass; see entries above |
| Stranded Inbox cleanup | F1 | `sudo rm` refused (policy); **a reboot reaps it** (verified 2026-09-07, +5 GB). Doctor's remediation is "restart the Mac". Helper verb for this is pointless — remove it. |
| E9 CoreSimulator symlink | H5 | **done (2026-09-08)** — see entry above; the reported Files-app failure did **not** reproduce. Rule 7 / ADR-0004 unchanged. Still pending: the `~/Library/Developer`-wide symlink of FB12363725 (forbidden by rule 7), Xcode.app GUI, Apple Silicon, iCloud-signed-in |
| E11 staging space | Runtime Library UX | pending — manual |

### F10 orphaned dyld caches + F11 export cost — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-08 / 09
- Gates: H11 (are regenerable system caches reclaimed by the system?), and the cost model the
  `runtime export` preflight presents to the user
- **F11 — export of an already-installed runtime: VERIFIED for the no-`-buildVersion` case,
  near-zero internal cost.** Both runs used `runtime export iOS --to …` with no `-buildVersion`, so
  what is verified is "the latest available build is the installed one → copy-out". Exporting a
  *pinned* build that is installed is inferred from this, not measured. Exported the
  installed iOS 26.5 image (10.6 GB) to an external APFS volume with `-downloadPlatform iOS
  -exportPath`. Internal free was 14 GiB before, during and after; 4.4 GB had landed at the
  destination within the first 20 s, so this is a copy-out of the sealed image, not a re-download.
  Second independent measurement of the same behaviour (E11 saw a 1 MB peak). The preflight now
  branches on whether the platform is installed instead of always quoting E11's ~7 GB download peak.
- **Blocker found and fixed while doing it:** Xcode names the exported file after the SDK
  (`iphonesimulator_26.5_23F77.dmg`), which `RuntimeInstaller.parse` did not recognise — only the
  display form `iOS 26.5 Simulator Runtime.dmg`. `installer(for:in:)` therefore matched nothing and
  `runtime offload` refused every offload with "NO installer in library" while the installer was in
  the library. Not caught by fixtures, which used hand-written display names.
- **F10 — orphaned cache: the restart probe has run, and it SURVIVED (E13, 2026-09-16).** 2.3 GiB
  under `Caches/dyld/25G83/inc/com.apple.CoreSimulator.SimRuntime.tvOS-26-5.23L470` for a runtime
  absent from `simctl runtime list`, `Profiles/Runtimes` and `Images`. Captured before a reboot and
  again 5h46m after: the cache tree is **byte-identical**, down to the newest write inside the
  orphan. It has in fact outlived two restarts — it was born Sep 7 and the machine had already
  booted Sep 15 before the bracketed pair. Status: **durable on this machine**, and the startup
  reaper that collects the stranded Inbox does **not** cover this path.
  - Evidence: `evidence/e13-dyld-reboot-20260916T100005.txt` (before),
    `evidence/e13-dyld-reboot-20260916T155821.txt` (after).
  - Scope: one machine, one host build (25G83), one orphan. Not a claim about other builds.
  - `doctor` no longer recommends a restart for this finding — it was measured to do nothing.
  - **Superseded the same day by a macOS update.** 26.6.2 (25G83) to 26.7 (25G229): the entire
    previous host-build tree was gone, 9.4 GB, orphan included. These caches are keyed by host build.
    Durable across restarts, not across an OS update. Which process removes it — installer or
    CoreSimulatorService — is not established.
  - **But only the orphan's share is durable free space.** Eight minutes later the installed
    runtimes had rebuilt on the new build at the same sizes (iOS 4.4G, watchOS 2.7G); `inc/` stayed
    at 0B. Net: ~2.3 GB, internal free 16 GiB to 19 GiB. The 29 GiB visible mid-rebuild was a
    transient and must not be quoted as a reclaim.
- Root-deletability: **unknown, and not inferable.** No BSD flags anywhere on the ancestor chain and
  `/Library/Developer/CoreSimulator` is absent from `rootless.conf` — but the Inbox file had both
  properties and root was still refused. **E13 did not touch this** — it settled the restart
  question, not the root one. `doctor` no longer recommends a restart (measured useless here) and now
  presents root deletion as the open probe E13b, labelled unverified, with the Inbox refusal cited in
  the same breath.
- Evidence: `docs/research/FINDINGS-2026-09-05.md` §F10, §F11

### E14a alternate device set — read-only reconnaissance — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-09
- Gates: H12 (is the device set a relocation target?), and the F1/F2 judgement that `simctl --set`
  is "not a viable foundation for transparent relocation"
- Procedure: `scripts/experiments/e14a-device-set-static.sh`. Read-only throughout — `simctl help`,
  `defaults read`, `du -shx`, `strings`, `otool`, `nm`, `file`, `log`-free. No mutation, no sudo.
  The static half resolves `__objc_selrefs` and `__cfstring` against the shipped x86_64 `__text` of
  `IDEiOSSupportCore` and prints the annotated instruction window, so the claim can be re-derived
  rather than taken on trust.
- **Result 1 — the inherited claim is partly falsified.** Xcode 26.5 has a custom-device-set code
  path: `-[DVTiPhoneSimulatorLocator startLocating]` reads
  `[[NSUserDefaults standardUserDefaults] dvt_filePathForKey:@"DVTSimulatorSetLocation"]` and
  branches to `deviceSetWithPath:error:` when it is set, `defaultDeviceSetWithError:` when it is
  not, then `_startLocatingDevicesInDeviceSet:`. One binary in all of `Xcode.app` mentions the key.
  F2's "no evidence the IDE run-destination picker honours it" no longer stands as written.
- **Result 2 — but nothing here shows the picker repopulating**, and the IDE does *not* pass the
  path to Simulator.app, which reads its own `DeviceSetPath`. Silent split brain is the expected
  failure and is a rule 6 hazard.
- **Result 3 — the prize is 2.6 GB, not 9.1 GB.** ~6.5 GB of the device set is
  `containermanagerd/Dead` + simulated `MobileAsset` + the unified-log store, against ~0.5 GB of app
  containers (F18).
- **Result 4** — `simctl help create` documents a `/Volumes/...` `.simruntime` path as a runtime
  specifier (F19 → H13); `IDECustomDistributionArchivesLocation` and
  `IDECustomCompilationCacheLocation` exist in Xcode 26.5's `IDEFoundation` (F21).
- Evidence: `../research/evidence/e14a-device-set-static-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Verdict: **H12 promoted from "dismissed on hearsay" to "unverified, two gates".** Status stays
  *unverified* — no behaviour was observed. Next: E14b phases 0–3 (kill gate), then E15.

### E14b attempt 1 — aborted on a harness defect, no verdict — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date: 2026-09-15. Hypothesis: H12 (kill gate), H6.
- Test: `scripts/experiments/e14b-device-set-external.sh /Volumes/<vault>/XCodeVault/E14bSet
  --i-understand`, run by the user on the connected vault (Case-sensitive APFS, owners on,
  349 GiB free). Three default-set devices `Shutdown`, no `xcodebuild` running, before and after.
- **Result — no verdict on H12. The run is invalid and its printed conclusion is wrong.** The
  script aborted at phase 1 because `device_set.plist` was absent after
  `simctl --set <external> list devices`, and printed "H12 falsified at the cheapest gate".
  `device_set.plist` is materialised by the first `create`, not by a `list`.
- **Control that establishes this:** the identical command against an empty set on the *internal*
  disk produced an equally empty directory, exit 0, identical output. The gate discriminates
  empty-vs-non-empty set, not external-vs-internal, and would have "falsified" H12 on the
  internal disk. Gate corrected to test the list's exit status; the invalid evidence file is kept
  with an appended correction.
- **What phase 1 can support: nothing about this volume.** Measured after the run,
  `simctl --set <path> list devices` exits 1 only when the path does not exist and 0 for any
  existing directory (`/tmp` included); the script creates the directory immediately before
  asking, so exit 0 asserts that `mkdir` worked. It is a `stat()`, not a verdict from
  CoreSimulatorService, and output invariant to the path is output that never consulted it. An
  earlier draft of this entry read the exit 0 as the service accepting external storage — that
  was the same error one level up and is corrected here.
- **Phases 2 and 3 never executed.** The H6 boot gate that decides H12 remains unrun.
- Accounting checked after the run: probe set removed by the marker-guarded cleanup, no `XCV-E14b`
  in the default set, default set still 10G, all three user devices still `Shutdown`. No shadow
  data, no leak into the default set (rule 6 clean).
- Evidence: `../research/evidence/e14b-device-set-external-attempt1-void-macos26.6.2-25G83-xcode26.5-x86_64.txt`
  (invalid run + appended correction; do not cite its verdict line),
  `../research/evidence/e14b-control-internal-macos26.6.2-25G83-xcode26.5-x86_64.txt`.
- **Harness hardened after two safety reviews of the fix, before any re-run.** The reviews found
  four defects that predate this run and would have fired on it: `mkdir -p` adopted a
  pre-existing directory for cleanup's `rm -rf`; the path refusal was textual, so
  `/Volumes/<vault>/../../Users/<user>/Library/Developer/CoreSimulator` was accepted and would
  have been deleted; `cleanup` gated `rm -rf` on a return code that is 0 when nothing was
  deleted; and there was no `trap`, so an interrupt during the ten-minute phase-3 poll left a
  booted device and the probe set behind. Now: canonicalised path plus a same-device check,
  `mkdir` without `-p`, a "this run created it" marker the trap requires, a device-count check
  instead of a return code before `rm -rf`, volume-UUID assertions between phases and inside the
  poll, line-buffered redaction so an interrupted run still has evidence, and a real exit status.
- **Test gap, stated rather than left implicit:** none of these guards are exercised by CI —
  `.github/workflows/ci.yml` runs `e1` and `e8` only, and nothing references `e14b`. They were
  fault-injected by hand on 2026-09-15 (five refusal paths, each verified to exit 2 before any
  mutation). A guard verified once by hand is not a regression test.
- Verdict: **H12 stays *unverified*.** Not promoted, not falsified. Next: re-run E14b to reach
  phases 2–3, which are the phases that can say anything.

### E14b attempt 2 — phase 2 fails on the vault: CoreSimulatorService cannot write the device's data — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date: 2026-09-15. Hypothesis: H12 (kill gate), and corroborating for H6.
- Test: same command as attempt 1, with the corrected harness. Vault connected and VERIFIED,
  three default-set devices `Shutdown`, no `xcodebuild` running, before and after.
- **Phase 1 passed as the smoke test it now is. Phase 2 failed, and this one is a real gate.**
  `simctl --set <vault> create XCV-E14b <iPhone SE 3rd gen> <iOS 26.5>` exited 22 (EINVAL):
  "Device was allocated but was stuck in creation state."
- **Mechanism — sourced OUT OF BAND, not by the run.** The run's own evidence records only
  `code=22`: `EXPERIMENTS.md` specified log capture on a phase 3/4 failure, and the phase-2 path
  went straight to cleanup, so the harness captured nothing. The mechanism below was read from
  `CoreSimulator.log` by hand afterwards and is recorded in its own file; the script has since
  been given a phase-2 capture so the next run sources itself. Cite the log file, not the run.
  `Error copying sample content to path …/E14bSet/<UDID>/data : NSCocoaErrorDomain 513 …
  NSUnderlyingError=NSPOSIXErrorDomain Code=1 "Operation not permitted"`, then "New device is
  stuck in creation state, deleting".
- **EPERM (1), not EACCES (13).** One alternative is excluded by the run's own evidence: the
  script — running as the invoking user, which is also who `CoreSimulatorService` runs as —
  created `.xcv-e14b` inside that same directory moments earlier, so the directory's mode bits
  are not what refused. That excludes the mode bits and nothing else. A sample-content copy also
  exercises xattrs, ACLs, BSD flags and ownership, none of which a zero-byte `creat()` touches.
- **The unified-log capture is NOT empty, and it names the mechanism.** An interactive
  `log show` minutes earlier returned nothing for the same window and the first draft of this
  entry recorded "TCC capture empty" on that basis; the harness-style capture contradicts it, and
  the ad-hoc grep was simply the worse instrument. Within 80 ms, in causal order: three `tccd`
  `AUTHREQ_CTX` queries for `service=kTCCServiceSystemPolicyRemovableVolumes` attributed to
  `com.apple.CoreSimulator.CoreSimulatorService` (pid 9381) at the request of `sandboxd`; then
  `kernel [com.apple.sandbox.reporting:violation] System Policy:
  com.apple.CoreSimulator.CoreSimu(9381) deny(1) file-write-create
  /Volumes/<vault>/XCodeVault/E14bSet/<UDID>`; then the `Code=1` failure copying sample content.
- **This is the first time this repo has named the mechanism.** E2's entry above says
  "mechanism unnamed" after querying the same subsystems and finding nothing. Here a
  removable-volumes TCC service is queried and a sandbox policy denies the write, on a code path
  with no `xctest` anywhere in it. **What that licenses for H6 is deliberately not decided in
  this entry** — it is one observation, on one volume, on one machine, with the internal control
  still unrun, and today has already cost two rounds to premature conclusions.
- **What this does NOT yet establish.** Two readings survive: (A) something about that volume is
  the problem; (B) alternate device sets do not work this way at all, in which case the
  observation says nothing about external storage — and reading B cannot be separated from "the
  harness is wrong a third time" without the control. Note also what (A) would *not* buy: the
  control's set is internal, case-insensitive, on the boot volume with default mount options,
  while the vault is external, **Case-sensitive APFS**, `nodev,nosuid`, USB. A create that
  succeeds internally narrows the cause to volume class and no further — it does not isolate
  removability, and so does not by itself reproduce H6. E2 controlled case sensitivity for bundle
  loading; nothing has controlled it for device creation. `scripts/experiments/e14b-control-internal-create.sh`
  discriminates them: identical device type, runtime and commands, on an internal `mktemp` set.
  **Written, not yet run.**
- Accounting clean: cleanup counted zero remaining devices, removed the probe set, and both
  post-cleanup probes came back empty — no stray `device_set.plist` anywhere on the volume, no
  `XCV-E14b` in the default set, default set still 10G, all three user devices `Shutdown`.
- Evidence: `../research/evidence/e14b-device-set-external-attempt2-macos26.6.2-25G83-xcode26.5-x86_64.txt` (the run), `../research/evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt` (the mechanism,
  captured by hand after the fact — read its PROVENANCE header before citing it)
- Verdict: **H12 not yet falsified, but its first real gate failed.** Falsification waits on the
  internal control, because reading B would mean the observation is not about external storage.

### E14b control — `create` in an alternate set on the INTERNAL disk — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date: 2026-09-15. Hypothesis: H12 (decides it), H6 (corroborates).
- Test: `scripts/experiments/e14b-control-internal-create.sh --i-understand`. Identical device
  type and runtime to the E14b phase-2 failure, identical commands, on a `mktemp` set the script
  asserts is on the boot volume.
- **Result: CREATED, exit 0**, UDID recorded, and the `<UDID>/data` container — the "sample
  content" whose copy the vault refused — was written at **17 MB**.
- **Verdict on the pair: alternate device sets work as a mechanism; the volume is the variable.**
  Same commands, same runtime: fails externally, succeeds internally. **H12 is falsified for
  external storage**, and phase 3 is moot — a device that cannot be created cannot be booted.
  E15 (the transparency half) is moot with it for a v1 product.
- **What it does not isolate.** The control's set is internal, case-insensitive, on the boot
  volume with default mount options; the vault is external, Case-sensitive APFS, `nodev,nosuid`,
  USB. This narrows the cause to *volume class* by experiment. Removability is implicated by the
  log rather than by the design: `tccd` was queried three times for
  `kTCCServiceSystemPolicyRemovableVolumes` about CoreSimulatorService immediately before the
  kernel denied the write, and neither case sensitivity nor mount flags explain a
  removable-volumes policy being consulted. **Superseded:** E14c ran and did not isolate
  removability — see its entry below. It narrowed the discriminator, and left removability and
  bus confounded.
- Accounting: default set 10G before and after, all three user devices present and `Shutdown` in
  both captures, zero devices remaining in the control set, set removed. The `shutdown` step
  returned 149 — benign, the probe was created and never booted.
- Evidence: `../research/evidence/e14b-control-internal-create-macos26.6.2-25G83-xcode26.5-x86_64.txt`, with
  `../research/evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt` for the mechanism.

### E14c disk image vs the external volume — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date: 2026-09-15. Hypothesis: H6. **Run twice — 17 minutes apart, same machine, same volume,
  same script.** Identical property tables and verdicts (byte-identical from the phase-3 header
  through the verdict). These are repeats, not independent replications.
- **Neither E14c run re-measured the failing arm.** The contrast comes from E14b, roughly five
  hours earlier, across an unrelated set of mounts. There is no concurrent negative control.
- Test: `scripts/experiments/e14c-image-on-vault.sh /Volumes/<vault>/XCodeVault --i-understand`.
  Two arms: a case-sensitive APFS sparse image on the internal disk (arm B, the control for the
  control), then one whose image FILE is stored on the vault (arm A). Identical device type,
  runtime and commands to the E14b create that failed.
- **Arm B: CREATED.** Disk images host device sets, so arm A is interpretable. Without this the
  null reading of arm A would have had two explanations and no way to choose.
- **Arm A: CREATED**, while the identical create fails on the vault volume itself (E14b).
- **Property table, computed by the script from both volumes in each run:**

  | property | vault | image-on-vault | |
  |---|---|---|---|
  | File System Personality | Case-sensitive APFS | Case-sensitive APFS | held |
  | Device Location | External | External | held |
  | mount options | `nodev,nosuid,journaled` | `nodev,nosuid,journaled` | held, after normalizing¹ |
  | Removable Media | Fixed | Removable | varied |
  | Protocol | USB | Disk Image | varied |

  ¹ As measured the image also carries `nobrowse` and `mounted by <user>`. The script strips
  both before comparing. `-nobrowse` is a flag the script itself passed, so stripping it is fair;
  **`mounted by <user>` is not** — it is the difference between a user-initiated `hdiutil attach`
  and a system-mounted volume, which a policy could plausibly read. It is normalized away here
  and named rather than hidden.

  Held by construction rather than measurement: the bytes live on the vault's physical device,
  and the set path is under `/Volumes` (the two paths themselves differ).
- **`Removable Media` is not what TCC reads — and the evidence for that is E14b's log, not this
  experiment's direction argument.** `../research/evidence/e14b-attempt2-coresimulator-log-macos26.6.2-25G83-xcode26.5-x86_64.txt` shows `tccd` queried three
  times for `service=kTCCServiceSystemPolicyRemovableVolumes` about a volume `diskutil` labels
  `Removable Media: **Fixed**`. TCC's notion of "removable" is therefore already known not to be
  that field, with no inference required.
- **The direction argument is corroboration, not proof, and the first draft of this entry had it
  the other way round.** It observed that the volume labelled `Removable` works while the one
  labelled `Fixed` fails, and concluded a policy keyed on that field would have to be inverted.
  That only follows if the policy was *evaluated* for the image volume and allowed — and **E14c
  captured no TCC or sandbox logs in either run**; its only instruments were create-success and
  `diskutil`. A restriction that short-circuits on "this is a disk image" and never reaches any
  removability field explains the same data, and under it the image's label constrains nothing.
  So "Protocol is the discriminator" and "direction excludes Removable Media" cannot both carry
  weight; the first is the claim, the second is consistent with it.
- **What survives: `Protocol` — a real device versus a virtual one.** Matches E2, whose xctest
  failure also vanished inside images stored on this same SSD.
- **Still not varied, and still what H6 needs to finish: bus.** A Thunderbolt enclosure would
  separate "physically removable" from "USB". Nothing here has done that. Also untested:
  Apple Silicon, a second physical device.
- Accounting, **the deliberate run**: both probe sets reported 0 remaining devices, both images
  detached and removed, nothing left attached, no `XCV-E14c` in the default set, default set 10G
  before and after, and the user's three devices `Shutdown` in both the before and after captures
  (two snapshots, not continuous observation).
- The earlier run's own post-cleanup probe did **not** come back empty: it listed
  `xcv-e14c-vault-78980.sparseimage`, 0 bytes — the decoy file from the mis-written guard test
  that triggered that run, not an image the run created. It was removed by hand afterwards, which
  is why the later independent check found the vault clean.
- Evidence: `../research/evidence/e14c-image-on-vault-macos26.6.2-25G83-xcode26.5-x86_64.txt` (the deliberate run — cite this one),
  `../research/evidence/e14c-image-on-vault-run1-unannounced-macos26.6.2-25G83-xcode26.5-x86_64.txt` (an earlier run that fired
  unannounced through a mis-written test of the script's own guard; kept with a provenance note
  because its measurement agreed, not as a citable result).
- Verdict: **H6 stays *probable*, and is now much sharper.** Path-independence is established on
  this combination by E14c's two runs, and is consistent with E2 — which tested a different
  operation (xctest bundle loading, not device creation), so the two are corroborating rather
  than cumulative. The mechanism is narrowed from "volume
  class" to "a real removable device rather than the removable *classification*" — but
  removability and bus are still confounded, so *verified* is not earned.

### E18 `log erase` inside a device — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date: 2026-09-15. Category: `simulatorLogStore`, strategy `appleManaged` (report-only).
- Test: `scripts/experiments/e18-simctl-log-erase.sh --i-understand`. Throwaway device in a
  `mktemp` device set on the internal disk, booted, 120 s of logging, then the erase inside the
  device via `simctl spawn`. Three forms tried, taken from the verb's own usage text.
- **Result: refused, identically, in all three forms.** `log erase --all`, `log erase --ttl` and
  `log erase` with no argument each returned `Error from logd: Operation not permitted`, exit 1.
- **The control that makes it a refusal rather than a broken call:** `log stats` on the same device
  exited 0 and printed the archive summary. The binary spawns, runs, and reads the store; the
  daemon declines the erase.
- **No denial appeared in the last 30 lines of a host-side sandbox/logd query**, which is weaker
  than "the host log showed no denial" — the capture is `log show --last 3m … | tail -30` and those
  30 lines are dominated by unrelated `cache_delete` and `dasd` traffic, including the query
  observing itself. **The guest's own log was never examined**, and a denial issued by the simulated
  logd would land there rather than on the host. It resembles the silence E2 and E14b recorded; it
  is not established to be the same thing.
- One arm was void and is recorded as such: an earlier run passed `--ttl 1`, but `--ttl` takes no
  argument, so it exited 64 on usage and proved nothing about permission.
- Accounting, and it took a review and a re-run to become true: the block that compares the default
  device set to its baseline sat *after* the verdict's `exit 1`, so on the branch that is this
  experiment's actual outcome it never ran — while an earlier version of this bullet described the
  comparison as if it had. It now lives inside `cleanup()`, which runs on every exit path, and the
  cited run has both halves: default set 10G at baseline and 10G after, the user's three devices
  `Shutdown` in both captures, `XCV-E18` appearing only in the probe set's own `create` line and
  never in the default-set listing, probe set removed and confirmed gone.
- Evidence: `../research/evidence/e18-simctl-log-erase-macos26.6.2-25G83-xcode26.5-x86_64.txt` (two superseded
  runs from the same afternoon are kept alongside it by the harness's rotation).
- Verdict: **`simulatorLogStore` stays report-only, now because it was tried.** The category's
  `evidenceStatus` moves to *verified* — meaning it is established that no documented verb reclaims
  this storage on this combination, **not** that the bytes are reclaimable. Nothing in the product
  becomes offerable.
- Not established: whether a different runtime, a device booted for days, or root inside the device
  behaves differently. The refusal was identical across three forms on one runtime.

### Pending — added 2026-09-09

| Experiment | Gates | Status |
|---|---|---|
| E14b device set on an external volume | H12 (kill gate), H6 | **done 2026-09-15 — H12 falsified for external storage.** `create` cannot populate the device's data container on the vault; the internal control creates it fine. Phase 3 unreachable |
| E14b control — `create` in an internal alternate set | H12, H6 | **done 2026-09-15 — created, exit 0.** The mechanism works; the volume is the variable |
| E14c disk image vs the external volume | H6 | **done 2026-09-15, run twice.** Create works inside an image whose file is on the vault; fails on the vault volume itself. Narrows the discriminator to `Protocol` (real device vs virtual) |
| E14d `create` on a **non-USB external** volume (Thunderbolt/NVMe enclosure) | H6 (separates removability from bus) | **pending — no hardware.** The one confound E14c could not break: every external volume tested so far is USB. Until this runs, "removable" and "USB" are the same variable here. Needs an enclosure the project does not have |
| E15 does xcodebuild/Xcode honour `DVTSimulatorSetLocation` | H12 (transparency) | **moot for v1** — H12 is falsified for external storage, so the transparency question no longer gates a product decision. Keep the script for the R&D tier |
| E15 does xcodebuild/Xcode honour `DVTSimulatorSetLocation` | H12 (transparency) | pending — `scripts/experiments/e15-ide-honours-device-set.sh`, mutating (one user default), phase E is manual |
| E16 `simctl create` against an external `.simruntime` | H13 | pending — not yet written; fold into E14b's harness |
| E17 Archives on an external volume | H6 scope, F21 | pending — not yet written; no Archives exist on this machine to test with |

---

### Re-baseline: E1 + E8 + E14a re-run — macOS 26.7 (25G229) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-16
- Why: every other entry in this file is macOS **26.6.2 (25G83)**, and this machine moved to 26.7
  mid-session without anything noticing. A matrix whose entire purpose is "which combinations is this
  verified on" had one combination in it, and that combination had stopped being the one in use.
- Scope: the three experiments that are read-only and need neither root, nor the vault, nor a device.
  Nothing was created, deleted, booted or mounted; no `sudo`. The evidence filenames carry the
  environment slug, so the 25G83 captures sit untouched beside the new ones.

**Result: all three survive the OS bump. No finding in this file changes.**

| experiment | verdict on 26.7 | evidence |
|---|---|---|
| E1 mountability / SIP | **unchanged** — no BSD flags anywhere on the ancestor chain, `/Library/Developer/CoreSimulator` still absent from `rootless.conf`, no nested mount points, `AssetsV2` still on `/System/Volumes/Data` | `e1-macos26.7-25G229-xcode26.5-x86_64.txt` |
| E8 feature detection | **unchanged — zero substantive differences.** Every `xcodebuild`/`simctl` capability answer is byte-identical outside the header | `e8-macos26.7-25G229-xcode26.5-x86_64.txt` |
| E14a device-set recon | **unchanged** — 22 of 25 finding sections identical, including `simctl --set` docs, `DVTSimulatorSetLocation` in `IDEiOSSupportCore`, Simulator.app's own `DeviceSetPath`, FSKit availability, and the Locations default keys. The 3 that differ are `du`/`df` size sections | `e14a-device-set-static-macos26.7-25G229-xcode26.5-x86_64.txt` |

**Method note, because the first instrument was wrong.** A raw `diff` of the old and new captures
reported 64 differences for E1 and 39 for E14a, which reads like the findings moved. They had not:
the diffs were machine *inventory* — the two runtime `.dmg` files are now present under `Images/`
where they had been offloaded before, so `du` totals and the runtime UUID changed (`90F2566D…` →
`99ABCCEF…`, the churn F10's round-trip already recorded), and the device set shrank 9.1 GB → 8.2 GB.
Comparing whole files conflates "the machine changed" with "the experiment concluded differently".
The verdicts above come from comparing the finding-bearing sections with sizes and timestamps
normalised out.

**`doctor` on 26.7:** runs clean, 4 findings — low free space (22.25 GB), and the three per-device
report-only categories. The orphaned-dyld-cache rule correctly does **not** fire, because the orphan
no longer exists: the rule is not reporting a stale finding.

**What was NOT re-verified, and why.** Three of roughly twenty-one entries were re-run. The rest need
something this pass deliberately did not do:

- **E14b, E14c, E18, E9, E8c, E15** — all mutate devices or the device set, all gated behind
  `--i-understand`. Re-running them on 26.7 is legitimate but is a device-touching session of its own,
  and the user runs real test suites against the default set.
- **E2, E12** — need the vault and build a bundle onto it. Runnable (the vault is mounted and
  verified), heavier, and they mutate the vault. Best candidates if this goes further.
- **E13/E13b** — already 26.7-era by accident; the orphan they targeted was removed by this very
  update, which is recorded in the F10 entry above.
- **E4b, E6, E11, E1b** — need root, a forced unmount, or an install event.

So: **the read-only half of the matrix is re-verified on 26.7; the mutating half remains
26.6.2-only** and should be read as such until someone runs it. That is a narrower claim than "the
matrix is current", and it is the accurate one.

### E2 + E12 re-run on the vault — macOS 26.7 (25G229) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-16
- Extends the re-baseline above to the two experiments that need the external volume but no device
  and no root. `xcodebuild test -destination 'platform=macOS'` throughout — **no simulator is
  touched**. E2 writes only under `/Volumes/<vault>/.TemporaryItems/folders.<uid>/`, the per-user temp
  directory macOS guarantees is writable; the user's own folders on the vault are never opened.
  E12 does not touch the vault at all: it runs on a disposable sparse image under `/private/tmp`, and
  refuses any path outside `/private/tmp/xcv-e12*`.

**E2 — all nine cases reproduce exactly. 9/9 verdicts identical to 25G83.**

| case | DerivedData on | 26.6.2 | 26.7 |
|---|---|---|---|
| A | internal disk (control) | PASS | **PASS** |
| B | the vault, `/Volumes/<vault>` | FAIL (65) | **FAIL (65)** |
| E | internal path that is a *symlink* to the vault | FAIL (65) | **FAIL (65)** |
| C | APFS disk image at `/Volumes` | PASS | **PASS** |
| D | the same image at a `$HOME` path | PASS | **PASS** |
| D2 | the image, hidden `.TemporaryItems`-like path | PASS | **PASS** |
| C2 | **case-sensitive** APFS image at `/Volumes` | PASS | **PASS** |
| C3 | the image attached `-owners on` | PASS | **PASS** |
| F | image whose **backing file is on the external device** | PASS | **PASS** |

Two of these carry the argument:

- **E fails.** A symlink from an internal path to the vault fails exactly as the vault does, so the
  restriction follows the **device**, not the text of the path. Path rewriting cannot evade it.
- **F passes.** A disk image whose backing file sits on the USB SSD works: the bytes traverse the
  same physical device, through the same I/O path, and the test runs. That exonerates the hardware
  and the bus from being the cause, and leaves the volume's own DiskArbitration classification.

That is an independent corroboration of E14c, reached by a different mechanism (xctest bundle loading
rather than `simctl create`) and on a different OS build. H6 keeps its `probable` status — still one
machine, one physical device — but it now has two mechanisms agreeing across two macOS versions.

**E12 — case-sensitive APFS still fine. 19 of 20 sections identical.** Both surfaces pass on 26.7:
SwiftPM `--scratch-path` with dependency *source* on the case-sensitive volume (the riskier half),
and `xcodebuild -derivedDataPath` with source left internal — `** BUILD SUCCEEDED **`, and the
produced binary runs. The single differing section is the SwiftPM build's step count
(112/115 → 113/116), which moved because this repository gained a file, not because anything about
case sensitivity did.

- Evidence: `e2-macos26.7-25G229-xcode26.5-x86_64.txt`,
  `e12-case-sensitivity-macos26.7-25G229-xcode26.5-x86_64.txt`
- Cleanup verified after the run: no `XCVE2` image left attached, the vault scratch directory
  removed, the internal scratch and mount point removed, and the user's folders on the vault
  (`XCodeVault`, `backup-ios`, `parallels`) untouched.
- Harness note: `e2-external-xctest.sh` has **no `trap`**. It cleaned up correctly here, but a death
  mid-run would leave sparse images attached — not destructive, and not fixed in this pass because
  the script was being re-run as-is to re-verify a recorded result, and editing the instrument during
  a re-verification is how a comparison stops being one.
  - **Followed up 2026-09-17, and adding one would not have helped.** Measured: in this harness's
    `{ … } | xcv_redact | tee | grep` shape, a cleanup trap does not run on interruption at all —
    parent or body, and under `SIGTERM` to the parent, `SIGTERM` to the whole pipeline, or `SIGINT`
    to the process group. A parent trap does cover the normal exit path; a body trap covers nothing.
    The fix is structural: body as a function with a redirect instead of a pipeline, so the shell
    holding the trap is the one receiving signals. **Applied to this script and validated on
    2026-09-17** — the nine-case re-run gave 9/9 identical verdicts, and an interrupted run detached
    the image, removed both scratch directories and kept a partial transcript. Bench and table in
    `EXPERIMENTS.md` under "Harness"; nine other scripts still carry the old shape.

### Helper cleanup-verb path guard — ownership of the `/Library/Developer/CoreSimulator` chain — macOS 26.7 (25G229) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-18
- Hypothesis reference: none — this records an **environmental precondition** the privileged
  helper's cleanup verb now depends on, not a storage strategy.
- Test performed: `stat -f '%Lp %Su:%Sg %N'` on every component the guarded walk traverses.
- Result: pass
- Evidence:

  ```
  755 root:wheel /
  755 root:wheel /Library
  755 root:wheel /Library/Developer
  755 root:admin /Library/Developer/CoreSimulator
  755 root:admin /Library/Developer/CoreSimulator/Caches
  755 root:admin /Library/Developer/CoreSimulator/Caches/dyld
  755 root:admin /Library/Developer/CoreSimulator/Cryptex
  755 root:admin /Library/Developer/CoreSimulator/Cryptex/Caches
  ```

- Functional checks: N/A — no simulator was booted and nothing was deleted to obtain this.
- Verdict: verified **on this configuration only**
- Notes: `removeRegenerableSystemDirectoryContents` refuses any component that is not owned by
  root or that is writable by group or other. Every component here is `0755`, so the group bit
  is `r-x` and the guard passes — including the `root:admin` components, where `admin` membership
  does *not* confer write.

  This is recorded because it is the precondition under which the guard is a no-op rather than a
  behaviour change, and **one passing configuration is not a proof** (CLAUDE.md rule 7; the
  Definition of Done in `NON_GOALS_AND_SAFETY.md`). A machine where an MDM profile or a
  third-party installer leaves any of these `0775` gets a hard `ok: false` from the cleanup verb
  with no other diagnosis. That is fail-closed and therefore safe, but it is a support case, and
  it is why the measurement lives here rather than only in a code comment where it would read as
  a general fact. Not measured on Apple Silicon, on managed machines, or after an Xcode
  reinstall.

**Matrix status after this pass:** five of roughly twenty-one entries re-verified on 26.7 (E1, E8,
E14a, E2, E12). Everything still outstanding mutates devices, needs root, or needs an event — see
the list in the entry above.

---

### F22 per-device regenerables — dead containers, MobileAsset payloads, log store — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-13 (entry written 2026-09-19, issue #20)
- Hypothesis reference: H7 (per-device regenerable data is separable from the device)
- Test performed: observation with a control. One booted simulator device driven by an
  `xcodebuild test` loop, one shutdown sibling left alone, both measured over several hours.
- Result: pass, for the dead-container claim only. The other two subpaths were measured but not
  controlled.
- Evidence: **none written as a file.** The measurement was recorded inline in
  `Sources/XCodeVaultCore/Catalog/StorageCatalog.swift:128` and `:159` and in
  `docs/product/STORAGE_CATALOG.md:131`, and this entry is the first time it appears in the
  matrix. That absence is the finding this entry exists to record: the catalog carried
  `evidenceStatus: .verified` on the strength of an `F22` tag that the evidence ledger had no
  entry for. Found by `REVIEW-2026-09-17.md` §3.5 Q6.
- Functional checks: simulator boot — yes, the booted device is the instrument. `xcodebuild` —
  ran throughout, as the workload. Physical device — N/A.
- Verdict: **probable**, on this machine, for the dead-container reaping. Demoted from the
  `verified` the catalog claimed.
- Notes:
  - What was seen: a booted device reaped 19 of 19 pre-existing `Dead/temp.XXXXXX` entries
    (1.5 GB → 306 MB) in a single bulk sweep, while the shutdown sibling stayed byte-identical at
    676 MB. Three entries created shortly before the sweep were still present an hour later.
  - Why this is `probable` and not `verified`, in the Definition-of-Done sense of
    `NON_GOALS_AND_SAFETY.md`: n=1 machine, n=1 occurrence, one macOS/Xcode pair, and — as the
    catalog's own note already says — "an observation with a control, not a controlled
    experiment". An `xcodebuild test` was driving the booted device for part of the window, so
    containermanagerd's own timer cannot be separated from something the test triggered. The
    shutdown control makes the *direction* unambiguous; it does not make the mechanism proven.
  - The cadence is explicitly **not** established. The sweep was a bulk event that took everything
    predating it and left the three newest alone. "Booting gets it collected" is supported;
    "booting collects it within N minutes" is not, and nothing may promise a schedule from this.
  - The MobileAsset figures at `StorageCatalog.swift:159` (3.3 GB across two devices) are a size
    measurement from the same session with **no control at all**. They are a description of what
    was on this machine, not a claim about behaviour, and nothing in the product acts on them
    beyond reporting.
  - No category with a relocation or cleanup strategy depends on this entry: all three subpaths
    are `.appleManaged` with `allowedStrategies: [.appleManaged]`, so safety rule 10 is not
    implicated either way. That is why this was a documentation defect rather than a product one.
  - What would upgrade it: the same observation on a second machine, and a run where nothing else
    is driving the booted device. See `CONTRIBUTING.md`.

---

### Correction — "external volumes mount `noowners` by default" is narrower than stated — macOS 26.7 (25G229) · x86_64

- Date tested: 2026-09-19 (issue #5 review)
- Hypothesis reference: H8 (ownership semantics on the vault volume)
- Test performed: read the live mount flags and `diskutil info` for the external APFS volume
  attached to this machine, while reviewing the `createVaultDirectory` hardening.
- Result: the claim does not hold for this volume.
- Evidence: `mount` reports `/dev/disk3s1 on /Volumes/<vault> (apfs, local, nodev, nosuid,
  journaled)` — no `noowners` — and `diskutil info` reports `Owners: Enabled`. The reviewer
  independently read `f_flags = 0x04809218` with `MNT_IGNORE_OWNERSHIP` clear.
- Functional checks: N/A — this is a property of the mount, not of a developer workflow.
- Verdict: **`noowners` is a default, not an invariant.** Both readings in this matrix that mention
  it are still correct about what they measured — a freshly attached volume and a sparse disk image
  both came up `noowners` — but ownership can be, and on this machine has been, enabled afterwards
  (`diskutil enableOwnership` persists it). Nothing may assume either state.
- Notes:
  - Why it matters beyond bookkeeping: the `createVaultDirectory` identity check (issue #5) reads
    `st_uid` from a descriptor, and the question "could an unprivileged user stage a root-owned
    directory on a `noowners` volume?" was the sharpest objection to it. Measured answer, from the
    same review: no. `chown 0:0` as an unprivileged user on such a volume returns `EPERM` — ignoring
    ownership grants *owner* rights on everything, not the superuser right to give a file away — and
    a root caller reads the true on-disk uid, because XNU applies the `MNT_IGNORE_OWNERSHIP`
    substitution only for non-superuser callers. The attacker-created directories read uid 501 on
    disk when the same image is re-attached with `-owners on`.
  - The root-observer half of that rests on XNU's documented behaviour rather than on a measurement
    here, because `sudo -n` is unavailable on this machine. If it were false, the consequence is a
    *functional* break — the created-branch check would refuse on every `noowners` volume, which is
    the primary target — not an escalation. That asymmetry is why it is recorded rather than
    assumed, and it is the shape of an experiment somebody with root can run in a minute.
  - Not measured: Apple Silicon, HFS+, or a volume that has never had `enableOwnership` run on it
    by this machine's owner.

### E6c — mounting over a CoreSimulator cache path — macOS 26.7 (25G229) · Xcode 26.5 (17F42) · x86_64

Four runs, 2026-09-21 and 2026-09-22, as root, against **disk-image volumes only**. Every recorded
device-class row in the series says `Protocol=Disk Image`, for the donor (`/dev/disk9s1`) as well as
for B0's own image (`/dev/disk11s1`); no row says anything else.
Evidence: `research/evidence/e6c-mount-mechanism-cryptex-macos26.7-25G229-xcode26.5-x86_64.txt`
plus its three `-superseded-` predecessors and
`e6b-mount-stub-cryptex-FAILED-macos26.7-25G229-xcode26.5-x86_64.txt`.

**Only one path was ever tested: `/Library/Developer/CoreSimulator/Cryptex/Caches`.**

| destination | `mount_apfs -o nobrowse` | `diskutil mount -mountPoint` |
|---|---|---|
| `/Library/Developer/xcv-e6c-probe` (throwaway, created and verified empty by the run) | **MOUNTED** | **MOUNTED** with a fresh image (3×); **REFUSED** with the donor (2×) |
| `/Library/Developer/CoreSimulator/Cryptex/Caches` | **REFUSED**, `Operation not permitted`, exit 77 | **REFUSED**, exit 1, **and no `diskarbitrationd` record** |

**Status: observed, one configuration, one path.**

**The `mount_apfs` row is the firm result.** The same volume mounts at a throwaway directory one
level up and is refused at the cache path. Measured on the target and all negative: no BSD flag
(`ls -lO`), no ACL, no `com.apple.rootless` xattr — only a Time Machine exclusion — and no
`rootless.conf` entry for `/Library/Developer`. SIP enabled, normally. `drwxr-xr-x root:admin`.
The cause is unidentified and is the same unexplained shape as E4b's `images.plist` refusal.

**The `diskutil` row is weaker than it looks, and the evidence says so — reproduced 2026-09-22.**
Both probe-path refusals captured their own `diskarbitrationd` failure (`status code
0x0000004D`); both cache-path attempts added **nothing of their own** — their log
windows hold only earlier cells' events. The refusal is therefore not shown to have been a mount refusal at all; it may be
a client-side rejection before the request reaches `diskarbitrationd`. The fourth run reproduces
this: C's `diskarbitrationd` block is **byte-identical to B2's** (as in runs 2 and 3), both its
`0x4D` lines predate C, and nothing from C's own attempt appears. C's verdict is void, so the
claim rests on **E** — runs 3 and 4 — and the property is *attribution*, not naming: E's window
holds 35 records naming its own device, and nothing in it postdates E0's teardown. Cause: `log show --last 60s`
runs after the cell with no start sentinel, so a refused cell replays its predecessors — **no
per-cell log claim in any E6c file is safe without diffing the block against its predecessor's.** Mount history and mount depth *are*
excluded for that volume: it mounted at the probe immediately before the refused attempt and
again immediately after.

**Three things the series has and never stated.** The kernel takes the donor at the control
directory where DiskArbitration will not — cell A mounted `/dev/disk9s1` there in the same session
that refused B1 and B2, which narrows — but does not foreclose — reading `0x0000004D` as
`mount_apfs`'s exit status passing through: direct invocation accepts the donor there, while DA's
internal mount is a different invocation, and the resulting flags differ. `noowners` is excluded as the donor-versus-image differentiator: the donor mounts
`noowners` and so does B0's accepted image. And DA does not refuse the donor everywhere — see the
next paragraph, which is the same fact stated as a puzzle.

**Side observation.** `diskutil mount` with **no** `-mountPoint` mounted the donor at
DiskArbitration's own choice of location, while every `-mountPoint` attempt with that volume was
refused — including at the throwaway directory, where a different image of the identical device
class succeeded. Unexplained, non-blocking, recorded so it is not rediscovered.

**A `mkdir` inside the hierarchy is refused for root (2026-09-22, two runs, errno
captured on the second).** The run-created in-hierarchy control below could not be built:
`mkdir -p /Library/Developer/CoreSimulator/xcv-e6c-hprobe` failed under `sudo` and E6c's own guard
stopped the run. The script at the time discarded its report on that exit, so that run left "it
failed" and not the errno; E6c now records the error text as cell H0 and continues, and the next
run captured it: **`Operation not permitted`** (the run records `strerror`, so `EPERM` is an
inference, safe on Darwin). Four `mkdir` probes run **as a non-root user**
separate two levels: `/Library/Developer/` gives `EACCES` and yields to `sudo` (the
out-of-hierarchy probe mounts in every run), while `/Library/Developer/CoreSimulator/`,
`…/Caches/` and `…/Cryptex/` each give `EPERM`; the probes recorded errno only, not mode or
owner. Read it
narrowly on two counts. The non-root contrast does not carry to root on its own, and the root
observation that would join them is the one without an errno. And this is a refusal to *create a
directory*: cell D was refused at a directory that already existed, so it does not explain D. The
mechanism is unidentified.

**Consequence.** E6c is closed for this path. **H14 is not**: its own path is
`…/CoreSimulator/Caches/dyld`, which no run has attempted, and `common.sh` records why that
substitution may not be waved through. Issue #29 stays open.

- Not measured: `…/CoreSimulator/Caches/dyld`, by either mechanism — H14's path and the issue
  #24 guard's path; whether `$TARGET` was empty at the time of the attempts (the probe is
  guarded and recorded, the target is not — **closed 2026-09-22: `entries: 0` at run start,
  `links=2` at cell time, which excludes child directories and not regular files**); a *mount* at a matched control directory inside
  `/Library/Developer/CoreSimulator/` — the run-created form (cells H1/H2) cannot be built here,
  but the question is still open against a **pre-existing** empty directory in the hierarchy
  other than the target (using `Cryptex/Caches` would collapse H1 into D), and that cell is not
  written; which mechanism returns the `mkdir` refusal, and whether it refuses every write in the hierarchy or only directory
  creation; the DiskArbitration API called directly rather than through
  `diskutil`; Apple Silicon; any macOS other than 26.7 (25G229); **physical external media — every
  volume in the series was a disk image.** *(On 2026-09-22 I replaced that last clause with "A, B1,
  B2 and B3 ran against the operator's physical external donor", on the strength of the script's own
  comments, and then restored it. The comments say "physical external"; they describe intent. The
  device-class rows the runs actually recorded say `Protocol=Disk Image` for `/dev/disk9s1` in both
  runs that captured them, and the donor was a sparse image that no longer exists. Prose over the
  measured row, the third time in this series — the original sentence was right.)*
