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
