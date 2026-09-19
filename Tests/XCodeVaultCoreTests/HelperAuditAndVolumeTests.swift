import XCTest

@testable import XCodeVaultCore
@testable import XCodeVaultHelperCore
@testable import XCodeVaultHelperProtocol

/// Issues #3, #4 and #5 — the three privileged-helper findings.
///
/// The helper has never run: no daemon registered, no XPC connection opened, and no shipped
/// artifact contains it (`bundle-app.sh` gates it behind `--with-helper`, off by default). All
/// three become live the moment that flag is used in a release, which is why they are fixed now
/// and why every one of these tests exercises the real primitive rather than a mock — there is no
/// production experience to fall back on if the test is wrong.
final class HelperAuditAndVolumeTests: XCTestCase {

    // MARK: issue #3 — ATTR_VOL_UUID parsed without ATTR_CMN_RETURNED_ATTRS

    /// The boot volume has a real UUID, so a correct parse must produce one.
    ///
    /// This is the control the rest of the issue rests on. The fix adds `ATTR_CMN_RETURNED_ATTRS`,
    /// which changes the reply layout — the UUID moves from offset 4 to offset 24 — so a fix that
    /// got the new offset wrong would read sixteen bytes of the returned-attribute set instead and
    /// produce a plausible-looking UUID that is not the volume's.
    func testTheBootVolumesUUIDIsReadAndMatchesTheIndependentReader() throws {
        let fromHelper = try XCTUnwrap(
            HelperService.volumeUUID(ofMountPoint: "/"), "the boot volume has a UUID; failing to read it is the fix reading the wrong offset")
        // `MountStatus.volumeUUID` is Core's own reader, written independently and without
        // `ATTR_CMN_RETURNED_ATTRS`. Agreement across two implementations is what says the offset
        // arithmetic is right, which a self-consistent parse cannot.
        let fromCore = try XCTUnwrap(XCodeVaultCoreVolumeUUIDReader.read("/"))
        XCTAssertEqual(
            fromHelper.uuidString.lowercased(), fromCore.lowercased(),
            "the helper's reader and Core's reader disagree about the boot volume — one of them is reading the wrong bytes")
    }

    /// Every mounted filesystem, not just the ones that behave. The issue named smbfs, nfs, webdav
    /// and FUSE as untested; whatever this machine has mounted is what can actually be checked.
    ///
    /// The property asserted is the one that was broken: a filesystem that does not supply the
    /// attribute must produce **nil**, never the all-zero UUID. Before the fix the zeros left in
    /// the buffer parsed as a valid `UUID` and acted as a wildcard.
    func testNoMountedFilesystemEverYieldsTheAllZeroUUID() {
        var mounts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        guard n > 0, let mounts else { return XCTFail("could not enumerate mounted filesystems") }
        defer { free(mounts) }

        var examined = 0
        for i in 0..<Int(n) {
            var fs = mounts[i]
            let mp = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            examined += 1
            if let uuid = HelperService.volumeUUID(ofMountPoint: mp) {
                XCTAssertNotEqual(
                    uuid, HelperService.nilVolumeUUID,
                    "\(mp) reported the all-zero UUID as a real one; that value matches any caller who sends it")
            }
        }
        XCTAssertGreaterThan(examined, 1, "a machine has more than one mounted filesystem; this test examined too few to mean anything")
    }

    /// The wildcard, closed at the entry point as well as at the parse. The issue asked for both:
    /// "treat the all-zero UUID as invalid input so it can never match a volume even if it arrives
    /// by another route."
    func testTheAllZeroUUIDNeverResolvesToAMountPoint() {
        XCTAssertNil(
            HelperService.mountPoint(forVolumeUUID: "00000000-0000-0000-0000-000000000000"),
            "the all-zero UUID must be refused before any filesystem is examined")
        // Case-insensitively too — `UUID(uuidString:)` accepts both spellings.
        XCTAssertNil(HelperService.mountPoint(forVolumeUUID: "00000000-0000-0000-0000-00000000000a".uppercased().replacingOccurrences(of: "A", with: "0")))
    }

    func testAMalformedUUIDResolvesToNothing() {
        XCTAssertNil(HelperService.mountPoint(forVolumeUUID: "not-a-uuid"))
        XCTAssertNil(HelperService.mountPoint(forVolumeUUID: ""))
    }

    /// A path that is not a mount point has no volume UUID *of its own* to report through this
    /// reader — the reader asks about the volume at that mount point.
    func testAMissingPathHasNoVolumeUUID() {
        XCTAssertNil(HelperService.volumeUUID(ofMountPoint: "/" + UUID().uuidString))
    }

