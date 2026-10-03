# S1 — Savings Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every storage category the user-facing savings options (delete / park / run from external / keep local) and add a disjoint, temporary-vs-permanent `SavingsSummary` to every `ScanReport`.

**Architecture:** Pure derivation in `XCodeVaultCore/Savings`: `SavingsBucket` and `StorageCategory.savingsOptions` are computed from the existing `allowedStrategies`/`cleanupCommand`/`regenerability` (no new hand-maintained field). `SavingsCalculator.summarize` folds scan items into a `SavingsSummary`; `Scanner.scan()` stores it on the report. No CLI or GUI change in this plan (S3/S4).

**Tech Stack:** Swift 6, SwiftPM, XCTest (the suite is XCTest, not swift-testing).

**Spec:** `docs/superpowers/specs/2026-10-03-savings-visibility-i18n-identity-design.md` §3.

## Global Constraints

- Swift 6 language mode, macOS 14+, 4-space indent, 160 columns (`.swift-format`); `swift-format lint --strict` must pass.
- Archives (`regenerability == .nonRegenerable`) never get `.deleteAndRegenerate` (CLAUDE.md rule 5).
- `.symlinkRelocation` and `.canonicalMount` never produce `.runFromExternal` (rule 7, ADR-0002/0004).
- Experimental labeling is the category's `isExperimental` (rule 10); this plan does not change any evidence status.
- Breakdown categories (`isBreakdownOf != nil`) are never counted in totals (same rule as `Scanner.summarize`).
- This machine is slow (build+test 10–20 min): run the focused test class with `swift test --filter <ClassName>`, and **always check the printed "Executed N tests" is non-zero** — a broken build also reports zero failures.
- Run `scripts/preflight.sh` once before pushing; all gates must pass.

---

### Task 1: `SavingsBucket` and `StorageCategory.savingsOptions`

**Files:**
- Create: `Sources/XCodeVaultCore/Savings/SavingsBucket.swift`
- Test: `Tests/XCodeVaultCoreTests/SavingsModelTests.swift`

**Interfaces:**
- Produces:
  - `public enum SavingsBucket: String, Sendable, Codable, CaseIterable { case runFromExternal, parkExternally, deleteAndRegenerate, keepLocal }`
  - `SavingsBucket.isPermanent: Bool`, `SavingsBucket.isSaving: Bool`
  - `StorageCategory.savingsOptions: [SavingsBucket]` (most durable first; `[.keepLocal]` when none)
  - `StorageCategory.primaryBucket: SavingsBucket`
  - `StorageCategory.parkCommandCategoryIDs: Set<String>` (static, internal)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest

@testable import XCodeVaultCore

/// The savings vocabulary (spec 2026-10-03 §3). The whole-catalog table is pinned on purpose: a catalog
/// edit that moves a category between buckets changes what the user is promised, so it must fail here
/// and be a reviewed decision, not a side effect.
final class SavingsOptionsTests: XCTestCase {
    func testTheWholeCatalogMapsToThePinnedOptions() {
        let expected: [String: [SavingsBucket]] = [
            "derivedData": [.runFromExternal, .deleteAndRegenerate],
            "archives": [.runFromExternal, .parkExternally],
            "deviceSupport": [.deleteAndRegenerate],
            "previews": [.deleteAndRegenerate],
            "xcodePackages": [.deleteAndRegenerate],
            "xcodeCaches": [.deleteAndRegenerate],
            "deviceLogs": [.deleteAndRegenerate],
            "swiftPMCaches": [.deleteAndRegenerate],
            "simulatorDevices": [.deleteAndRegenerate],
            "simulatorDeadContainers": [.keepLocal],
            "simulatorMobileAssets": [.keepLocal],
            "simulatorLogStore": [.keepLocal],
            "simulatorUserCaches": [.deleteAndRegenerate],
            "xctestDevices": [.deleteAndRegenerate],
            "playgroundDevices": [.deleteAndRegenerate],
            "coreSimulatorSystemCaches": [.deleteAndRegenerate],
            "runtimeInbox": [.keepLocal],
            "runtimeBundles": [.keepLocal],
            "runtimeMounts": [.keepLocal],
            "simulatorRuntimeAssets": [.parkExternally, .deleteAndRegenerate],
            "runtimeLibrary": [.runFromExternal],
            "developerDiskImages": [.keepLocal],
            "coreDevice": [.keepLocal],
            "toolchains": [.keepLocal],
            "commandLineTools": [.keepLocal],
        ]
        let actual = Dictionary(uniqueKeysWithValues: StorageCatalog.all.map { ($0.id, $0.savingsOptions) })
        // Both directions: a new category with no pinned row fails as loudly as a moved one.
        XCTAssertEqual(Set(actual.keys), Set(expected.keys), "catalog ids changed: pin the new category's options here")
        for (id, options) in expected { XCTAssertEqual(actual[id], options, id) }
    }

