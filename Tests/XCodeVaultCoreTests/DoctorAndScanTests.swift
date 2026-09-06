import XCTest
@testable import XCodeVaultCore

final class DoctorTests: XCTestCase {
    private func fakeReport(home: String, volumes: [Volume] = [], runtimes: [SimulatorRuntime] = [], devices: [SimulatorDevice] = [], free: UInt64 = 100_000_000_000) -> ScanReport {
        let host = HostEnvironment(macOSVersion: "26.6", macOSBuild: "25G83", architecture: "arm64", homeDirectory: home,
                                   dataVolumeFreeBytes: free, dataVolumeTotalBytes: 500_000_000_000, userName: "tester", isRoot: false)
        return ScanReport(generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: host, xcodes: [], runtimes: runtimes,
                          devices: devices, volumes: volumes, items: [], summary: ScanSummary(), warnings: [])
    }
    private let quiet = FakeRunner(responses: [:])

    func testDetectsForbiddenCoreSimulatorSymlink() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("elsewhere/CoreSimulator")
        t.symlink("Library/Developer/CoreSimulator", to: t.path + "/elsewhere/CoreSimulator")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        let hit = f.first { $0.id == "forbidden-symlink:~/Library/Developer/CoreSimulator" }
        XCTAssertEqual(hit?.severity, .critical)
        XCTAssertTrue(hit?.detail.contains("Files app") == true)
    }

    func testDetectsWholeDeveloperSymlinkAndBrokenLinks() {
        let t = TempDir()
        t.dir("real/Developer/Xcode")
        t.symlink("Library/Developer", to: t.path + "/real/Developer")
        t.symlink("real/Developer/Xcode/DerivedData", to: "/Volumes/GONE/DerivedData")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        XCTAssertTrue(f.contains { $0.id == "forbidden-symlink:~/Library/Developer" && $0.severity == .critical })
        XCTAssertTrue(f.contains { $0.id.hasPrefix("broken-symlink:") && $0.severity == .error }, "\(f.map(\.id))")
    }

    func testDetectsPriorToolLeftoversOnExternalVolume() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("ext/mac-ssd-rescue/DerivedData")
        let vol = Volume(deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
                         filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
                         isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
                         totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        XCTAssertTrue(f.contains { $0.id.hasPrefix("prior-tool:mac-ssd-rescue") && $0.detail.contains("DerivedData") })
    }

    func testLowFreeSpaceSeverity() {
        let t = TempDir(); t.dir("Library/Developer")
        let d = Doctor(home: t.path, runner: quiet)
        XCTAssertEqual(d.diagnose(report: fakeReport(home: t.path, free: 5_000_000_000)).first { $0.id == "low-free-space" }?.severity, .critical)
        XCTAssertEqual(d.diagnose(report: fakeReport(home: t.path, free: 30_000_000_000)).first { $0.id == "low-free-space" }?.severity, .warning)
        XCTAssertNil(d.diagnose(report: fakeReport(home: t.path, free: 80_000_000_000)).first { $0.id == "low-free-space" })
    }

    func testRuntimeRegistryProblems() {
        let t = TempDir(); t.dir("Library/Developer")
        var rt = SimulatorRuntime(identifier: "ABC")
        rt.state = "Ready"; rt.mountPath = t.path + "/not-a-mount"; rt.signatureState = "Invalid"; rt.path = t.path + "/missing.dmg"
        t.dir("not-a-mount")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, runtimes: [rt]))
        XCTAssertTrue(f.contains { $0.id == "runtime-not-mounted:ABC" })
        XCTAssertTrue(f.contains { $0.id == "runtime-signature:ABC" })
        XCTAssertTrue(f.contains { $0.id == "runtime-image-missing:ABC" })
    }

    func testUnavailableDevices() {
        let t = TempDir(); t.dir("Library/Developer")
        let dev = SimulatorDevice(udid: "U", name: "iPhone X", runtimeIdentifier: "r", state: "Shutdown", isAvailable: false,
                                  availabilityError: "runtime profile not found", dataPath: nil, dataPathSize: 123, logPath: nil, lastBootedAt: nil)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, devices: [dev]))
        XCTAssertTrue(f.contains { $0.id == "unavailable-devices" && $0.remediation?.contains("simctl delete unavailable") == true })
    }

    func testFindingsAreSortedBySeverity() {
        let t = TempDir(); t.dir("Library/Developer")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, free: 1_000_000_000))
        XCTAssertEqual(f.map(\.severity), f.map(\.severity).sorted(by: >))
    }
}