    // MARK: issue #4 — the root daemon keeps no audit log

    func testAnUnauthorizedCallIsRecordedAsSuchRatherThanAsAnOrdinaryDecline() {
        let record = HelperAudit.AuditRecord.from(
            verb: "createVaultDirectory", callerUID: 501, validatedArguments: ["volumeUUID": "X"],
            result: HelperResult(ok: false, message: "not authorized: this operation requires an administrator account"),
            wasUnauthorized: true)
        XCTAssertEqual(record.outcome, .refusedUnauthorized)
        XCTAssertEqual(
            record.outcome.label, "refused-unauthorized",
            "the one line that matters most in this log must be distinguishable from an ordinary refusal")
    }

    func testASuccessCarriesTheBytesItFreed() {
        let record = HelperAudit.AuditRecord.from(
            verb: "removeRegenerableSystemDirectoryContents", callerUID: 501, validatedArguments: ["target": "/x"],
            result: HelperResult(ok: true, message: "cleaned /x", bytesFreed: 4096), wasUnauthorized: false)
        XCTAssertEqual(record.outcome, .succeeded(bytesFreed: 4096))
    }

    func testADeclineCarriesTheReasonTheCallerWasGiven() {
        let record = HelperAudit.AuditRecord.from(
            verb: "removeRegenerableSystemDirectoryContents", callerUID: 501, validatedArguments: ["target": "/x"],
            result: HelperResult(ok: false, message: "target is a mount point"), wasUnauthorized: false)
        XCTAssertEqual(
            record.outcome, .declined("target is a mount point"),
            "a verb must not be able to tell the caller one thing and the log another")
    }

    /// The record is derived from the `HelperResult` the caller receives, so the two cannot drift.
    /// Asserted as a property over both outcomes rather than by re-stating the mapping.
    func testTheRecordAgreesWithTheResultTheCallerReceives() {
        for (ok, message) in [(true, "cleaned"), (false, "refused")] {
            let result = HelperResult(ok: ok, message: message)
            let record = HelperAudit.AuditRecord.from(
                verb: "v", callerUID: 501, validatedArguments: [:], result: result, wasUnauthorized: false)
            switch record.outcome {
            case .succeeded: XCTAssertTrue(ok, "recorded success for a result that failed")
            case .declined(let why):
                XCTAssertFalse(ok, "recorded a decline for a result that succeeded")
                XCTAssertEqual(why, message)
            default: XCTFail("unexpected outcome \(record.outcome) for ok=\(ok)")
            }
        }
    }

    /// The authorization outcome is read from the result the caller received, not from a second
    /// evaluation of the gate.
    ///
    /// The second evaluation was the defect: the dispatch called `authorize()` to label the record
    /// while the verb called it again to enforce, and the two can disagree — a transient
    /// directory-service failure on the first and success on the second means the verb performs
    /// the work while the log says `refused-unauthorized`. Wrong in the direction that conceals a
    /// performed action.
    func testTheUnauthorizedLabelIsDerivedFromTheResultNotASecondEvaluation() {
        let refusal = HelperResult(ok: false, message: HelperService.unauthorizedMessage)
        XCTAssertTrue(HelperService.wasUnauthorized(refusal))

        // Any other refusal is a decline, not an authorization failure.
        XCTAssertFalse(HelperService.wasUnauthorized(HelperResult(ok: false, message: "target is a mount point")))
        XCTAssertFalse(HelperService.wasUnauthorized(HelperResult(ok: false, message: "invalid UUID")))
        // And a success is never an authorization failure, whatever its message says.
        XCTAssertFalse(
            HelperService.wasUnauthorized(HelperResult(ok: true, message: HelperService.unauthorizedMessage)),
            "a result the verb reported as ok must never be recorded as a refusal")
    }

