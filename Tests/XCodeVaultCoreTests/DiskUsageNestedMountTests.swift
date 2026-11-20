import XCTest

@testable import XCodeVaultCore

/// STATUS open item 13, #66's accepted gap: a mount point inside the disk-image store (`CoreSimulator/Images`, which can
/// hold `Images/mnt`) must be recorded and left out of the store's total, not counted with it. No test can mount a volume
/// inside a fixture, so these answer a fixture directory *as* a mount point through `DiskUsage.measure(_:mountAnswer:)`.
final class DiskUsageNestedMountTests: XCTestCase {
    private var images = ""

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcv-nested-mount-\(UUID().uuidString)")
        images = root.appendingPathComponent("Images").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: images + "/Inbox", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: images + "/mnt/inner", withIntermediateDirectories: true)
        try Data(count: 64 * 1024).write(to: URL(fileURLWithPath: images + "/R1.dmg"))
        try Data(count: 16 * 1024).write(to: URL(fileURLWithPath: images + "/Inbox/R2.dmg"))
        // What a mounted runtime image would hold: big, and never part of the store's bytes.
        try Data(count: 512 * 1024).write(to: URL(fileURLWithPath: images + "/mnt/inner/payload"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private func answering(_ path: String, _ answer: MountStatus.MountAnswer) -> (String) -> MountStatus.MountAnswer {
        { $0 == path ? answer : .isNotMountPoint }
    }

    /// The seam changes nothing when it answers what the filesystem would: the public entry point and the seam agree.
    func testTheSeamWithTheRealAnswerMatchesThePublicEntryPoint() throws {
        let viaPublic = try XCTUnwrap(DiskUsage.measure(images))
        let viaSeam = try XCTUnwrap(DiskUsage.measure(images, mountAnswer: MountStatus.mountAnswer))
        XCTAssertEqual(viaPublic, viaSeam)
        XCTAssertTrue(viaPublic.skippedMountPoints.isEmpty)
        XCTAssertEqual(viaPublic.fileCount, 3)
    }

    func testAMountInsideTheStoreIsRecordedAndNotCounted() throws {
        let whole = try XCTUnwrap(DiskUsage.measure(images, mountAnswer: { _ in .isNotMountPoint }))
        let pruned = try XCTUnwrap(DiskUsage.measure(images, mountAnswer: answering(images + "/mnt", .isMountPoint)))

        XCTAssertEqual(pruned.skippedMountPoints, [images + "/mnt"])
        XCTAssertFalse(pruned.isLowerBound, "a mount point that answered is excluded by design, not a missing read")
        XCTAssertEqual(pruned.fileCount, 2, "the two images, not the mounted payload")
        XCTAssertEqual(pruned.logicalBytes, 80 * 1024)
        XCTAssertGreaterThanOrEqual(whole.allocatedBytes - pruned.allocatedBytes, 512 * 1024, "the payload's bytes are gone")
        // The mount point itself is not counted as one of the store's directories either: root, Inbox — not mnt, not inner.
        XCTAssertEqual(pruned.directoryCount, 2)
    }

    /// Any depth, not only the store's direct children: a mutation to `fts_level == 1` must not survive.
    func testAMountDeeperInTheStoreIsRecordedToo() throws {
        let deep = images + "/mnt/inner"
        let u = try XCTUnwrap(DiskUsage.measure(images, mountAnswer: answering(deep, .isMountPoint)))
        XCTAssertEqual(u.skippedMountPoints, [deep])
        XCTAssertEqual(u.fileCount, 2, "the payload is under the deeper mount")
        XCTAssertEqual(u.directoryCount, 3, "root, Inbox and mnt; not inner")
    }

    /// The Inbox breakdown is a separate measurement of a subtree; a mount beside it does not leak into it.
    func testTheInboxBreakdownIsUnaffectedByTheMountBesideIt() throws {
        let inbox = try XCTUnwrap(DiskUsage.measure(images + "/Inbox", mountAnswer: answering(images + "/mnt", .isMountPoint)))
        XCTAssertTrue(inbox.skippedMountPoints.isEmpty)
        XCTAssertEqual(inbox.logicalBytes, 16 * 1024)
    }

    /// Issue #25's case inside the store: an unanswerable nested directory is recorded (so `CleanPlanner` skips the item)
    /// and makes the total a lower bound, because its bytes are deliberately missing.
    func testAnUndeterminedNestedDirectoryIsRecordedAndMakesALowerBound() throws {
        let u = try XCTUnwrap(DiskUsage.measure(images, mountAnswer: answering(images + "/mnt", .undetermined)))
        XCTAssertEqual(u.skippedMountPoints, [images + "/mnt"])
        XCTAssertEqual(u.unreadable, [images + "/mnt"])
        XCTAssertTrue(u.isLowerBound)
        XCTAssertEqual(u.privacyRefusalCount, 0, "not a privacy refusal: nothing was refused")
        XCTAssertEqual(u.fileCount, 2)
    }

    /// The measured root itself is never asked (`fts_level > 0`): the store being a mount point is the scanner's
    /// question (`Scanner.resolve`), not the walk's, and answering it here must not empty the total.
    func testTheRootIsNeverAskedByTheWalk() throws {
        var asked: [String] = []
        let u = try XCTUnwrap(
            DiskUsage.measure(
                images,
                mountAnswer: {
                    asked.append($0); return $0 == self.images ? .isMountPoint : .isNotMountPoint
                }))
        XCTAssertFalse(asked.contains(images), "\(asked)")
        XCTAssertTrue(u.skippedMountPoints.isEmpty)
        XCTAssertEqual(u.fileCount, 3)
    }
}
