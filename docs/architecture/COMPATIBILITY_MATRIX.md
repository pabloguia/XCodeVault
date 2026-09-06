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
- Result: partial — path not SIP-protected (no restricted flag, no rootless xattr,
  `rootless.conf` covers only `/System/Developer`); two nested runtime mounts already present
  under `Volumes/`; `Cryptex/Images/bundle` empty; all runtime bytes in
  `/System/Library/AssetsV2`. **Mount attempt not run (needs root).**
- Evidence: `../research/evidence/e1-macos26.6.2-25G83-xcode26.5-x86_64.txt`
- Functional checks: N/A
- Verdict: H8 probable (read-only half); H1 unverified and reframed (ADR-0004)
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

### Pending — manual (procedures in `../process/MANUAL_TEST_PROTOCOL.md`)

| Experiment | Gates | Status |
|---|---|---|
| E1 mount half | H8 | pending — manual (root) |
| E6 surprise removal | H3, disconnect safety DoD | pending — manual (hardware); harness = `vault`/`externalize`/`migration` commands + fault-injection unit tests |
| E7 shadow-data defense | H3 | pending — manual (root); low priority after ADR-0004 |
| E8 export/import round trip | H4 | export done (tvOS, see entry above); import half + iOS-size run pending (needs ≥ 20 GB free) |
| E9 CoreSimulator symlink | H5 | pending — manual (scratch account) |
| E11 staging space | Runtime Library UX | pending — manual |