    /// The constant carries a decision, so nothing else in the helper may produce that exact
    /// string — otherwise an ordinary decline would be recorded as an authorization failure.
    func testNoOtherRefusalInTheHelperAdoptsTheAuthorizationMessage() throws {
        let helperCore = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/XCodeVaultHelperCore")
        var producers: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: helperCore, includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" {
            for (n, line) in try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            {
                guard line.contains(HelperService.unauthorizedMessage) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // The one declaration is allowed; a doc comment quoting it is not a producer.
                guard !trimmed.hasPrefix("///"), !trimmed.hasPrefix("//") else { continue }
                guard !trimmed.contains("static let unauthorizedMessage") else { continue }
                producers.append("\(url.lastPathComponent):\(n + 1): \(trimmed)")
            }
        }
        XCTAssertTrue(
            producers.isEmpty,
            """
            Something other than `unauthorizedMessage` produces the authorization refusal string.             `wasUnauthorized` compares against it to label the audit record, so a second producer             makes an ordinary decline look like an authorization failure in the root daemon's trail.

            \(producers.joined(separator: "\n"))
            """)
    }

    // MARK: issue #5 — the identity of the directory the verb just created

    /// The truth table for `isTheObjectThisCallJustCreated`, exhausted.
    ///
    /// Extracted from `doCreateVaultDirectory` precisely so it could be exhausted: a reviewer
    /// showed both checks were unkillable, because no test calls that verb and deleting either
    /// guard passed the build, the suite and the invariants script. This file's own rule, written
    /// beside `mayTakeOwnership`, is that a guard no test can fail is a guard the next refactor
    /// deletes.
    func testTheCreatedObjectIdentityTruthTable() {
        typealias S = HelperService
        let sameDev: dev_t = 42, otherDev: dev_t = 43

        // A different filesystem is refused whether or not this call created the directory — that
        // is the mount-appeared-under-the-name case, and `/Volumes` is where it happens.
        for created in [true, false] {
            XCTAssertEqual(
                S.isTheObjectThisCallJustCreated(
                    created: created, directoryDevice: otherDev, parentDevice: sameDev, linkCount: 2, directoryUID: 0),
                .differentFilesystem, "created=\(created)")
        }

        // Created by this call: must be empty (nlink 2) and root-owned.
        XCTAssertEqual(
            S.isTheObjectThisCallJustCreated(created: true, directoryDevice: sameDev, parentDevice: sameDev, linkCount: 2, directoryUID: 0),
            .yes)
        XCTAssertEqual(
            S.isTheObjectThisCallJustCreated(created: true, directoryDevice: sameDev, parentDevice: sameDev, linkCount: 3, directoryUID: 0),
            .notWhatWeCreated, "a directory with something in it is not one root made a moment ago")
        XCTAssertEqual(
            S.isTheObjectThisCallJustCreated(created: true, directoryDevice: sameDev, parentDevice: sameDev, linkCount: 2, directoryUID: 501),
            .notWhatWeCreated, "root created it, so root owns it")

        // Pre-existing: this function makes no identity claim; `mayTakeOwnership` decides, and it
        // refuses anything not already owned by the caller.
        for (nlink, uid) in [(nlink_t(2), uid_t(0)), (nlink_t(9), uid_t(501))] {
            XCTAssertEqual(
                S.isTheObjectThisCallJustCreated(
                    created: false, directoryDevice: sameDev, parentDevice: sameDev, linkCount: nlink, directoryUID: uid),
                .yes, "nlink=\(nlink) uid=\(uid)")
        }
    }

    // MARK: issue #5 — the mkdir/open race

    /// The window is closed by operating through a descriptor for the parent, and the parent is
    /// opened `O_NOFOLLOW`. A symlink where the volume root should be therefore fails the open
    /// rather than being followed — the first step of the walk the fix introduces.
    func testTheVerbRefusesAVolumeRootThatIsASymlink() throws {
        // The verb resolves the mount point itself from a UUID, so this exercises the primitive
        // the verb relies on rather than the verb: a symlink cannot be opened `O_NOFOLLOW`.
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let fd = open(link.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertLessThan(fd, 0, "O_NOFOLLOW must refuse a symlink; if this opens, the walk's first step is not a walk")
        // Either errno is a correct refusal and which one appears is Darwin's business, not this
        // code's: `O_DIRECTORY` is evaluated against the symlink itself — which is not a directory,
        // hence `ENOTDIR` — while `O_NOFOLLOW` alone would give `ELOOP`. Measured as `ENOTDIR` on
        // macOS 26. Asserting the specific value pinned the kernel's ordering rather than the
        // property, and failed on the first run for a reason that says nothing about safety.
        XCTAssertTrue(
            errno == ELOOP || errno == ENOTDIR,
            "the refusal must be about the symlink (ELOOP) or about it not being a directory (ENOTDIR), not something unrelated. Got errno \(errno)")
    }

    /// The identity check the fix leans on: a directory root has just created is empty, and an
    /// empty directory has exactly two links — `.` and its entry in the parent. A directory
    /// renamed into the name in the meantime existed before, so it fails this unless it is also
    /// empty and root-owned.
    func testAFreshlyCreatedDirectoryHasExactlyTwoLinksAndAPopulatedOneDoesNot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fresh = root.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        var st = stat()
        XCTAssertEqual(lstat(fresh.path, &st), 0)
        XCTAssertEqual(st.st_nlink, 2, "an empty directory is `.` plus its parent's entry, and nothing else")

        try FileManager.default.createDirectory(at: fresh.appendingPathComponent("child"), withIntermediateDirectories: true)
        XCTAssertEqual(lstat(fresh.path, &st), 0)
        XCTAssertGreaterThan(st.st_nlink, 2, "a directory with a subdirectory in it is distinguishable from a fresh one")
    }

    /// `fstatat` with `AT_SYMLINK_NOFOLLOW` relative to a parent descriptor sees the same object
    /// the later `openat` will, which is the property that replaced the path-based `lstat`.
    func testFstatatRelativeToAParentDescriptorSeesTheEntryWithoutResolvingThePath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d"), withIntermediateDirectories: true)

        let parentFD = open(root.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(parentFD, 0)
        defer { close(parentFD) }

        var st = stat()
        XCTAssertEqual(fstatat(parentFD, "d", &st, AT_SYMLINK_NOFOLLOW), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFDIR)
        XCTAssertNotEqual(fstatat(parentFD, "missing", &st, AT_SYMLINK_NOFOLLOW), 0, "and it reports absence rather than succeeding")

        // Same device as the parent: the check that refuses a volume mounted onto the name between
        // the `mkdirat` and the `openat`.
        var parentST = stat()
        XCTAssertEqual(fstat(parentFD, &parentST), 0)
        let fd = openat(parentFD, "d", O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var childST = stat()
        XCTAssertEqual(fstat(fd, &childST), 0)
        XCTAssertEqual(childST.st_dev, parentST.st_dev, "an ordinary child is on the parent's filesystem")
    }
}

