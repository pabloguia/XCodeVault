import XCTest
@testable import XCodeVaultCore

/// Regression tests for the migration-safety review findings (2026-09-06).
final class PathSafetyTests: XCTestCase {
    func testCanonicalizationRejectsRelativeComponentsAndResolvesInteriorSymlinks() throws {
        let t = TempDir()
        t.dir("real/Archives/x"); t.symlink("link", to: t.path + "/real")
        XCTAssertThrowsError(try PathSafety.canonicalize(t.path + "/real/Archives/../../etc"))
        XCTAssertThrowsError(try PathSafety.canonicalize("relative/path"))
        XCTAssertEqual(try PathSafety.canonicalize(t.path + "/link/Archives"), try PathSafety.canonicalize(t.path + "/real") + "/Archives")
        XCTAssertTrue(PathSafety.isContained(t.path + "/real/Archives/x", in: t.path + "/real/Archives"))
        XCTAssertTrue(PathSafety.isContained(t.path + "/real/Archives", in: t.path + "/real/Archives"))
        XCTAssertFalse(PathSafety.isContained(t.path + "/real/ArchivesEvil", in: t.path + "/real/Archives"), "prefix without separator must not match")
        XCTAssertFalse(PathSafety.isContained(t.path + "/real/Archives/../Other", in: t.path + "/real/Archives"))
        // A symlink INSIDE the approved tree pointing OUTSIDE is caught because canonicalization resolves the parent.
        t.dir("outside"); t.symlink("real/Archives/escape", to: t.path + "/outside")
        XCTAssertFalse(PathSafety.isContained(t.path + "/real/Archives/escape/file", in: t.path + "/real/Archives"))
    }
}

final class ReviewFixMigrationTests: XCTestCase {
    typealias Fixture = MigrationEngineTests.Fixture

    func testAbortRefusesAfterVerification() throws {
        let f = try Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        let outcome = try engine.copyAndVerify(plan)
        // Simulate a crash during CLEANUP: journal has the CLEANUP phase, source half-deleted.
        try f.journal.record(id: plan.operationID, kind: .migration, state: .started, summary: "CLEANUP", paths: [plan.source, plan.destination], detail: ["phase": "CLEANUP"])
        try FileManager.default.removeItem(atPath: f.archives + "/2026-09-02")
        XCTAssertThrowsError(try engine.abort(operationID: plan.operationID)) { XCTAssertTrue("\($0)".contains("only complete copy"), "\($0)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.plan.destination + "/2026-09-02/B.xcarchive/Info.plist"), "vault copy must survive")
        // Even the VERIFIED phase alone is enough to refuse.
        let plan2 = MigrationPlan(operationID: "op2", direction: .externalize, categoryID: "archives", source: f.archives, destination: f.vaultDir + "/archives/Other", vaultUUID: "VU", sourceBytes: 1, sourceFiles: 1, deepVerify: true, warnings: [])
        try f.journal.record(id: "op2", kind: .migration, state: .planned, summary: "p", paths: [plan2.source, plan2.destination], detail: ["phase": "PLAN"])
        try f.journal.record(id: "op2", kind: .migration, state: .completed, summary: "v", paths: [plan2.source, plan2.destination], detail: ["phase": "VERIFIED"])
        XCTAssertThrowsError(try engine.abort(operationID: "op2"))
    }

    func testRemoveSourceRefusesWhileXcodeRunsAndRestoresOnPostRenameMutation() throws {
        let f = try Fixture()
        var engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        let outcome = try engine.copyAndVerify(plan)
        engine.isXcodeRunning = { true }
        XCTAssertThrowsError(try engine.removeSource(outcome, confirmNonRegenerable: true)) { XCTAssertTrue("\($0)".contains("Xcode.app is running")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives))
        // Mutation after the rename (a write that raced the rename) must fail verification and restore the source.
        engine.isXcodeRunning = { false }
        engine.afterRenameAside = { aside in FileManager.default.createFile(atPath: aside + "/late.xcarchive", contents: Data([1])) }
        XCTAssertThrowsError(try engine.removeSource(outcome, confirmNonRegenerable: true)) { XCTAssertTrue("\($0)".contains("restored"), "\($0)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives + "/late.xcarchive"), "source restored at its original path with the late write intact")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.archives + ".xcodevault-removing-" + String(plan.operationID.prefix(8))))
    }

    func testSourcePathEscapesAreRejected() throws {
        let f = try Fixture()
        let engine = f.engine()
        f.t.dir("home/Documents/Important")
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.archives + "/../../../../Documents/Important", vaultRef: "VU"))
        f.t.symlink("home/Library/Developer/Xcode/Archives/escape", to: f.home + "/Documents/Important")
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.archives + "/escape", vaultRef: "VU"))
        // restore --to must stay inside the category path
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        _ = try engine.copyAndVerify(plan)
        XCTAssertThrowsError(try engine.planRestore(categoryID: "archives", vaultRef: "VU", name: "Archives", to: f.home + "/Documents/Restored"))
        XCTAssertThrowsError(try engine.planRestore(categoryID: "archives", vaultRef: "VU", name: "../..", to: f.archives + "-restored"))
    }

