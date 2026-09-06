import XCTest

@testable import XCodeVaultCore

final class JournalTests: XCTestCase {
    func testAppendReadAndInterrupted() throws {
        let t = TempDir()
        let j = Journal(url: URL(fileURLWithPath: t.path + "/nested/journal.jsonl"))
        let a = try j.record(id: "op-a", kind: .clean, state: .planned, summary: "plan")
        _ = try j.record(id: "op-a", kind: .clean, state: .started, summary: "start", paths: ["/x"])
        _ = try j.record(id: "op-b", kind: .runtimeDelete, state: .started, summary: "del")
        _ = try j.record(id: "op-b", kind: .runtimeDelete, state: .completed, summary: "done")
        let all = try j.entries()
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(a.sequence, 1)
        let interrupted = try j.interrupted()
        XCTAssertEqual(interrupted.map(\.id), ["op-a"])
        XCTAssertEqual(try Journal(url: URL(fileURLWithPath: t.path + "/missing.jsonl")).entries(), [])
    }
}

final class CleanTests: XCTestCase {
    private func report(home: String, items: [StorageItem]) -> ScanReport {
        let host = HostEnvironment(
            macOSVersion: "26.6", macOSBuild: "x", architecture: "arm64", homeDirectory: home,
            dataVolumeFreeBytes: 1, dataVolumeTotalBytes: 2, userName: "t", isRoot: false)
        return ScanReport(
            generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: host, xcodes: [], runtimes: [],
            devices: [], volumes: [], items: items, summary: ScanSummary(), warnings: [])
    }

    func testPlanIsGranularForDerivedDataAndSkipsSymlinksAndArchives() throws {
        let t = TempDir()
        t.file("Library/Developer/Xcode/DerivedData/ProjA-abc/Build/a.o", bytes: 8192)
        t.file("Library/Developer/Xcode/DerivedData/ProjB-def/Index/b", bytes: 4096)
        t.file("Library/Developer/Xcode/Archives/2026/x.xcarchive/Info.plist", bytes: 10)
        t.dir("elsewhere"); t.symlink("Library/Developer/Xcode/UserData/Previews/Simulator Devices", to: t.path + "/elsewhere")
        let scanner = XCodeVaultCore.Scanner(
            runner: FakeRunner(responses: [:]), home: t.path,
            catalog: ["derivedData", "archives", "previews"].compactMap(StorageCatalog.category))
        let items = scanner.resolveItems()
        let plan = CleanPlanner(home: t.path).plan(report: report(home: t.path, items: items))
        XCTAssertEqual(plan.actions.count, 2, "\(plan.actions.map(\.path))")
        XCTAssertTrue(plan.actions.allSatisfy { $0.categoryID == "derivedData" })
        XCTAssertTrue(plan.actions.contains { $0.path.hasSuffix("ProjA-abc") })
        XCTAssertFalse(plan.actions.contains { $0.path.contains("Archives") }, "archives are never cleaned")
        XCTAssertTrue(plan.skipped.contains { $0.contains("Previews") && $0.contains("symlink") })
        let devs = XCodeVaultCore.Scanner(runner: FakeRunner(responses: [:]), home: t.path, catalog: [StorageCatalog.category("simulatorDevices")!])
        t.file("Library/Developer/CoreSimulator/Devices/UUID/data/x", bytes: 4096)
        let devPlan = CleanPlanner(home: t.path).plan(report: report(home: t.path, items: devs.resolveItems()))
        XCTAssertTrue(devPlan.actions.isEmpty, "simulator devices are never filesystem-deleted")
        XCTAssertTrue(devPlan.skipped.contains { $0.contains("simctl delete unavailable") })
        XCTAssertGreaterThanOrEqual(plan.totalBytes, 12288)
        XCTAssertTrue(plan.warnings.contains { $0.contains("full build") })
    }

