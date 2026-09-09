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
    /// The three shapes the previous inline copies missed, all fail-open: the caller would conclude
    /// "nothing points here" and offer to delete a live redirect target.
    func testSymlinkRedirectDetectionClosesTheChainedSlashAndCaseGaps() {
        let t = TempDir()
        let candidate = t.dir("target")

        // 1. chained: link -> hop -> candidate. One hop of resolution matches nothing.
        t.symlink("hop", to: candidate)
        let chained = t.symlink("chained", to: t.path + "/hop")
        XCTAssertTrue(PathSafety.symlinkRedirectsBetween(chained, candidate), "a link to a link must still count")

        // 2. doubled slash: URL.standardized does not collapse the empty component; realpath does.
        let doubled = t.symlink("doubled", to: t.path + "//target")
        XCTAssertTrue(PathSafety.symlinkRedirectsBetween(doubled, candidate), "// must not defeat the comparison")

        // 3. relative, with .. — resolved against the link's own directory, not the cwd.
        t.dir("deep/nested")
        let rel = t.symlink("deep/nested/rel", to: "../../target")
        XCTAssertTrue(PathSafety.symlinkRedirectsBetween(rel, candidate), "relative destinations must resolve")
    }

    /// Containment must hold in both directions: a redirect at the *parent* (the mac-ssd-rescue
    /// layout, where ~/Library/Developer points at the volume root) contains the candidate rather
    /// than being contained by it.
    func testSymlinkRedirectDetectionIsBidirectional() {
        let t = TempDir()
        t.dir("volume/inner")
        let parentLink = t.symlink("points-at-parent", to: t.path + "/volume")
        XCTAssertTrue(PathSafety.symlinkRedirectsBetween(parentLink, t.path + "/volume/inner"), "parent-of-candidate counts")
        let deeperLink = t.symlink("points-deeper", to: t.path + "/volume/inner")
        XCTAssertTrue(PathSafety.symlinkRedirectsBetween(deeperLink, t.path + "/volume"), "child-of-candidate counts")
    }

    func testUnrelatedSymlinkAndNonSymlinkAreNotReportedAsRedirects() {
        let t = TempDir()
        let candidate = t.dir("target")
        t.dir("elsewhere")
        let away = t.symlink("away", to: t.path + "/elsewhere")
        XCTAssertFalse(PathSafety.symlinkRedirectsBetween(away, candidate), "an unrelated link must not match")
        XCTAssertFalse(PathSafety.symlinkRedirectsBetween(t.dir("plain"), candidate), "a plain directory is not a redirect")
        XCTAssertFalse(PathSafety.symlinkRedirectsBetween(t.path + "/missing", candidate), "a missing link is not a redirect")
    }

    /// A link whose target does not exist still has to be compared — otherwise a dangling redirect
    /// into the directory we are about to advise deleting reads as "nothing points here".
    func testDanglingSymlinkStillCompares() {
        let t = TempDir()
        let dangling = t.symlink("dangling", to: t.path + "/not-created-yet")
        XCTAssertTrue(PathSafety.symlinkRedirectsBetween(dangling, t.path + "/not-created-yet"))
    }

    /// The root volume is always mounted and always reports a UUID, on any machine.
    func testRootVolumeReportsAMountPointAndAUUID() throws {
        XCTAssertTrue(MountStatus.isMountPoint("/"))
        let uuid = try XCTUnwrap(MountStatus.volumeUUID(at: "/"), "the root volume must report a UUID")
        XCTAssertNotNil(UUID(uuidString: uuid), "must be a parseable UUID, got \(uuid)")
        XCTAssertNotEqual(uuid, "00000000-0000-0000-0000-000000000000", "all-zero must be reported as absent, not as an identity")
    }

    /// `getattrlist` with ATTR_VOL_* answers about the volume *containing* the path, so an ordinary
    /// directory reports its filesystem's UUID rather than nil. Callers must therefore pair this
    /// with `isMountPoint` — asking it alone cannot tell "this is the volume" from "this is on the
    /// volume". Pinned because the two functions read as interchangeable and are not.
    func testAnOrdinaryDirectoryReportsItsContainingVolumeNotNil() throws {
        let t = TempDir()
        XCTAssertFalse(MountStatus.isMountPoint(t.path), "a temp directory is not a mount point")
        let dirUUID = MountStatus.volumeUUID(at: t.path)
        XCTAssertNotNil(dirUUID, "ATTR_VOL_UUID answers for the containing volume, not only for mount points")
        let containing = try XCTUnwrap(MountStatus.filesystem(containing: t.path))
        XCTAssertEqual(dirUUID, MountStatus.volumeUUID(at: containing.mountPoint), "must match the volume it lives on")
    }

    func testMissingPathHasNoUUID() {
        XCTAssertNil(MountStatus.volumeUUID(at: "/definitely/not/a/real/path/\(UUID().uuidString)"))
    }

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
