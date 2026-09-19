import XCTest

@testable import XCodeVaultCore

/// Issue #26 — the offload journal recorded an installer's **path** and nothing that identified the
/// volume it was on, so `doctor` could not tell "the vault is unplugged" from "a different drive is
/// now mounted at `/Volumes/VAULT` and the file there belongs to somebody else".
///
/// The whole safety argument for `runtime offload` is *delete the installed runtime only because an
/// installer exists to restore it from*, and `doctor` re-states that argument to the user later. It
/// was re-stating it from a path.
final class OffloadVolumeIdentityTests: XCTestCase {

    // MARK: the plan carries the identity

    private func runtime(_ id: String = "RT") -> SimulatorRuntime {
        SimulatorRuntime(
            identifier: id, runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            platformIdentifier: "com.apple.platform.iphonesimulator", version: "26.5", build: "23F77", sizeBytes: 1_000)
    }

    private func installer(_ path: String) -> RuntimeInstaller {
        RuntimeInstaller(
            path: path, fileName: (path as NSString).lastPathComponent, sizeBytes: 900_000_000, modifiedAt: Date(),
            platform: "iOS", version: "26.5", build: "23F77")
    }

    private func ops() -> RuntimeOperations {
        RuntimeOperations(
            runner: FakeRunner(responses: [:]), journal: Journal(url: URL(fileURLWithPath: "/dev/null")),
            xcode: XcodeInstallation(
                path: "/Applications/Xcode.app", developerDirectory: "/Applications/Xcode.app/Contents/Developer",
                version: "26.5", build: "17F42", isSelected: true, capabilities: XcodeCapabilities()),
            host: HostEnvironment(
                macOSVersion: "26.6", macOSBuild: "x", architecture: "x86_64", homeDirectory: "/tmp",
                dataVolumeFreeBytes: 1 << 40, dataVolumeTotalBytes: 1 << 41, userName: "t", isRoot: false))
    }

    func testThePlanRecordsTheVolumeTheInstallerWasVerifiedOn() throws {
        let path = "/Volumes/VAULT/RuntimeLibrary/iphonesimulator_26.5_23F77.dmg"
        let (plan, warnings) = try ops().preflightOffload(
            identifier: "RT", library: "/Volumes/VAULT/RuntimeLibrary", installedRuntimes: [runtime()],
            isMountPoint: { _ in true }, listLibrary: { _ in [self.installer(path)] }, imageIsReadable: { _ in true },
            volumeUUIDAt: { _ in "AAAAAAAA-1111-2222-3333-444444444444" })

        XCTAssertEqual(plan.installerVolumeUUID, "AAAAAAAA-1111-2222-3333-444444444444")
        XCTAssertEqual(
            plan.journalDetail["installerVolumeUUID"], "AAAAAAAA-1111-2222-3333-444444444444",
            "the identity has to reach the journal, which is where `doctor` reads it back from")
        XCTAssertEqual(plan.journalDetail["installer"], path, "the path stays too — a user needs it to find the file")
        XCTAssertTrue(warnings.isEmpty, "a volume that reports a UUID needs no caveat: \(warnings)")
    }

    /// A filesystem that reports no UUID is a real case, and it must not look like one that does.
    func testAVolumeWithNoUUIDIsRecordedAsAbsentAndWarnedAbout() throws {
        let path = "/Volumes/VAULT/RuntimeLibrary/x.dmg"
        let (plan, warnings) = try ops().preflightOffload(
            identifier: "RT", library: "/Volumes/VAULT/RuntimeLibrary", installedRuntimes: [runtime()],
            isMountPoint: { _ in true }, listLibrary: { _ in [self.installer(path)] }, imageIsReadable: { _ in true },
            volumeUUIDAt: { _ in nil })

        XCTAssertNil(plan.installerVolumeUUID)
        XCTAssertNil(
            plan.journalDetail["installerVolumeUUID"],
            "an empty string in the journal would read as a recorded identity that matches nothing")
        XCTAssertTrue(
            warnings.contains { $0.contains("reports no volume UUID") },
            "the user has to be told that this offload cannot be identity-checked later. Got: \(warnings)")
    }

