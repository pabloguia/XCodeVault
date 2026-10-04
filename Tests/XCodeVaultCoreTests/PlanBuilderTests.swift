import XCTest

@testable import XCodeVaultCore

/// R7-C: the guided Plan's steps, a pure function of what the app read (`PlanBuilder.plan`), from fixtures only — the R6
/// drive fixtures, hand-made scan items and journal rows. Nothing reads this Mac's disks, Xcode or journal.
final class PlanBuilderTests: XCTestCase {
    static let gb: UInt64 = 1_000_000_000

    static func item(_ id: String, _ bytes: UInt64, mount: String? = "/", onBoot: Bool = true) -> StorageItem {
        var usage = DiskUsage.zero
        usage.allocatedBytes = bytes
        return StorageItem(
            categoryID: id, path: (mount == "/" ? "" : (mount ?? "")) + "/fixture/\(id)/\(bytes)", exists: true, isSymlink: false, symlinkTarget: nil,
            isMountPoint: false, usage: usage, volumeMountPoint: mount, onBootVolume: onBoot)
    }

    /// A Mac with DerivedData, Archives, a runtime image and caches on the internal disk.
    static func report(_ extra: [StorageItem] = []) -> ScanReport {
        var r = Fixtures.minimalReport()
        r.items =
            [
                item("derivedData", 30 * gb), item("archives", 18 * gb), item("simulatorRuntimeAssets", 10 * gb), item("xcodeCaches", 4 * gb),
                item("swiftPMCaches", 2 * gb),
            ] + extra
        return r
    }

    static func drives(_ snapshot: DriveSnapshot, vaults: [VaultVolumeCheck]) -> [DriveAssessment] { DriveEvaluation.assessAll(snapshot, vaults: vaults) }

    /// The R6 fixture with only the PABLO-like drive (disk2, a case-sensitive "Media" volume).
    static func pabloSnapshot() throws -> DriveSnapshot {
        var s = try R6DriveTests.snapshot()
        s.disks = s.disks.filter { ["disk0", "disk2"].contains($0.id) }
        return s
    }

    static func mediaVault() -> VaultVolumeCheck { R6DriveTests.vaultCheck(uuid: R6DriveTests.u(301), mount: "/Volumes/Media") }

    private func states(_ p: Plan) -> [PlanStep.State] { p.steps.map(\.state) }

    // MARK: - The catalog facts the plan relies on

    func testTheBucketsTheItemsAreCountedIn() {
        XCTAssertEqual(StorageCatalog.category("derivedData")?.primaryBucket, .runFromExternal)
        XCTAssertEqual(StorageCatalog.category("archives")?.primaryBucket, .parkExternally, "existing Archives move; new ones run from the drive")
        XCTAssertEqual(StorageCatalog.category("simulatorRuntimeAssets")?.primaryBucket, .parkExternally)
        XCTAssertEqual(StorageCatalog.category("xcodeCaches")?.primaryBucket, .deleteAndRegenerate)
    }

    // MARK: - No drive

    func testWithNoDriveTheFirstStepIsBlockedWithAHint() {
        let p = PlanBuilder.plan(report: Self.report(), drives: [], vaults: [], locations: nil, history: [], findings: [])
        XCTAssertEqual(states(p), [.blocked(.noExternalDrive), .blocked(.needsEarlierStep), .blocked(.needsEarlierStep), .blocked(.needsEarlierStep), .done])
        XCTAssertEqual(p.step(.chooseDrive)?.action, .showDrives)
        XCTAssertNil(p.vaultUUID)
        let move = try? XCTUnwrap(p.step(.moveItems))
        XCTAssertTrue(move?.items.filter { $0.outcome != .deletedRecreated }.allSatisfy { $0.action == nil } ?? false, "nothing can go to a vault yet")
        XCTAssertTrue(move?.items.filter { $0.outcome == .deletedRecreated }.allSatisfy { $0.action == .showBucket(.deleteAndRegenerate) } ?? false)
        XCTAssertNil(p.primaryStepKind, "nothing is next: the first step is blocked")
    }

    func testAnOfflineVaultIsNamed() {
        let offline = R6DriveTests.vaultCheck(state: .absent, mount: nil)
        let p = PlanBuilder.plan(report: Self.report(), drives: [], vaults: [offline], locations: nil, history: [], findings: [])
        XCTAssertEqual(p.step(.chooseDrive)?.state, .blocked(.vaultOffline("Vault")))
    }

