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
- Verdict: import mechanism **verified safe against a large, real, in-use runtime** — the
  offload→import round trip does not lose devices or data even when the runtime being cycled
  is the one actively backing the user's own development devices. Confirms the preflight
  formula generalizes beyond the single tvOS data point.

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
- Evidence: this session's transcript (no `.txt` evidence file written — no script exists for
  E7; recorded here and in `HYPOTHESES.md` H3 directly, per the "informative, low-priority"
  nature of the experiment).
- Verdict: for this failure shape (a build tool asked to create a derived-data directory under
  a locked path), the shadow-data defense **fails loudly, does not crash or corrupt state.**
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
| E7 shadow-data defense | H3 | **done (2026-09-07)** — see entry below; does not crash Xcode; low priority after ADR-0004 |
| E8 export/import round trip | H4 | **done** — export (2026-09-06) + import with functional boot probe (2026-09-07) both pass; see entries above |
| Stranded Inbox cleanup | F1 | `sudo rm` refused (policy); **a reboot reaps it** (verified 2026-09-07, +5 GB). Doctor's remediation is "restart the Mac". Helper verb for this is pointless — remove it. |
| E9 CoreSimulator symlink | H5 | **done (2026-09-08)** — see entry above; the reported Files-app failure did **not** reproduce. Rule 7 / ADR-0004 unchanged. Still pending: the `~/Library/Developer`-wide symlink of FB12363725 (forbidden by rule 7), Xcode.app GUI, Apple Silicon, iCloud-signed-in |
| E11 staging space | Runtime Library UX | pending — manual |

### F10 orphaned dyld caches + F11 export cost — macOS 26.6.2 (25G83) · Xcode 26.5 (17F42) · x86_64

- Date tested: 2026-09-08 / 09
- Gates: H10 (are regenerable system caches reclaimed by the system?), and the cost model the
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
- **F10 — orphaned cache: PARTIAL, and the decisive probe has not run.** 2.3 GiB under
  `Caches/dyld/25G83/inc/com.apple.CoreSimulator.SimRuntime.tvOS-26-5.23L470` for a runtime absent
  from `simctl runtime list`, `Profiles/Runtimes` and `Images`. Survived the runtime's removal and
  later simulator boots, but was created after the last boot (`kern.boottime` Sep 7 17:39 vs mtime
  Sep 7 18:54), so it has **never been through a restart** — which is what reclaims the analogous
  stranded Inbox file. Status: **pending E13**, not "confirmed garbage".
- Root-deletability: **unknown, and not inferable.** No BSD flags anywhere on the ancestor chain and
  `/Library/Developer/CoreSimulator` is absent from `rootless.conf` — but the Inbox file had both
  properties and root was still refused. `doctor` therefore recommends a restart and no `sudo`.
- Evidence: `docs/research/FINDINGS-2026-09-05.md` §F10, §F11