    func testPlanFiltersByCategoryAndListsRootActionsSeparately() throws {
        let t = TempDir()
        t.file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A123)/Symbols/x", bytes: 4096)
        t.file("Library/Caches/com.apple.dt.Xcode/y", bytes: 4096)
        let cat = ["deviceSupport", "xcodeCaches"].compactMap(StorageCatalog.category)
        var items = XCodeVaultCore.Scanner(runner: FakeRunner(responses: [:]), home: t.path, catalog: cat).resolveItems()
        // Pretend the root-owned dyld cache exists with a size.
        items.append(
            StorageItem(
                categoryID: "coreSimulatorSystemCaches", path: "/Library/Developer/CoreSimulator/Caches/dyld", exists: true,
                isSymlink: false, symlinkTarget: nil, isMountPoint: false,
                usage: DiskUsage(
                    allocatedBytes: 999, logicalBytes: 999, fileCount: 1, directoryCount: 1, symlinkCount: 0, skippedMountPoints: [], unreadable: []),
                volumeMountPoint: "/System/Volumes/Data", onBootVolume: true))
        let all = CleanPlanner(home: t.path).plan(report: report(home: t.path, items: items))
        XCTAssertEqual(all.rootActions.map(\.categoryID), ["coreSimulatorSystemCaches"])
        XCTAssertEqual(Set(all.userActions.map(\.categoryID)), ["deviceSupport", "xcodeCaches"])
        XCTAssertTrue(all.userActions.contains { $0.path.hasSuffix("17.0 (21A123)") }, "device support is per OS build")
        let only = CleanPlanner(home: t.path).plan(report: report(home: t.path, items: items), categories: ["xcodeCaches"])
        XCTAssertEqual(only.actions.map(\.categoryID), ["xcodeCaches"])
    }

    func testExecutorDeletesJournalsAndRefusesUnsafeActions() throws {
        let t = TempDir()
        let dd = t.file("Library/Developer/Xcode/DerivedData/ProjA-abc/Build/a.o", bytes: 4096)
        let ddDir = (dd as NSString).deletingLastPathComponent.replacingOccurrences(of: "/Build", with: "")
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/journal.jsonl"))
        let executor = CleanExecutor(journal: journal, home: t.path, useTrash: false, isXcodeRunning: { false })
        let good = CleanAction(
            categoryID: "derivedData", categoryName: "DerivedData", path: ddDir, bytes: 4096, isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        let outside = CleanAction(
            categoryID: "derivedData", categoryName: "DerivedData", path: t.dir("not-derived-data"), bytes: 1, isExperimental: true, risk: .low,
            requiresRoot: false, notes: [])
        let protected = CleanAction(
            categoryID: "simulatorDevices", categoryName: "x", path: t.dir("Library/Developer/CoreSimulator"), bytes: 1, isExperimental: true, risk: .low,
            requiresRoot: false, notes: [])
        let result = try executor.execute(CleanPlan(actions: [good, outside, protected], skipped: [], warnings: []))
        XCTAssertEqual(result.deleted.map(\.path), [ddDir])
        XCTAssertEqual(result.failedPairs.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ddDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.path + "/not-derived-data"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.path + "/Library/Developer/CoreSimulator"))
        let states = try journal.entries().map(\.state)
        XCTAssertEqual(states.first, .planned); XCTAssertEqual(states.last, .completed)
        XCTAssertTrue(states.contains(.failed))
    }

    func testExecutorRefusesDerivedDataWhileXcodeRuns() throws {
        let t = TempDir()
        let dd = t.dir("Library/Developer/Xcode/DerivedData/P-1")
        let executor = CleanExecutor(journal: Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl")), home: t.path, isXcodeRunning: { true })
        let a = CleanAction(
            categoryID: "derivedData", categoryName: "DerivedData", path: dd, bytes: 1, isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        XCTAssertThrowsError(try executor.execute(CleanPlan(actions: [a], skipped: [], warnings: [])))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dd))
        XCTAssertNoThrow(try executor.execute(CleanPlan(actions: [a], skipped: [], warnings: []), force: true))
    }
}

final class RuntimeOperationsTests: XCTestCase {
    private var xcode26: XcodeInstallation {
        var c = XcodeCapabilities.parse(xcodebuildHelp: Fixtures.string("xcodebuild-help-xcode26.5.txt"))
        c.apply(simctlRuntimeHelp: Fixtures.string("simctl-runtime-help-xcode26.5.txt"))
        return XcodeInstallation(
            path: "/Applications/Xcode.app", developerDirectory: "/Applications/Xcode.app/Contents/Developer", version: "26.5", build: "17F42",
            isSelected: true, capabilities: c)
    }
    private func host(free: UInt64, arm: Bool) -> HostEnvironment {
        HostEnvironment(
            macOSVersion: "26.6", macOSBuild: "x", architecture: arm ? "arm64" : "x86_64", homeDirectory: "/tmp", dataVolumeFreeBytes: free,
            dataVolumeTotalBytes: 500_000_000_000, userName: "t", isRoot: false)
    }

