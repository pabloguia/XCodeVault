import XCTest

@testable import XCodeVaultCore

/// Regression tests for the migration-safety review findings (2026-09-06).
final class PathSafetyTests: XCTestCase {
    func testCanonicalizationRejectsRelativeComponentsAndResolvesInteriorSymlinks() throws {
        let t = TempDir()
        t.dir("real/Archives/x"); t.symlink("link", to: t.path + "/real")
        XCTAssertThrowsError(try PathSafety.canonicalize(t.path + "/real/Archives/../../etc"))
        XCTAssertThrowsError(try PathSafety.canonicalize("relative/path"))
        XCTAssertEqual(try PathSafety.canonicalize(t.path + "/link/Archives"), try PathSafety.canonicalize(t.path + "/real") + "/Archives")
        XCTAssertTrue(PathSafety.isContained(t.path + "/real/Archives/x", in: t.path + "/real/Archives"))
        XCTAssertTrue(PathSafety.isContained(t.path + "/real/Archives", in: t.path + "/real/Archives"))
        XCTAssertFalse(PathSafety.isContained(t.path + "/real/ArchivesEvil", in: t.path + "/real/Archives"), "prefix without separator must not match")
        XCTAssertFalse(PathSafety.isContained(t.path + "/real/Archives/../Other", in: t.path + "/real/Archives"))
        // A symlink INSIDE the approved tree pointing OUTSIDE is caught because canonicalization resolves the parent.
        t.dir("outside"); t.symlink("real/Archives/escape", to: t.path + "/outside")
        XCTAssertFalse(PathSafety.isContained(t.path + "/real/Archives/escape/file", in: t.path + "/real/Archives"))
    }
}

final class ReviewFixMigrationTests: XCTestCase {
    typealias Fixture = MigrationEngineTests.Fixture

    func testAbortRefusesAfterVerification() throws {
        let f = try Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        let outcome = try engine.copyAndVerify(plan)
        // Simulate a crash during CLEANUP: journal has the CLEANUP phase, source half-deleted.
        try f.journal.record(
            id: plan.operationID, kind: .migration, state: .started, summary: "CLEANUP", paths: [plan.source, plan.destination], detail: ["phase": "CLEANUP"])
        try FileManager.default.removeItem(atPath: f.archives + "/2026-09-02")
        XCTAssertThrowsError(try engine.abort(operationID: plan.operationID)) { XCTAssertTrue("\($0)".contains("only complete copy"), "\($0)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.plan.destination + "/2026-09-02/B.xcarchive/Info.plist"), "vault copy must survive")
        // Even the VERIFIED phase alone is enough to refuse.
        let plan2 = MigrationPlan(
            operationID: "op2", direction: .externalize, categoryID: "archives", source: f.archives, destination: f.vaultDir + "/archives/Other",
            vaultUUID: "VU", sourceBytes: 1, sourceFiles: 1, deepVerify: true, warnings: [])
        try f.journal.record(id: "op2", kind: .migration, state: .planned, summary: "p", paths: [plan2.source, plan2.destination], detail: ["phase": "PLAN"])
        try f.journal.record(
            id: "op2", kind: .migration, state: .completed, summary: "v", paths: [plan2.source, plan2.destination], detail: ["phase": "VERIFIED"])
        XCTAssertThrowsError(try engine.abort(operationID: "op2"))
    }

    func testRemoveSourceRefusesWhileXcodeRunsAndRestoresOnPostRenameMutation() throws {
        let f = try Fixture()
        var engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        let outcome = try engine.copyAndVerify(plan)
        engine.isXcodeRunning = { true }
        XCTAssertThrowsError(try engine.removeSource(outcome, confirmNonRegenerable: true)) { XCTAssertTrue("\($0)".contains("Xcode.app is running")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives))
        // Mutation after the rename (a write that raced the rename) must fail verification and restore the source.
        engine.isXcodeRunning = { false }
        engine.afterRenameAside = { aside in FileManager.default.createFile(atPath: aside + "/late.xcarchive", contents: Data([1])) }
        XCTAssertThrowsError(try engine.removeSource(outcome, confirmNonRegenerable: true)) { XCTAssertTrue("\($0)".contains("restored"), "\($0)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives + "/late.xcarchive"), "source restored at its original path with the late write intact")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.archives + ".xcodevault-removing-" + String(plan.operationID.prefix(8))))
    }

    func testSourcePathEscapesAreRejected() throws {
        let f = try Fixture()
        let engine = f.engine()
        f.t.dir("home/Documents/Important")
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.archives + "/../../../../Documents/Important", vaultRef: "VU"))
        f.t.symlink("home/Library/Developer/Xcode/Archives/escape", to: f.home + "/Documents/Important")
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.archives + "/escape", vaultRef: "VU"))
        // restore --to must stay inside the category path
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        _ = try engine.copyAndVerify(plan)
        XCTAssertThrowsError(try engine.planRestore(categoryID: "archives", vaultRef: "VU", name: "Archives", to: f.home + "/Documents/Restored"))
        XCTAssertThrowsError(try engine.planRestore(categoryID: "archives", vaultRef: "VU", name: "../..", to: f.archives + "-restored"))
    }