/// Issue #16 — `Change.key` was a free-form `String` written straight into
/// `defaults write com.apple.dt.Xcode`.
final class XcodeLocationsKeyTests: XCTestCase {
    /// The enumeration must cover exactly the four keys the tool owns, and each case must resolve
    /// to the key the rest of the type already declares. Without this the enum is a second place
    /// the key literals live, free to disagree with the first.
    func testEveryCaseResolvesToTheKeyTheTypeAlreadyDeclares() {
        XCTAssertEqual(XcodeLocations.Key.allCases.count, 4, "four keys are owned; a fifth case is a fifth Xcode preference this tool writes")
        XCTAssertEqual(XcodeLocations.Key.derivedData.defaultsKey, XcodeLocations.derivedDataKey)
        XCTAssertEqual(XcodeLocations.Key.buildLocationStyle.defaultsKey, XcodeLocations.buildLocationStyleKey)
        XCTAssertEqual(XcodeLocations.Key.archives.defaultsKey, XcodeLocations.archivesKey)
        XCTAssertEqual(XcodeLocations.Key.compilationCache.defaultsKey, XcodeLocations.compilationCacheKey)
    }

    /// Every owned key is a real `IDE…` preference and they are distinct. A case that resolved to
    /// the empty string, or two that resolved to the same key, would both compile.
    func testTheOwnedKeysAreDistinctAndLookLikeXcodePreferences() {
        let keys = XcodeLocations.Key.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count, "two cases resolve to the same defaults key: \(keys)")
        for k in keys {
            XCTAssertTrue(k.hasPrefix("IDE"), "\(k) does not look like an Xcode Locations preference")
        }
    }

    /// The short name used in journal entries and CLI output is deliberately *not* the defaults
    /// key. Pinned because tying them together — `rawValue` returning the `IDE…` literal — would
    /// make renaming the short name silently rewrite a real Xcode preference key.
    func testTheShortNameIsNotTheDefaultsKey() {
        for key in XcodeLocations.Key.allCases {
            XCTAssertNotEqual(key.rawValue, key.defaultsKey, "\(key) has fused its display name and the preference key it writes")
        }
    }
}

/// A deliberately separate reader, so the helper's parse is checked against something that was not
/// written from the same misunderstanding. Mirrors `MountStatus.volumeUUID` without importing Core
/// into a test that is about the helper.
private enum XCodeVaultCoreVolumeUUIDReader {
    static func read(_ path: String) -> String? {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBytes { getattrlist(path, &attrList, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) }
        let returned = buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard rc == 0, returned >= 20 else { return nil }
        let b = Array(buffer[4..<20])
        guard b.contains(where: { $0 != 0 }) else { return nil }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
    }
}