    func testInstallerNameParsing() {
        let p = RuntimeInstaller.parse(fileName: "iOS 26.5 Simulator Runtime.dmg")
        XCTAssertEqual(p.platform, "iOS"); XCTAssertEqual(p.version, "26.5")
        let q = RuntimeInstaller.parse(fileName: "watchOS_11.2_23S123_Simulator_Runtime.dmg")
        XCTAssertEqual(q.platform, "watchOS"); XCTAssertEqual(q.version, "11.2"); XCTAssertEqual(q.build, "23S123")
        XCTAssertNil(RuntimeInstaller.parse(fileName: "random.dmg").platform)
    }

    func testLibraryListingAndMatching() throws {
        let t = TempDir()
        t.file("iOS 26.5 Simulator Runtime.dmg", bytes: 600_000_000)
        t.file("notes.txt", bytes: 3)
        t.file("tvOS 26.0 Simulator Runtime.dmg", bytes: 10)  // too small to be real
        t.file("appletvsimulator_26.5_23L470.exportedBundle/Restore/AppleTVOSSimulatorRuntime_Cryptex.dmg", bytes: 600_000_000)
        t.file("appletvsimulator_26.5_23L470.exportedBundle/ExportedMetadata.plist", bytes: 10)
        let lib = try RuntimeOperations.library(at: t.path)
        XCTAssertEqual(lib.map(\.fileName).sorted(), ["appletvsimulator_26.5_23L470.exportedBundle", "iOS 26.5 Simulator Runtime.dmg", "tvOS 26.0 Simulator Runtime.dmg"])
        let bundle = lib.first { $0.fileName.hasSuffix(".exportedBundle") }!
        XCTAssertEqual(bundle.platform, "tvOS"); XCTAssertEqual(bundle.version, "26.5"); XCTAssertEqual(bundle.build, "23L470")
        XCTAssertTrue(bundle.path.hasSuffix("/Restore/AppleTVOSSimulatorRuntime_Cryptex.dmg"))
        let rts = try SimulatorDiscovery.parseRuntimes(json: Fixtures.data("simctl-runtime-list-xcode26.5.json"))
        let ios = rts.first { $0.platformName == "iphone" }!
        XCTAssertEqual(RuntimeOperations.installer(for: ios, in: lib)?.fileName, "iOS 26.5 Simulator Runtime.dmg")
        let watch = rts.first { $0.platformName == "watch" }!
        XCTAssertNil(RuntimeOperations.installer(for: watch, in: lib))
    }

