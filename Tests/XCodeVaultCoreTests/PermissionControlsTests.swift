import XCTest

@testable import XCodeVaultCore

/// The scan's half of asking for Full Disk Access at the moment of need (spec §3): it must say when macOS
/// privacy protection — not ordinary permission bits — refused a read.
///
/// No in-process unit test can make macOS answer `EPERM` on demand (a subprocess under `sandbox-exec` can;
/// not done here), so what is pinned is the rule the walk's two increments share, and that an ordinary
/// refusal does not count. The `FTS_DNR` increment was measured once instead (2026-09-28, a process without
/// Full Disk Access, `DiskUsage.measure` of H15's indicator folder `/Library/Application Support/com.apple.TCC`:
/// one unreadable entry, counted; the migration-safety review's fts-level probe showed that refusal arrives
/// as a root `FTS_DNR` with `EPERM`). The `fts_open` failure branch has not been exercised at all.
final class ScanPrivacyRefusalTests: XCTestCase {
    func testOnlyEPERMCountsAsAPrivacyRefusal() {
        XCTAssertTrue(DiskUsage.isPrivacyRefusal(EPERM))
        for code in [EACCES, ENOENT, EIO] { XCTAssertFalse(DiskUsage.isPrivacyRefusal(code), "errno \(code)") }
    }

    func testAnEACCESFolderIsUnreadableButNotAPrivacyRefusal() throws {
        let t = TempDir()
        let locked = t.dir("tree/locked")
        t.file("tree/locked/f", bytes: 10)
        chmod(locked, 0o000)
        defer { chmod(locked, 0o755) }
        let usage = try XCTUnwrap(DiskUsage.measure(t.path + "/tree"))
        // Positive control: the refusal was seen, so the zero below is not the walk missing the folder —
        // and seen by the unreadable-entry branch, not the undetermined-mount one, which also records it.
        XCTAssertTrue(usage.unreadable.contains(locked), "\(usage.unreadable)")
        XCTAssertTrue(usage.skippedMountPoints.isEmpty, "\(usage.skippedMountPoints)")
        XCTAssertEqual(usage.privacyRefusalCount, 0)
    }

    private func item(_ path: String, unreadable: [String], privacyRefusals: Int) -> StorageItem {
        var usage = DiskUsage.zero
        usage.unreadable = unreadable
        usage.privacyRefusalCount = privacyRefusals
        return StorageItem(
            categoryID: "derivedData", path: path, exists: true, isSymlink: false, symlinkTarget: nil, isMountPoint: false, usage: usage,
            volumeMountPoint: nil, onBootVolume: true)
    }

    private func summarize(_ items: [StorageItem]) -> ScanSummary {
        XCodeVaultCore.Scanner(
            runner: FakeRunner(responses: [:]), home: "/nonexistent", catalog: [StorageCatalog.category("derivedData")!], measureSizes: false,
            detectXcodeCapabilities: false
        ).summarize(items: items, runtimes: [])
    }

    func testTheSummaryAddsUpPrivacyRefusals() {
        // Two items, so a sum is told apart from the last value or the largest one.
        let summary = summarize([item("/x", unreadable: ["/x/a", "/x/b"], privacyRefusals: 2), item("/y", unreadable: ["/y/c"], privacyRefusals: 1)])
        XCTAssertEqual(summary.privacyRefusalCount, 3)
        XCTAssertTrue(summary.lowerBound)
    }

    func testTheLowerBoundDoesNotDependOnTheCount() {
        // Unreadable for an ordinary reason: still a lower bound, and nothing to ask for.
        let summary = summarize([item("/z", unreadable: ["/z/d"], privacyRefusals: 0)])
        XCTAssertTrue(summary.lowerBound)
        XCTAssertEqual(summary.privacyRefusalCount, 0)
    }
}

/// The GUI's decisions, extracted so they can be tested (spec §4): the app target has no tests.
final class FullDiskAccessPromptTests: XCTestCase {
    func testAScanThatCountsNoRefusalAsksForNothing() {
        // Nothing refused, not granted: no prompt — asking is for the moment of need only.
        XCTAssertFalse(PermissionPrompts.shouldAskForFullDiskAccess(privacyRefusalCount: 0, state: .notGranted))
        XCTAssertFalse(PermissionPrompts.shouldAskForFullDiskAccess(privacyRefusalCount: 0, state: .unknown))
    }

    func testARefusedScanAsksUnlessTheGrantIsKnownToBeThere() {
        // One refusal is enough: it is exactly what the one real measurement produced.
        XCTAssertTrue(PermissionPrompts.shouldAskForFullDiskAccess(privacyRefusalCount: 1, state: .notGranted))
        XCTAssertTrue(PermissionPrompts.shouldAskForFullDiskAccess(privacyRefusalCount: 1, state: .unknown))
        // Granted and still refused means something other than Full Disk Access; asking for it would mislead.
        XCTAssertFalse(PermissionPrompts.shouldAskForFullDiskAccess(privacyRefusalCount: 1, state: .granted))
    }