    func testNonRegenerableDataIsNeverOfferedForDeletion() {
        for c in StorageCatalog.all where c.regenerability == .nonRegenerable {
            XCTAssertFalse(c.savingsOptions.contains(.deleteAndRegenerate), c.id)
        }
        // Positive control: the rule is not vacuous — the catalog has a non-regenerable category.
        XCTAssertTrue(StorageCatalog.all.contains { $0.regenerability == .nonRegenerable })
    }

    func testSymlinkAndMountStrategiesNeverMeanRunFromExternal() {
        for strategies in [[Strategy.symlinkRelocation], [.canonicalMount], [.symlinkRelocation, .canonicalMount]] {
            let c = StorageCategory(
                id: "synthetic", name: "Synthetic", subsystem: .other, pathTemplates: ["~/x"], description: "",
                regenerability: .regenerable, deletionRisk: .low, relocationRisk: .high,
                recommendedStrategy: strategies[0], allowedStrategies: strategies)
            XCTAssertEqual(c.savingsOptions, [.keepLocal], "\(strategies)")
        }
    }

    func testThePrimaryBucketIsTheMostDurableOption() {
        XCTAssertEqual(StorageCatalog.category("derivedData")?.primaryBucket, .runFromExternal)
        XCTAssertEqual(StorageCatalog.category("simulatorRuntimeAssets")?.primaryBucket, .parkExternally)
        XCTAssertEqual(StorageCatalog.category("xcodeCaches")?.primaryBucket, .deleteAndRegenerate)
        XCTAssertEqual(StorageCatalog.category("toolchains")?.primaryBucket, .keepLocal)
    }

    func testEveryNamedParkCategoryExistsInTheCatalog() {
        for id in StorageCategory.parkCommandCategoryIDs { XCTAssertNotNil(StorageCatalog.category(id), id) }
    }

