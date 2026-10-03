import XCTest

@testable import XCodeVaultCore

/// `scan` leads with the savings and `status` ends with the next step (spec 2026-10-03 §5, §10).
final class ScanTextTests: XCTestCase {
    override func setUp() { L10n.configure(override: "en", environment: [:], preferred: []) }
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private let itemPath = "/fixture/derivedData/1000"

    private func report() -> ScanReport {
        var usage = DiskUsage.zero
        usage.allocatedBytes = 1000
        var r = Fixtures.minimalReport()
        r.items = [
            StorageItem(
                categoryID: "derivedData", path: itemPath, exists: true, isSymlink: false, symlinkTarget: nil, isMountPoint: false,
                usage: usage, volumeMountPoint: nil, onBootVolume: true)
        ]
        r.savings = SavingsCalculator.summarize(items: r.items, category: StorageCatalog.category)
        r.warnings = ["fixture warning"]
        return r
    }

    func testScanLeadsWithTheSavingsAndDropsTheOldSummary() {
        let out = TextRenderer.scan(report())
        XCTAssertTrue(out.contains("What you can reclaim on this Mac"), out)
        XCTAssertFalse(out.contains("Summary:"), out)
        XCTAssertFalse(out.contains("with verified strategies only"), out)
        XCTAssertTrue(out.hasPrefix(TextRenderer.status(report())), "status comes first")
    }

    func testTheItemTableIsOnlyWithDetails() {
        XCTAssertFalse(TextRenderer.scan(report()).contains(itemPath))
        XCTAssertTrue(TextRenderer.scan(report(), details: true).contains(itemPath))
    }

    func testWarningsAreAlwaysPrinted() {
        XCTAssertTrue(TextRenderer.scan(report()).contains("fixture warning"))
        XCTAssertTrue(TextRenderer.scan(report(), details: true).contains("fixture warning"))
    }

    func testWarningsAreSeparatedByABlankLine() {
        XCTAssertTrue(TextRenderer.scan(report()).contains("\n\nWarnings:\n"))
    }

    func testStatusFooterPointsAtScanAndOnlyWhenNotGrantedAtPermissions() {
        let granted = TextRenderer.statusFooter(fullDiskAccess: .granted)
        XCTAssertTrue(granted.contains("xcodevaultctl scan"), granted)
        XCTAssertFalse(granted.contains("Full Disk Access"), granted)
        let denied = TextRenderer.statusFooter(fullDiskAccess: .notGranted)
        XCTAssertTrue(denied.contains("xcodevaultctl scan"), denied)
        XCTAssertTrue(denied.contains("Full Disk Access is not granted"), denied)
        XCTAssertTrue(denied.contains("xcodevaultctl permissions"), denied)
        let unknown = TextRenderer.statusFooter(fullDiskAccess: .unknown)
        XCTAssertTrue(unknown.contains("xcodevaultctl scan"), unknown)
        XCTAssertFalse(unknown.contains("Full Disk Access"), unknown)
    }
}