    func testDestinationClaimIsAtomicAndPreexistingDataIsNeverDeleted() throws {
        let f = try Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        // Something appears at the destination between planning and copying (another process, another Mac).
        f.t.file("vault/" + VaultVolume.directoryName + "/archives/Archives/precious", bytes: 3)
        XCTAssertThrowsError(try engine.copyAndVerify(plan)) { XCTAssertTrue("\($0)".contains("appeared since planning"), "\($0)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination + "/precious"), "pre-existing vault data must not be deleted on failure")
    }
}

final class ReReviewTests: XCTestCase {
    typealias Fixture = MigrationEngineTests.Fixture

    func testQuarantinedFilesSurviveVerificationAfterDitto() throws {
        let f = try Fixture()
        let quarantined = f.archives + "/2026-09-01/App.xcarchive/Info.plist"
        let q = "0083;68bd0000;Safari;ABCDEF"
        XCTAssertEqual(setxattr(quarantined, "com.apple.quarantine", q, q.utf8.count, 0, 0), 0)
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        let outcome = try engine.copyAndVerify(plan)
        XCTAssertTrue(outcome.verification.isIdentical, "\(outcome.verification.mismatches)")
        // The flag itself must have survived the copy.
        XCTAssertGreaterThan(getxattr(plan.destination + "/2026-09-01/App.xcarchive/Info.plist", "com.apple.quarantine", nil, 0, 0, 0), 0)
        // But a *missing* quarantine flag on the copy is still a mismatch.
        XCTAssertEqual(removexattr(plan.destination + "/2026-09-01/App.xcarchive/Info.plist", "com.apple.quarantine", 0), 0)
        XCTAssertFalse(TreeVerifier(deep: false).verify(source: f.archives, destination: plan.destination).isIdentical)
    }

    /// `resume` used to recover the category by splitting the journal's free-text `summary` on
    /// spaces, falling back to `"archives"`, and to read the `aside` path — the one that reaches
    /// `removeItem` — as "the last entry that happens to carry the key". Both are gone. These tests
    /// are written to FAIL against the implementations they exclude; two earlier versions of them
    /// passed against the old parser as well, which made them decoration.
    private func cleanupInterruptedAfterRename(_ f: MigrationEngineTests.Fixture) throws -> (MigrationPlan, String) {
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        _ = try engine.copyAndVerify(plan)
        // The name `removeSource` would have produced. `resume` derives it rather than reading it.
        let aside = f.archives + ".xcodevault-removing-" + String(plan.operationID.prefix(8))
        XCTAssertEqual(rename(f.archives, aside), 0)
        // The line `removeSource` writes before renaming. Without it the operation reads as complete
        // rather than interrupted, and `resume` is not the verb under test at all.
        try f.journal.record(
            id: plan.operationID, kind: .migration, state: .started, summary: "CLEANUP rename",
            paths: [plan.source, plan.destination], detail: ["phase": "CLEANUP"])
        return (plan, aside)
    }

    private func rewriteJournal(_ f: MigrationEngineTests.Fixture, _ transform: (String) -> String) throws {
        let url = URL(fileURLWithPath: f.t.path + "/journal.jsonl")
        try transform(try String(contentsOf: url, encoding: .utf8)).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Foundation's `JSONEncoder` escapes forward slashes by default, so the journal holds
    /// `\/var\/folders\/…`. A plain replacement of a path silently matches nothing — which is how a
    /// test like this ends up asserting against an unmodified journal and passing for free.
    private func replacePath(_ text: String, _ from: String, _ to: String) -> String {
        let esc = { (p: String) in p.replacingOccurrences(of: "/", with: "\\/") }
        return text.replacingOccurrences(of: esc(from), with: esc(to)).replacingOccurrences(of: from, with: to)
    }

    /// The distinguishing case: the PLAN line's *summary* names one category and its `category`
    /// field names another. The old parser read the plan line's summary, so this is exactly where
    /// the two implementations disagree.
    func testResumeBelievesTheCategoryFieldAndNotThePlanLinesProse() throws {
        let f = try MigrationEngineTests.Fixture()
        let (plan, aside) = try cleanupInterruptedAfterRename(f)
        try rewriteJournal(f) { $0.replacingOccurrences(of: "externalize archives:", with: "externalize derivedData:") }
        // Without this the test passes against an untouched journal: the field would still say
        // `archives`, the confirmation would still be demanded, and the assertion below would be
        // satisfied for the wrong reason. The string depends on a summary format defined in
        // `copyAndVerify`, three functions away.
        XCTAssertTrue(
            try String(contentsOf: URL(fileURLWithPath: f.t.path + "/journal.jsonl"), encoding: .utf8).contains("externalize derivedData:"),
            "precondition: the summary rewrite did not take effect")
        // derivedData is regenerable: under the old parser the confirmation would have been skipped
        // and the delete would have proceeded. The field still says archives, so it must be demanded.
        XCTAssertThrowsError(try f.engine().resume(operationID: plan.operationID, confirmNonRegenerable: false)) { e in
            XCTAssertTrue("\(e)".contains("non-regenerable"), "the summary was believed over the field: \(e)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside), "a refused resume deleted the aside copy")
    }

    /// And the case that separates `planned.detail` from "the first entry that carries the key":
    /// strip the field from the PLAN line only, and let a later line offer one.
    func testALaterLineCannotSupplyTheCategoryThePlanLineLacks() throws {
        let f = try MigrationEngineTests.Fixture()
        let (plan, aside) = try cleanupInterruptedAfterRename(f)
        try rewriteJournal(f) {
            $0.replacingOccurrences(of: ",\"category\":\"archives\"", with: "").replacingOccurrences(of: "\"category\":\"archives\",", with: "")
        }
        try f.journal.record(
            id: plan.operationID, kind: .migration, state: .started, summary: "CLEANUP rename",
            paths: [plan.source, plan.destination], detail: ["phase": "CLEANUP", "category": "derivedData"])
        XCTAssertThrowsError(try f.engine().resume(operationID: plan.operationID, confirmNonRegenerable: true)) { e in
            XCTAssertTrue("\(e)".contains("without guessing"), "a later line supplied the category: \(e)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside))
    }

    /// The `aside` path is the one that reaches `removeItem`. It used to come from the journal, so a
    /// single appended line pointing it at the destination would have deleted the vault copy — a
    /// tree verifies as identical against itself.
    func testAJournalLineCannotAimTheDeletionAtTheVaultCopy() throws {
        let f = try MigrationEngineTests.Fixture()
        let (plan, aside) = try cleanupInterruptedAfterRename(f)
        try f.journal.record(
            id: plan.operationID, kind: .migration, state: .started, summary: "CLEANUP rename",
            paths: [plan.source, plan.destination], detail: ["phase": "CLEANUP", "aside": plan.destination])
        _ = try? f.engine().resume(operationID: plan.operationID, confirmNonRegenerable: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plan.destination + "/2026-09-02/B.xcarchive/Info.plist"),
            "the vault copy was deleted by a path taken from the journal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside), "the real aside should still have been processed normally")
    }

    /// A refusal must describe what is on disk, not assert it. The original is at the aside path at
    /// this point, not at `source`; an earlier version of this message sent the user to `source` and
    /// told them to delete "the original" there.
    func testTheRefusalMessageNamesTheCopyThatActuallyHoldsTheData() throws {
        let f = try MigrationEngineTests.Fixture()
        let (plan, aside) = try cleanupInterruptedAfterRename(f)
        try rewriteJournal(f) {
            $0.replacingOccurrences(of: ",\"category\":\"archives\"", with: "").replacingOccurrences(of: "\"category\":\"archives\",", with: "")
        }
        XCTAssertThrowsError(try f.engine().resume(operationID: plan.operationID, confirmNonRegenerable: true)) { e in
            let m = "\(e)"
            XCTAssertTrue(m.contains(aside), "the message does not name where the original actually is: \(m)")
            XCTAssertFalse(m.contains("remove the original yourself"), "still tells the user to delete by hand: \(m)")
            XCTAssertTrue(m.contains("forget"), "a refusal that wedges the tool must name the way out: \(m)")
        }
    }

    /// The destination is re-confirmed to be *on the verified vault volume*, by UUID and sentinel —
    /// not merely to exist. After a crash and a reboot the external volume can lose the mount race
    /// and a directory holding an older copy can sit at the mount point; `lstat` cannot tell those
    /// apart, and deleting against the wrong one leaves shadow data as the only survivor.
    func testResumeRefusesWhenTheVaultVolumeCannotBeReConfirmed() throws {
        let f = try MigrationEngineTests.Fixture()
        let (plan, aside) = try cleanupInterruptedAfterRename(f)
        // The plan recorded vault "VU"; point it at a volume the registry does not know.
        try rewriteJournal(f) { $0.replacingOccurrences(of: "\"vault\":\"VU\"", with: "\"vault\":\"NOT-REGISTERED\"") }
        XCTAssertThrowsError(try f.engine().resume(operationID: plan.operationID, confirmNonRegenerable: true)) { e in
            // Named, not just "some error": this refusal comes out of `resolveUsable` rather than a
            // `MigrationError`, so a bare throws-assertion would keep passing if that function later
            // started throwing for an incidental reason.
            XCTAssertTrue("\(e)".contains("NOT-REGISTERED"), "the refusal does not name the volume it could not confirm: \(e)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside), "the original was deleted against an unconfirmed volume")
    }

    /// ...and the copy must actually be *inside* that volume's vault directory. A byte-identical
    /// shadow at some other path is exactly what this check exists to reject.
    func testResumeRefusesWhenTheCopyIsNotInsideTheVaultDirectory() throws {
        let f = try MigrationEngineTests.Fixture()
        let (plan, aside) = try cleanupInterruptedAfterRename(f)
        // A perfect copy of the vault copy, outside the vault — the shadow-directory shape.
        let shadow = f.t.path + "/shadow"
        // Take the destination as the journal actually spells it. `plan.destination` and the stored
        // string can differ by /private prefixing, and a rewrite keyed on the wrong one silently
        // changes nothing — which would leave this test passing against a missing guard.
        let stored = try XCTUnwrap(
            f.journal.entries().first { $0.id == plan.operationID && $0.state == .planned }?.paths.last)
        try ProcessCommandRunner().check(Tools.ditto, [stored, shadow])
        try rewriteJournal(f) { replacePath($0, stored, shadow) }
        XCTAssertNotEqual(
            try f.journal.entries().first { $0.id == plan.operationID && $0.state == .planned }?.paths.last, stored,
            "precondition: the journal rewrite did not take effect")
        XCTAssertThrowsError(try f.engine().resume(operationID: plan.operationID, confirmNonRegenerable: true)) { e in
            XCTAssertTrue("\(e)".contains("not on the verified vault volume"), "\(e)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside), "the original was deleted against a shadow copy")
    }

    /// `Journal.read` drops undecodable lines silently, so a torn write to the PLAN line would make
    /// the COPY line first — two paths, no category — and an implementation that trusts
    /// `entries.first` would proceed on it. The refusal must name the real problem, not misreport a
    /// corrupt journal as an old one.
    func testACorruptPlanLineIsReportedAsCorruptRatherThanAsAnOldJournal() throws {
        let f = try MigrationEngineTests.Fixture()
        let (plan, aside) = try cleanupInterruptedAfterRename(f)
        try rewriteJournal(f) { text in
            text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.contains("\"planned\"") ? "{ this line is truncated" : String($0) }
                .joined(separator: "\n") + "\n"
        }
        XCTAssertThrowsError(try f.engine().resume(operationID: plan.operationID, confirmNonRegenerable: true)) { e in
            XCTAssertTrue("\(e)".contains("no readable PLAN line"), "a non-plan line was trusted, or the cause was misreported: \(e)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside))
    }

    /// `copyAndVerify` deliberately leaves the source intact and the operation `completed`. That is
    /// not an interrupted cleanup, and `resume` — whose abstract promises only to finish interrupted
    /// work — must not delete the original of a healthy copy.
    func testResumeRefusesAHealthyCompletedCopyRatherThanDeletingItsOriginal() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        _ = try engine.copyAndVerify(plan)  // VERIFIED, source intact, nothing interrupted
        XCTAssertThrowsError(try engine.resume(operationID: plan.operationID, confirmNonRegenerable: true)) { e in
            XCTAssertTrue("\(e)".contains("not interrupted"), "\(e)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives + "/2026-09-02/B.xcarchive/Info.plist"), "the original was deleted")
    }

    /// The disconnect case, not an attack: crash during COPY, reboot, the vault loses the mount race
    /// and an ordinary local directory sits where the volume should be. `lstat` succeeds and the
    /// mount-point check does not fire, because the *volume* would be the mount point while the
    /// destination is several levels under it. `abort` is the command the tool tells the user to run.
    func testAbortRefusesToDeleteADestinationThatIsNotInsideTheVaultDirectory() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        // A crash during COPY: the partial copy exists, nothing reached verification.
        let stranded = f.t.path + "/not-the-vault/archives/Archives"
        try FileManager.default.createDirectory(atPath: stranded, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stranded + "/partial", contents: Data([1]))
        try f.journal.record(
            id: plan.operationID, kind: .migration, state: .planned, summary: "x", paths: [plan.source, stranded],
            detail: ["vault": "VU", "phase": "PLAN", "category": "archives", "direction": "externalize"])
        try f.journal.record(id: plan.operationID, kind: .migration, state: .started, summary: "COPY", paths: [plan.source, stranded], detail: ["phase": "COPY"])

        XCTAssertThrowsError(try engine.abort(operationID: plan.operationID)) { e in
            XCTAssertTrue("\(e)".contains("not the partial copy this externalization made"), "\(e)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranded + "/partial"), "abort deleted local data that was never a partial copy")
    }

    /// `forget` must not take the operations that belong to `abort`. Recording `.rolledBack` on a
    /// pre-verification failure drops it out of `leftoverPartialCopies`, so `doctor`,
    /// `migration status` and the retry hint all stop being able to name the partial copy it left.
    func testForgetRefusesPreVerificationFailuresSoItCannotOrphanAPartialCopy() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        try f.journal.record(
            id: plan.operationID, kind: .migration, state: .planned, summary: "x", paths: [plan.source, plan.destination],
            detail: ["vault": "VU", "phase": "PLAN", "category": "archives"])
        try f.journal.record(id: plan.operationID, kind: .migration, state: .started, summary: "COPY", paths: [plan.source, plan.destination], detail: ["phase": "COPY"])
        try FileManager.default.createDirectory(atPath: plan.destination, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: plan.destination + "/partial", contents: Data([1]))
        XCTAssertEqual(try engine.leftoverPartialCopies().map(\.id), [plan.operationID], "precondition: the partial copy is visible")

        XCTAssertThrowsError(try engine.forget(operationID: plan.operationID, confirmComparedBothCopies: true)) { e in
            XCTAssertTrue("\(e)".contains("migration abort"), "the refusal must name the verb that actually cleans this up: \(e)")
        }
        XCTAssertEqual(try engine.leftoverPartialCopies().map(\.id), [plan.operationID], "the partial copy stopped being visible")
    }

    /// The aside branch is the one `removeItem` that does not go through `preflightSource`. Its
    /// target must still belong to the category that is supposed to own it.
    func testTheAsideDeleteRevalidatesTheSourceAgainstItsCategory() throws {
        let f = try MigrationEngineTests.Fixture()
        let (plan, aside) = try cleanupInterruptedAfterRename(f)
        // Move both the recorded source and its aside outside anything `archives` templates cover.
        let outside = f.t.path + "/elsewhere/Archives"
        try FileManager.default.createDirectory(atPath: f.t.path + "/elsewhere", withIntermediateDirectories: true)
        XCTAssertEqual(rename(aside, outside + ".xcodevault-removing-" + String(plan.operationID.prefix(8))), 0)
        let storedSource = try XCTUnwrap(
            f.journal.entries().first { $0.id == plan.operationID && $0.state == .planned }?.paths.first)
        try rewriteJournal(f) { replacePath($0, storedSource, outside) }

        XCTAssertThrowsError(try f.engine().resume(operationID: plan.operationID, confirmNonRegenerable: true)) { e in
            // Pinned by message, not merely "it threw". A later refusal inserted above this guard
            // would otherwise make the test pass while the guard itself stopped being reached — the
            // mutation run that proved control gets here happens once; this assertion runs forever.
            XCTAssertTrue("\(e)".contains("approved"), "refused for some other reason than containment: \(e)")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside + ".xcodevault-removing-" + String(plan.operationID.prefix(8))),
            "deleted a path that does not belong to the category")
    }

    /// A restore's partial copy sits at the canonical home path, not on the vault — so checking
    /// every abort against the vault directory refuses every restore, with a message claiming the
    /// copy is not this migration's when it is exactly this migration's. No test aborted a restore,
    /// which is how that shipped unnoticed for a pass.
    func testAbortRemovesTheHalfRestoredCopyAtTheCanonicalPath() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        // A restore that failed during COPY: source is the vault copy, destination is the home path.
        let vaultCopy = f.vaultDir + "/archives/Archives"
        try FileManager.default.createDirectory(atPath: vaultCopy, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: vaultCopy + "/A", contents: Data([1]))
        // Inside the category's template, which is what `planRestore` requires of a destination —
        // restoring one archive back beside the others. A sibling with a suffix is not contained and
        // would not have been an acceptable plan in the first place.
        let halfRestored = f.archives + "/2026-09-03"
        try FileManager.default.createDirectory(atPath: halfRestored, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: halfRestored + "/partial", contents: Data([1]))
        let op = UUID().uuidString
        try f.journal.record(
            id: op, kind: .migration, state: .planned, summary: "restore archives", paths: [vaultCopy, halfRestored],
            detail: ["vault": "VU", "phase": "PLAN", "category": "archives", "direction": "restore"])
        try f.journal.record(id: op, kind: .migration, state: .started, summary: "COPY", paths: [vaultCopy, halfRestored], detail: ["phase": "COPY"])

        try engine.abort(operationID: op)
        XCTAssertFalse(FileManager.default.fileExists(atPath: halfRestored), "the half-restored copy was left at a canonical developer path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultCopy + "/A"), "abort touched the vault copy")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: f.archives + "/2026-09-02/B.xcarchive/Info.plist"),
            "abort removed more of the live tree than the copy this migration made")
    }

    /// The `.restore` arm narrows, it does not merely duplicate the legacy one: a restore whose
    /// destination is on the vault is not a restore's partial copy. Without this, deleting the
    /// `.restore` case entirely would leave every other abort test green, because `.none` accepts
    /// `onVault` as well as `atOwnHome`.
    func testARestoreIsJudgedAgainstItsOwnLocationAndNotTheVault() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let onVault = f.vaultDir + "/archives/Archives"
        try FileManager.default.createDirectory(atPath: onVault, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: onVault + "/A", contents: Data([1]))
        let op = UUID().uuidString
        try f.journal.record(
            id: op, kind: .migration, state: .planned, summary: "restore archives", paths: [f.archives, onVault],
            detail: ["vault": "VU", "phase": "PLAN", "category": "archives", "direction": "restore"])
        try f.journal.record(id: op, kind: .migration, state: .started, summary: "COPY", paths: [f.archives, onVault], detail: ["phase": "COPY"])

        XCTAssertThrowsError(try engine.abort(operationID: op)) { e in
            XCTAssertTrue("\(e)".contains("not the partial copy this restore made"), "\(e)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: onVault + "/A"), "a restore's abort deleted something on the vault")
    }

    /// The ordinary failed restore on an unplugged drive: `abort` cannot act (its `source` is the
    /// vault copy), so `forget` must take it. Before the decision was factored into one function,
    /// both verbs refused this and the residue at a canonical path had no owner.
    func testForgetTakesAFailedRestoreWhoseDriveIsUnplugged() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let halfRestored = f.archives + "/2026-09-03"
        try FileManager.default.createDirectory(atPath: halfRestored, withIntermediateDirectories: true)
        let op = UUID().uuidString
        let goneSource = "/Volumes/GONE/XCodeVault/archives/Archives"
        try f.journal.record(
            id: op, kind: .migration, state: .planned, summary: "restore archives", paths: [goneSource, halfRestored],
            detail: ["vault": "NOT-REGISTERED", "phase": "PLAN", "category": "archives", "direction": "restore"])
        try f.journal.record(id: op, kind: .migration, state: .started, summary: "COPY", paths: [goneSource, halfRestored], detail: ["phase": "COPY"])

        // `abort` CAN act here — the destination is local and inside the category's own location —
        // so `forget` must decline and point at it. That is the invariant, stated once.
        XCTAssertThrowsError(try engine.forget(operationID: op, confirmComparedBothCopies: true)) { e in
            XCTAssertTrue("\(e)".contains("migration abort"), "\(e)")
        }
        try engine.abort(operationID: op)
        XCTAssertFalse(FileManager.default.fileExists(atPath: halfRestored), "the half-restored copy survived an abort that should have removed it")
    }

    /// The two rows where "ask `abort`" and "re-derive the rule" disagree. Without these, factoring
    /// the decision is indistinguishable from leaving it duplicated, and the duplication is what put
    /// a partial copy beyond every verb in the product.
    ///
    /// Row one: a legacy PLAN line (no `direction`) with the vault absent but the destination at the
    /// category's own location. `abort` can clean it. The old derivation read "not a restore, vault
    /// absent" and let `forget` take it — dropping a reachable partial copy out of
    /// `leftoverPartialCopies` permanently.
    func testForgetDeclinesALegacyOperationAbortCanStillClean() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let stray = f.archives + "/2026-09-03"
        try FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)
        let op = UUID().uuidString
        try f.journal.record(
            id: op, kind: .migration, state: .planned, summary: "x", paths: [f.archives, stray],
            detail: ["vault": "NOT-REGISTERED", "phase": "PLAN", "category": "archives"])  // no `direction`
        try f.journal.record(id: op, kind: .migration, state: .started, summary: "COPY", paths: [f.archives, stray], detail: ["phase": "COPY"])

        XCTAssertThrowsError(try engine.forget(operationID: op, confirmComparedBothCopies: true)) { e in
            XCTAssertTrue("\(e)".contains("migration abort"), "forget took an operation abort can clean: \(e)")
        }
        try engine.abort(operationID: op)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray), "abort could not clean what forget refused to take")
    }

    /// Row two: a restore whose destination `abort` declines. `abort` cannot act, so `forget` must
    /// take it. The old derivation refused every restore, so this one had no owner at all.
    func testForgetTakesARestoreAbortDeclines() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let elsewhere = f.t.path + "/nowhere-a-restore-belongs"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        let op = UUID().uuidString
        try f.journal.record(
            id: op, kind: .migration, state: .planned, summary: "restore archives", paths: [f.vaultDir + "/archives/Archives", elsewhere],
            detail: ["vault": "VU", "phase": "PLAN", "category": "archives", "direction": "restore"])
        try f.journal.record(id: op, kind: .migration, state: .started, summary: "COPY", paths: [f.vaultDir + "/archives/Archives", elsewhere], detail: ["phase": "COPY"])

        XCTAssertThrowsError(try engine.abort(operationID: op), "precondition: abort declines this one")
        try engine.forget(operationID: op, confirmComparedBothCopies: true)
        XCTAssertEqual(try f.journal.interrupted(), [], "the operation still blocks migrations")
        let record = try XCTUnwrap(f.journal.entries().filter { $0.id == op }.last)
        XCTAssertTrue(record.summary.contains("left untouched"), "the record does not say what happened to the path: \(record.summary)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere), "forget touched a file")
    }

    /// Row three: a torn PLAN line on a pre-verification failure. `abort` cannot establish paths,
    /// direction or category, so it refuses — and `forget` must therefore take it. Deciding "is
    /// there a usable PLAN line?" separately in each verb is what left this one owned by neither,
    /// and it was a regression introduced by the very pass that factored the rest of the decision.
    func testForgetTakesAnOperationWhosePlanLineIsUnreadable() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        _ = try engine.copyAndVerify(plan)
        // Pre-verification state with the PLAN line destroyed, the shape a torn write leaves.
        try rewriteJournal(f) { text in
            text.split(separator: "\n", omittingEmptySubsequences: true)
                .filter { !$0.contains("\"VERIFIED\"") }
                .map { $0.contains("\"planned\"") ? "{ truncated" : String($0) }
                .joined(separator: "\n") + "\n"
        }
        XCTAssertFalse(try f.journal.interrupted().isEmpty, "precondition: the operation blocks migrations")

        XCTAssertThrowsError(try engine.abort(operationID: plan.operationID)) { e in
            XCTAssertTrue("\(e)".contains("no readable PLAN line"), "\(e)")
        }
        try engine.forget(operationID: plan.operationID, confirmComparedBothCopies: true)
        XCTAssertEqual(try f.journal.interrupted(), [], "both verbs refused and the operation stayed wedged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination), "forget touched the copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives), "forget touched the source")
    }

    /// With the vault absent, `abort` cannot look at the destination at all. Recording "no partial
    /// copy present" would be a confident terminal claim about a disk that is not here — and would
    /// drop the operation out of `leftoverPartialCopies` forever.
    func testAbortWillNotClaimThereIsNoPartialCopyOnAVolumeItCannotSee() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let op = UUID().uuidString
        let onGoneDrive = "/Volumes/GONE/XCodeVault/archives/Archives"
        try f.journal.record(
            id: op, kind: .migration, state: .planned, summary: "externalize archives", paths: [f.archives, onGoneDrive],
            detail: ["vault": "NOT-REGISTERED", "phase": "PLAN", "category": "archives", "direction": "externalize"])
        try f.journal.record(id: op, kind: .migration, state: .started, summary: "COPY", paths: [f.archives, onGoneDrive], detail: ["phase": "COPY"])

        XCTAssertThrowsError(try engine.abort(operationID: op)) { e in
            XCTAssertTrue("\(e)".contains("cannot be determined"), "\(e)")
        }
        XCTAssertEqual(try f.journal.entries().filter { $0.id == op }.last?.state, .started, "abort recorded a terminal state anyway")
        XCTAssertEqual(try engine.leftoverPartialCopies().map(\.id), [], "nothing is listed while the volume is away, but the entry is still open")
    }

    /// ...and that is the one case `forget` must accept, or the two verbs refuse the same operation
    /// and the user has no way out at all.
    func testForgetAcceptsThePreVerificationCaseAbortCannotReach() throws {
        let f = try MigrationEngineTests.Fixture()
        let engine = f.engine()
        let op = UUID().uuidString
        let onGoneDrive = "/Volumes/GONE/XCodeVault/archives/Archives"
        try f.journal.record(
            id: op, kind: .migration, state: .planned, summary: "externalize archives", paths: [f.archives, onGoneDrive],
            detail: ["vault": "NOT-REGISTERED", "phase": "PLAN", "category": "archives", "direction": "externalize"])
        try f.journal.record(id: op, kind: .migration, state: .started, summary: "COPY", paths: [f.archives, onGoneDrive], detail: ["phase": "COPY"])

        try engine.forget(operationID: op, confirmComparedBothCopies: true)
        XCTAssertEqual(try f.journal.interrupted(), [], "the operation still blocks migrations")
        let record = try XCTUnwrap(f.journal.entries().filter { $0.id == op }.last)
        XCTAssertTrue(record.summary.contains("may remain"), "the record does not say a copy was abandoned: \(record.summary)")
        XCTAssertTrue(record.summary.contains(onGoneDrive), "the record does not name where: \(record.summary)")
    }

    /// Refusing leaves the operation `started` forever, which blocks every future migration. `forget`
    /// is the supported way out, and it must not touch a single file.
    func testForgetClearsTheEntryWithoutTouchingEitherCopy() throws {
        let f = try MigrationEngineTests.Fixture()
        let (plan, aside) = try cleanupInterruptedAfterRename(f)
        let engine = f.engine()
        XCTAssertThrowsError(try engine.forget(operationID: plan.operationID, confirmComparedBothCopies: false), "confirmation required")
        XCTAssertFalse(try f.journal.interrupted().isEmpty, "precondition: the operation is blocking")
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU"), "precondition: blocked")

        try engine.forget(operationID: plan.operationID, confirmComparedBothCopies: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside), "forget deleted the original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination + "/2026-09-02/B.xcarchive/Info.plist"), "forget deleted the vault copy")
        XCTAssertEqual(try f.journal.interrupted(), [], "the operation still blocks migrations")
    }

    func testResumeCompletesACleanupInterruptedAfterRename() throws {
        let f = try Fixture()
        let engine = f.engine()
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        _ = try engine.copyAndVerify(plan)
        // Crash after the rename-aside, before delete.
        let aside = f.archives + ".xcodevault-removing-" + String(plan.operationID.prefix(8))
        XCTAssertEqual(rename(f.archives, aside), 0)
        try f.journal.record(
            id: plan.operationID, kind: .migration, state: .started, summary: "CLEANUP rename", paths: [plan.source, plan.destination],
            detail: ["phase": "CLEANUP", "aside": aside])
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU"), "blocked while interrupted")
        XCTAssertThrowsError(try engine.abort(operationID: plan.operationID), "abort must refuse post-verification")
        XCTAssertThrowsError(try engine.resume(operationID: plan.operationID, confirmNonRegenerable: false))
        let msg = try engine.resume(operationID: plan.operationID, confirmNonRegenerable: true)
        XCTAssertTrue(msg.contains("removed"), msg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination + "/2026-09-02/B.xcarchive/Info.plist"))
        XCTAssertEqual(try f.journal.interrupted(), [], "resolved")
        // Resume with a corrupted aside restores it instead of deleting.
        let f2 = try Fixture(); let e2 = f2.engine()
        let p2 = try e2.planExternalize(categoryID: "archives", source: f2.archives, vaultRef: "VU")
        _ = try e2.copyAndVerify(p2)
        // The derived name, not an arbitrary one: `resume` no longer reads the aside path from the
        // journal, because that was the value that reached `removeItem`. A test that keeps naming
        // its own aside stops exercising the branch it claims to.
        let aside2 = f2.archives + ".xcodevault-removing-" + String(p2.operationID.prefix(8))
        XCTAssertEqual(rename(f2.archives, aside2), 0)
        FileManager.default.createFile(atPath: aside2 + "/late", contents: Data([1]))
        try f2.journal.record(
            id: p2.operationID, kind: .migration, state: .started, summary: "CLEANUP rename", paths: [p2.source, p2.destination],
            detail: ["phase": "CLEANUP"])
        XCTAssertThrowsError(try e2.resume(operationID: p2.operationID, confirmNonRegenerable: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f2.archives + "/late"), "restored to the original path")
    }
}

final class E6LeftoverTests: XCTestCase {
    typealias Fixture = MigrationEngineTests.Fixture
    func testFailedCopyWithSurvivingDestinationIsReportedAndAbortable() throws {
        let f = try Fixture()
        // The volume "vanishes" mid-copy: the failure path cannot remove the destination (simulate by making
        // the removal fail) — here we emulate the aftermath directly: a failed journal entry + a leftover copy.
        let engine = f.engine(afterCopy: { plan in
            // Recreate the destination after the engine deletes it, as if the volume had been absent at cleanup time
            // and came back later with the partial copy still on it.
            throw MigrationError("volume vanished")
        })
        let plan = try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        XCTAssertThrowsError(try engine.copyAndVerify(plan))
        // Emulate the partial copy surviving (the engine removed it here because the fixture "volume" never went away).
        f.t.file("vault/" + VaultVolume.directoryName + "/archives/Archives/partial.bin", bytes: 4096)
        let leftovers = try engine.leftoverPartialCopies()
        XCTAssertEqual(leftovers.map(\.id), [plan.operationID])
        XCTAssertThrowsError(try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")) { XCTAssertTrue("\($0)".contains("migration abort \(plan.operationID)"), "\($0)") }
        try engine.abort(operationID: plan.operationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.archives + "/2026-09-02/B.xcarchive/Info.plist"), "source untouched")
        XCTAssertEqual(try engine.leftoverPartialCopies(), [])
        XCTAssertNoThrow(try engine.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU"))
        // A verified migration's destination is never reported as a leftover, and never abortable.
        let healthy = f.engine()
        let ok = try healthy.planExternalize(categoryID: "archives", source: f.archives, vaultRef: "VU")
        _ = try healthy.copyAndVerify(ok)
        XCTAssertEqual(try healthy.leftoverPartialCopies(), [])
        XCTAssertThrowsError(try healthy.abort(operationID: ok.operationID))
    }
}

final class ReviewFixCleanTests: XCTestCase {
    func testExecutorRefusesPathEscapesAndNestedMounts() throws {
        let t = TempDir()
        t.dir("Library/Developer/Xcode/DerivedData"); t.dir("Documents/Secret")
        t.symlink("Library/Developer/Xcode/DerivedData/link", to: t.path + "/Documents/Secret")
        let executor = CleanExecutor(journal: Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl")), home: t.path, isXcodeRunning: { false })
        let escape = CleanAction(
            categoryID: "derivedData", categoryName: "DD", path: t.path + "/Library/Developer/Xcode/DerivedData/../../../../Documents/Secret", bytes: 1,
            isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        let viaLink = CleanAction(
            categoryID: "derivedData", categoryName: "DD", path: t.path + "/Library/Developer/Xcode/DerivedData/link/inner", bytes: 1, isExperimental: true,
            risk: .low, requiresRoot: false, notes: [])
        t.dir("Documents/Secret/inner")
        let r = try executor.execute(CleanPlan(actions: [escape, viaLink], skipped: [], warnings: []))
        XCTAssertEqual(r.deleted, []); XCTAssertEqual(r.failedPairs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.path + "/Documents/Secret/inner"))
        // Nested mount: attach a tiny disk image inside a DerivedData child and check the planner skips and the executor refuses.
        let img = t.path + "/img.sparseimage"
        let proj = t.dir("Library/Developer/Xcode/DerivedData/Proj-1")
        let mp = t.dir("Library/Developer/Xcode/DerivedData/Proj-1/mount")
        let create = try ProcessCommandRunner().run(
            Tools.hdiutil, ["create", "-quiet", "-size", "16m", "-fs", "APFS", "-type", "SPARSE", "-volname", "XCVT", img, "-ov"])
        guard create.succeeded, (try ProcessCommandRunner().run(Tools.hdiutil, ["attach", "-quiet", "-nobrowse", "-mountpoint", mp, img])).succeeded else {
            throw XCTSkip("hdiutil unavailable")
        }
        defer { _ = try? ProcessCommandRunner().run(Tools.hdiutil, ["detach", "-quiet", mp]) }
        FileManager.default.createFile(atPath: mp + "/on-the-volume", contents: Data([1]))
        let scanner = XCodeVaultCore.Scanner(runner: FakeRunner(responses: [:]), home: t.path, catalog: [StorageCatalog.category("derivedData")!])
        let items = scanner.resolveItems()
        let plan = CleanPlanner(home: t.path).plan(
            report: ScanReport(
                generatedAt: Date(), toolVersion: "t", catalogVersion: "c",
                host: HostEnvironment(
                    macOSVersion: "26", macOSBuild: "x", architecture: "arm64", homeDirectory: t.path, dataVolumeFreeBytes: 1, dataVolumeTotalBytes: 2,
                    userName: "t", isRoot: false), xcodes: [], runtimes: [], devices: [], volumes: [], items: items, summary: ScanSummary(), warnings: []))
        XCTAssertFalse(plan.actions.contains { $0.path == proj }, "child containing a mount must not be planned: \(plan.actions.map(\.path))")
        let forced = CleanAction(
            categoryID: "derivedData", categoryName: "DD", path: proj, bytes: 1, isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        let r2 = try executor.execute(CleanPlan(actions: [forced], skipped: [], warnings: []))
        XCTAssertEqual(r2.deleted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp + "/on-the-volume"), "data on the mounted volume must survive")
    }

    func testDeviceSetsUseSimctl() throws {
        let t = TempDir()
        t.file("Library/Developer/XCTestDevices/UUID/device.plist", bytes: 10)
        let scanner = XCodeVaultCore.Scanner(runner: FakeRunner(responses: [:]), home: t.path, catalog: [StorageCatalog.category("xctestDevices")!])
        let plan = CleanPlanner(home: t.path).plan(
            report: ScanReport(
                generatedAt: Date(), toolVersion: "t", catalogVersion: "c",
                host: HostEnvironment(
                    macOSVersion: "26", macOSBuild: "x", architecture: "arm64", homeDirectory: t.path, dataVolumeFreeBytes: 1, dataVolumeTotalBytes: 2,
                    userName: "t", isRoot: false), xcodes: [], runtimes: [], devices: [], volumes: [], items: scanner.resolveItems(), summary: ScanSummary(),
                warnings: []))
        XCTAssertEqual(plan.actions.map(\.method), [.simctlDeleteAllInDeviceSet])
        let runner = FakeRunner(responses: ["xcrun simctl --set \(t.path)/Library/Developer/XCTestDevices delete all": .init(status: 0, stdout: "", stderr: "")]
        )
        let executor = CleanExecutor(journal: Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl")), home: t.path, isXcodeRunning: { false }, runner: runner)
        let r = try executor.execute(plan)
        XCTAssertEqual(r.deleted.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.path + "/Library/Developer/XCTestDevices"))
    }
}

final class ReviewFixLocationsTests: XCTestCase {
    func testRefusesPlainDirectoryUnderVolumes() throws {
        // /Volumes/<name> that is not a mount point ⇒ shadow-data trap ⇒ refuse. We cannot create
        // one without root, so exercise the check through a path whose top component is verifiably
        // not a mount point when such a directory exists; otherwise assert the mount-point rule holds for a real one.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"),
            let plain = names.first(where: { !MountStatus.isMountPoint("/Volumes/" + $0) && !$0.hasPrefix(".") })
        {
            XCTAssertThrowsError(try XcodeLocations.preflightArchives(path: "/Volumes/" + plain, volumes: [], xcodeRunning: false))
        } else {
            throw XCTSkip("no plain directory under /Volumes on this machine")
        }
    }
}