final class ScannerTests: XCTestCase {
    func testResolvesCatalogAgainstFakeHome() throws {
        let t = TempDir()
        t.file("Library/Developer/Xcode/DerivedData/Proj-abc/Build/x.o", bytes: 4096)
        t.file("Library/Developer/Xcode/DerivedData/Proj-abc/Index/y", bytes: 4096)
        t.symlink("Library/Developer/Xcode/Archives", to: "/Volumes/GONE/Archives")
        let cat = [StorageCatalog.category("derivedData")!, StorageCatalog.category("archives")!, StorageCatalog.category("previews")!]
        let scanner = XCodeVaultCore.Scanner(runner: FakeRunner(responses: [:]), home: t.path, catalog: cat)
        let items = scanner.resolveItems()
        let dd = try XCTUnwrap(items.first { $0.categoryID == "derivedData" })
        XCTAssertTrue(dd.exists); XCTAssertFalse(dd.isSymlink); XCTAssertEqual(dd.usage?.fileCount, 2)
        XCTAssertGreaterThanOrEqual(dd.allocatedBytes, 8192)
        XCTAssertTrue(dd.onBootVolume)
        let ar = try XCTUnwrap(items.first { $0.categoryID == "archives" })
        XCTAssertTrue(ar.isSymlink); XCTAssertEqual(ar.symlinkTarget, "/Volumes/GONE/Archives")
        let pv = try XCTUnwrap(items.first { $0.categoryID == "previews" })
        XCTAssertFalse(pv.exists); XCTAssertNil(pv.usage)
        let summary = scanner.summarize(items: items, runtimes: [])
        XCTAssertEqual(summary.relocatableBytes, dd.allocatedBytes)   // symlinked archives are not counted
        XCTAssertEqual(summary.cleanableBytes, dd.allocatedBytes)
        XCTAssertEqual(summary.estimatedInternalSavingsBytes, dd.allocatedBytes)
    }

    func testReportRoundTripsThroughJSON() throws {
        let t = TempDir(); t.dir("Library/Developer")
        let runner = FakeRunner(responses: [
            "sw_vers -productVersion": .init(status: 0, stdout: "26.6\n", stderr: ""),
            "sw_vers -buildVersion": .init(status: 0, stdout: "25G83\n", stderr: ""),
            "xcrun simctl runtime list -j": .init(status: 0, stdout: Fixtures.string("simctl-runtime-list-xcode26.5.json"), stderr: ""),
            "xcrun simctl list devices -j": .init(status: 0, stdout: Fixtures.string("simctl-list-devices-xcode26.5.json"), stderr: ""),
            "diskutil list -plist": .init(status: 0, stdout: "<plist version=\"1.0\"><dict><key>AllDisksAndPartitions</key><array/></dict></plist>", stderr: ""),
            "xcode-select -p": .init(status: 0, stdout: "/nonexistent/Xcode.app/Contents/Developer\n", stderr: ""),
        ])
        let report = XCodeVaultCore.Scanner(runner: runner, home: t.path, catalog: [StorageCatalog.category("derivedData")!], measureSizes: false, detectXcodeCapabilities: false).scan()
        XCTAssertEqual(report.runtimes.count, 2)
        XCTAssertEqual(report.devices.count, 3)
        let json = try JSONOutput.encode(report)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(ScanReport.self, from: Data(json.utf8))
        XCTAssertEqual(back.runtimes, report.runtimes)
        XCTAssertEqual(back.items.count, 1)
        XCTAssertFalse(TextRenderer.scan(report).isEmpty)
    }
}
