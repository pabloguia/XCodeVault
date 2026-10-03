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
