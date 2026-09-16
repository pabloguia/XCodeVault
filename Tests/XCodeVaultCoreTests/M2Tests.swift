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

    /// The dyld-cache line is usually the largest number in the plan, and most of it is not free
    /// space: a cache whose runtime is installed is rebuilt on the next boot of that runtime. Before
    /// F10 the warning said only "root-owned", which reads as "you would get 10 GB back if you had
    /// permission". The durability caveat is the load-bearing half.
    func testTheDyldCacheWarningSaysMostOfTheTotalIsNotDurableSpace() {
        let item = StorageItem(
            categoryID: "coreSimulatorSystemCaches", path: "/Library/Developer/CoreSimulator/Caches/dyld", exists: true,
            isSymlink: false, isMountPoint: false, usage: DiskUsage(
                allocatedBytes: 10_000_000_000, logicalBytes: 10_000_000_000, fileCount: 1, directoryCount: 1,
                symlinkCount: 0, skippedMountPoints: [], unreadable: []),
            volumeMountPoint: "/", onBootVolume: true)
        let plan = CleanPlanner(home: "/Users/t").plan(report: report(home: "/Users/t", items: [item]))
        let w = plan.warnings.filter { $0.contains("dyld") }
        XCTAssertEqual(w.count, 1, "\(plan.warnings)")
        let only = try? XCTUnwrap(w.first)
        XCTAssertTrue(only?.contains("NOT durable free space") == true, "\(w)")
        XCTAssertTrue(only?.contains("rebuilt on the next boot") == true, "the reason must be stated, not just the caveat: \(w)")
        // This asserted `contains("untested")` until 2026-09-16, when E13 tested it: the orphaned
        // part of the tree came back byte-identical across a reboot. The warning must now state the
        // measurement rather than the gap, and must cite the experiment so the claim stays checkable.
        XCTAssertTrue(only?.contains("restart does not reclaim") == true, "\(w)")
        XCTAssertTrue(only?.contains("E13") == true, "the durability claim must cite its evidence: \(w)")
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
        // Deliberately NOT `simctl delete unavailable`: that command is permanent and sweeps up
        // devices whose runtime XCodeVault offloaded on purpose and can bring back. `clean` printed
        // it unconditionally on every run, which is the same defect `doctor` was corrected for.
        XCTAssertTrue(devPlan.skipped.contains { $0.contains("simctl delete <udid>") }, "\(devPlan.skipped)")
        XCTAssertFalse(devPlan.skipped.contains { $0.contains("delete unavailable") }, "\(devPlan.skipped)")
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

    /// The canary for the bug that made the first version of this guard inert. `/Volumes` is a
    /// firmlink onto the Data volume, so `statfs` reports `/System/Volumes/Data` for it and for every
    /// ordinary directory inside it — never `/`. Any future rewrite reaching for a `statfs`
    /// mount-point comparison fails here instead of shipping a check that cannot fire.
    func testVolumesIsAFirmlinkSoStatfsNeverReportsTheRootMountPointForIt() {
        XCTAssertNotEqual(MountStatus.filesystem(containing: "/Volumes")?.mountPoint, "/", "the firmlink assumption changed; re-read isNotOnAMountedVolume")
        XCTAssertEqual(MountStatus.filesystem(containing: "/")?.mountPoint, "/")
    }

    /// Rule 6: a path is not a volume. When an external volume goes away uncleanly macOS can leave
    /// its mount-point directory behind on the internal disk, and `fileExists` cannot tell that apart
    /// from the volume being mounted — so a 10 GB installer lands on the disk this operation exists
    /// to free, at a path that reads like the drive.
    func testAPathUnderVolumesWhoseVolumeIsNotMountedIsRefused() {
        let mounted: (String) -> Bool = { $0 == "/Volumes/VAULT" }
        let nothingMounted: (String) -> Bool = { _ in false }
        let path = "/Volumes/VAULT/XCodeVault/RuntimeLibrary"

        XCTAssertTrue(RuntimeOperations.isNotOnAMountedVolume(destination: path, isMountPoint: nothingMounted))
        XCTAssertFalse(RuntimeOperations.isNotOnAMountedVolume(destination: path, isMountPoint: mounted))
        // Outside /Volumes the question does not arise: a boot-volume destination is a real choice.
        XCTAssertFalse(RuntimeOperations.isNotOnAMountedVolume(destination: "/Users/x/RuntimeLibrary", isMountPoint: nothingMounted))
        // `/Volumes` itself names no volume.
        XCTAssertFalse(RuntimeOperations.isNotOnAMountedVolume(destination: "/Volumes", isMountPoint: nothingMounted))
    }

    /// Every one of these reaches the same directory as the plain form and defeated the first
    /// version's raw `hasPrefix("/Volumes/")`.
    func testTheMountedVolumeCheckSurvivesPathSpellings() {
        let nothingMounted: (String) -> Bool = { _ in false }
        for spelling in [
            "/Volumes/VAULT/XCodeVault/",  // trailing slash
            "/Volumes//VAULT/XCodeVault",  // doubled separator
            "/Volumes/VAULT/./XCodeVault",  // dot component
            "/Volumes/VAULT/x/../XCodeVault",  // parent component
        ] {
            XCTAssertTrue(RuntimeOperations.isNotOnAMountedVolume(destination: spelling, isMountPoint: nothingMounted), spelling)
        }
    }

    /// Case-insensitivity is load-bearing only for a path that does not exist — and that is exactly
    /// the case that matters. Measured: `resolvingSymlinksInPath` normalises `/volumes/VAULT/…` to
    /// `/Volumes/…` while VAULT is mounted, but leaves a non-existent `/volumes/Ghost/…` lowercase,
    /// so a case-sensitive comparison silently stops asking whether a volume is there.
    func testALowercaseVolumesPathIsStillRecognisedWhenItDoesNotExist() {
        let ghost = "/volumes/XCVGhost-\(UUID().uuidString)/RuntimeLibrary"
        XCTAssertTrue(RuntimeOperations.isNotOnAMountedVolume(destination: ghost, isMountPoint: { _ in false }), ghost)
    }

    /// `/Volumes/<bootname>` is a symlink to `/` — it exists on this machine as `/Volumes/MacOS`.
    /// Writing there is writing to the internal disk under a path that reads like a drive, so it is
    /// refused; and because it resolves *out* of `/Volumes`, only the literal spelling can catch it.
    /// This runs against the real `MountStatus.isMountPoint`, which answers false for a symlink.
    func testAVolumesEntryThatIsASymlinkToTheBootVolumeIsRefused() throws {
        try XCTSkipUnless(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/Volumes/MacOS")) != nil,
            "this machine has no /Volumes/<bootname> symlink to exercise")
        // An **existing** path on purpose: `resolvingSymlinksInPath` only resolves what exists, so a
        // made-up path under the symlink stays under /Volumes and the resolved candidate would catch
        // it anyway. Measured: `/Volumes/MacOS~` → `~`, which leaves
        // `/Volumes` entirely — so here the literal spelling is the only candidate that can see it.
        let home = NSHomeDirectory()
        let viaSymlink = "/Volumes/MacOS" + home
        try XCTSkipUnless(FileManager.default.fileExists(atPath: viaSymlink), "no reachable path through the boot-volume symlink")
        XCTAssertTrue(RuntimeOperations.isNotOnAMountedVolume(destination: viaSymlink), viaSymlink)
    }

    /// The default argument is where the inert version lived, and no test exercised it: every test
    /// passed an explicit closure, so mutating the default to a constant survived the whole suite.
    /// This calls `preflightExport` with no seam at all, against a path under /Volumes that is not a
    /// volume on any machine.
    func testTheExportPreflightRefusesAnUnmountedVolumePathThroughTheRealCheck() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let ops = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 500_000_000_000, arm: false))
        let absent = "/Volumes/XCVDefinitelyNotMounted-\(UUID().uuidString)/RuntimeLibrary"
        XCTAssertThrowsError(try ops.preflightExport(.init(platform: "iOS", destination: absent), freeBytesAtDestination: nil)) { error in
            let d = (error as? RuntimeOperationError)?.description ?? "\(error)"
            XCTAssertTrue(d.contains("no volume is mounted there"), "wrong refusal: \(d)")
            // The check must beat the existence guard: a leftover mount-point directory *exists*, so
            // "not an existing directory" would never fire for the case this is written for.
            XCTAssertFalse(d.contains("not an existing directory"), "the vaguer guard answered first: \(d)")
        }
        // A real, mounted destination outside /Volumes still passes with no seam.
        XCTAssertNoThrow(try ops.preflightExport(.init(platform: "iOS", destination: t.path), freeBytesAtDestination: nil))
    }

    /// An architecture variant is a third axis, and answering a three-axis question on two axes is
    /// exactly how the no-`-buildVersion` hole got in. `-architectureVariant arm64` against an
    /// installed universal image names a different image, so it is a real download — and
    /// `supportedArchitectures` says what the installed image *runs*, not which variant it *is*.
    func testAnArchitectureVariantRequestIsNotAssumedToBeACopyOut() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let ops = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 3_000_000_000, arm: true))
        let universal = SimulatorRuntime(
            identifier: "U", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", version: "26.5", build: "23F77",
            supportedArchitectures: ["arm64", "x86_64"])
        let req = { (v: String?) in RuntimeOperations.ExportRequest(platform: "iOS", buildVersion: "23F77", architectureVariant: v, destination: t.path) }
        XCTAssertEqual(ops.exportCost(req(nil), among: [universal]), .copyOut, "no variant requested: the installed image is the one")
        XCTAssertEqual(
            ops.exportCost(req("arm64"), among: [universal]), .unknownDependsOnWhatIsLatest,
            "an arm64-only export from a universal install is a different image")
        XCTAssertEqual(ops.exportCost(req("universal"), among: [universal]), .copyOut)

        let armOnly = SimulatorRuntime(
            identifier: "A", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", version: "26.5", build: "23F77",
            supportedArchitectures: ["arm64"])
        XCTAssertEqual(ops.exportCost(req("arm64"), among: [armOnly]), .copyOut)
        XCTAssertEqual(ops.exportCost(req("universal"), among: [armOnly]), .unknownDependsOnWhatIsLatest)
    }

    /// `-buildVersion` is matched three ways because it accepts three things. The dashed suffix in
    /// the identifier answers most real cases, which made the `version` comparison look redundant —
    /// it is not, for a runtime whose identifier does not encode its version. Synthetic on purpose:
    /// no such identifier exists today, and a mutation-surviving clause is either load-bearing
    /// somewhere or dead code, with no third option.
    func testTheVersionComparisonCoversIdentifiersThatDoNotEncodeTheVersion() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let ops = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 1, arm: false))
        let unencoded = SimulatorRuntime(
            identifier: "L", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-legacy", version: "26.5", build: nil)
        XCTAssertEqual(
            ops.exportCost(.init(platform: "iOS", buildVersion: "26.5", destination: t.path), among: [unencoded]), .copyOut,
            "the identifier does not carry `26-5`, so only the version comparison can match")
    }

    /// Xcode names exported installers after the SDK — `iphonesimulator_26.5_23F77.dmg` — not after
    /// the display name. Only the display form parsed, so a real export yielded `platform == nil`,
    /// `installer(for:in:)` matched nothing, and `runtime offload` refused to free a runtime whose
    /// installer was sitting in the library. The fixtures used hand-written display names and never
    /// caught it; this was found by exporting for real and reading the output.
    func testInstallersAreParsedFromXcodesOwnSdkStyleFileNames() {
        let real = RuntimeInstaller.parse(fileName: "iphonesimulator_26.5_23F77.dmg")
        XCTAssertEqual(real.platform, "iOS")
        XCTAssertEqual(real.version, "26.5")
        XCTAssertEqual(real.build, "23F77")

        XCTAssertEqual(RuntimeInstaller.parse(fileName: "watchsimulator_26.5_23T570.dmg").platform, "watchOS")
        XCTAssertEqual(RuntimeInstaller.parse(fileName: "appletvsimulator_26.5_23L470.exportedBundle").platform, "tvOS")
        XCTAssertEqual(RuntimeInstaller.parse(fileName: "xrsimulator_26.5_23M100.dmg").platform, "visionOS")
        // The display form Apple used elsewhere must keep working.
        XCTAssertEqual(RuntimeInstaller.parse(fileName: "iOS 26.5 Simulator Runtime.dmg").platform, "iOS")
    }

    /// End to end: the SDK-named installer must actually satisfy `installer(for:in:)`, because that
    /// is the gate `runtime offload` gets its answer from. Parsing the name is only half the bug.
    func testAnSdkNamedInstallerSatisfiesTheOffloadGate() throws {
        let t = TempDir()
        t.file("iphonesimulator_26.5_23F77.dmg", bytes: 600_000_000)
        let lib = try RuntimeOperations.library(at: t.path)
        let rts = try SimulatorDiscovery.parseRuntimes(json: Fixtures.data("simctl-runtime-list-xcode26.5.json"))
        let ios = try XCTUnwrap(rts.first { $0.platformName == "iphone" })
        XCTAssertEqual(
            RuntimeOperations.installer(for: ios, in: lib)?.fileName, "iphonesimulator_26.5_23F77.dmg",
            "offload refuses to delete a runtime whose installer it cannot find")
    }

    /// The export preflight tells two opposite cost stories, and picking the wrong one is not
    /// cosmetic: the expensive story ("~7 GB peak, watch for ENOSPC") on a nearly-full disk talks a
    /// user out of the one operation that frees the most space, while the cheap story on a runtime
    /// that is not installed invites the ENOSPC it should have warned about.
    func testExportPreflightDistinguishesAnInstalledRuntimeFromADownload() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        // Deliberately a low-free-space host: that is where the wrong story does the damage.
        let ops = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 3_000_000_000, arm: false))
        let installed = try SimulatorDiscovery.parseRuntimes(json: Fixtures.data("simctl-runtime-list-xcode26.5.json"))
        XCTAssertFalse(installed.isEmpty, "fixture must contain runtimes or this test proves nothing")

        let iosVersion = try XCTUnwrap(installed.first { $0.runtimeIdentifier?.contains(".SimRuntime.iOS-") == true }?.version)
        let cheap = try ops.preflightExport(
            .init(platform: "iOS", buildVersion: iosVersion, destination: t.path), freeBytesAtDestination: 500_000_000_000, installedRuntimes: installed)
        XCTAssertTrue(cheap.contains { $0.contains("already installed") }, "iOS \(iosVersion) is in the fixture: \(cheap)")
        XCTAssertFalse(cheap.contains { $0.contains("ENOSPC") }, "must not warn about internal staging for a copy-out: \(cheap)")

        // tvOS is absent from the fixture, so this is a real download on a 3 GB-free machine.
        let costly = try ops.preflightExport(.init(platform: "tvOS", destination: t.path), freeBytesAtDestination: 500_000_000_000, installedRuntimes: installed)
        XCTAssertTrue(costly.contains { $0.contains("NOT already installed") }, "\(costly)")
        XCTAssertTrue(costly.contains { $0.contains("ENOSPC") }, "a download onto a 3 GB-free volume must warn: \(costly)")
    }

    /// An empty list is what a failed `simctl` probe looks like. It must fall back to the expensive
    /// story — under-promising costs a user nothing, over-promising costs them a full disk.
    func testExportPreflightWithNoRuntimeListAssumesTheExpensiveCase() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let ops = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 3_000_000_000, arm: false))
        let w = try ops.preflightExport(.init(platform: "iOS", destination: t.path), freeBytesAtDestination: nil, installedRuntimes: [])
        XCTAssertTrue(w.contains { $0.contains("NOT already installed") }, "\(w)")
    }

    /// The hole this replaced: `-downloadPlatform iOS` with no `-buildVersion` fetches the LATEST
    /// runtime. Answering "already installed" because *some* iOS is present told a user with 3 GB
    /// free that a 10 GB download was free — and, worse, suppressed the ENOSPC warning along with it,
    /// because that warning lived in the else branch. "I cannot tell" needs its own answer.
    func testNoBuildVersionIsNotTreatedAsFreeJustBecauseThePlatformIsInstalled() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let ops = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 3_000_000_000, arm: false))
        let installed = try SimulatorDiscovery.parseRuntimes(json: Fixtures.data("simctl-runtime-list-xcode26.5.json"))
        let w = try ops.preflightExport(.init(platform: "iOS", destination: t.path), freeBytesAtDestination: 500_000_000_000, installedRuntimes: installed)
        XCTAssertFalse(w.contains { $0.contains("internal use stays flat.") }, "must not promise the cheap path: \(w)")
        XCTAssertTrue(w.contains { $0.contains("fetches the LATEST") }, "\(w)")
        XCTAssertTrue(w.contains { $0.contains("ENOSPC") }, "3 GB free and possibly a download — the warning must survive: \(w)")
    }

    func testExportCostIsPreciseAboutPlatformAndVersion() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let ops = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 1, arm: false))
        let rts = try SimulatorDiscovery.parseRuntimes(json: Fixtures.data("simctl-runtime-list-xcode26.5.json"))
        let ios = try XCTUnwrap(rts.first { $0.runtimeIdentifier?.contains(".SimRuntime.iOS-") == true })
        let iosVersion = try XCTUnwrap(ios.version)

        XCTAssertEqual(ops.exportCost(.init(platform: "iOS", destination: t.path), among: rts), .unknownDependsOnWhatIsLatest)
        XCTAssertEqual(ops.exportCost(.init(platform: "tvOS", destination: t.path), among: rts), .download)
        // A different version of an installed platform is a genuine download, not a copy-out.
        XCTAssertEqual(
            ops.exportCost(.init(platform: "iOS", buildVersion: "18.0", destination: t.path), among: rts), .download,
            "iOS 18.0 is not installed just because some iOS is")
        XCTAssertEqual(ops.exportCost(.init(platform: "iOS", buildVersion: iosVersion, destination: t.path), among: rts), .copyOut)
        // `-buildVersion` accepts a build string too, not only an OS version. Unconditional on
        // purpose: wrapping this in `if let` made the assertion optional, and an optional assertion
        // let the "drop build-string matching" mutant survive a whole round.
        let build = try XCTUnwrap(ios.build, "the fixture must carry a build or this asserts nothing")
        XCTAssertEqual(ops.exportCost(.init(platform: "iOS", buildVersion: build, destination: t.path), among: rts), .copyOut, "build \(build)")

        // The trailing `-` in the marker. No Apple platform today is a prefix of another, so this
        // guards a case that cannot currently occur — mutation testing showed removing the dash
        // killed no test, and a synthetic identifier is the only way to pin the intent rather than
        // leave the character looking decorative. If Apple ever ships an `iOSFoo` platform, the
        // failure without this would be silent: a real download reported as a free copy-out.
        let lookalike = SimulatorRuntime(identifier: "X", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOSFoo-1-0")
        XCTAssertEqual(
            ops.exportCost(.init(platform: "iOS", destination: t.path), among: [lookalike]), .download,
            "`iOS` must not match the platform `iOSFoo`")
    }

    func testImportPreflightEnforcesStagingSpace() throws {
        let t = TempDir()
        let dmg = t.file("iOS 26.5 Simulator Runtime.dmg", bytes: 1_000_000)
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        let tight = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 2_001_000_000, arm: true))
        XCTAssertThrowsError(try tight.preflightImport(dmg: dmg))
        let ok = RuntimeOperations(runner: FakeRunner(responses: [:]), journal: journal, xcode: xcode26, host: host(free: 2_001_750_000, arm: true))
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
