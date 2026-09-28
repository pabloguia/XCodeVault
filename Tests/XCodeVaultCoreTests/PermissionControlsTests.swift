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
