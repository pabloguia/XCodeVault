import XCTest

@testable import XCodeVaultCore

final class DiskBarTests: XCTestCase {
    private func host(free: UInt64, total: UInt64) -> HostEnvironment {
        HostEnvironment(
            macOSVersion: "26.6", macOSBuild: "25G83", architecture: "arm64", homeDirectory: "/Users/tester",
            dataVolumeFreeBytes: free, dataVolumeTotalBytes: total, userName: "tester", isRoot: false)
    }

    private func savings(run: UInt64 = 0, park: UInt64 = 0, delete: UInt64 = 0, keep: UInt64 = 0) -> SavingsSummary {
        var s = SavingsSummary()
        s.runFromExternal.primaryBytes = run
        s.parkExternally.primaryBytes = park
        s.deleteAndRegenerate.primaryBytes = delete
        s.keepLocal.primaryBytes = keep
        // Option bytes are not additive and must never reach the bar.
        s.deleteAndRegenerate.optionBytes = delete + 999
        return s
    }

    func testSegmentsAreInFixedOrderAndSumToTheVolume() {
        let bar = DiskBar(host: host(free: 100, total: 1000), savings: savings(run: 10, park: 20, delete: 30, keep: 40))
        XCTAssertEqual(
            bar.segments.map(\.kind),
            [.otherData, .bucket(.runFromExternal), .bucket(.parkExternally), .bucket(.deleteAndRegenerate), .bucket(.keepLocal), .free])
        XCTAssertEqual(bar.segments.map(\.bytes), [800, 10, 20, 30, 40, 100])
        XCTAssertEqual(bar.segments.reduce(UInt64(0)) { $0 + $1.bytes }, 1000)
        XCTAssertFalse(bar.isClamped)
        XCTAssertEqual(DiskBar.segments(host: host(free: 100, total: 1000), savings: savings(run: 10, park: 20, delete: 30, keep: 40)), bar.segments)
    }

    func testZeroByteSegmentsAreOmitted() {
        let bar = DiskBar(host: host(free: 0, total: 500), savings: savings(park: 50, keep: 0))
        XCTAssertEqual(bar.segments.map(\.kind), [.otherData, .bucket(.parkExternally)])
        XCTAssertEqual(bar.segments.map(\.bytes), [450, 50])
        XCTAssertFalse(bar.isClamped)
    }

    func testOtherDataClampsAtZeroAndSaysSo() {
        // Free plus developer data exceeds the volume (a stale measurement or clones counted twice).
        let bar = DiskBar(host: host(free: 900, total: 1000), savings: savings(delete: 300))
        XCTAssertEqual(bar.segments.map(\.kind), [.bucket(.deleteAndRegenerate), .free])
        XCTAssertEqual(bar.segments.map(\.bytes), [300, 900])
        XCTAssertTrue(bar.isClamped)
    }

    func testExactlyFullVolumeIsNotClamped() {
        let bar = DiskBar(host: host(free: 700, total: 1000), savings: savings(run: 300))
        XCTAssertEqual(bar.segments.map(\.kind), [.bucket(.runFromExternal), .free])
        XCTAssertFalse(bar.isClamped)
    }

    func testUnknownVolumeSizeYieldsNoOtherData() {
        // `HostEnvironment.discover` reports 0/0 when the volume could not be measured.
        let bar = DiskBar(host: host(free: 0, total: 0), savings: savings(delete: 5))
        XCTAssertEqual(bar.segments.map(\.kind), [.bucket(.deleteAndRegenerate)])
        XCTAssertTrue(bar.isClamped)
    }
}