    func testDestinationClaimIsAtomicAndPreexistingDataIsNeverDeleted() throws {
        let f = try Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        // Something appears at the destination between planning and copying (another process, another Mac).
        f.t.file("vault/" + VaultVolume.directoryName + "/archives/Archives/precious", bytes: 3)
        XCTAssertThrowsError(try engine.copyAndVerify(plan)) { XCTAssertTrue("\($0)".contains("appeared since planning"), "\($0)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination + "/precious"), "pre-existing vault data must not be deleted on failure")
    }
}

final class ReviewFixCleanTests: XCTestCase {
    func testExecutorRefusesPathEscapesAndNestedMounts() throws {
        let t = TempDir()
        t.dir("Library/Developer/Xcode/DerivedData"); t.dir("Documents/Secret")
        t.symlink("Library/Developer/Xcode/DerivedData/link", to: t.path + "/Documents/Secret")
        let executor = CleanExecutor(journal: Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl")), home: t.path, isXcodeRunning: { false })
        let escape = CleanAction(categoryID: "derivedData", categoryName: "DD", path: t.path + "/Library/Developer/Xcode/DerivedData/../../../../Documents/Secret", bytes: 1, isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        let viaLink = CleanAction(categoryID: "derivedData", categoryName: "DD", path: t.path + "/Library/Developer/Xcode/DerivedData/link/inner", bytes: 1, isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        t.dir("Documents/Secret/inner")
        let r = try executor.execute(CleanPlan(actions: [escape, viaLink], skipped: [], warnings: []))
        XCTAssertEqual(r.deleted, []); XCTAssertEqual(r.failedPairs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.path + "/Documents/Secret/inner"))
        // Nested mount: attach a tiny disk image inside a DerivedData child and check the planner skips and the executor refuses.
        let img = t.path + "/img.sparseimage"
        let proj = t.dir("Library/Developer/Xcode/DerivedData/Proj-1")
        let mp = t.dir("Library/Developer/Xcode/DerivedData/Proj-1/mount")
        let create = try ProcessCommandRunner().run(Tools.hdiutil, ["create", "-quiet", "-size", "16m", "-fs", "APFS", "-type", "SPARSE", "-volname", "XCVT", img, "-ov"])
        guard create.succeeded, (try ProcessCommandRunner().run(Tools.hdiutil, ["attach", "-quiet", "-nobrowse", "-mountpoint", mp, img])).succeeded else { throw XCTSkip("hdiutil unavailable") }
        defer { _ = try? ProcessCommandRunner().run(Tools.hdiutil, ["detach", "-quiet", mp]) }
        FileManager.default.createFile(atPath: mp + "/on-the-volume", contents: Data([1]))
        let scanner = XCodeVaultCore.Scanner(runner: FakeRunner(responses: [:]), home: t.path, catalog: [StorageCatalog.category("derivedData")!])
        let items = scanner.resolveItems()
        let plan = CleanPlanner(home: t.path).plan(report: ScanReport(generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: HostEnvironment(macOSVersion: "26", macOSBuild: "x", architecture: "arm64", homeDirectory: t.path, dataVolumeFreeBytes: 1, dataVolumeTotalBytes: 2, userName: "t", isRoot: false), xcodes: [], runtimes: [], devices: [], volumes: [], items: items, summary: ScanSummary(), warnings: []))
        XCTAssertFalse(plan.actions.contains { $0.path == proj }, "child containing a mount must not be planned: \(plan.actions.map(\.path))")
        let forced = CleanAction(categoryID: "derivedData", categoryName: "DD", path: proj, bytes: 1, isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        let r2 = try executor.execute(CleanPlan(actions: [forced], skipped: [], warnings: []))
        XCTAssertEqual(r2.deleted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp + "/on-the-volume"), "data on the mounted volume must survive")
    }

    func testDeviceSetsUseSimctl() throws {
        let t = TempDir()
        t.file("Library/Developer/XCTestDevices/UUID/device.plist", bytes: 10)
        let scanner = XCodeVaultCore.Scanner(runner: FakeRunner(responses: [:]), home: t.path, catalog: [StorageCatalog.category("xctestDevices")!])
        let plan = CleanPlanner(home: t.path).plan(report: ScanReport(generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: HostEnvironment(macOSVersion: "26", macOSBuild: "x", architecture: "arm64", homeDirectory: t.path, dataVolumeFreeBytes: 1, dataVolumeTotalBytes: 2, userName: "t", isRoot: false), xcodes: [], runtimes: [], devices: [], volumes: [], items: scanner.resolveItems(), summary: ScanSummary(), warnings: []))
        XCTAssertEqual(plan.actions.map(\.method), [.simctlDeleteAllInDeviceSet])
        let runner = FakeRunner(responses: ["xcrun simctl --set \(t.path)/Library/Developer/XCTestDevices delete all": .init(status: 0, stdout: "", stderr: "")])
        let executor = CleanExecutor(journal: Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl")), home: t.path, isXcodeRunning: { false }, runner: runner)
        let r = try executor.execute(plan)
        XCTAssertEqual(r.deleted.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path + "/Library/Developer/XCTestDevices"))
    }
}

final class ReviewFixLocationsTests: XCTestCase {
    func testRefusesPlainDirectoryUnderVolumes() throws {
        // /Volumes/<name> that is not a mount point ⇒ shadow-data trap ⇒ refuse. We cannot create
        // one without root, so exercise the check through a path whose top component is verifiably
        // not a mount point when such a directory exists; otherwise assert the mount-point rule holds for a real one.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"), let plain = names.first(where: { !MountStatus.isMountPoint("/Volumes/" + $0) && !$0.hasPrefix(".") }) {
            XCTAssertThrowsError(try XcodeLocations.preflightArchives(path: "/Volumes/" + plain, volumes: [], xcodeRunning: false))
        } else {
            throw XCTSkip("no plain directory under /Volumes on this machine")
        }
    }
}