    // MARK: doctor reads it back

    /// The three states `doctor` has to keep apart, asserted through the finding a user actually
    /// reads. Building them by hand rather than through `offload` because the point is what the
    /// *journal* says, and a journal line is what survives a reboot.
    private func doctorFinding(installerOnDisk: URL, recordedUUID: String?, actualUUID: String?) throws -> Finding? {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Application Support/XCodeVault"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let journal = Journal(url: home.appendingPathComponent("Library/Application Support/XCodeVault/journal.jsonl"))
        var detail = ["runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "installer": installerOnDisk.path]
        if let recordedUUID { detail["installerVolumeUUID"] = recordedUUID }
        try journal.record(
            id: UUID().uuidString, kind: .runtimeOffload, state: .completed, summary: "offloaded",
            paths: [installerOnDisk.path], detail: detail)

        let doctor = Doctor(
            home: home.path, runner: FakeRunner(responses: [:]), journal: journal, volumeUUIDAt: { _ in actualUUID })
        let device = SimulatorDevice(
            udid: "U1", name: "iPhone 17", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            state: "Shutdown", isAvailable: false, availabilityError: "runtime profile not found")
        return doctor.checkUnavailableDevices(devices: [device]).first
    }

    /// A 900 MB file that passes the size floor, so the identity check is the only thing deciding.
    private func makeImage() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("iphonesimulator_26.5_23F77.dmg")
        // Sparse: `truncate` gives the size the floor reads without writing 900 MB.
        let fd = open(file.path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 900_000_000), 0)
        close(fd)
        return file
    }

    func testAMatchingVolumeStillPromisesRecovery() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
        let finding = try doctorFinding(installerOnDisk: image, recordedUUID: "AAAA-1111", actualUUID: "AAAA-1111")
        XCTAssertTrue(
            finding?.remediation?.contains("Re-import instead") ?? false,
            "a verified installer on the verified volume must still be offered as the recovery path. Got: \(finding?.remediation ?? "nil")")
    }

    /// **The case this issue is about.** A real image sits at the recorded path and it is on a
    /// different volume than the one that was verified.
    func testADifferentVolumeAtTheSamePathIsNotVouchedFor() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
        let finding = try doctorFinding(installerOnDisk: image, recordedUUID: "AAAA-1111", actualUUID: "BBBB-2222")
        let text = finding?.remediation ?? ""
        XCTAssertTrue(
            text.contains("different volume"),
            "doctor must say the file is on a different volume than the one verified. Got: \(text)")
        XCTAssertFalse(
            text.contains("Re-import instead"),
            "it must NOT offer the image as the recovery path — that is the reassurance the issue is about")
        XCTAssertFalse(
            text.contains("simctl delete unavailable` removes"),
            "and it must not fall through to the delete-is-safe branch either")
    }

    /// An entry written before the field existed carries no identity. It must keep working, and it
    /// must not be demoted: telling a user with a perfectly good installer that their devices are
    /// unrecoverable is the more dangerous of the two errors.
    func testAnEntryWithNoRecordedIdentityIsStillTrusted() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
        let finding = try doctorFinding(installerOnDisk: image, recordedUUID: nil, actualUUID: "BBBB-2222")
        let text = finding?.remediation ?? ""
        XCTAssertTrue(
            text.contains("Re-import instead"),
            "a pre-#26 entry has nothing to contradict, so it keeps its old behaviour. Got: \(text)")
        // Review finding F3. The comment above `isOnTheVolumeThatWasVerified` claimed these entries
        // were "separated out below so the wording never promises more than was checked" — and they
        // were not: this remediation was word-for-word the one given for a volume that *was*
        // verified. The claim was in a comment, which is the worst place for a property the code
        // does not have.
        XCTAssertTrue(
            text.contains("not by volume"),
            "the promise must say it rests on path and size, not on a verified drive. Got: \(text)")
    }

    /// The control for that qualifier: an entry whose volume *was* verified must not carry it, or
    /// the hedge is noise that teaches a user to ignore it.
    func testAVerifiedEntryCarriesNoIdentityCaveat() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
        let text = try doctorFinding(installerOnDisk: image, recordedUUID: "AAAA-1111", actualUUID: "AAAA-1111")?.remediation ?? ""
        XCTAssertTrue(text.contains("Re-import instead"), text)
        XCTAssertFalse(text.contains("not by volume"), "a verified entry has nothing to hedge. Got: \(text)")
    }

    // MARK: the fall-through (review finding F2)

    /// The journal records an offload, the drive **is** mounted, and the installer is not on it.
    /// That is neither "reachable" nor "disconnected", so it fell through to the final branch —
    /// which tells the user the journal records no offloaded runtime and that deletion is fine.
    ///
    /// The sentence was false and it was the one sentence that green-lights a permanent delete.
    func testAnInstallerMissingFromAMountedVolumeIsNotReportedAsNoOffloadRecorded() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Recorded, and not there. A temp path is not under `/Volumes`, so the disconnected rule
        // correctly declines it — which is exactly how it reached the final `else`.
        let absent = dir.appendingPathComponent("iphonesimulator_26.5_23F77.dmg")

        let text = try doctorFinding(installerOnDisk: absent, recordedUUID: "AAAA-1111", actualUUID: "AAAA-1111")?.remediation ?? ""
        XCTAssertFalse(
            text.contains("journal records no offloaded runtime"),
            "the journal records one; saying otherwise is what makes the deletion look safe. Got: \(text)")
        XCTAssertTrue(text.contains("Do NOT run"), "it must still advise against the permanent delete. Got: \(text)")
        XCTAssertTrue(
            text.contains("is not there") || text.contains("too small"),
            "and it must say what is actually wrong: the drive is here and the installer is not. Got: \(text)")
    }

    /// The same shape with a file that exists and is too small to be an installer — a truncated or
    /// interrupted copy, which `isUsableImage` also rejects.
    func testATruncatedInstallerOnAMountedVolumeIsReportedTheSameWay() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("iphonesimulator_26.5_23F77.dmg")
        FileManager.default.createFile(atPath: stub.path, contents: Data(repeating: 0, count: 1024))

        let text = try doctorFinding(installerOnDisk: stub, recordedUUID: "AAAA-1111", actualUUID: "AAAA-1111")?.remediation ?? ""
        XCTAssertFalse(text.contains("journal records no offloaded runtime"), text)
        XCTAssertTrue(text.contains("Do NOT run"), text)
    }

    /// Recorded identity, and the volume cannot be read at all now. That is not a match.
    func testAnUnreadableVolumeDoesNotCountAsMatching() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
        let finding = try doctorFinding(installerOnDisk: image, recordedUUID: "AAAA-1111", actualUUID: nil)
        XCTAssertFalse(
            finding?.remediation?.contains("Re-import instead") ?? false,
            "an identity that was recorded and cannot now be checked is not a match")
    }

    // MARK: the destructive step (review finding F1)

    /// `offload` re-validates before deleting, and until this fix it re-validated a **path**: that
    /// something mounted is there and that it is a readable image. A 900 MB `.dmg` belonging to
    /// somebody else satisfies both. This is the only place in issue #26 where the recorded identity
    /// can prevent a loss rather than a wrong sentence afterwards.
    private func offloadAttempt(
        recorded: String?, actual: String?, isMountPoint: @escaping (String) -> Bool = { _ in true },
        libraryDirectory: String? = nil
    ) throws -> (runner: RecordingRunner, thrown: Error?, offloadEntries: Int) {
        // `simctl runtime delete` enabled, so the control case actually reaches the deletion. With
        // the default capabilities it fails one step *past* the identity guard, which would let a
        // broken guard look like a passing control.
        var capabilities = XcodeCapabilities()
        capabilities.simctlRuntimeDelete = true
        // `libraryDirectory` overrides where the installer is said to live, for the mount-guard
        // test: `isNotOnAMountedVolume` consults the mount predicate only for paths under
        // `/Volumes`, so a temporary directory short-circuits to "mounted" and that guard can never
        // fire. Nothing needs the file to exist — the preflight's readability check and its library
        // listing are both seams, and `offload`'s own check goes through the stubbed runner.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let dir = libraryDirectory.map { URL(fileURLWithPath: $0) } ?? scratch
        let image = dir.appendingPathComponent("iphonesimulator_26.5_23F77.dmg")
        if libraryDirectory == nil { FileManager.default.createFile(atPath: image.path, contents: Data([0])) }

        let runner = RecordingRunner(responses: [
            "hdiutil imageinfo": CommandResult(status: 0, stdout: "", stderr: ""),
            "xcrun": CommandResult(status: 0, stdout: "", stderr: ""),
            "simctl": CommandResult(status: 0, stdout: "", stderr: ""),
        ])
        // A real journal, not `/dev/null`: a guard that refuses must also not have written
        // `.started`, and an orphan `.started` is a state nothing could read until finding B1.
        let journal = Journal(url: scratch.appendingPathComponent("journal.jsonl"))
        let ops = RuntimeOperations(
            runner: runner, journal: journal,
            xcode: XcodeInstallation(
                path: "/Applications/Xcode.app", developerDirectory: "/Applications/Xcode.app/Contents/Developer",
                version: "26.5", build: "17F42", isSelected: true, capabilities: capabilities),
            host: HostEnvironment(
                macOSVersion: "26.6", macOSBuild: "x", architecture: "x86_64", homeDirectory: "/tmp",
                dataVolumeFreeBytes: 1 << 40, dataVolumeTotalBytes: 1 << 41, userName: "t", isRoot: false))

        let (plan, _) = try ops.preflightOffload(
            identifier: "RT", library: dir.path, installedRuntimes: [runtime()],
            isMountPoint: { _ in true }, listLibrary: { _ in [self.installer(image.path)] }, imageIsReadable: { _ in true },
            volumeUUIDAt: { _ in recorded })
        XCTAssertEqual(plan.installerVolumeUUID, recorded, "precondition: the plan carries what was verified")

        // Counted **here**, not returned as a `Journal` for the caller to read: `scratch` is removed
        // by the `defer` above the moment this function returns, so a caller reading the journal
        // afterwards would find an empty file and a count of zero no matter what happened. That is
        // how the first version of `testARefusedOffloadJournalsNothingAtAll` passed against a
        // deliberately broken build — it asserted nothing at all.
        func offloadEntries() -> Int { ((try? journal.entries()) ?? []).filter { $0.kind == .runtimeOffload }.count }
        do {
            try ops.offload(
                plan, confirmedByUser: .explicitUserIntent(recordedAs: "test"), volumeUUIDAt: { _ in actual },
                isMountPoint: isMountPoint)
            return (runner, nil, offloadEntries())
        } catch {
            return (runner, error, offloadEntries())
        }
    }

    /// The scenario: the user confirms, the vault is unplugged, another drive mounts at the same
    /// path with a readable image on it. Both pre-existing guards pass.
    func testOffloadRefusesToDeleteAgainstADifferentVolume() throws {
        let (runner, thrown, _) = try offloadAttempt(
            recorded: "AAAAAAAA-1111-2222-3333-444444444444", actual: "BBBBBBBB-5555-6666-7777-888888888888")
        let message = thrown?.localizedDescription ?? "nothing was thrown"
        XCTAssertNotNil(thrown, "deleting 12 GB against an unverified installer is the loss this issue is about")
        XCTAssertTrue(message.contains("different volume"), message)
        XCTAssertTrue(message.contains("Nothing was deleted"), message)
        XCTAssertFalse(
            runner.invocations.contains { $0.contains("delete") },
            "and it must refuse BEFORE the deletion, not report it afterwards: \(runner.invocations)")
    }

    /// Recorded, and unreadable now. Not a match — the same answer `doctor` gives.
    func testOffloadRefusesWhenTheVolumeIdentityCannotBeRead() throws {
        let (runner, thrown, _) = try offloadAttempt(recorded: "AAAAAAAA-1111-2222-3333-444444444444", actual: nil)
        XCTAssertNotNil(thrown)
        XCTAssertTrue((thrown?.localizedDescription ?? "").contains("cannot be read"), "\(thrown as Any)")
        XCTAssertFalse(runner.invocations.contains { $0.contains("delete") }, "\(runner.invocations)")
    }

    /// The control, twice: this guard must not block the offloads it has nothing to say about, or
    /// the fix breaks the verb on every machine whose filesystem reports no UUID.
    func testOffloadProceedsOnAMatchAndWhenNothingWasRecorded() throws {
        let match = try offloadAttempt(recorded: "AAAAAAAA-1111-2222-3333-444444444444", actual: "AAAAAAAA-1111-2222-3333-444444444444")
        XCTAssertNil(match.thrown, "a verified volume must proceed: \(match.thrown as Any)")
        XCTAssertTrue(match.runner.invocations.contains { $0.contains("delete") }, "\(match.runner.invocations)")

        let none = try offloadAttempt(recorded: nil, actual: "BBBBBBBB-5555-6666-7777-888888888888")
        XCTAssertNil(none.thrown, "nothing recorded means nothing to contradict: \(none.thrown as Any)")
        XCTAssertTrue(none.runner.invocations.contains { $0.contains("delete") }, "\(none.runner.invocations)")
    }

    /// Same volume, written in a different case. A string compare would call this a foreign drive
    /// and refuse a legitimate offload (review finding F7).
    func testTheSameUUIDInADifferentCaseIsAMatch() {
        XCTAssertEqual(
            MountStatus.compareVolumeIdentity(
                recorded: "aaaaaaaa-1111-2222-3333-444444444444", found: "AAAAAAAA-1111-2222-3333-444444444444"),
            .matches)
        XCTAssertEqual(
            MountStatus.compareVolumeIdentity(recorded: "AAAA-1111", found: "aaaa-1111"), .matches,
            "a non-UUID identifier still compares case-insensitively")
        XCTAssertEqual(MountStatus.compareVolumeIdentity(recorded: nil, found: "X"), .notRecorded)
        XCTAssertEqual(MountStatus.compareVolumeIdentity(recorded: "", found: "X"), .notRecorded, "an empty journal field is not an identity")
        XCTAssertEqual(MountStatus.compareVolumeIdentity(recorded: "X", found: nil), .unreadable(recorded: "X"))
        XCTAssertEqual(MountStatus.compareVolumeIdentity(recorded: "X", found: ""), .unreadable(recorded: "X"))
    }

    // MARK: the seams are wired to the real thing (review finding F8)

    /// Both seams default to the real lookup, and nothing pinned that. A default quietly changed to
    /// `{ _ in nil }` would leave every test green — they all inject — while the shipped product
    /// answered "identity unreadable" for every volume, refusing every offload.
    func testTheInjectedSeamsDefaultToTheRealVolumeLookup() throws {
        let probes = ["/", NSTemporaryDirectory(), NSHomeDirectory()]
        let real = probes.map { MountStatus.volumeUUID(at: $0) }
        try XCTSkipIf(
            real.allSatisfy { $0 == nil },
            "no probed path reports a volume UUID on this machine, so this test cannot tell the real lookup from a stub")

        let doctor = Doctor(home: NSHomeDirectory(), runner: FakeRunner(responses: [:]), journal: Journal(url: URL(fileURLWithPath: "/dev/null")))
        XCTAssertEqual(probes.map { doctor.volumeUUIDAt($0) }, real, "Doctor's default must be the real lookup")

        // `preflightOffload`'s default is not reachable as a value, so it is pinned through the
        // plan it produces: with no seam passed, the recorded identity must be what the real lookup
        // returns for that path.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("iphonesimulator_26.5_23F77.dmg")
        FileManager.default.createFile(atPath: image.path, contents: Data([0]))

        let (plan, _) = try ops().preflightOffload(
            identifier: "RT", library: dir.path, installedRuntimes: [runtime()],
            isMountPoint: { _ in true }, listLibrary: { _ in [self.installer(image.path)] }, imageIsReadable: { _ in true })
        XCTAssertEqual(
            plan.installerVolumeUUID, MountStatus.volumeUUID(at: image.path),
            "preflightOffload's default must be the real lookup, not a stub")
        XCTAssertNotNil(plan.installerVolumeUUID, "and this machine does report one for that path")
    }

    // MARK: the journal read end to end (review finding B1)

    /// Builds a journal from raw lines so a test can stage states `offload()` only reaches by
    /// crashing: a `.started` with no terminal record.
    private func findingFromJournal(_ build: (Journal) throws -> Void, actualUUID: String? = nil) throws -> Finding? {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Application Support/XCodeVault"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let journal = Journal(url: home.appendingPathComponent("Library/Application Support/XCodeVault/journal.jsonl"))
        try build(journal)

        let doctor = Doctor(
            home: home.path, runner: FakeRunner(responses: [:]), journal: journal, volumeUUIDAt: { _ in actualUUID })
        let device = SimulatorDevice(
            udid: "U1", name: "iPhone 17", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            state: "Shutdown", isAvailable: false, availabilityError: "runtime profile not found")
        return doctor.checkUnavailableDevices(devices: [device]).first
    }

    /// **The crash route to the F2 falsehood.** `offload` journals `.started`, deletes the runtime,
    /// then journals `.completed`. Lose power in between and the runtime is gone, the devices are
    /// unavailable, the installer is fine — and the journal holds only `.started`.
    ///
    /// The rule read `.completed` and nothing else, so that entry vanished, every category came out
    /// empty, and the user was told the journal records no offloaded runtime and deletion was fine.
    func testAnOffloadThatNeverRecordedItsOutcomeIsNotReportedAsNoOffloadAtAll() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }

        let text =
            try findingFromJournal({ journal in
                try journal.record(
                    id: "op-1", kind: .runtimeOffload, state: .started, summary: "offload",
                    paths: [image.path], detail: ["runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "installer": image.path])
            })?.remediation ?? ""

        XCTAssertFalse(
            text.contains("journal records no offloaded runtime"),
            "the journal records one; that sentence green-lights a permanent delete. Got: \(text)")
        XCTAssertTrue(text.contains("never recorded how it ended"), "and it must say what is actually unknown. Got: \(text)")
        XCTAssertTrue(text.contains("Do NOT run"), text)
    }

    /// The control: a `.started` followed by `.failed` means the delete did not happen, so there is
    /// no interrupted operation to warn about.
    func testAStartedOffloadThatRecordedAFailureIsNotTreatedAsInterrupted() throws {
        let text =
            try findingFromJournal({ journal in
                try journal.record(id: "op-1", kind: .runtimeOffload, state: .started, summary: "offload", paths: ["/tmp/x.dmg"], detail: [:])
                try journal.record(id: "op-1", kind: .runtimeOffload, state: .failed, summary: "failed", paths: ["/tmp/x.dmg"], detail: [:])
            })?.remediation ?? ""
        XCTAssertFalse(text.contains("never recorded how it ended"), "a recorded failure is not an unknown outcome. Got: \(text)")
    }

    // MARK: categories are decided once (review finding B2)

    /// Every offload entry lands in exactly one disposition, and the sentence a user reads is chosen
    /// from stored values rather than from syscalls re-run per branch. Staged as the mixed case: one
    /// good installer, one on a foreign drive.
    ///
    /// The old code evaluated `isUsableImage` and the identity check two and three times per entry
    /// across separate passes, so a drive ejected mid-`diagnose` could put one entry in two
    /// categories, or in none — and a single uncategorised entry sent the finding to the branch that
    /// says nothing was offloaded.
    func testAMixedSetOfOffloadsMentionsBothRatherThanOnlyTheWinningBranch() throws {
        let good = try makeImage()
        let foreign = try makeImage()
        defer {
            try? FileManager.default.removeItem(at: good.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: foreign.deletingLastPathComponent())
        }

        // `volumeUUIDAt` answers per path, so one entry matches and the other does not.
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Application Support/XCodeVault"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let journal = Journal(url: home.appendingPathComponent("Library/Application Support/XCodeVault/journal.jsonl"))
        for (path, recorded) in [(good.path, "AAAA-1111"), (foreign.path, "AAAA-1111")] {
            try journal.record(
                id: UUID().uuidString, kind: .runtimeOffload, state: .completed, summary: "offloaded", paths: [path],
                detail: ["runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "installer": path, "installerVolumeUUID": recorded])
        }
        let foreignPath = foreign.path
        let doctor = Doctor(
            home: home.path, runner: FakeRunner(responses: [:]), journal: journal,
            volumeUUIDAt: { $0 == foreignPath ? "BBBB-2222" : "AAAA-1111" })
        let device = SimulatorDevice(
            udid: "U1", name: "iPhone 17", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            state: "Shutdown", isAvailable: false, availabilityError: "runtime profile not found")
        let text = doctor.checkUnavailableDevices(devices: [device]).first?.remediation ?? ""

        XCTAssertTrue(text.contains("Re-import instead"), "the good installer is still offered. Got: \(text)")
        XCTAssertTrue(
            text.contains("different volume"),
            "and the foreign-drive entry must not disappear because another entry won the branch — that is the shadow data #26 exists to surface. Got: \(text)")
    }

    /// A reachable, identified installer whose runtime is not one of these devices' (finding N4).
    /// The old code let it fall to the branch that says nothing was offloaded — true only if two
    /// different simctl subcommands spell the runtime identifier identically.
    func testAnOffloadForSomeOtherRuntimeDoesNotGreenLightDeletion() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
        let text =
            try findingFromJournal(
                { journal in
                    try journal.record(
                        id: UUID().uuidString, kind: .runtimeOffload, state: .completed, summary: "offloaded", paths: [image.path],
                        detail: [
                            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", "installer": image.path,
                            "installerVolumeUUID": "AAAA-1111",
                        ])
                }, actualUUID: "AAAA-1111")?.remediation ?? ""

        XCTAssertFalse(text.contains("journal records no offloaded runtime"), text)
        XCTAssertTrue(text.contains("does not match any of these unavailable devices"), text)
    }

    /// The identity guard must run **before** the journal's `.started` line, not merely before the
    /// deletion. Moving it below the write survives an assertion that only checks `delete` was not
    /// invoked, and leaves an orphan `.started` behind — the state that reads as an interrupted
    /// offload and is now its own warning.
    func testARefusedOffloadJournalsNothingAtAll() throws {
        let attempt = try offloadAttempt(
            recorded: "AAAAAAAA-1111-2222-3333-444444444444", actual: "BBBBBBBB-5555-6666-7777-888888888888")
        XCTAssertNotNil(attempt.thrown)
        XCTAssertEqual(
            attempt.offloadEntries, 0,
            "a refusal must leave no trace of an operation that never began — an orphan `.started` reads as an interrupted offload")
    }

    /// The mount guard, which had no seam and so was unkillable: every test runs under
    /// `NSTemporaryDirectory()`, which is never a `/Volumes` path, so the predicate was constantly
    /// false and deleting the guard left the suite green.
    func testOffloadRefusesWhenTheInstallerDirectoryIsNoLongerAMountedVolume() throws {
        let attempt = try offloadAttempt(
            recorded: "AAAAAAAA-1111-2222-3333-444444444444", actual: "AAAAAAAA-1111-2222-3333-444444444444",
            isMountPoint: { _ in false }, libraryDirectory: "/Volumes/XCV-TEST-\(UUID().uuidString)")
        XCTAssertNotNil(attempt.thrown, "the vault was unplugged between the preflight and the confirmation")
        XCTAssertTrue(
            (attempt.thrown?.localizedDescription ?? "").contains("no longer a mounted volume"),
            "\(attempt.thrown as Any)")
        XCTAssertFalse(attempt.runner.invocations.contains { $0.contains("delete") }, "\(attempt.runner.invocations)")
    }
}
