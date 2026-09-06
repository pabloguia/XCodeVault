import XCTest

@testable import XCodeVaultCore

final class DiskUsageTests: XCTestCase {
    func testMeasuresTreeWithoutFollowingSymlinks() throws {
        let t = TempDir()
        t.file("a/one.bin", bytes: 10_000)
        t.file("a/b/two.bin", bytes: 5_000)
        t.file("c/three.bin", bytes: 1)
        t.symlink("link-to-a", to: t.path + "/a")
        let u = try XCTUnwrap(DiskUsage.measure(t.path))
        XCTAssertEqual(u.fileCount, 3)
        XCTAssertEqual(u.symlinkCount, 1)
        XCTAssertEqual(u.logicalBytes, 15_001)
        XCTAssertGreaterThanOrEqual(u.allocatedBytes, u.logicalBytes)
        XCTAssertEqual(u.directoryCount, 4)  // root, a, a/b, c
        XCTAssertTrue(u.unreadable.isEmpty)
        XCTAssertNil(DiskUsage.measure(t.path + "/nope"))
    }

    func testSingleFile() throws {
        let t = TempDir()
        let p = t.file("f", bytes: 123)
        let u = try XCTUnwrap(DiskUsage.measure(p))
        XCTAssertEqual(u.fileCount, 1); XCTAssertEqual(u.logicalBytes, 123)
    }

    func testDoesNotCrossMountPoints() throws {
        // /System/Volumes/Data is a separate mount under /System/Volumes; measuring the parent
        // directory must record it as skipped rather than descending into the whole data volume.
        guard MountStatus.isMountPoint("/System/Volumes/Data") else { throw XCTSkip("no split system/data volume") }
        let u = try XCTUnwrap(DiskUsage.measure("/System/Volumes"))
        XCTAssertTrue(u.skippedMountPoints.contains("/System/Volumes/Data"), "\(u.skippedMountPoints)")
        XCTAssertLessThan(u.allocatedBytes, 1_000_000_000, "must not have descended into the data volume")
    }
}

final class MountStatusTests: XCTestCase {
    func testRootIsMountPointAndTempDirIsNot() {
        XCTAssertTrue(MountStatus.isMountPoint("/"))
        let t = TempDir()
        XCTAssertFalse(MountStatus.isMountPoint(t.path))
        XCTAssertFalse(MountStatus.isMountPoint(t.path + "/missing"))
    }

    func testFilesystemInfo() throws {
        let fs = try XCTUnwrap(MountStatus.filesystem(containing: NSHomeDirectory()))
        XCTAssertFalse(fs.mountPoint.isEmpty)
        XCTAssertFalse(fs.isReadOnly)
        XCTAssertTrue(fs.isLocal)
        let space = try XCTUnwrap(MountStatus.space(at: NSHomeDirectory()))
        XCTAssertGreaterThan(space.total, space.free)
    }
}
