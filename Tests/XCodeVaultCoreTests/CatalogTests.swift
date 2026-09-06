import XCTest
@testable import XCodeVaultCore

final class CatalogTests: XCTestCase {
    func testSeededCatalogSatisfiesSafetyInvariants() {
        XCTAssertEqual(CatalogRules.validate(StorageCatalog.all).map(\.description), [])
    }

    func testNoCategoryMayRelocateForbiddenPaths() {
        let bad = StorageCategory(id: "bad", name: "bad", subsystem: .coreSimulator,
                                  pathTemplates: ["~/Library/Developer/CoreSimulator"], description: "",
                                  regenerability: .regenerable, deletionRisk: .low, relocationRisk: .low,
                                  recommendedStrategy: .symlinkRelocation, allowedStrategies: [.symlinkRelocation])
        let v = CatalogRules.validate(bad)
        XCTAssertEqual(v.count, 1)
        XCTAssertTrue(v[0].description.contains("rule 7"))
    }

    func testSystemPathsAreAppleManagedOnly() {
        let bad = StorageCategory(id: "sys", name: "sys", subsystem: .mobileAsset,
                                  pathTemplates: ["/System/Library/AssetsV2/x"], description: "",
                                  regenerability: .regenerable, deletionRisk: .low, relocationRisk: .low,
                                  recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup])
        XCTAssertTrue(CatalogRules.validate(bad).contains { $0.description.contains("rule 2") })
    }

    func testNonRegenerableCannotBeSafeCleanup() {
        let bad = StorageCategory(id: "arch", name: "arch", subsystem: .xcodeIDE,
                                  pathTemplates: ["~/Library/Developer/Xcode/Archives"], description: "",
                                  regenerability: .nonRegenerable, deletionRisk: .critical, relocationRisk: .low,
                                  recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup])
        XCTAssertTrue(CatalogRules.validate(bad).contains { $0.description.contains("rule 5") })
    }

    func testExperimentalLabelingFollowsEvidence() {
        let noEvidence = StorageCategory(id: "a", name: "a", subsystem: .other, pathTemplates: ["/tmp/a"], description: "",
                                         regenerability: .regenerable, deletionRisk: .low, relocationRisk: .low,
                                         recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup], evidence: nil, evidenceStatus: .verified)
        XCTAssertEqual(noEvidence.evidenceStatus, .unverified, "verified without evidence must downgrade")
        XCTAssertTrue(noEvidence.isExperimental)
        let verified = StorageCategory(id: "b", name: "b", subsystem: .other, pathTemplates: ["/tmp/b"], description: "",
                                       regenerability: .regenerable, deletionRisk: .low, relocationRisk: .low,
                                       recommendedStrategy: .safeCleanup, allowedStrategies: [.safeCleanup], evidence: "matrix#1", evidenceStatus: .verified)
        XCTAssertFalse(verified.isExperimental)
        XCTAssertFalse(StorageCatalog.category("runtimeMounts")!.isExperimental, "neverMove is not a strategy that needs the DoD")
    }

    func testOutcomeLabels() {
        XCTAssertEqual(StorageCatalog.category("derivedData")!.outcomeLabel, "relocatable")
        XCTAssertEqual(StorageCatalog.category("deviceSupport")!.outcomeLabel, "delete-only")
        XCTAssertEqual(StorageCatalog.category("simulatorRuntimeAssets")!.outcomeLabel, "delete-only (official tool)")
        XCTAssertEqual(StorageCatalog.category("runtimeMounts")!.outcomeLabel, "must stay local")
        XCTAssertEqual(StorageCatalog.category("archives")!.regenerability, .nonRegenerable)
        XCTAssertFalse(StorageCatalog.category("archives")!.isCleanable)
    }

    func testCoreSimulatorHasNoSymlinkStrategyAnywhere() {
        for c in StorageCatalog.all where c.pathTemplates.contains(where: { $0.contains("CoreSimulator") }) {
            XCTAssertFalse(c.allowedStrategies.contains(.symlinkRelocation), c.id)
            XCTAssertFalse(c.allowedStrategies.contains(.userDirectoryRelocation), c.id)
        }
    }
}
