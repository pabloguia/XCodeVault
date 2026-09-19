import XCTest

@testable import XCodeVaultCore
@testable import XCodeVaultHelperCore

/// Issue #25: `MountStatus.isMountPoint` answered `false` both for "this is not a mount point" and
/// for "the attribute could not be read", which made every guard written as `guard !isMountPoint`
/// fail open on an unanswerable question.
///
/// These tests do three jobs. They pin the primitive against real paths; they pin the parity
/// between the two spellings of the same idea, which are duplicated on purpose; and they audit the
/// source for the guard shape that reintroduces the defect.
final class MountAnswerTests: XCTestCase {

    // MARK: the primitive

    func testARealMountPointAnswersIsMountPoint() {
        // `/` is a mount point on every Mac, needs no privilege to read, and is not a symlink —
        // which is why the guards that use it need no injected answer.
        XCTAssertEqual(MountStatus.mountAnswer("/"), .isMountPoint)
    }

    func testAnOrdinaryDirectoryAnswersIsNotMountPoint() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(MountStatus.mountAnswer(dir.path), .isNotMountPoint)
    }

    /// The case the whole issue is about. A missing path cannot answer the question, and the old
    /// `Bool` said "not a mount point" — a definite answer to a question that was never asked.
    func testAMissingPathAnswersUndeterminedRatherThanIsNotMountPoint() {
        let missing = "/" + UUID().uuidString + "/" + UUID().uuidString
        XCTAssertEqual(
            MountStatus.mountAnswer(missing), .undetermined,
            "A path that cannot be stat'd has no mount state. Reporting `.isNotMountPoint` here is the defect.")
    }

    /// The collapse still exists — it is a documented convenience, not an accident — so pin the
    /// direction it collapses in. A future change that made `isMountPoint` return `true` on
    /// `.undetermined` would be safer at the `guard !` sites and unsafe at the `guard` sites, and
    /// would silently invert four call sites that rely on the current direction.
    func testTheBoolConvenienceCollapsesUndeterminedToFalse() {
        let missing = "/" + UUID().uuidString
        XCTAssertEqual(MountStatus.mountAnswer(missing), .undetermined)
        XCTAssertFalse(MountStatus.isMountPoint(missing))
    }

    // MARK: parity between the two duplicated enums

    /// `XCodeVaultCore.MountStatus.MountAnswer` and `XCodeVaultHelperCore.HelperService.MountAnswer`
    /// are the same idea written twice, because sharing one would mean the root daemon importing
    /// all of Core. Nothing in the compiler keeps them in step, so this does.
    func testTheTwoMountAnswerSpellingsAgreeOnTheSameRealPaths() {
        XCTAssertEqual(MountStatus.mountAnswer("/"), .isMountPoint)
        XCTAssertEqual(HelperService.mountStatus("/"), .isMountPoint)

        let missing = "/" + UUID().uuidString
        XCTAssertEqual(MountStatus.mountAnswer(missing), .undetermined)
        XCTAssertEqual(HelperService.mountStatus(missing), .undetermined)
    }

    /// Case-set parity, asserted by exhaustive switch rather than by counting. If either enum
    /// gains or loses a case, one of these stops compiling — which is the point: a drift that
    /// only a runtime assertion catches is a drift that ships in a build nobody ran the tests on.
    func testTheTwoMountAnswerSpellingsHaveTheSameCases() {
        func coreIsExhaustive(_ a: MountStatus.MountAnswer) -> String {
            switch a {
            case .isMountPoint: return "isMountPoint"
            case .isNotMountPoint: return "isNotMountPoint"
            case .undetermined: return "undetermined"
            }
        }
        func helperIsExhaustive(_ a: HelperService.MountAnswer) -> String {
            switch a {
            case .isMountPoint: return "isMountPoint"
            case .isNotMountPoint: return "isNotMountPoint"
            case .undetermined: return "undetermined"
            }
        }
        XCTAssertEqual(coreIsExhaustive(.undetermined), helperIsExhaustive(.undetermined))
        XCTAssertEqual(coreIsExhaustive(.isMountPoint), helperIsExhaustive(.isMountPoint))
        XCTAssertEqual(coreIsExhaustive(.isNotMountPoint), helperIsExhaustive(.isNotMountPoint))
    }

    // MARK: the audit

    /// Sites where the module reads the `Bool` convenience in a negated form, which is where
    /// `.undetermined` collapsing to `false` becomes `true` and lets an operation through on a
    /// question that was never answered.
    ///
    /// Every known-safe site is allowlisted **by file and by the reason it is safe**, so the test
    /// fails on anything new rather than on a shape it happens to recognise. A first version was
    /// far narrower than its own description — it required the literal `MountStatus.` prefix,
    /// matched single lines only, and exempted every `if`. A reviewer pointed out that this made
    /// the seam spelling at `RuntimeOperations.swift:132` invisible, along with multi-line guards
    /// (ordinary at this repo's 160 columns), `== false`, and ternaries.
    private static let negatedReadAllowlist: [String: String] = [
        // Diagnostics. `.undetermined` raises the finding rather than suppressing it, and
        // over-reporting is the safe direction for a rule that only proposes.
        "Doctor.swift": "diagnostic — over-reports on .undetermined",
        "Doctor+Vault.swift": "diagnostic — over-reports on .undetermined",
        // Double negation: the function returns "is NOT on a mounted volume", and both callers
        // turn that into a refusal. `.undetermined` therefore refuses. Documented at its :112.
        "RuntimeOperations.swift": "double negation — .undetermined refuses at both call sites",
    ]

    func testNoGuardNegatesTheBoolConvenience() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/XCodeVaultCore")

        var offenders: [String] = []
        var allowlistHits: Set<String> = []
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("Could not walk \(sources.path)")
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (n, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments describe the collapse at length in this codebase; they are not reads.
                guard !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") else { continue }
                // Both spellings: qualified, and the injectable-seam form without the prefix.
                let negated =
                    trimmed.contains("!MountStatus.isMountPoint(") || trimmed.contains("!isMountPoint(")
                    || trimmed.contains("MountStatus.isMountPoint(") && trimmed.contains("== false")
                    || trimmed.contains("isMountPoint(") && trimmed.contains("== false")
                guard negated else { continue }
                if let reason = Self.negatedReadAllowlist[url.lastPathComponent] {
                    allowlistHits.insert("\(url.lastPathComponent): \(reason)")
                    continue
                }
                offenders.append("\(url.lastPathComponent):\(n + 1): \(trimmed)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            A negated read of the `Bool` convenience appeared outside the allowlist. This is the \
            issue #25 defect: `.undetermined` collapses to `false`, the negation makes it `true`, \
            and whatever follows proceeds on a question that was never answered.

            Either switch on `MountStatus.mountAnswer` and handle `.undetermined` explicitly, or — \
            if the direction is genuinely safe here — add the file to `negatedReadAllowlist` with \
            the reason, so the next reader sees the argument rather than an absence.

            \(offenders.joined(separator: "\n"))
            """)

        // The allowlist must not outlive its entries. A stale exemption is how a scan quietly
        // stops covering the thing it was written for.
        let allowlistedFiles = Set(Self.negatedReadAllowlist.keys)
        let hitFiles = Set(allowlistHits.map { String($0.split(separator: ":")[0]) })
        XCTAssertEqual(
            allowlistedFiles, hitFiles,
            "Every allowlisted file must still contain a negated read. Stale entries: \(allowlistedFiles.subtracting(hitFiles))")
    }

    /// The message has to survive `localizedDescription`, or the assertion above is pinning a
    /// sentence nothing ever shows. Found through that assertion: every error type in this module
    /// rendered as Foundation's placeholder wherever the code asked for `localizedDescription`.
    func testTheModulesErrorsRenderTheirOwnTextThroughLocalizedDescription() {
        let errors: [(any Error, String)] = [
            (MigrationError("the mount question was not answered"), "the mount question was not answered"),
            (CleanError("refusing to clean a mount point"), "refusing to clean a mount point"),
            (VaultError("the vault is not where it says"), "the vault is not where it says"),
            (RuntimeOperationError("the installer is gone"), "the installer is gone"),
        ]
        for (error, text) in errors {
            XCTAssertEqual(
                error.localizedDescription, text,
                """
                \(type(of: error)) loses its message through `localizedDescription`, which is what \
                `catch` handlers, the journal and the CLI print. Conform it to `DescribedError`.
                """)
        }
    }

    // MARK: the sites that were fixed

    /// Only a directory can be a mount point, so a non-directory is a definite `.isNotMountPoint`
    /// even though the attribute itself comes back short.
    ///
    /// This is here because the first version of the fix got it backwards. `ATTR_DIR_MOUNTSTATUS`
    /// is a directory attribute; every regular file and device node returns a four-byte reply, and
    /// reading that as `.undetermined` would have made `Scanner` mark every catalog path that is a
    /// plain file as "mount state unreadable" — which `CleanPlanner` then refuses to clean. A
    /// regression introduced by a safety fix, found by probing the syscall instead of assuming.
    func testANonDirectoryIsDefinitelyNotAMountPointEvenThoughTheAttributeIsShort() {
        XCTAssertEqual(MountStatus.mountAnswer("/dev/null"), .isNotMountPoint, "a device node cannot be a mount point")
        XCTAssertFalse(
            XCodeVaultCore.Scanner().resolve(categoryID: "derivedData", path: "/dev/null", bootMountPoint: "/").mountStateUndetermined,
            "a plain file must not be reported as having an unreadable mount state; CleanPlanner refuses those")
    }

    /// A directory with no permissions still answers, because `getattrlist` needs search permission
    /// on the **parent**, not on the entry. Pinned because the first attempt at staging an
    /// `.undetermined` directory used exactly this and silently got a definite answer instead.
    func testADirectoryWithNoPermissionsStillAnswersTheMountQuestion() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let opaque = root.appendingPathComponent("opaque")
        try FileManager.default.createDirectory(at: opaque, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: opaque.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: opaque.path)
        XCTAssertEqual(MountStatus.mountAnswer(opaque.path), .isNotMountPoint)
    }

    /// `abort` refuses the *deletion* on an unanswered mount question — and still journals the
    /// attempt, so the abort/forget termination bound advances.
    ///
    /// This is the shape the fix had to take. The obvious place for the refusal is
    /// `abortDisposition`, and putting it there re-broke the bound: that function runs before any
    /// journal line, so declining means `ABORT_FAILED` is never written and both verbs refuse the
    /// operation forever. The guard therefore lives inside the `do` block whose `catch` writes
    /// that record. This test pins both halves — the refusal happens, *and* it is the kind of
    /// refusal the entry can recover from.
    ///
    /// Without the message assertion this would pass on the fix being absent: `removeItem` through
    /// a `0o000` parent fails with `EACCES` on its own, throws, and journals the same record. The
    /// message is the only thing that distinguishes "refused because the question was unanswered"
    /// from "tried and was denied".
    func testAbortRefusesTheDeletionWhenTheMountQuestionCannotBeAnswered() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        try f.journal.record(
            id: plan.operationID, kind: .migration, state: .planned, summary: "x",
            paths: [plan.source, plan.destination],
            detail: ["vault": "VU", "phase": "PLAN", "category": "archives"])
        try f.journal.record(
            id: plan.operationID, kind: .migration, state: .failed, summary: "COPY",
            paths: [plan.source, plan.destination], detail: ["phase": "COPY"])
        try FileManager.default.createDirectory(atPath: plan.destination, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: plan.destination + "/partial", contents: Data([9]))

        // An unreadable parent is what makes `getattrlist` fail on the destination, which is the
        // `.undetermined` this is about.
        let parent = (plan.destination as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: parent) }

        XCTAssertEqual(
            MountStatus.mountAnswer(plan.destination), .undetermined,
            "precondition: with the parent unreadable, the mount question has no answer")

        XCTAssertThrowsError(try engine.abort(operationID: plan.operationID)) { e in
            XCTAssertTrue(
                "\(e)".contains("Could not determine whether") && "\(e)".contains("is a mount point"),
                "abort must say it refused because the mount question was unanswered, not report a bare permission error. Got: \(e)")
        }
        XCTAssertEqual(
            try f.journal.entries().filter { $0.id == plan.operationID && $0.detail["phase"] == "ABORT_FAILED" }.count, 1,
            "the refusal must be journalled, or the bound never advances and both verbs wedge")

        // The liveness half: the pair can still close the entry, with the copy left named.
        XCTAssertThrowsError(try engine.abort(operationID: plan.operationID))
        try engine.forget(operationID: plan.operationID, confirmComparedBothCopies: true)
        XCTAssertEqual(
            try engine.knownLeftoversAfterForget().map(\.id), [plan.operationID],
            "refusing the delete may not cost the ability to close the entry")
    }

    /// `DiskUsage` does not record an ordinary readable directory as skipped or unreadable.
    ///
    /// This is the control half of the `DiskUsage` change, and the only half that can be staged.
    /// **The `.undetermined` branch in that walk is not covered by any test, and this comment is
    /// the honest statement of that gap rather than a skipped test that reads like coverage.**
    ///
    /// Why it cannot be staged: `fts` only yields an entry whose parent it enumerated
    /// successfully, and `getattrlist` needs search permission on the *parent*, not on the entry —
    /// so a directory `fts` reaches can essentially always answer. A `0o000` directory answers
    /// `.isNotMountPoint` (pinned above). What is left as a producer of `.undetermined` for a
    /// directory is a filesystem that does not implement `ATTR_DIR_MOUNTSTATUS`, or an I/O error,
    /// and neither can be created inside a unit test on APFS.
    ///
    /// The branch is kept because it is correct defensively and costs four lines, and because the
    /// alternative — injecting the answer — was tried elsewhere in this repo under issue #13 and a
    /// reviewer showed it only moved the untested mutation to the line feeding the seam.
    func testDiskUsageDoesNotMarkAnOrdinaryDirectoryAsSkippedOrUnreadable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: nested.appendingPathComponent("f").path, contents: Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: root) }

        let usage = try XCTUnwrap(DiskUsage.measure(root.path))
        XCTAssertTrue(usage.skippedMountPoints.isEmpty, "an ordinary nested directory is not a skipped mount point")
        XCTAssertTrue(usage.unreadable.isEmpty, "and it is not unreadable")
        XCTAssertFalse(usage.isLowerBound, "so the total is exact")
        XCTAssertEqual(usage.fileCount, 1, "and the walk actually descended — without this the three assertions above are vacuous")
    }

    /// `StorageItem` carries the third state in its own field rather than folding it into
    /// `isMountPoint`, so that a report never asserts a mount that was never observed.
    ///
    /// Only the two definite outcomes are asserted here, and that is the honest limit: reaching
    /// `mountStateUndetermined == true` needs an existing, non-symlink path whose mount question is
    /// unanswerable, which is the same unstageable class as the `DiskUsage` branch above. The
    /// field's consumer is pinned instead, by
    /// `testCleanPlannerSkipsAnItemWhoseMountStateCouldNotBeRead`, which builds the item directly.
    func testAScannedItemSeparatesBeingAMountPointFromNotHavingBeenAnswered() {
        // Fully qualified: `Scanner` unqualified resolves to `Foundation.Scanner`.
        //
        // `measureSizes: false` is load-bearing, not tidiness. The default is `true`, and
        // `resolve` then calls `DiskUsage.measure` on the path — so the first version of this
        // test, which resolves `/`, walked the entire boot volume. It ran for fifteen minutes
        // before it was killed, and nothing about the failure said "this test is measuring your
        // disk": the suite simply never finished. This test is about the mount-state fields and
        // wants no byte counts at all.
        let scanner = XCodeVaultCore.Scanner(measureSizes: false)

        let root = scanner.resolve(categoryID: "derivedData", path: "/", bootMountPoint: "/")
        XCTAssertTrue(root.isMountPoint, "`/` is a mount point")
        XCTAssertFalse(root.mountStateUndetermined, "and the question was answered, so the field must be false")

        let file = scanner.resolve(categoryID: "derivedData", path: "/dev/null", bootMountPoint: "/")
        XCTAssertFalse(file.isMountPoint, "a device node is not a mount point")
        XCTAssertFalse(file.mountStateUndetermined, "and that is a definite answer, not an unreadable one")
    }

    func testCleanPlannerSkipsAnItemWhoseMountStateCouldNotBeRead() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let dir = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/ProjA-abc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        func item(undetermined: Bool) -> StorageItem {
            StorageItem(
                categoryID: "derivedData", path: dir.path, exists: true, isSymlink: false, symlinkTarget: nil,
                isMountPoint: false, mountStateUndetermined: undetermined,
                usage: DiskUsage(
                    allocatedBytes: 4096, logicalBytes: 4096, fileCount: 1, directoryCount: 1, symlinkCount: 0,
                    skippedMountPoints: [], unreadable: []),
                volumeMountPoint: "/", onBootVolume: true)
        }
        func report(_ items: [StorageItem]) -> ScanReport {
            ScanReport(
                generatedAt: Date(), toolVersion: "t", catalogVersion: "c",
                host: HostEnvironment(
                    macOSVersion: "26.6", macOSBuild: "x", architecture: "arm64", homeDirectory: home.path,
                    dataVolumeFreeBytes: 1, dataVolumeTotalBytes: 2, userName: "t", isRoot: false),
                xcodes: [], runtimes: [], devices: [], volumes: [], items: items, summary: ScanSummary(), warnings: [])
        }
        let planner = CleanPlanner(home: home.path)

        // Control: the same item is plannable when the mount state *was* readable. Without this the
        // assertion below would pass for any reason the planner declined, including the wrong one.
        let control = planner.plan(report: report([item(undetermined: false)]))
        XCTAssertEqual(control.actions.map(\.path), [dir.path], "precondition: this item is plannable when its mount state is known")

        let plan = planner.plan(report: report([item(undetermined: true)]))
        XCTAssertTrue(
            plan.actions.isEmpty,
            "An item whose mount state could not be read must not be planned for deletion; the executor refuses it anyway.")
        XCTAssertTrue(
            plan.skipped.contains(where: { $0.contains("could not determine whether it is a mount point") }),
            "The skip must say why. Got: \(plan.skipped)")
    }
}