    func testDrivesThatCannotHoldAVaultSaySo() throws {
        var s = try R6DriveTests.snapshot()
        s.disks = s.disks.filter { $0.id == "disk7" }  // the Time Machine disk
        let p = PlanBuilder.plan(report: Self.report(), drives: Self.drives(s, vaults: []), vaults: [], locations: nil, history: [], findings: [])
        XCTAssertEqual(p.step(.chooseDrive)?.state, .blocked(.noUsableDrive))
    }

    // MARK: - PABLO: a case-sensitive drive

    func testACaseSensitiveDriveIsPreparedWithItsRecommendedNewVolume() throws {
        let s = try Self.pabloSnapshot()
        let p = PlanBuilder.plan(report: Self.report(), drives: Self.drives(s, vaults: []), vaults: [], locations: nil, history: [], findings: [])
        XCTAssertEqual(p.step(.chooseDrive)?.state, .done)
        let prepare = try XCTUnwrap(p.step(.prepareDrive))
        XCTAssertEqual(prepare.state, .next)
        XCTAssertEqual(prepare.action, .prepareDrive(diskID: "disk2", option: .addVolume(container: "disk3")))
        XCTAssertTrue(prepare.isExperimental, "every drive preparation is experimental (rule 10)")
        XCTAssertEqual(p.step(.registerVault)?.state, .blocked(.needsEarlierStep))
        XCTAssertEqual(p.primaryStepKind, .prepareDrive)
    }

    /// PABLO itself: a registered, usable vault on a case-sensitive volume. The path still goes through the new volume.
    func testARegisteredCaseSensitiveVaultStillGetsItsFixFirst() throws {
        let s = try Self.pabloSnapshot()
        let vaults = [Self.mediaVault()]
        let p = PlanBuilder.plan(report: Self.report(), drives: Self.drives(s, vaults: vaults), vaults: vaults, locations: nil, history: [], findings: [])
        XCTAssertEqual(p.step(.prepareDrive)?.action, .prepareDrive(diskID: "disk2", option: .addVolume(container: "disk3")))
        XCTAssertEqual(p.step(.registerVault)?.state, .blocked(.needsEarlierStep))
        XCTAssertNil(p.vaultUUID, "moves wait for the case-insensitive vault")
    }

    /// After the new volume is added, the prepare step is done and registering that volume is next.
    func testAfterTheNewVolumeRegisteringItIsNext() throws {
        let s = try R7ACoreTests.snapshotWithMadeVolume()
        let vaults = [Self.mediaVault()]
        let p = PlanBuilder.plan(report: Self.report(), drives: Self.drives(s, vaults: vaults), vaults: vaults, locations: nil, history: [], findings: [])
        XCTAssertEqual(p.step(.prepareDrive)?.state, .done)
        XCTAssertEqual(p.step(.registerVault)?.state, .next)
        XCTAssertEqual(p.step(.registerVault)?.action, .useDrive(diskID: "disk2", volumeUUID: R6DriveTests.u(302)))
        XCTAssertEqual(p.step(.registerVault)?.subject, "XCodeVault")
    }

    func testAPlainDriveNeedsNoPreparation() throws {
        var s = try Self.pabloSnapshot()
        s.volumes = s.volumes.map {
            var v = $0; if v.volumeName == "Media" { v.filesystemPersonality = "APFS" }; return v
        }
        let p = PlanBuilder.plan(report: Self.report(), drives: Self.drives(s, vaults: []), vaults: [], locations: nil, history: [], findings: [])
        XCTAssertEqual(p.step(.prepareDrive)?.state, .notNeeded)
        XCTAssertEqual(p.step(.registerVault)?.action, .useDrive(diskID: "disk2", volumeUUID: R6DriveTests.u(301)))
    }

    /// The Plan never proposes an erase: a drive whose only options erase data says to choose in Drives.
    func testAnEraseIsNeverProposed() throws {
        var s = try R6DriveTests.snapshot()
        s.disks = s.disks.filter { $0.id == "disk6" }  // the NTFS stick: erase options only
        let p = PlanBuilder.plan(report: Self.report(), drives: Self.drives(s, vaults: []), vaults: [], locations: nil, history: [], findings: [])
        XCTAssertEqual(p.step(.prepareDrive)?.state, .blocked(.chooseInDrives))
        XCTAssertEqual(p.step(.prepareDrive)?.action, .showDrives)
        for step in p.steps {
            if case .prepareDrive(_, let option)? = step.action { XCTAssertFalse(option.erases, "\(step.kind)") }
        }
    }