    func testOnlyRunFromExternalIsPermanent() {
        XCTAssertEqual(SavingsBucket.allCases.filter(\.isPermanent), [.runFromExternal])
        XCTAssertEqual(SavingsBucket.allCases.filter { !$0.isSaving }, [.keepLocal])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SavingsOptionsTests 2>&1 | tail -20`
Expected: build failure, "cannot find type 'SavingsBucket' in scope".

- [ ] **Step 3: Implement**

```swift
import Foundation

/// What the user can do with a category's bytes, in their terms (spec 2026-10-03 §3.1). Declared in
/// durability order: the first case a category supports is where the dashboard counts its bytes.
public enum SavingsBucket: String, Sendable, Codable, CaseIterable {
    /// Lives on an external drive from now on; stops growing on this Mac. The only permanent saving.
    case runFromExternal
    /// Copied to a vault and removed here; brought back by copying, without downloading.
    case parkExternally
    /// Deleted; Xcode rebuilds it or Apple downloads it again on demand. Grows back as you work.
    case deleteAndRegenerate
    /// Nothing XCodeVault can reclaim safely.
    case keepLocal

    public var isPermanent: Bool { self == .runFromExternal }
    public var isSaving: Bool { self != .keepLocal }
}

extension StorageCategory {
    /// Categories whose park command exists although their strategy is `.appleManaged`: a runtime is
    /// offloaded through the Runtime Library (`runtime offload`). Named rather than inferred, because
    /// nothing in `allowedStrategies` says so; `SavingsOptionsTests` pins that every id here exists.
    static let parkCommandCategoryIDs: Set<String> = ["simulatorRuntimeAssets"]

    /// Derived from the strategies the catalog already records, never stored: a second field could
    /// disagree with `allowedStrategies`, and the disagreement would be a promise the product does not
    /// keep. Most durable first; `[.keepLocal]` when the category offers nothing.
    public var savingsOptions: [SavingsBucket] {
        let strategies = Set(allowedStrategies)
        var options: [SavingsBucket] = []
        // `.symlinkRelocation` and `.canonicalMount` are deliberately absent (rule 7, ADR-0004).
        if !strategies.isDisjoint(with: [.nativeConfiguration, .userDirectoryRelocation, .downloadRepository]) {
            options.append(.runFromExternal)
        }
        if strategies.contains(.coldStorage) || Self.parkCommandCategoryIDs.contains(id) {
            options.append(.parkExternally)
        }
        // Rule 5: whatever the strategies say, non-regenerable data is never offered for deletion.
        if (strategies.contains(.safeCleanup) || cleanupCommand != nil) && regenerability != .nonRegenerable {
            options.append(.deleteAndRegenerate)
        }
        return options.isEmpty ? [.keepLocal] : options
    }

    /// Where the dashboard counts this category's bytes: its most durable option.
    public var primaryBucket: SavingsBucket { savingsOptions[0] }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SavingsOptionsTests 2>&1 | tail -20`
Expected: `Executed 6 tests, with 0 failures`. If `testTheWholeCatalogMapsToThePinnedOptions` fails on a row, **stop and report it** — do not edit the pinned table to match; a mismatch means the spec's §3.2 mapping and the catalog disagree, which is the operator's decision.

- [ ] **Step 5: Commit**

```bash
git add Sources/XCodeVaultCore/Savings/SavingsBucket.swift Tests/XCodeVaultCoreTests/SavingsModelTests.swift
git commit -m "Savings: user-facing buckets derived from the catalog's strategies (S1)"
```

---

### Task 2: `SavingsSummary` and `SavingsCalculator`

**Files:**
- Create: `Sources/XCodeVaultCore/Savings/SavingsSummary.swift`
- Modify: `Tests/XCodeVaultCoreTests/SavingsModelTests.swift` (append a second test class)

**Interfaces:**
- Consumes: `SavingsBucket`, `StorageCategory.savingsOptions`, `.primaryBucket`, `.isExperimental`, `.isBreakdownOf` (Task 1 and existing).
- Produces:
  - `public struct SavingsBucketTotals: Sendable, Codable, Equatable { optionBytes, primaryBytes, verifiedOptionBytes: UInt64 }`
  - `public struct SavingsSummary: Sendable, Codable, Equatable` with `runFromExternal`, `parkExternally`, `deleteAndRegenerate`, `keepLocal: SavingsBucketTotals`; `temporaryBytes`, `verifiedTemporaryBytes`, `reclaimableBytes`, `verifiedReclaimableBytes: UInt64`; `isLowerBound: Bool`; `subscript(bucket: SavingsBucket) -> SavingsBucketTotals { get }`; computed `permanentBytes`, `verifiedPermanentBytes`.
  - `public enum SavingsCalculator { public static func summarize(items: [StorageItem], category: (String) -> StorageCategory?) -> SavingsSummary }`

- [ ] **Step 1: Write the failing tests** (append to `SavingsModelTests.swift`)

```swift
final class SavingsSummaryTests: XCTestCase {
    private func item(_ id: String, _ bytes: UInt64, onBoot: Bool = true, exists: Bool = true, symlink: Bool = false, unreadable: [String] = [])
        -> StorageItem
    {
        var usage = DiskUsage.zero
        usage.allocatedBytes = bytes
        usage.unreadable = unreadable
        return StorageItem(
            categoryID: id, path: "/fixture/\(id)/\(bytes)", exists: exists, isSymlink: symlink, symlinkTarget: nil, isMountPoint: false,
            usage: usage, volumeMountPoint: nil, onBootVolume: onBoot)
    }

    private func summarize(_ items: [StorageItem]) -> SavingsSummary {
        SavingsCalculator.summarize(items: items, category: StorageCatalog.category)
    }

    func testAnOverlappingCategoryCountsOnceInPrimaryAndInEveryOption() {
        // DerivedData can be deleted or run from external: both options see it, the primary total once.
        let s = summarize([item("derivedData", 1000)])
        XCTAssertEqual(s.runFromExternal.optionBytes, 1000)
        XCTAssertEqual(s.deleteAndRegenerate.optionBytes, 1000)
        XCTAssertEqual(s.runFromExternal.primaryBytes, 1000)
        XCTAssertEqual(s.deleteAndRegenerate.primaryBytes, 0)
        XCTAssertEqual(s.temporaryBytes, 1000)
        XCTAssertEqual(s.permanentBytes, 1000)
        XCTAssertEqual(s.reclaimableBytes, 1000, "the union counts a byte once, not once per option")
    }

    func testPrimaryTotalsAddUpToEveryCountedByte() {
        let items = [
            item("derivedData", 1000), item("archives", 200), item("xcodeCaches", 30), item("simulatorRuntimeAssets", 4000),
            item("toolchains", 5),
        ]
        let s = summarize(items)
        let primary = SavingsBucket.allCases.reduce(UInt64(0)) { $0 + s[$1].primaryBytes }
        XCTAssertEqual(primary, 5235)
        XCTAssertEqual(s.keepLocal.primaryBytes, 5)
        XCTAssertEqual(s.reclaimableBytes, 5230)
        // Archives park, runtimes park: temporary includes them; xcodeCaches deletes.
        XCTAssertEqual(s.temporaryBytes, 1000 + 200 + 30 + 4000)
        XCTAssertEqual(s.permanentBytes, 1000 + 200)
    }

    func testBreakdownsSymlinksMissingAndOffBootItemsAreNotCounted() {
        let s = summarize([
            item("simulatorDeadContainers", 7),  // breakdown of simulatorDevices
            item("xcodeCaches", 11, symlink: true),
            item("xcodeCaches", 13, exists: false),
            item("xcodeCaches", 17, onBoot: false),
            item("xcodeCaches", 19),
        ])
        XCTAssertEqual(s.reclaimableBytes, 19)
        XCTAssertEqual(s.keepLocal.primaryBytes, 0)
    }

    func testVerifiedSharesFollowTheCategorysExperimentalLabel() {
        let s = summarize([item("derivedData", 1000), item("simulatorRuntimeAssets", 4000)])
        let derived = StorageCatalog.category("derivedData")!
        let runtimes = StorageCatalog.category("simulatorRuntimeAssets")!
        let expectedVerified = (derived.isExperimental ? 0 : 1000) + (runtimes.isExperimental ? 0 : 4000)
        XCTAssertEqual(s.verifiedReclaimableBytes, UInt64(expectedVerified))
        XCTAssertLessThanOrEqual(s.verifiedTemporaryBytes, s.temporaryBytes)
        XCTAssertLessThanOrEqual(s.verifiedPermanentBytes, s.permanentBytes)
    }

    func testAnUnreadableItemMakesEveryHeadlineALowerBound() {
        XCTAssertFalse(summarize([item("xcodeCaches", 1)]).isLowerBound)
        XCTAssertTrue(summarize([item("xcodeCaches", 1), item("derivedData", 2, unreadable: ["/x"])]).isLowerBound)
    }

    func testAnUnknownCategoryIsSkippedNotCountedAsLocal() {
        XCTAssertEqual(summarize([item("noSuchCategory", 99)]), SavingsSummary())
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SavingsSummaryTests 2>&1 | tail -20`
Expected: build failure, "cannot find 'SavingsCalculator' in scope".

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One bucket's bytes, three ways (spec 2026-10-03 §3.3).
public struct SavingsBucketTotals: Sendable, Codable, Equatable {
    /// Bytes for which this bucket is *an* option. Not additive across buckets: DerivedData is in two.
    public var optionBytes: UInt64 = 0
    /// Bytes counted once, under the category's most durable option. Additive across buckets.
    public var primaryBytes: UInt64 = 0
    /// The part of `optionBytes` whose category is not experimental (rule 10).
    public var verifiedOptionBytes: UInt64 = 0
    public init() {}
}

/// What the user can reclaim from the boot volume, temporarily and permanently. Every headline is an
/// "up to": the options are alternatives for the same bytes, and the unions count each byte once.
public struct SavingsSummary: Sendable, Codable, Equatable {
    public var runFromExternal = SavingsBucketTotals()
    public var parkExternally = SavingsBucketTotals()
    public var deleteAndRegenerate = SavingsBucketTotals()
    public var keepLocal = SavingsBucketTotals()
    /// Bytes that can be freed for a while: deleted (grows back) or parked (until brought back). A union.
    public var temporaryBytes: UInt64 = 0
    public var verifiedTemporaryBytes: UInt64 = 0
    /// Bytes with any saving option at all — temporary or permanent. A union.
    public var reclaimableBytes: UInt64 = 0
    public var verifiedReclaimableBytes: UInt64 = 0
    /// Some counted item could not be fully read: every number above is "at least".
    public var isLowerBound = false

    public init() {}

    public var permanentBytes: UInt64 { runFromExternal.optionBytes }
    public var verifiedPermanentBytes: UInt64 { runFromExternal.verifiedOptionBytes }

    public subscript(bucket: SavingsBucket) -> SavingsBucketTotals {
        switch bucket {
        case .runFromExternal: runFromExternal
        case .parkExternally: parkExternally
        case .deleteAndRegenerate: deleteAndRegenerate
        case .keepLocal: keepLocal
        }
    }

    fileprivate mutating func add(_ bytes: UInt64, to bucket: SavingsBucket, primary: Bool, verified: Bool) {
        func bump(_ t: inout SavingsBucketTotals) {
            t.optionBytes += bytes
            if primary { t.primaryBytes += bytes }
            if verified { t.verifiedOptionBytes += bytes }
        }
        switch bucket {
        case .runFromExternal: bump(&runFromExternal)
        case .parkExternally: bump(&parkExternally)
        case .deleteAndRegenerate: bump(&deleteAndRegenerate)
        case .keepLocal: bump(&keepLocal)
        }
    }
}

public enum SavingsCalculator {
    /// Counts the same items `Scanner.summarize` counts for the boot-volume total — existing, not a symlink,
    /// not a breakdown — restricted to the boot volume, because only bytes there are a saving. An item whose
    /// category is unknown is skipped rather than guessed into `.keepLocal`.
    public static func summarize(items: [StorageItem], category: (String) -> StorageCategory?) -> SavingsSummary {
        var s = SavingsSummary()
        for item in items where item.exists && !item.isSymlink && item.onBootVolume {
            guard let c = category(item.categoryID), c.isBreakdownOf == nil else { continue }
            let bytes = item.allocatedBytes
            let verified = !c.isExperimental
            if item.usage?.isLowerBound == true { s.isLowerBound = true }
            let options = c.savingsOptions
            for bucket in options { s.add(bytes, to: bucket, primary: bucket == c.primaryBucket, verified: verified) }
            if options.contains(where: \.isSaving) {
                s.reclaimableBytes += bytes
                if verified { s.verifiedReclaimableBytes += bytes }
            }
            if options.contains(.deleteAndRegenerate) || options.contains(.parkExternally) {
                s.temporaryBytes += bytes
                if verified { s.verifiedTemporaryBytes += bytes }
            }
        }
        return s
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SavingsSummaryTests 2>&1 | tail -20`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/XCodeVaultCore/Savings/SavingsSummary.swift Tests/XCodeVaultCoreTests/SavingsModelTests.swift
git commit -m "Savings: temporary vs permanent summary, each byte once in the unions (S1)"
```

---

### Task 3: Put the savings on every `ScanReport`

**Files:**
- Modify: `Sources/XCodeVaultCore/Scan/ScanReport.swift` (add a field to `ScanReport`, after `summary`)
- Modify: `Sources/XCodeVaultCore/Scan/Scanner.swift:34-52` (compute and pass it)
- Modify: `Tests/XCodeVaultCoreTests/SavingsModelTests.swift` (append a third class)
- Modify: any test or fake that calls `ScanReport(` positionally — find them with
  `grep -n -m20 "ScanReport(" Sources Tests -r`; the new field is defaulted, so labelled calls compile unchanged.

**Interfaces:**
- Consumes: `SavingsCalculator.summarize(items:category:)` (Task 2).
- Produces: `ScanReport.savings: SavingsSummary` (defaulted to `SavingsSummary()`), filled by `Scanner.scan()`.

- [ ] **Step 1: Write the failing test** (append)

```swift
final class ScanReportSavingsTests: XCTestCase {
    func testTheScannerFillsTheSavingsFromTheSameItemsAsTheSummary() {
        let t = TempDir()
        t.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x", bytes: 8192)
        let scanner = XCodeVaultCore.Scanner(
            runner: FakeRunner(responses: [:]), home: t.path, catalog: [StorageCatalog.category("derivedData")!], measureSizes: true,
            detectXcodeCapabilities: false)
        let report = scanner.scan()
        // Positive control: the fixture was measured, so equal zeros below would not pass vacuously.
        XCTAssertGreaterThan(report.summary.internalDeveloperBytes, 0)
        XCTAssertEqual(report.savings.runFromExternal.primaryBytes, report.summary.internalDeveloperBytes)
        XCTAssertEqual(report.savings, SavingsCalculator.summarize(items: report.items, category: StorageCatalog.category))
    }

    func testTheSavingsAreInTheJSON() throws {
        var report = Fixtures.minimalReport()
        report.savings.deleteAndRegenerate.optionBytes = 42
        let json = try JSONOutput.encode(report)
        XCTAssertTrue(json.contains("\"savings\""), json)
        XCTAssertTrue(json.contains("\"deleteAndRegenerate\""), json)
    }
}
```

Before writing the second test, check whether `Tests/XCodeVaultCoreTests/Support.swift` already has a helper that builds a `ScanReport` (search it for `ScanReport(`). If it does, use that helper instead of `Fixtures.minimalReport()`. If not, add this to `Support.swift` (it extends the existing `enum Fixtures`, which loads bundled fixture files):

```swift
extension Fixtures {
    static func minimalReport() -> ScanReport {
        XCodeVaultCore.Scanner(
            runner: FakeRunner(responses: [:]), home: "/nonexistent", catalog: [], measureSizes: false, detectXcodeCapabilities: false
        ).scan()
    }
}
```

The `TempDir` fixture path must be one the scanner resolves for `derivedData` with `home: t.path`; confirm it against the category's `pathTemplates` in `StorageCatalog.swift` (`~/Library/Developer/Xcode/DerivedData`). If the scanner also asks the boot volume and the temp dir is on it, `onBootVolume` is true; if the test fails only on `internalDeveloperBytes == 0`, the fixture is not on the boot volume — report that instead of weakening the control.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ScanReportSavingsTests 2>&1 | tail -20`
Expected: build failure, "value of type 'ScanReport' has no member 'savings'".

- [ ] **Step 3: Implement**

In `ScanReport.swift`, add after `public var summary: ScanSummary`:

```swift
    /// The user-facing savings (spec 2026-10-03 §3.3). `summary` stays for its existing readers; new
    /// renderings read this. Defaulted for the fixtures that build reports by hand; like every defaulted
    /// field here, it does not make an older stored report decodable, and nothing decodes one.
    public var savings = SavingsSummary()
```

In `Scanner.swift`, after `let summary = summarize(items: items, runtimes: runtimes)` (line 34):

```swift
        let savings = SavingsCalculator.summarize(items: items) { id in
            StorageCatalog.category(id) ?? catalog.first { $0.id == id }
        }
```

and change the `ScanReport(...)` construction at lines 49–52 to set it:

```swift
        var report = ScanReport(
            generatedAt: Date(), toolVersion: XCodeVaultVersion.current, catalogVersion: StorageCatalog.version,
            host: host, xcodes: xcodes, runtimes: runtimes, devices: devices, volumes: volumes,
            items: items, summary: summary, warnings: warnings)
        report.savings = savings
        return report
```

(The category lookup is the same one `summarize` uses at Scanner.swift:150, so the two totals cannot read the catalog differently.)

- [ ] **Step 4: Run to verify pass, then the whole suite once**

Run: `swift test --filter ScanReportSavingsTests 2>&1 | tail -20` → `Executed 2 tests, with 0 failures`.
Then: `swift build -Xswiftc -warnings-as-errors && swift test 2>&1 | tail -5` → all pass, executed count non-zero.

- [ ] **Step 5: Run the public-surface and format gates**

Run: `bash scripts/public-surface.sh && swift-format lint --recursive --strict --configuration .swift-format Sources Tests`
Expected: both exit 0. `public-surface.sh` checks fault-injection seams; the new public types add none.

- [ ] **Step 6: Commit**

```bash
git add Sources/XCodeVaultCore/Scan/ScanReport.swift Sources/XCodeVaultCore/Scan/Scanner.swift Tests/XCodeVaultCoreTests/SavingsModelTests.swift Tests/XCodeVaultCoreTests/Support.swift
git commit -m "Scan: every report carries the savings summary (S1)"
```

---

### Task 4: Document the vocabulary

**Files:**
- Modify: `docs/product/STORAGE_CATALOG.md` (add a "Savings buckets" section)
- Modify: `docs/product/UX_AND_CLI.md` (point the summary groupings at the new section)
- Modify: `STATUS.md` ("In flight": one bullet for this spec, naming S1 done and S2–S5 pending)

- [ ] **Step 1: Add to `STORAGE_CATALOG.md`**

```markdown
## Savings buckets (user-facing; spec 2026-10-03)

Every category is shown to the user through the options it offers, derived in code
(`StorageCategory.savingsOptions`) from `allowedStrategies`, `cleanupCommand` and `regenerability` —
never a separate field:

| Bucket | Derived from | Promise | Cost to undo |
|---|---|---|---|
| Run from external | `nativeConfiguration`, `userDirectoryRelocation`, `downloadRepository` | Permanent | None; drive must be connected |
| Park externally | `coldStorage`, or a named park command (`simulatorRuntimeAssets`) | Temporary | One copy back, no download |
| Delete | `safeCleanup` or a `cleanupCommand`, and not non-regenerable | Temporary | Rebuild or re-download |
| Keep local | none of the above | — | — |

`symlinkRelocation` and `canonicalMount` never produce "run from external". The current mapping is
pinned by `SavingsOptionsTests`; moving a category between buckets is a reviewed decision.
```

- [ ] **Step 2: In `UX_AND_CLI.md`**, under the section describing the summary groupings, add one
  sentence: "The user-facing grouping is the savings buckets in `STORAGE_CATALOG.md` § Savings
  buckets; the groupings below remain in `ScanSummary` and the JSON for existing readers."

- [ ] **Step 3: `STATUS.md`** — add under "In flight":

```markdown
- **Savings visibility, i18n and identity** — spec `docs/superpowers/specs/2026-10-03-savings-visibility-i18n-identity-design.md`.
  S1 (savings model in Core) done; S2 (localization), S3 (CLI), S4 (GUI), S5 (identity) pending, in that order.
```

- [ ] **Step 4: Run the doc-mirror gate**

Run: `bash scripts/check-doc-mirror.sh` → exit 0 (CLAUDE.md's non-negotiables are mirrored; this plan does not touch them).

- [ ] **Step 5: Commit, preflight, push**

```bash
git add docs/product/STORAGE_CATALOG.md docs/product/UX_AND_CLI.md STATUS.md
git commit -m "Docs: the savings buckets (S1)"
scripts/preflight.sh
git push
```

`preflight.sh` must report every gate run and passed before the push.
