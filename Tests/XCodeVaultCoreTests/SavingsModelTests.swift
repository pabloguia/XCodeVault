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

    func testRuleFiveHoldsEvenWhenAStrategyWouldAllowDeletion() {
        // Positive control for the guard itself: the catalog's only non-regenerable category offers no cleanup,
        // so the catalog test alone would pass without the guard.
        let c = StorageCategory(
            id: "synthetic", name: "Synthetic", subsystem: .other, pathTemplates: ["~/x"], description: "",
            regenerability: .nonRegenerable, deletionRisk: .critical, relocationRisk: .low,
            recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup], cleanupCommand: "rm")
        XCTAssertEqual(c.savingsOptions, [.keepLocal])
    }

    func testExperimentalIsDecidedPerOption() {
        let runtime = StorageCatalog.category("simulatorRuntimeAssets")!.savingsOptionDetails
        XCTAssertEqual(runtime.map(\.bucket), [.parkExternally, .deleteAndRegenerate])
        XCTAssertEqual(runtime.map(\.isExperimental), [true, false], "offload is experimental; simctl runtime delete is verified")
        XCTAssertTrue(StorageCatalog.category("derivedData")!.savingsOptionDetails.allSatisfy(\.isExperimental))
        XCTAssertEqual(StorageCatalog.category("toolchains")!.savingsOptionDetails.map(\.isExperimental), [false])
    }

    func testArchivesRunFromExternalOnlyRedirectsNewArchives() {
        let archives = StorageCatalog.category("archives")!
        XCTAssertEqual(archives.savingsOptionDetails.map(\.appliesToExistingData), [false, true])
        XCTAssertEqual(archives.primaryBucket, .parkExternally)
    }

    func testOnlyDeletingSimulatorDevicesLosesUserData() {
        for c in StorageCatalog.all {
            for o in c.savingsOptionDetails where o.losesUserData {
                XCTAssertEqual(c.id, "simulatorDevices")
                XCTAssertEqual(o.bucket, .deleteAndRegenerate)
            }
        }
        XCTAssertTrue(StorageCatalog.category("simulatorDevices")!.savingsOptionDetails.contains(where: \.losesUserData))
    }

    func testThePrimaryBucketIsTheMostDurableOption() {
        XCTAssertEqual(StorageCatalog.category("derivedData")?.primaryBucket, .runFromExternal)
        XCTAssertEqual(StorageCatalog.category("simulatorRuntimeAssets")?.primaryBucket, .parkExternally)
        XCTAssertEqual(StorageCatalog.category("xcodeCaches")?.primaryBucket, .deleteAndRegenerate)
        XCTAssertEqual(StorageCatalog.category("toolchains")?.primaryBucket, .keepLocal)
        XCTAssertEqual(StorageCatalog.category("archives")?.primaryBucket, .parkExternally)
    }

    func testEveryNamedParkCategoryExistsInTheCatalog() {
        for id in StorageCategory.parkCommandCategoryIDs { XCTAssertNotNil(StorageCatalog.category(id), id) }
    }

    func testOnlyRunFromExternalIsPermanent() {
        XCTAssertEqual(SavingsBucket.allCases.filter(\.isPermanent), [.runFromExternal])
        XCTAssertEqual(SavingsBucket.allCases.filter { !$0.isSaving }, [.keepLocal])
    }
}

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
        XCTAssertEqual(s.permanentBytes, 1000, "archives' run-from-external only redirects new archives")
        XCTAssertEqual(s.parkExternally.primaryBytes, 4200)
        XCTAssertEqual(s.runFromExternal.optionBytes, 1000)
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

    func testOnlyVerifiedOptionsCountAsVerified() {
        let s = summarize([item("derivedData", 1000), item("simulatorRuntimeAssets", 4000)])
        XCTAssertEqual(s.verifiedReclaimableBytes, 4000)
        XCTAssertEqual(s.verifiedTemporaryBytes, 4000)
        XCTAssertEqual(s.verifiedPermanentBytes, 0)
        XCTAssertEqual(s.parkExternally.verifiedOptionBytes, 0)
        XCTAssertEqual(s.deleteAndRegenerate.verifiedOptionBytes, 4000)
    }

    func testPrimaryTotalsMatchTheScannersBootVolumeTotal() {
        let items = [
            item("derivedData", 1000), item("archives", 200), item("xcodeCaches", 30), item("toolchains", 5),
            item("simulatorDevices", 70), item("simulatorDeadContainers", 7),  // a breakdown of simulatorDevices
            item("xcodeCaches", 17, onBoot: false), item("xcodeCaches", 11, symlink: true),
        ]
        let summary = XCodeVaultCore.Scanner(
            runner: FakeRunner(responses: [:]), home: "/nonexistent", catalog: StorageCatalog.all, measureSizes: false,
            detectXcodeCapabilities: false
        ).summarize(items: items, runtimes: [])
        let s = summarize(items)
        // Positive control: the scanner counted something, so equality is not 0 == 0.
        XCTAssertEqual(summary.internalDeveloperBytes, 1305)
        XCTAssertEqual(SavingsBucket.allCases.reduce(UInt64(0)) { $0 + s[$1].primaryBytes }, summary.internalDeveloperBytes)
    }

    func testAnUnreadableItemMakesEveryHeadlineALowerBound() {
        XCTAssertFalse(summarize([item("xcodeCaches", 1)]).isLowerBound)
        XCTAssertTrue(summarize([item("xcodeCaches", 1), item("derivedData", 2, unreadable: ["/x"])]).isLowerBound)
    }

    func testAnUnknownCategoryIsSkippedNotCountedAsLocal() {
        XCTAssertEqual(summarize([item("noSuchCategory", 99)]), SavingsSummary())
    }
}

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
        XCTAssertTrue(json.contains("42"), json)
        XCTAssertTrue(json.contains("\"permanentBytes\""), json)
    }
}