    func testThePermissionsRowOffersSettingsUnlessGranted() {
        XCTAssertTrue(FullDiskAccessState.notGranted.offersOpenSettings)
        XCTAssertTrue(FullDiskAccessState.unknown.offersOpenSettings)
        XCTAssertFalse(FullDiskAccessState.granted.offersOpenSettings)
    }
}

/// Spec §4's first mutant target: a control that runs a root action appears only when the helper is enabled.
final class PrivilegedActionControlTests: XCTestCase {
    func testOnlyAnEnabledHelperRunsAnAction() {
        XCTAssertEqual(HelperState.enabled.actionControl, .run)
        XCTAssertEqual(HelperState.awaitingApproval.actionControl, .requestHelper)
        XCTAssertEqual(HelperState.notInstalled.actionControl, .requestHelper)
        XCTAssertEqual(HelperState.unavailableInThisBuild.actionControl, .notAvailableInThisBuild)
        XCTAssertEqual(HelperState.allCases.filter { $0.actionControl == .run }, [.enabled])
    }

    func testTheHelperRowNeverOffersAButtonThisBuildCannotHonour() {
        XCTAssertEqual(HelperState.unavailableInThisBuild.rowButton, HelperRowButton.none)
        XCTAssertEqual(HelperState.notInstalled.rowButton, .install)
        XCTAssertEqual(HelperState.awaitingApproval.rowButton, .install)
        XCTAssertEqual(HelperState.enabled.rowButton, .uninstall)
    }

    func testOnlyTheWholeDyldCacheMapsToTheHelperVerb() {
        func action(_ path: String, root: Bool) -> CleanAction {
            CleanAction(categoryID: "x", categoryName: "X", path: path, bytes: 1, isExperimental: true, risk: .low, requiresRoot: root, notes: [])
        }
        XCTAssertEqual(action(PrivilegeRequirement.coreSimulatorDyldCachePath, root: true).privilegedAction, .emptyCoreSimulatorDyldCache)
        // The verb empties the whole cache; a path inside it must not borrow that.
        XCTAssertNil(action(PrivilegeRequirement.coreSimulatorDyldCachePath + "/25G229", root: true).privilegedAction)
        XCTAssertNil(action("/Library/Developer/CommandLineTools", root: true).privilegedAction)
        XCTAssertNil(action(PrivilegeRequirement.coreSimulatorDyldCachePath, root: false).privilegedAction)
    }

    func testTheSimulatorWorkPredicateNamesTheProcessesThatUseTheCache() {
        for path in [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/launchd_sim",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl", "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
            // Where the builder was found on 2026-09-28, in each installed runtime.
            "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime"
                + "/Contents/Resources/update_dyld_sim_shared_cache",
        ] {
            XCTAssertTrue(CleanExecutor.isSimulatorWorkExecutable(path), path)
        }
        XCTAssertFalse(CleanExecutor.isSimulatorWorkExecutable("/usr/bin/xcodebuild-wrapper"))
        XCTAssertFalse(CleanExecutor.isSimulatorWorkExecutable("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
        // The daemon that spawns the builder stays up; naming it would refuse the action for good.
        XCTAssertFalse(CleanExecutor.isSimulatorWorkExecutable("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simdiskimaged"))
    }
}

/// Carried note 7 of the 2026-09-27 permissions plan: never two scans, and one more after the running one when a
/// scan was asked for meanwhile.
final class ScanGateTests: XCTestCase {
    func testTheFirstRequestStartsAScan() {
        var gate = ScanGate()
        XCTAssertFalse(gate.isScanning)
        XCTAssertTrue(gate.requestScan())
        XCTAssertTrue(gate.isScanning)
    }

    func testARequestWhileScanningStartsNothingAndOneMoreFollows() {
        var gate = ScanGate()
        XCTAssertTrue(gate.requestScan())
        XCTAssertFalse(gate.requestScan(), "no second, overlapping scan")
        XCTAssertFalse(gate.requestScan(), "however often it is asked")
        XCTAssertTrue(gate.scanEnded(), "exactly one more, for the requests made meanwhile")
        XCTAssertTrue(gate.isScanning, "still scanning: nothing can slip a scan in between")
        XCTAssertFalse(gate.scanEnded())
        XCTAssertFalse(gate.isScanning)
    }

    func testWithNoRequestMeanwhileTheGateReopens() {
        var gate = ScanGate()
        XCTAssertTrue(gate.requestScan())
        XCTAssertFalse(gate.scanEnded(), "nothing was asked for meanwhile")
        XCTAssertFalse(gate.isScanning)
        XCTAssertTrue(gate.requestScan(), "a later request starts a scan again")
    }
}
