import XCTest

@testable import XCodeVaultCore

/// R7-C: the guided Plan's steps, a pure function of what the app read (`PlanBuilder.plan`), from fixtures only — the R6
/// drive fixtures, hand-made scan items and journal entries. Nothing reads this Mac's disks, Xcode or journal.
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

    static func plan(
        _ report: ScanReport = report(), drives: [DriveAssessment] = [], vaults: [VaultVolumeCheck] = [], locations: XcodeLocations? = nil,
        parked: [ParkedRuntime] = [], findings: [Finding] = []
    ) -> Plan {
        PlanBuilder.plan(report: report, drives: drives, vaults: vaults, locations: locations, parked: parked, findings: findings)
    }

    static func good() throws -> (DriveAssessment, VaultVolumeCheck, [DriveAssessment]) {
        let vault = R6DriveTests.vaultCheck()
        let drives = Self.drives(try R6DriveTests.snapshot(), vaults: [vault])
        return (try XCTUnwrap(drives.first { $0.vault != nil && $0.vault?.volume.volumeUUID == vault.volume.volumeUUID }), vault, drives)
    }

    static let onVault = XcodeLocations(derivedData: "/Volumes/Vault/XCodeVault/DerivedData", archives: "/Volumes/Vault/XCodeVault/Archives")

    static func entry(_ seq: Int, _ id: String, _ kind: JournalEntry.Kind, paths: [String], detail: [String: String] = [:]) -> JournalEntry {
        JournalEntry(
            id: id, sequence: seq, timestamp: Date(timeIntervalSince1970: Double(seq)), kind: kind, state: .completed, summary: "\(kind)", paths: paths,
            bytes: nil, detail: detail, toolVersion: "t")
    }

    static func offload(_ seq: Int, _ id: String, rid: String = "com.apple.CoreSimulator.SimRuntime.iOS-26-5", build: String = "23F77") -> JournalEntry {
        entry(
            seq, id, .runtimeOffload, paths: ["/Volumes/Vault/XCodeVault/Runtimes/\(build).dmg"],
            detail: [
                "runtimeIdentifier": rid, "build": build, "installer": "/Volumes/Vault/XCodeVault/Runtimes/\(build).dmg",
                "installerSizeBytes": String(10 * gb),
            ])
    }

    private func states(_ p: Plan) -> [PlanStep.State] { p.steps.map(\.state) }
    private func item(_ p: Plan, _ id: String) -> PlanItem? { p.step(.moveItems)?.items.first { $0.id == id } }

    // MARK: - The catalog facts the plan relies on

    func testTheBucketsTheItemsAreCountedIn() {
        XCTAssertEqual(StorageCatalog.category("derivedData")?.primaryBucket, .runFromExternal)
        XCTAssertEqual(StorageCatalog.category("archives")?.primaryBucket, .parkExternally, "existing Archives move; new ones run from the drive")
        XCTAssertEqual(StorageCatalog.category("simulatorRuntimeAssets")?.primaryBucket, .parkExternally)
        XCTAssertEqual(StorageCatalog.category("xcodeCaches")?.primaryBucket, .deleteAndRegenerate)
        XCTAssertEqual(StorageCatalog.category("simulatorDevices")?.primaryBucket, .deleteAndRegenerate)
        XCTAssertEqual(StorageCatalog.category("simulatorDevices")?.savingsOptionDetails.first?.losesUserData, true)
        XCTAssertNotNil(StorageCatalog.category("derivedData")?.savingsOptionDetails.first { $0.bucket == .deleteAndRegenerate })
    }

    // MARK: - No drive

    func testWithNoDriveTheFirstStepIsBlockedAndDeletingIsPartlyAvailable() {
        let p = Self.plan()
        XCTAssertEqual(states(p), [.blocked(.noExternalDrive), .blocked(.needsEarlierStep), .blocked(.needsEarlierStep), .partly, .done])
        XCTAssertEqual(p.step(.chooseDrive)?.action, .showDrives)
        XCTAssertNil(p.vaultUUID)
        let items = p.step(.moveItems)?.items ?? []
        XCTAssertTrue(
            items.filter { $0.outcome != .deletedRebuilt && $0.outcome != .deletedLost }.allSatisfy { $0.action == nil }, "nothing can go to a vault yet")
        XCTAssertTrue(items.filter { $0.outcome == .deletedRebuilt }.allSatisfy { $0.action == .showBucket(.deleteAndRegenerate) })
        XCTAssertNil(p.step(.moveItems)?.action, "the move step has no button of its own")
        XCTAssertEqual(p.primary, .item("deleteAndRegenerate:derivedData"), "the first thing that can be done now")
        XCTAssertTrue(p.hasSomethingToDo)
    }

    func testNothingInTheMoveStepAndNoDriveIsBlocked() {
        var r = Fixtures.minimalReport()
        r.items = [Self.item("archives", 18 * Self.gb)]
        let p = Self.plan(r)
        XCTAssertEqual(p.step(.moveItems)?.state, .blocked(.needsEarlierStep))
        XCTAssertFalse(p.hasSomethingToDo)
        XCTAssertNil(p.primary)
    }

    // MARK: - F4: an unusable vault says why

    func testAnOfflineVaultIsNamed() {
        let p = Self.plan(vaults: [R6DriveTests.vaultCheck(state: .absent, mount: nil)])
        XCTAssertEqual(p.step(.chooseDrive)?.state, .blocked(.vaultOffline("Vault")))
        XCTAssertEqual(p.step(.chooseDrive)?.action, .showDrives)
    }

    func testShadowDataAtTheVaultsMountPointIsReportedWithItsSize() throws {
        var shadowed = R6DriveTests.vaultCheck(state: .ambiguous, mount: nil)
        shadowed.shadowBytes = 3 * Self.gb
        // Even with a usable drive connected, the shadow is what step 1 reports (rule 6).
        let drives = Self.drives(try Self.pabloSnapshot(), vaults: [shadowed])
        let p = Self.plan(drives: drives, vaults: [shadowed])
        XCTAssertEqual(p.step(.chooseDrive)?.state, .blocked(.vaultShadowed(name: "Vault", bytes: 3 * Self.gb)))
        XCTAssertEqual(p.step(.chooseDrive)?.action, .showHealth)
        XCTAssertEqual(p.step(.prepareDrive)?.state, .blocked(.needsEarlierStep))
        XCTAssertEqual(p.step(.registerVault)?.state, .blocked(.needsEarlierStep))
    }

    func testADifferentVolumeAtTheVaultsPathIsNamed() {
        for state in [VaultVolumeState.foreign, .sentinelMissing] {
            let p = Self.plan(vaults: [R6DriveTests.vaultCheck(state: state, mount: "/Volumes/Vault")])
            XCTAssertEqual(p.step(.chooseDrive)?.state, .blocked(.vaultReplaced("Vault")), "\(state)")
            XCTAssertEqual(p.step(.chooseDrive)?.action, .showDrives)
        }
    }

    func testDrivesThatCannotHoldAVaultSaySo() throws {
        var s = try R6DriveTests.snapshot()
        s.disks = s.disks.filter { $0.id == "disk7" }  // the Time Machine disk
        let p = Self.plan(drives: Self.drives(s, vaults: []))
        XCTAssertEqual(p.step(.chooseDrive)?.state, .blocked(.noUsableDrive))
    }

    // MARK: - PABLO: a case-sensitive drive

    func testACaseSensitiveDriveIsPreparedWithItsRecommendedNewVolume() throws {
        let p = Self.plan(drives: Self.drives(try Self.pabloSnapshot(), vaults: []))
        XCTAssertEqual(p.step(.chooseDrive)?.state, .done)
        XCTAssertNil(p.step(.chooseDrive)?.note)
        let prepare = try XCTUnwrap(p.step(.prepareDrive))
        XCTAssertEqual(prepare.state, .next)
        XCTAssertEqual(prepare.action, .prepareDrive(diskID: "disk2", option: .addVolume(container: "disk3")))
        XCTAssertTrue(prepare.isExperimental, "every drive preparation is experimental (rule 10)")
        XCTAssertEqual(p.step(.registerVault)?.state, .blocked(.addVolumeFirst))
        XCTAssertEqual(p.primary, .step(.prepareDrive))
    }

    /// PABLO itself: a registered, usable vault on a case-sensitive volume. Step 1 says so; the path goes through the new
    /// volume; nothing moves until it is registered.
    func testARegisteredCaseSensitiveVaultStillGetsItsFixFirst() throws {
        let vaults = [Self.mediaVault()]
        let p = Self.plan(drives: Self.drives(try Self.pabloSnapshot(), vaults: vaults), vaults: vaults)
        XCTAssertEqual(p.step(.chooseDrive)?.note, .vaultNeedsVolume(drive: "Media"))
        XCTAssertEqual(p.step(.prepareDrive)?.action, .prepareDrive(diskID: "disk2", option: .addVolume(container: "disk3")))
        XCTAssertEqual(p.step(.registerVault)?.state, .blocked(.addVolumeFirst))
        XCTAssertNil(p.vaultUUID, "moves wait for the case-insensitive vault")
    }

    /// After the new volume is added, the prepare step is done — saying what is there — and registering it is next.
    func testAfterTheNewVolumeRegisteringItIsNext() throws {
        let s = try R7ACoreTests.snapshotWithMadeVolume()
        let vaults = [Self.mediaVault()]
        let p = Self.plan(drives: Self.drives(s, vaults: vaults), vaults: vaults)
        XCTAssertEqual(p.step(.prepareDrive)?.state, .done)
        XCTAssertEqual(p.step(.prepareDrive)?.note, .suitableVolume(drive: "Media", volume: "XCodeVault"))
        XCTAssertEqual(p.step(.registerVault)?.state, .next)
        XCTAssertEqual(p.step(.registerVault)?.action, .useDrive(diskID: "disk2", volumeUUID: R6DriveTests.u(302)))
        XCTAssertEqual(p.step(.registerVault)?.subject, "XCodeVault")
    }

    /// A drive that needs no fix is "not needed", never "done": the step claims no work that was not done.
    func testAPlainDriveNeedsNoPreparation() throws {
        var s = try Self.pabloSnapshot()
        s.volumes = s.volumes.map {
            var v = $0
            if v.volumeName == "Media" { v.filesystemPersonality = "APFS" }
            return v
        }
        let p = Self.plan(drives: Self.drives(s, vaults: []))
        XCTAssertEqual(p.step(.prepareDrive)?.state, .notNeeded)
        XCTAssertNil(p.step(.prepareDrive)?.note)
        XCTAssertEqual(p.step(.registerVault)?.action, .useDrive(diskID: "disk2", volumeUUID: R6DriveTests.u(301)))
    }

    /// The Plan never proposes an erase: a drive whose only options erase data says to choose in Drives.
    func testAnEraseIsNeverProposed() throws {
        var s = try R6DriveTests.snapshot()
        s.disks = s.disks.filter { $0.id == "disk6" }  // the NTFS stick: erase options only
        let p = Self.plan(drives: Self.drives(s, vaults: []))
        XCTAssertEqual(p.step(.prepareDrive)?.state, .blocked(.chooseInDrives))
        XCTAssertEqual(p.step(.prepareDrive)?.action, .showDrives)
        for step in p.steps {
            if case .prepareDrive(_, let option)? = step.action { XCTAssertFalse(option.erases, "\(step.kind)") }
        }
    }

    // MARK: - Ready: the moves, counted once (F2/I1)

    func testWithAGoodVaultEveryItemOpensItsSheetAndTheTotalsCountEachItemOnce() throws {
        let (_, vault, drives) = try Self.good()
        let p = Self.plan(drives: drives, vaults: [vault])
        XCTAssertEqual(states(p), [.done, .notNeeded, .done, .next, .done])
        XCTAssertEqual(p.vaultUUID, vault.volume.volumeUUID)
        let newBuilds = try XCTUnwrap(item(p, "runFromExternal:derivedData"))
        XCTAssertEqual(newBuilds.name, .newDerivedData)
        XCTAssertEqual(newBuilds.bytes, 0, "new builds: the location moves, no byte here is freed by it")
        XCTAssertEqual(newBuilds.outcome, .runsFromDrive)
        XCTAssertEqual(newBuilds.action, .run(categoryID: "derivedData", bucket: .runFromExternal))
        XCTAssertEqual(newBuilds.warnings, ["derivedDataTests"], "the tests caveat is never hidden")
        let old = try XCTUnwrap(item(p, "deleteAndRegenerate:derivedData"))
        XCTAssertEqual(old.name, .oldDerivedData)
        XCTAssertEqual(old.bytes, 30 * Self.gb)
        XCTAssertEqual(old.outcome, .deletedRebuilt)
        XCTAssertEqual(old.action, .showBucket(.deleteAndRegenerate), "the existing Delete flow")
        XCTAssertEqual(item(p, "runFromExternal:archives")?.name, .newArchives)
        XCTAssertEqual(item(p, "runFromExternal:archives")?.bytes, 0)
        XCTAssertEqual(item(p, "parkExternally:archives")?.name, .existingArchives)
        XCTAssertEqual(item(p, "parkExternally:archives")?.outcome, .movedToDrive)
        XCTAssertEqual(item(p, "parkExternally:archives")?.action, .run(categoryID: "archives", bucket: .parkExternally))
        XCTAssertEqual(item(p, "parkExternally:simulatorRuntimeAssets")?.outcome, .parkedOnDrive)
        XCTAssertEqual(item(p, "deleteAndRegenerate:xcodeCaches")?.outcome, .deletedRebuilt)
        let items = try XCTUnwrap(p.step(.moveItems)).items
        XCTAssertFalse(items.contains { ($0.outcome == .deletedRebuilt || $0.outcome == .deletedLost) && $0.name == .existingArchives })
        XCTAssertFalse(items.contains { $0.id == "deleteAndRegenerate:archives" }, "Archives are never deleted (rule 5)")
        // Each byte once: the scan's 64 GB, DerivedData's 30 under deleted (the only thing that frees it), not twice.
        XCTAssertEqual(p.summary.upTo, 64 * Self.gb)
        XCTAssertEqual(p.summary.byOutcome[.runsFromDrive], nil, "new data frees nothing now")
        XCTAssertEqual(p.summary.byOutcome[.movedToDrive], 18 * Self.gb)
        XCTAssertEqual(p.summary.byOutcome[.parkedOnDrive], 10 * Self.gb)
        XCTAssertEqual(p.summary.byOutcome[.deletedRebuilt], 36 * Self.gb)
        XCTAssertEqual(p.summary.byOutcome.values.reduce(0, +), p.summary.upTo, "the breakdown adds up to the headline")
        XCTAssertEqual(p.summary.lostIfDeleted, 0)
        XCTAssertEqual(p.summary.done, 0)
        XCTAssertEqual(p.primary, .item("runFromExternal:derivedData"), "the move step has no button: its first item's")
    }

    // MARK: - F1: data the user made is never "recreated on demand"

    func testSimulatorDevicesAreLostNotRecreatedAndNotInTheHeadline() throws {
        let (_, vault, drives) = try Self.good()
        let p = Self.plan(Self.report([Self.item("simulatorDevices", 7 * Self.gb)]), drives: drives, vaults: [vault])
        let devices = try XCTUnwrap(item(p, "deleteAndRegenerate:simulatorDevices"))
        XCTAssertEqual(devices.outcome, .deletedLost)
        XCTAssertTrue(devices.losesUserData)
        XCTAssertEqual(devices.action, .showBucket(.deleteAndRegenerate))
        XCTAssertEqual(p.summary.upTo, 64 * Self.gb, "not in the headline")
        XCTAssertEqual(p.summary.lostIfDeleted, 7 * Self.gb, "its own line")
        XCTAssertNil(p.summary.byOutcome[.deletedLost])
        XCTAssertEqual(p.step(.moveItems)?.bytes, 64 * Self.gb)
        XCTAssertFalse(
            p.step(.moveItems)!.items.contains { $0.losesUserData && $0.outcome == .deletedRebuilt }, "nothing that loses data is 'rebuilt on demand'")
    }

    // MARK: - N1: data the user would lose never drives the Plan

    func testOnlySimulatorDevicesLeftIsDoneAndNothingToDo() throws {
        let (_, vault, drives) = try Self.good()
        var r = Fixtures.minimalReport()
        r.items = [Self.item("archives", 18 * Self.gb, mount: "/Volumes/Vault", onBoot: false), Self.item("simulatorDevices", 7 * Self.gb)]
        let p = Self.plan(r, drives: drives, vaults: [vault], locations: Self.onVault)
        XCTAssertEqual(p.step(.moveItems)?.state, .done, "only data the user would lose is left")
        XCTAssertEqual(item(p, "deleteAndRegenerate:simulatorDevices")?.action, .showBucket(.deleteAndRegenerate), "still listed, with Review")
        XCTAssertNil(p.primary)
        XCTAssertFalse(p.hasSomethingToDo)
        XCTAssertEqual(p.summary.lostIfDeleted, 7 * Self.gb)
    }

    func testSimulatorDevicesAreNeverThePrimaryEvenWhenFirst() {
        var r = Fixtures.minimalReport()
        r.items = [Self.item("simulatorDevices", 50 * Self.gb), Self.item("xcodeCaches", 1 * Self.gb)]
        let p = Self.plan(r)
        let deletable = p.step(.moveItems)?.items.filter { $0.action != nil }.map(\.id)
        XCTAssertEqual(deletable?.first, "deleteAndRegenerate:simulatorDevices", "the largest deletable item comes first")
        XCTAssertEqual(p.step(.moveItems)?.state, .partly)
        XCTAssertEqual(p.primary, .item("deleteAndRegenerate:xcodeCaches"), "the next thing to do is never losing the user's data")
        var onlyDevices = Fixtures.minimalReport()
        onlyDevices.items = [Self.item("simulatorDevices", 50 * Self.gb)]
        let q = Self.plan(onlyDevices)
        XCTAssertEqual(q.step(.moveItems)?.state, .blocked(.needsEarlierStep))
        XCTAssertNil(q.primary)
    }

    /// N5: the "Another … if you also delete simulator devices" line names one category. A second category that loses the
    /// user's data must make someone review that wording: this test fails until it is updated.
    func testExactlyOneCategoryLosesUserDataWhenDeleted() {
        let losing = StorageCatalog.all.filter { c in c.savingsOptionDetails.contains { $0.bucket == .deleteAndRegenerate && $0.losesUserData } }
        XCTAssertEqual(losing.map(\.id), ["simulatorDevices"], "review app.guide.summary.lost before adding another")
    }

    // MARK: - N3: shadow data on another vault

    func testShadowDataOnAnotherVaultIsANoteOnStepOne() throws {
        let (_, vault, drives) = try Self.good()
        var shadowed = R6DriveTests.vaultCheck(uuid: R6DriveTests.u(901), state: .ambiguous, mount: nil)
        shadowed.volume.volumeName = "Old"
        shadowed.shadowBytes = 2 * Self.gb
        let p = Self.plan(drives: drives, vaults: [vault, shadowed])
        XCTAssertEqual(p.step(.chooseDrive)?.state, .done, "not blocking: the good vault still works")
        XCTAssertEqual(p.step(.chooseDrive)?.note, .otherVaultShadowed(name: "Old", bytes: 2 * Self.gb))
        XCTAssertEqual(p.vaultUUID, vault.volume.volumeUUID)
    }

    // MARK: - Done from state

    func testDoneItemsAreTheOnesTheStateShowsDone() throws {
        let (_, vault, drives) = try Self.good()
        var r = Self.report()
        // Archives already moved, DerivedData deleted after new builds went to the vault.
        r.items =
            r.items.filter { $0.categoryID != "archives" && $0.categoryID != "derivedData" } + [
                Self.item("archives", 18 * Self.gb, mount: "/Volumes/Vault", onBoot: false)
            ]
        let parked = ParkedRuntimes.current([Self.offload(1, "op1")], installed: [])
        let p = Self.plan(r, drives: drives, vaults: [vault], locations: Self.onVault, parked: parked)
        XCTAssertEqual(item(p, "runFromExternal:derivedData")?.isDone, true, "Xcode builds on the vault")
        XCTAssertEqual(item(p, "deleteAndRegenerate:derivedData")?.isDone, true, "no old DerivedData left here")
        XCTAssertEqual(item(p, "runFromExternal:archives")?.isDone, true)
        XCTAssertEqual(item(p, "parkExternally:archives")?.isDone, true)
        XCTAssertEqual(item(p, "parked:op1")?.isDone, true)
        XCTAssertEqual(item(p, "parked:op1")?.name, .parkedRuntime("iOS 26.5 (23F77)"))
        let items = try XCTUnwrap(p.step(.moveItems)).items
        XCTAssertTrue(items.filter(\.isDone).allSatisfy { $0.action == nil }, "a done item opens nothing")
        XCTAssertEqual(p.summary.done, 18 * Self.gb + 10 * Self.gb)
        XCTAssertNil(p.summary.byOutcome[.movedToDrive], "nothing left to move")
    }

    func testOldDerivedDataIsOpenUntilItsBytesAreGone() throws {
        let (_, vault, drives) = try Self.good()
        let p = Self.plan(drives: drives, vaults: [vault], locations: Self.onVault)
        XCTAssertEqual(item(p, "runFromExternal:derivedData")?.isDone, true)
        XCTAssertEqual(item(p, "deleteAndRegenerate:derivedData")?.isDone, false, "the location moved new builds only")
        XCTAssertEqual(item(p, "deleteAndRegenerate:derivedData")?.bytes, 30 * Self.gb)
    }

    func testEverythingDone() throws {
        let (_, vault, drives) = try Self.good()
        var r = Fixtures.minimalReport()
        r.items = [Self.item("archives", 18 * Self.gb, mount: "/Volumes/Vault", onBoot: false)]
        let p = Self.plan(r, drives: drives, vaults: [vault], locations: Self.onVault)
        XCTAssertEqual(states(p), [.done, .notNeeded, .done, .done, .done])
        XCTAssertEqual(p.summary.upTo, 0)
        XCTAssertNil(p.primary)
        XCTAssertFalse(p.hasSomethingToDo)
    }

    // MARK: - F3: parked runtimes from the whole journal

    func testAnOffloadOlderThanHistorysWindowStillCounts() {
        // 150 other operations after it: History's newest 100 rows would not have it.
        var entries = [Self.offload(1, "old")]
        for i in 2...151 { entries.append(Self.entry(i, "c\(i)", .clean, paths: [])) }
        let parked = ParkedRuntimes.current(entries, installed: [])
        XCTAssertEqual(parked.map(\.operationID), ["old"])
        XCTAssertEqual(parked.first?.bytes, 10 * Self.gb)
    }

    func testAnImportBringsAParkedRuntimeBack() {
        let offload = Self.offload(1, "op1")
        let installer = offload.detail["installer"]!
        XCTAssertEqual(ParkedRuntimes.current([offload, Self.entry(2, "imp", .runtimeImport, paths: [installer])], installed: []), [])
        // An import from inside an exported bundle at that path counts too.
        var bundle = Self.offload(3, "op3", build: "23G1")
        bundle.detail["installer"] = "/Volumes/Vault/XCodeVault/Runtimes/iOS_26.5_23G1.exportedBundle"
        let inner = "/Volumes/Vault/XCodeVault/Runtimes/iOS_26.5_23G1.exportedBundle/Restore/x.dmg"
        XCTAssertEqual(ParkedRuntimes.current([bundle, Self.entry(4, "imp2", .runtimeImport, paths: [inner])], installed: []), [])
        // An import before the offload does not cancel it.
        XCTAssertEqual(ParkedRuntimes.current([Self.entry(0, "imp", .runtimeImport, paths: [installer]), offload], installed: []).count, 1)
    }

    func testARuntimeTheScanShowsInstalledAgainIsNotParked() {
        let installed = SimulatorRuntime(
            identifier: "R1", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", platformIdentifier: nil, version: "26.5", build: "23F77",
            state: "Ready")
        XCTAssertEqual(ParkedRuntimes.current([Self.offload(1, "op1")], installed: [installed]), [])
        var other = installed
        other.build = "23G1"
        XCTAssertEqual(ParkedRuntimes.current([Self.offload(1, "op1")], installed: [other]).count, 1, "another build of the same runtime")
    }

    func testEachRuntimeIsCountedOnce() {
        let parked = ParkedRuntimes.current([Self.offload(1, "a"), Self.offload(2, "b"), Self.offload(3, "c", build: "23G1")], installed: [])
        XCTAssertEqual(parked.map(\.operationID), ["b", "c"], "a second offload of the same runtime replaces the first")
        let p = Self.plan(parked: parked)
        XCTAssertEqual(p.summary.done, 20 * Self.gb)
    }

    func testFailedOrExportOnlyEntriesParkNothing() {
        var failed = Self.offload(1, "f")
        failed.state = .failed
        XCTAssertEqual(ParkedRuntimes.current([failed, Self.entry(2, "e", .runtimeExport, paths: ["/Volumes/Vault/x"])], installed: []), [])
    }

    func testTheRuntimesName() {
        XCTAssertEqual(
            ParkedRuntimes.name(rid: "com.apple.CoreSimulator.SimRuntime.watchOS-11-5", version: nil, build: "22T572", installer: "/x"), "watchOS 11.5 (22T572)"
        )
        XCTAssertEqual(ParkedRuntimes.name(rid: nil, version: nil, build: nil, installer: "/v/iOS_26.dmg"), "iOS_26.dmg")
    }

    // MARK: - Health, purity, tables

    func testHealthIsDoneWhenTheLastReadFoundNoWarning() {
        let finding = Finding(id: "f", severity: .warning, title: "t", detail: "d", path: nil, remediation: nil, evidence: nil, bytes: nil, parts: nil)
        let info = Finding(id: "i", severity: .info, title: "t", detail: "d", path: nil, remediation: nil, evidence: nil, bytes: nil, parts: nil)
        let warned = Self.plan(findings: [finding, info])
        XCTAssertEqual(warned.step(.checkHealth)?.state, .next)
        XCTAssertEqual(warned.step(.checkHealth)?.findingCount, 1)
        XCTAssertEqual(warned.step(.checkHealth)?.action, .showHealth)
        XCTAssertEqual(Self.plan(findings: [info]).step(.checkHealth)?.state, .done)
    }

    func testThePlanIsAPureFunction() throws {
        let (_, vault, drives) = try Self.good()
        XCTAssertEqual(Self.plan(drives: drives, vaults: [vault]), Self.plan(drives: drives, vaults: [vault]))
    }

    func testTheOutcomeAndActionTables() {
        XCTAssertEqual(PlanBuilder.outcome(categoryID: "derivedData", bucket: .runFromExternal), .runsFromDrive)
        XCTAssertEqual(PlanBuilder.outcome(categoryID: "archives", bucket: .parkExternally), .movedToDrive)
        XCTAssertEqual(PlanBuilder.outcome(categoryID: "simulatorRuntimeAssets", bucket: .parkExternally), .parkedOnDrive)
        XCTAssertEqual(PlanBuilder.outcome(categoryID: "xcodeCaches", bucket: .deleteAndRegenerate), .deletedRebuilt)
        XCTAssertEqual(PlanBuilder.outcome(categoryID: "simulatorDevices", bucket: .deleteAndRegenerate, losesUserData: true), .deletedLost)
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