    func testExportPreflightBlocksAndWarns() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let ops = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 3_000_000_000, arm: false))
        XCTAssertThrowsError(try ops.preflightExport(.init(platform: "macOS", destination: t.path), freeBytesAtDestination: nil))
        XCTAssertThrowsError(try ops.preflightExport(.init(platform: "iOS", destination: t.path + "/missing"), freeBytesAtDestination: nil))
        let w = try ops.preflightExport(.init(platform: "iOS", architectureVariant: "arm64", destination: t.path), freeBytesAtDestination: 5_000_000_000)
        XCTAssertTrue(w.contains { $0.contains("Intel") })
        XCTAssertTrue(w.contains { $0.contains("internal volume") })
        XCTAssertTrue(w.contains { $0.contains("free at the destination") })
        var noExport = xcode26; noExport.capabilities.exportPath = false
        let old = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: noExport, host: host(free: 1, arm: true))
        XCTAssertThrowsError(try old.preflightExport(.init(platform: "iOS", destination: t.path), freeBytesAtDestination: nil))
    }

    func testImportPreflightEnforcesStagingSpace() throws {
        let t = TempDir()
        let dmg = t.file("iOS 26.5 Simulator Runtime.dmg", bytes: 1_000_000)
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let tight = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 3_001_500_000, arm: true))
        XCTAssertThrowsError(try tight.preflightImport(dmg: dmg))
        let ok = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 3_002_500_000, arm: true))
        XCTAssertFalse(try ok.preflightImport(dmg: dmg).isEmpty, "tight-but-allowed should warn")
        XCTAssertThrowsError(try ok.preflightImport(dmg: t.path + "/nope.dmg"))
    }

    func testDeleteRunsSimctlAndJournals() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let runner = FakeRunner(responses: [
            "xcrun simctl runtime delete ABC --keep-asset": .init(status: 0, stdout: "", stderr: ""),
            "xcrun simctl runtime delete ABC --dry-run --keep-asset": .init(status: 0, stdout: "", stderr: ""),
            "xcrun simctl runtime delete BAD": .init(status: 1, stdout: "", stderr: "No such runtime"),
        ])
        let ops = RuntimeOperations(runner: runner, journal: journal, xcode: xcode26, host: host(free: 1, arm: true))
        XCTAssertNoThrow(try ops.delete(identifier: "ABC", keepAsset: true))
        XCTAssertThrowsError(try ops.delete(identifier: "BAD"))
        let states = try journal.entries().map(\.state)
        XCTAssertEqual(states, [.started, .completed, .started, .failed])
        XCTAssertNoThrow(try ops.delete(identifier: "ABC", keepAsset: true, dryRun: true))
        XCTAssertEqual(try journal.entries().count, 4, "dry runs are not journaled")
    }
}

final class XcodeLocationsTests: XCTestCase {
    func testReadUsesDefaults() {
        let runner = FakeRunner(responses: [
            "defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation": .init(status: 0, stdout: "/Volumes/X/DD\n", stderr: ""),
            "defaults read com.apple.dt.Xcode IDEBuildLocationStyle": .init(status: 0, stdout: "Shared\n", stderr: ""),
        ])
        let l = XcodeLocations.read(runner: runner)
        XCTAssertEqual(l.derivedData, "/Volumes/X/DD"); XCTAssertEqual(l.buildLocationStyle, "Shared"); XCTAssertNil(l.archives)
    }

    func testPreflightRequiresAcknowledgementForExternalVolumes() throws {
        let t = TempDir()
        let ext = t.dir("ext/DD")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: MountStatus.filesystem(containing: ext)!.mountPoint,
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false, isEjectable: true,
            busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: false, totalBytes: 1, freeBytes: 1, isBootVolume: false)
        XCTAssertThrowsError(try XcodeLocations.preflightDerivedData(path: ext, volumes: [vol], xcodeRunning: false, acknowledgeExternalTests: false))
        let w = try XcodeLocations.preflightDerivedData(path: ext, volumes: [vol], xcodeRunning: false, acknowledgeExternalTests: true)
        XCTAssertTrue(w.contains { $0.contains("E2") }); XCTAssertTrue(w.contains { $0.contains("Ownership") })
        XCTAssertThrowsError(try XcodeLocations.preflightDerivedData(path: ext, volumes: [], xcodeRunning: true, acknowledgeExternalTests: true))
        XCTAssertThrowsError(try XcodeLocations.preflightDerivedData(path: "relative/x", volumes: [], xcodeRunning: false, acknowledgeExternalTests: true))
        XCTAssertEqual(try XcodeLocations.preflightDerivedData(path: nil, volumes: [], xcodeRunning: false, acknowledgeExternalTests: false), [])
    }

    func testApplyWritesAndDeletesViaDefaultsAndJournals() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let runner = FakeRunner(responses: [
            "defaults write": .init(status: 0, stdout: "", stderr: ""), "defaults delete": .init(status: 0, stdout: "", stderr: ""),
            "defaults read": .init(status: 1, stdout: "", stderr: ""),
        ])
        try XcodeLocations.apply(.init(key: XcodeLocations.derivedDataKey, newValue: "/tmp/dd"), runner: runner, journal: journal)
        try XcodeLocations.apply(.init(key: XcodeLocations.derivedDataKey, newValue: nil), runner: runner, journal: journal)
        XCTAssertEqual(try journal.entries().map(\.state), [.started, .completed, .started, .completed])
    }
}