    // MARK: - Ready: the moves

    func testWithAGoodVaultEveryItemOpensItsSheetAndTheTotalsCountEachItemOnce() throws {
        let vault = R6DriveTests.vaultCheck()
        let s = try R6DriveTests.snapshot()
        let p = PlanBuilder.plan(report: Self.report(), drives: Self.drives(s, vaults: [vault]), vaults: [vault], locations: nil, history: [], findings: [])
        XCTAssertEqual(states(p), [.done, .notNeeded, .done, .next, .done])
        XCTAssertEqual(p.vaultUUID, vault.volume.volumeUUID)
        let items = try XCTUnwrap(p.step(.moveItems)).items
        let byCategory = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byCategory["runFromExternal:derivedData"]?.outcome, .runsFromDrive)
        XCTAssertEqual(byCategory["runFromExternal:derivedData"]?.action, .run(categoryID: "derivedData", bucket: .runFromExternal))
        XCTAssertEqual(byCategory["runFromExternal:derivedData"]?.warnings, ["derivedDataTests"], "the tests caveat is never hidden")
        XCTAssertEqual(byCategory["runFromExternal:archives"]?.bytes, 0, "new Archives: new data only")
        XCTAssertEqual(byCategory["runFromExternal:archives"]?.action, .run(categoryID: "archives", bucket: .runFromExternal))
        XCTAssertEqual(byCategory["parkExternally:archives"]?.outcome, .movedToDrive)
        XCTAssertEqual(byCategory["parkExternally:archives"]?.action, .run(categoryID: "archives", bucket: .parkExternally))
        XCTAssertEqual(byCategory["parkExternally:simulatorRuntimeAssets"]?.outcome, .leavesAndComesBack)
        XCTAssertEqual(byCategory["deleteAndRegenerate:xcodeCaches"]?.outcome, .deletedRecreated)
        XCTAssertEqual(byCategory["deleteAndRegenerate:xcodeCaches"]?.action, .showBucket(.deleteAndRegenerate))
        XCTAssertFalse(items.contains { $0.outcome == .deletedRecreated && $0.categoryID == "archives" }, "Archives are never deleted (rule 5)")
        // Each item once, in its primary bucket: the same rule as the Overview and the Storage chart.
        XCTAssertEqual(p.summary.upTo, 64 * Self.gb)
        XCTAssertEqual(p.summary.byOutcome[.runsFromDrive], 30 * Self.gb)
        XCTAssertEqual(p.summary.byOutcome[.movedToDrive], 18 * Self.gb)
        XCTAssertEqual(p.summary.byOutcome[.leavesAndComesBack], 10 * Self.gb)
        XCTAssertEqual(p.summary.byOutcome[.deletedRecreated], 6 * Self.gb)
        XCTAssertEqual(p.summary.done, 0)
        XCTAssertEqual(p.primaryStepKind, .moveItems)
    }

    func testDoneItemsAreTheOnesTheStateShowsDone() throws {
        let vault = R6DriveTests.vaultCheck()
        let s = try R6DriveTests.snapshot()
        var r = Self.report()
        // Archives already moved: none left on this Mac, 18 GB on the vault.
        r.items = r.items.filter { $0.categoryID != "archives" } + [Self.item("archives", 18 * Self.gb, mount: "/Volumes/Vault", onBoot: false)]
        let locations = XcodeLocations(derivedData: "/Volumes/Vault/XCodeVault/DerivedData", archives: "/Volumes/Vault/XCodeVault/Archives")
        let parked = JournalTimeline.Row(
            id: "op1", kind: .runtimeOffload, outcome: .completed, started: Date(), summary: "Offload iOS 26.5", endSummary: nil, bytes: 10 * Self.gb,
            recordCount: 2, sequence: 1)
        let p = PlanBuilder.plan(
            report: r, drives: Self.drives(s, vaults: [vault]), vaults: [vault], locations: locations, history: [parked], findings: [])
        let items = try XCTUnwrap(p.step(.moveItems)).items
        XCTAssertEqual(items.first { $0.id == "runFromExternal:derivedData" }?.isDone, true, "Xcode builds on the vault")
        XCTAssertEqual(items.first { $0.id == "runFromExternal:archives" }?.isDone, true)
        XCTAssertEqual(items.first { $0.id == "parkExternally:archives" }?.isDone, true)
        XCTAssertEqual(items.first { $0.id == "parked:op1" }?.isDone, true)
        XCTAssertTrue(items.filter(\.isDone).allSatisfy { $0.action == nil }, "a done item opens nothing")
        XCTAssertEqual(p.summary.done, 18 * Self.gb + 10 * Self.gb)
        XCTAssertEqual(p.summary.byOutcome[.movedToDrive], nil, "nothing left to move")
    }

    func testEverythingDone() throws {
        let vault = R6DriveTests.vaultCheck()
        let s = try R6DriveTests.snapshot()
        var r = Fixtures.minimalReport()
        r.items = [Self.item("archives", 18 * Self.gb, mount: "/Volumes/Vault", onBoot: false)]
        let locations = XcodeLocations(derivedData: "/Volumes/Vault/XCodeVault/DerivedData", archives: "/Volumes/Vault/XCodeVault/Archives")
        let p = PlanBuilder.plan(report: r, drives: Self.drives(s, vaults: [vault]), vaults: [vault], locations: locations, history: [], findings: [])
        XCTAssertEqual(states(p), [.done, .notNeeded, .done, .done, .done])
        XCTAssertEqual(p.summary.upTo, 0)
        XCTAssertNil(p.primaryStepKind)
    }

    func testHealthIsDoneWhenTheLastReadFoundNoWarning() {
        let finding = Finding(
            id: "f", severity: .warning, title: "t", detail: "d", path: nil, remediation: nil, evidence: nil, bytes: nil, parts: nil)
        let info = Finding(id: "i", severity: .info, title: "t", detail: "d", path: nil, remediation: nil, evidence: nil, bytes: nil, parts: nil)
        let warned = PlanBuilder.plan(report: Self.report(), drives: [], vaults: [], locations: nil, history: [], findings: [finding, info])
        XCTAssertEqual(warned.step(.checkHealth)?.state, .next)
        XCTAssertEqual(warned.step(.checkHealth)?.findingCount, 1)
        XCTAssertEqual(warned.step(.checkHealth)?.action, .showHealth)
        let clean = PlanBuilder.plan(report: Self.report(), drives: [], vaults: [], locations: nil, history: [], findings: [info])
        XCTAssertEqual(clean.step(.checkHealth)?.state, .done)
    }

    func testThePlanIsAPureFunction() throws {
        let vault = R6DriveTests.vaultCheck()
        let d = Self.drives(try R6DriveTests.snapshot(), vaults: [vault])
        XCTAssertEqual(
            PlanBuilder.plan(report: Self.report(), drives: d, vaults: [vault], locations: nil, history: [], findings: []),
            PlanBuilder.plan(report: Self.report(), drives: d, vaults: [vault], locations: nil, history: [], findings: []))
    }

    func testTheOutcomeAndActionTables() {
        XCTAssertEqual(PlanBuilder.outcome(categoryID: "derivedData", bucket: .runFromExternal), .runsFromDrive)
        XCTAssertEqual(PlanBuilder.outcome(categoryID: "archives", bucket: .parkExternally), .movedToDrive)
        XCTAssertEqual(PlanBuilder.outcome(categoryID: "simulatorRuntimeAssets", bucket: .parkExternally), .leavesAndComesBack)
        XCTAssertEqual(PlanBuilder.outcome(categoryID: "xcodeCaches", bucket: .deleteAndRegenerate), .deletedRecreated)
        // Every `.run` the Plan offers is a row the planner lists with a command.
        for (id, bucket) in [
            ("derivedData", SavingsBucket.runFromExternal), ("archives", .runFromExternal), ("archives", .parkExternally),
            ("simulatorRuntimeAssets", .parkExternally), ("runtimeLibrary", .runFromExternal),
        ] {
            XCTAssertEqual(PlanBuilder.action(categoryID: id, bucket: bucket), .run(categoryID: id, bucket: bucket))
            XCTAssertNotNil(SavingsPlanner.command(categoryID: id, bucket: bucket), "\(id) \(bucket)")
        }
        XCTAssertEqual(PlanBuilder.action(categoryID: "xcodeCaches", bucket: .deleteAndRegenerate), .showBucket(.deleteAndRegenerate))
        XCTAssertTrue(PlanBuilder.isOnVault("/Volumes/V/XCodeVault/DerivedData", "/Volumes/V"))
        XCTAssertFalse(PlanBuilder.isOnVault("/Volumes/Vault2/x", "/Volumes/V"), "a prefix of the name is not the volume")
        XCTAssertFalse(PlanBuilder.isOnVault(nil, "/Volumes/V"))
    }
}
