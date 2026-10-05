import Foundation
import XCTest

@testable import XCodeVaultCore
@testable import XCodeVaultHelperCore
@testable import XCodeVaultHelperProtocol

/// R8 (ADR-0014): the helper's `enableOwnership`, through `XCodeVaultHelperCore` with injected seams only. Nothing here
/// reaches launchd, the authorization service or database, TCC, or a real disk: `diskutil` and the volume lookup are
/// fakes, and the two live types (`SpawnedDiskutil`, `SecurityRightAuthority`) are exercised only in their pure parts.
final class R8HelperOwnershipTests: XCTestCase {

    // MARK: - Fakes

    final class FakeRights: OwnershipRightAuthority, @unchecked Sendable {
        let lock = NSLock()
        var definition: RightDefinition
        var answer: RightCheck
        private(set) var ensured = 0
        private(set) var checked: [Data] = []
        init(definition: RightDefinition = .unchanged, answer: RightCheck = .granted) {
            self.definition = definition
            self.answer = answer
        }
        func ensureDefinition() -> RightDefinition {
            lock.withLock {
                ensured += 1; return definition
            }
        }
        func check(externalForm: Data) -> RightCheck {
            lock.withLock {
                checked.append(externalForm); return answer
            }
        }
    }

    /// Answers each lookup from a queue (the last answer repeats), and counts them. `.notMounted` as the first answer
    /// means nothing could be pinned. `unchanged` is what the pin check before the command answers.
    final class FakeVolumes: OwnershipVolumeReading, @unchecked Sendable {
        let lock = NSLock()
        var answers: [OwnershipVolumeLookup]
        var unchanged = true
        private(set) var lookups: [UUID] = []
        private(set) var pins = 0
        private(set) var releases = 0
        init(_ answers: OwnershipVolumeLookup...) { self.answers = answers }
        func pin(volumeUUID: UUID) -> MountPin? {
            lock.withLock {
                guard answers.first != .notMounted else { return nil }
                pins += 1
                return MountPin(
                    descriptor: 42, mountPoint: "/Volumes/XCodeVault", deviceNode: "/dev/disk5s1", fsid: [1, 2], disk: DiskIdentifier("disk5s1")!,
                    uuid: volumeUUID)
            }
        }
        func lookup(volumeUUID: UUID, pin: MountPin) -> OwnershipVolumeLookup {
            lock.withLock {
                lookups.append(volumeUUID)
                return answers.count > 1 ? answers.removeFirst() : answers[0]
            }
        }
        func isUnchanged(_ pin: MountPin) -> Bool { lock.withLock { unchanged } }
        func release(_ pin: MountPin) { lock.withLock { releases += 1 } }
    }

    final class FakeDiskutil: DiskutilRunning, @unchecked Sendable {
        let lock = NSLock()
        let output: DiskutilOutput
        private(set) var runs: [DiskutilInvocation] = []
        init(_ output: DiskutilOutput = DiskutilOutput(exitStatus: 0, stdout: Data(), failure: nil)) { self.output = output }
        func run(_ invocation: DiskutilInvocation) -> DiskutilOutput {
            lock.withLock {
                runs.append(invocation); return output
            }
        }
    }

    static let uuid = "11111111-2222-3333-4444-555555555555"
    static let form = Data(repeating: 7, count: 32)

    static func facts(_ change: (inout OwnershipVolumeFacts) -> Void = { _ in }) -> OwnershipVolumeFacts {
        var f = OwnershipVolumeFacts(
            deviceNode: "/dev/disk5s1", mountPoint: "/Volumes/XCodeVault", filesystemType: "apfs", isInternal: false, busProtocol: "USB",
            isLocal: true, isWritable: true, ownersEnabled: false, roles: [], hasTimeMachineMarker: false, sharesTheBootContainer: false)
        change(&f)
        return f
    }

    private func service(uid: uid_t = getuid()) -> HelperService { HelperService(callerUID: uid, callerGID: getgid()) }

    // MARK: - The verb, in order

    func testAnEligibleVolumeIsTurnedOnWithTheHelpersOwnDeviceNodeAndVerified() {
        let rights = FakeRights(), du = FakeDiskutil()
        let volumes = FakeVolumes(.found(Self.facts()), .found(Self.facts { $0.ownersEnabled = true }))
        let r = service().doEnableOwnership(volumeUUID: Self.uuid, authorization: Self.form, rights: rights, volumes: volumes, diskutil: du)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(r.code, .enabled)
        XCTAssertEqual(du.runs, [.enableOwnership(disk: DiskIdentifier("disk5s1")!)], "the command names the pinned mount's disk identifier (N2)")
        XCTAssertEqual(volumes.pins, 1)
        XCTAssertEqual(volumes.releases, 1, "the pinned descriptor is released")
        XCTAssertEqual(rights.checked, [Self.form], "the right is checked from the client's form, once")
        XCTAssertEqual(rights.ensured, 1)
        XCTAssertEqual(volumes.lookups.count, 2, "read before, and again to verify")
    }

    func testANonAdministratorIsRefusedBeforeTheRightOrAnyDiskIsTouched() {
        let rights = FakeRights(), volumes = FakeVolumes(.found(Self.facts())), du = FakeDiskutil()
        let r = service(uid: 99).doEnableOwnership(volumeUUID: Self.uuid, authorization: Self.form, rights: rights, volumes: volumes, diskutil: du)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.code, .unauthorized)
        XCTAssertTrue(HelperService.wasUnauthorized(r), "the audit labels it refused-unauthorized")
        XCTAssertEqual(rights.ensured + rights.checked.count + volumes.lookups.count + du.runs.count, 0)
    }

    func testAnInvalidOrAllZeroUUIDIsRefused() {
        for bad in ["", "not-a-uuid", "00000000-0000-0000-0000-000000000000", "/Volumes/XCodeVault"] {
            let du = FakeDiskutil()
            let r = service().doEnableOwnership(
                volumeUUID: bad, authorization: Self.form, rights: FakeRights(), volumes: FakeVolumes(.notMounted), diskutil: du)
            XCTAssertEqual(r.code, .invalidArgument, bad)
            XCTAssertTrue(du.runs.isEmpty)
        }
    }

    func testAMissingDeniedOrForgedRightIsRefusedBeforeAnyDiskIsRead() {
        let cases: [(RightDefinition, RightCheck, HelperResultCode)] = [
            (.unchanged, .denied(-60005), .authorizationDenied),
            (.unchanged, .malformed, .authorizationMalformed),
            (.redefined, .granted, .authorizationUnavailable),  // a definition someone else wrote: repaired, this call refused
            (.failed(-60008), .granted, .authorizationUnavailable),
        ]
        for (definition, answer, code) in cases {
            let volumes = FakeVolumes(.found(Self.facts())), du = FakeDiskutil()
            let r = service().doEnableOwnership(
                volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(definition: definition, answer: answer), volumes: volumes, diskutil: du)
            XCTAssertFalse(r.ok)
            XCTAssertEqual(r.code, code, "\(definition) \(answer)")
            XCTAssertTrue(volumes.lookups.isEmpty, "nothing about the volumes is read for a caller without the right")
            XCTAssertTrue(du.runs.isEmpty)
        }
    }

    func testAnUnknownOrUnreadableVolumeIsRefused() {
        for lookup in [OwnershipVolumeLookup.notMounted, .unreadable("diskutil described a different volume")] {
            let du = FakeDiskutil()
            let r = service().doEnableOwnership(
                volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(), volumes: FakeVolumes(lookup), diskutil: du)
            XCTAssertEqual(r.code, .volumeNotFound)
            XCTAssertTrue(du.runs.isEmpty)
        }
    }

    func testEveryIneligibleVolumeIsRefusedAndNothingRuns() {
        let ineligible: [String: OwnershipVolumeFacts] = [
            "internal": Self.facts { $0.isInternal = true },
            "boot": Self.facts { $0.mountPoint = "/" },
            "data": Self.facts { $0.mountPoint = "/System/Volumes/Data" },
            "system role": Self.facts { $0.roles = ["System"] },
            "boot container": Self.facts { $0.sharesTheBootContainer = true },
            "disk image": Self.facts { $0.busProtocol = "Disk Image" },
            "read-only": Self.facts { $0.isWritable = false },
            "network type": Self.facts { $0.filesystemType = "smbfs" },
            "not local": Self.facts { $0.isLocal = false },
            "exFAT": Self.facts { $0.filesystemType = "exfat" },
            "Time Machine role": Self.facts { $0.roles = ["Backup"] },
            "Time Machine marker": Self.facts { $0.hasTimeMachineMarker = true },
            "whole disk node": Self.facts { $0.deviceNode = "/dev/disk5" },
        ]
        for (name, f) in ineligible {
            XCTAssertNotNil(HelperOwnership.refusal(f), name)
            let du = FakeDiskutil()
            let r = service().doEnableOwnership(
                volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(), volumes: FakeVolumes(.found(f)), diskutil: du)
            XCTAssertEqual(r.code, .volumeIneligible, name)
            XCTAssertTrue(du.runs.isEmpty, name)
        }
        XCTAssertNil(HelperOwnership.refusal(Self.facts()), "the eligible fixture")
        XCTAssertNil(HelperOwnership.refusal(Self.facts { $0.filesystemType = "hfs" }), "HFS+ is eligible")
    }

    func testAlreadyOnRunsNothing() {
        let du = FakeDiskutil()
        let r = service().doEnableOwnership(
            volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(), volumes: FakeVolumes(.found(Self.facts { $0.ownersEnabled = true })),
            diskutil: du)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.code, .alreadyEnabled)
        XCTAssertTrue(du.runs.isEmpty)
    }

    func testACommandFailureAndAnUnverifiedSuccessAreFailures() {
        let failed = service().doEnableOwnership(
            volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(), volumes: FakeVolumes(.found(Self.facts())),
            diskutil: FakeDiskutil(DiskutilOutput(exitStatus: 1, stdout: Data(), failure: nil)))
        XCTAssertEqual(failed.code, .commandFailed)
        XCTAssertFalse(failed.ok)
        let stillOff = service().doEnableOwnership(
            volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(), volumes: FakeVolumes(.found(Self.facts())), diskutil: FakeDiskutil())
        XCTAssertEqual(stillOff.code, .notVerified)
        let moved = service().doEnableOwnership(
            volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(),
            volumes: FakeVolumes(
                .found(Self.facts()),
                .found(
                    Self.facts {
                        $0.ownersEnabled = true; $0.deviceNode = "/dev/disk6s1"
                    })),
            diskutil: FakeDiskutil())
        XCTAssertEqual(moved.code, .notVerified, "a different device node after the run is not this volume verified")
        let gone = service().doEnableOwnership(
            volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(), volumes: FakeVolumes(.found(Self.facts()), .notMounted),
            diskutil: FakeDiskutil())
        XCTAssertEqual(gone.code, .notVerified)
    }

    func testTheAuditRecordCarriesTheCodeAndNeverTheForm() {
        let r = HelperResult(ok: false, message: "the authorization was not granted (-60005)", code: .authorizationDenied)
        let record = HelperAudit.AuditRecord.from(
            verb: "enableOwnership", callerUID: 501, validatedArguments: ["volumeUUID": Self.uuid], result: r, wasUnauthorized: false)
        XCTAssertEqual(record.code, .authorizationDenied)
        XCTAssertEqual(record.outcome, .declined("the authorization was not granted (-60005)"))
        XCTAssertEqual(Set(record.validatedArguments.keys), ["volumeUUID"], "the authorization form is a credential and is never recorded")
    }

    // MARK: - The pure parts of the live types

    func testTheArgvIsAVerbAndACanonicalUUID() {
        let uuid = UUID(uuidString: Self.uuid.lowercased())!
        XCTAssertEqual(DiskutilInvocation.enableOwnership(disk: DiskIdentifier("disk5s1")!).arguments, ["enableOwnership", "disk5s1"])
        XCTAssertEqual(DiskutilInvocation.infoPlist(volumeUUID: uuid).arguments, ["info", "-plist", Self.uuid])
        XCTAssertEqual(DiskutilInvocation.executable, "/usr/sbin/diskutil")
    }

    func testOnlyAVolumeDeviceNodePassesTheCrossCheck() {
        XCTAssertTrue(HelperOwnership.isVolumeDeviceNode("/dev/disk5s1"))
        for bad in [
            "/dev/disk5", "/dev/disk3s1s1", "/dev/rdisk5s1", "disk5s1", "/dev/disk5s1 ", "/dev/disk5s1;reboot", "/dev/disk5s", "/dev/disks1",
            "/dev/disk5s1\u{0301}", "/dev/disk٥s1", "-plist", "/Volumes/XCodeVault", "",
        ] {
            XCTAssertFalse(HelperOwnership.isVolumeDeviceNode(bad), bad)
        }
    }

    func testOnlyABareVolumeIdentifierIsADiskIdentifier() {
        XCTAssertEqual(DiskIdentifier("disk12s3")?.value, "disk12s3")
        for bad in ["disk5", "disk3s1s1", "rdisk5s1", "/dev/disk5s1", "disk5s1 ", "disk5s1;x", "disk5s", "disks1", "disk5s1\u{0301}", "disk٥s1", "-x", ""] {
            XCTAssertNil(DiskIdentifier(bad), bad)
        }
        XCTAssertEqual(HelperOwnership.diskIdentifier(ofDeviceNode: "/dev/disk5s1"), DiskIdentifier("disk5s1"))
        XCTAssertNil(HelperOwnership.diskIdentifier(ofDeviceNode: "disk5s1"), "a device node, or nothing")
    }

    /// N2 / data F3: two mounted volumes with one UUID leave "the volume" undefined; nothing is pinned and nothing runs.
    func testTwoMountsWithTheSameUUIDAreRefused() {
        XCTAssertNil(HelperOwnership.soleMountPoint(["/Volumes/A", "/Volumes/A 1"]))
        XCTAssertNil(HelperOwnership.soleMountPoint([]))
        XCTAssertEqual(HelperOwnership.soleMountPoint(["/Volumes/A"]), "/Volumes/A")
        // A reader that sees two mounts pins nothing (the live reader's `soleMountPoint`), so the verb refuses.
        let du = FakeDiskutil()
        let r = service().doEnableOwnership(
            volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(), volumes: FakeVolumes(.notMounted), diskutil: du)
        XCTAssertEqual(r.code, .volumeNotFound)
        XCTAssertTrue(du.runs.isEmpty)
    }

    func testAVolumeThatChangedBeforeTheCommandIsRefused() {
        let volumes = FakeVolumes(.found(Self.facts()))
        volumes.unchanged = false
        let du = FakeDiskutil()
        let r = service().doEnableOwnership(volumeUUID: Self.uuid, authorization: Self.form, rights: FakeRights(), volumes: volumes, diskutil: du)
        XCTAssertEqual(r.code, .volumeNotFound)
        XCTAssertTrue(du.runs.isEmpty, "nothing runs on a mount that is no longer the one read")
        XCTAssertEqual(volumes.releases, 1)
    }

    func testHowARunEndedDecidesItsOutcome() {
        let out = Data("x".utf8)
        XCTAssertTrue(DiskutilOutput.ended(output: out, reachedEOF: true, timedOut: false, waitStatus: 0).succeeded)
        XCTAssertEqual(DiskutilOutput.ended(output: out, reachedEOF: true, timedOut: false, waitStatus: 1 << 8).exitStatus, 1)
        XCTAssertFalse(DiskutilOutput.ended(output: out, reachedEOF: true, timedOut: true, waitStatus: 0).succeeded, "timed out")
        XCTAssertFalse(DiskutilOutput.ended(output: out, reachedEOF: false, timedOut: false, waitStatus: 0).succeeded, "output cut off")
        XCTAssertFalse(DiskutilOutput.ended(output: out, reachedEOF: true, timedOut: false, waitStatus: nil).succeeded, "not reaped")
        XCTAssertFalse(DiskutilOutput.ended(output: out, reachedEOF: true, timedOut: false, waitStatus: 9).succeeded, "a signal")
        XCTAssertFalse(DiskutilOutput(exitStatus: 0, stdout: out, failure: "x").succeeded, "a failure is never success")
    }

    func testAnExternalFormOfTheWrongLengthIsRefusedBeforeTheAuthorizationServiceIsAsked() {
        XCTAssertNotNil(SecurityRightAuthority.externalForm(from: Data(repeating: 1, count: 32)))
        for n in [0, 1, 31, 33, 64] { XCTAssertNil(SecurityRightAuthority.externalForm(from: Data(repeating: 1, count: n)), "\(n)") }
        let form = SecurityRightAuthority.externalForm(from: Data((0..<32).map { UInt8($0) }))!
        let back = withUnsafeBytes(of: form.bytes) { Data($0) }
        XCTAssertEqual(back, Data((0..<32).map { UInt8($0) }), "the bytes are copied as given")
    }

    /// Fix round 4: the definition the helper writes, as a value.
    func testTheRightsDefinitionIsItsOwnShortUnsharedAdminRule() {
        let d = OwnershipRightRule.definition
        XCTAssertEqual(d["class"] as? String, "user")
        XCTAssertEqual(d["group"] as? String, "admin")
        XCTAssertEqual(d["timeout"] as? Int, 10)
        XCTAssertEqual(d["shared"] as? Bool, false)
        XCTAssertEqual(d["allow-root"] as? Bool, false)
        XCTAssertNil(d["rule"], "never the stock admin rule, whose timeout of 0 made the re-check fail with -60007 (H18)")
        XCTAssertEqual(HelperIdentity.enableOwnershipRight, "com.xcodevault.helper.enable-ownership")
    }

    static let team = "ABCDE12345"

    /// What the database returns for a definition the helper wrote: ours, plus the metadata it adds — `tries`, which authd
    /// adds to every user-class rule (fix round 5, F1), and the writer's requirement naming its team (F3).
    static func readBack(_ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var d = OwnershipRightRule.definition
        d["identifier"] = "com.xcodevault.helper"
        d["created"] = 1.0
        d["modified"] = 2.0
        d["tries"] = 10000
        d["requirement"] =
            "identifier \"com.xcodevault.helper\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ "
            + "and certificate leaf[subject.OU] = \"\(team)\""
        change(&d)
        return d
    }

    private func ours(_ d: [String: Any], team: String = R8HelperOwnershipTests.team) -> Bool { SecurityRightAuthority.isOurDefinition(d, teamID: team) }

    func testOnlyTheHelpersOwnDefinitionCountsAsOurs() {
        XCTAssertTrue(ours(Self.readBack()))
        XCTAssertTrue(ours(Self.readBack { $0["authenticate-user"] = true }), "a default at its safe value")
        XCTAssertTrue(ours(Self.readBack { $0["default-prompt"] = ["": OwnershipRightRule.prompt] }))
        XCTAssertTrue(ours(Self.readBack { $0["default-prompt"] = ["": OwnershipRightRule.prompt, "fr": OwnershipRightRule.prompt] }))
        // The definition the user's database holds since 0.2.0 (H18): the stock admin rule. Not ours: rewritten.
        XCTAssertFalse(
            ours([
                "class": "rule", "rule": ["authenticate-admin"], "identifier": "com.xcodevault.helper", "version": 1, "created": 1.0,
            ]))
        let variants: [String: (inout [String: Any]) -> Void] = [
            "no writer": { $0["identifier"] = nil },
            "another writer": { $0["identifier"] = "com.example.squatter" },
            "class rule": { $0["class"] = "rule" },
            "class allow": { $0["class"] = "allow" },
            "another group": { $0["group"] = "staff" },
            "no group": { $0["group"] = nil },
            "timeout 0": { $0["timeout"] = 0 },
            "timeout 11": { $0["timeout"] = 11 },
            "timeout 300": { $0["timeout"] = 300 },
            "no timeout": { $0["timeout"] = nil },
            "shared": { $0["shared"] = true },
            "no shared": { $0["shared"] = nil },
            "allow-root": { $0["allow-root"] = true },
            "no allow-root": { $0["allow-root"] = nil },
            "a k": { $0["k"] = 1 },
            "mechanisms": { $0["mechanisms"] = ["builtin:authenticate"] },
            "a rule key": { $0["rule"] = ["allow"] },
            "authenticate-user off": { $0["authenticate-user"] = false },
            "session-owner on": { $0["session-owner"] = true },
            "extract-password on": { $0["extract-password"] = true },
            "password-only on": { $0["password-only"] = true },
        ]
        for (name, change) in variants {
            XCTAssertFalse(ours(Self.readBack(change)), name)
        }
    }

    /// Fix round 5 (F1): authd adds `tries` (10000 on this Mac) to every user-class rule. Accepted as a whole number of at
    /// least 1, and nothing else.
    func testTriesIsAcceptedOnlyAsAWholeNumberOfAtLeastOne() {
        XCTAssertTrue(ours(Self.readBack()), "the read-back as authd writes it, with tries 10000")
        XCTAssertTrue(ours(Self.readBack { $0["tries"] = 1 }))
        XCTAssertTrue(ours(Self.readBack { $0["tries"] = NSNumber(value: Int64(10000)) }))
        XCTAssertTrue(ours(Self.readBack { $0["tries"] = nil }), "absent, as the fixture of round 4 had it")
        let rejected: [String: Any] = [
            "zero": 0, "negative": -1, "fractional": 1.5, "a double ten thousand": 10000.0, "a string": "10000", "true": true, "false": false,
            "an array": [10000],
        ]
        for (name, value) in rejected {
            XCTAssertFalse(ours(Self.readBack { $0["tries"] = value }), name)
        }
    }

    /// Fix round 5 (F3): a squatter who defines the name first chooses the dialog's words and is recorded as the writer.
    /// The words must be ours, and the writer's requirement must name this build's team.
    func testThePromptMustBeOursAndTheWriterMustBeThisTeam() {
        XCTAssertFalse(ours(Self.readBack { $0["default-prompt"] = ["": "Enter your password to update Safari."] }), "a squatter's wording")
        XCTAssertFalse(ours(Self.readBack { $0["default-prompt"] = ["": OwnershipRightRule.prompt, "de": "anders"] }), "one language not ours")
        XCTAssertFalse(ours(Self.readBack { $0["default-prompt"] = OwnershipRightRule.prompt }), "not a dictionary of languages")
        XCTAssertFalse(ours(Self.readBack { $0["default-prompt"] = ["": 1] }))
        XCTAssertFalse(ours(Self.readBack { $0["requirement"] = nil }), "no requirement: the writer cannot be told")
        XCTAssertFalse(ours(Self.readBack { $0["requirement"] = "identifier \"com.xcodevault.helper\"" }), "an ad-hoc writer claiming the identifier")
        XCTAssertFalse(ours(Self.readBack { $0["requirement"] = "certificate leaf[subject.OU] = \"ZZZZZ99999\"" }), "another team")
        XCTAssertFalse(ours(Self.readBack { $0["requirement"] = "certificate leaf[subject.OU] = ABCDE123456" }), "a longer team")
        XCTAssertFalse(ours(Self.readBack { $0["requirement"] = 1 }))
        XCTAssertTrue(ours(Self.readBack { $0["requirement"] = "anchor apple generic and certificate leaf[subject.OU] = ABCDE12345" }), "the bare spelling")
        XCTAssertTrue(ours(Self.readBack { $0["requirement"] = "(certificate leaf[subject.OU] = ABCDE12345)" }))
        XCTAssertFalse(ours(Self.readBack(), team: "ZZZZZ99999"), "the build's team, not any team")
        XCTAssertFalse(ours(Self.readBack { $0["requirement"] = "certificate leaf[subject.OU] = \"TEAMID_PLACEHOLDER\"" }, team: HelperIdentity.teamIDPlaceholder),
            "an unsubstituted build accepts no definition")
        XCTAssertFalse(ours(Self.readBack(), team: ""))
        // The team reaches the check: the listener hands each connection's service the one `main.swift` validated, and a
        // service made without one holds the placeholder, which accepts nothing.
        XCTAssertEqual(ListenerDelegate(teamID: Self.team).teamID, Self.team)
        XCTAssertEqual(HelperService(callerUID: 1, callerGID: 1).teamID, HelperIdentity.teamIDPlaceholder)
        XCTAssertEqual(SecurityRightAuthority(teamID: Self.team).teamID, Self.team)
    }

    /// The upgrade path: the daemon repairs the old definition as it starts, before it accepts a connection, so the
    /// first click after the update finds the right already ours and is not refused for it.
    func testTheDaemonRepairsTheOldDefinitionAtStartAndTheFirstCallProceeds() {
        let rights = FakeRights(definition: .redefined)
        XCTAssertEqual(HelperStartup.defineAuthorizationRights(authority: rights), .redefined)
        XCTAssertEqual(rights.ensured, 1)
        rights.definition = .unchanged  // what the database now holds
        let r = service().doEnableOwnership(
            volumeUUID: Self.uuid, authorization: Self.form, rights: rights, volumes: FakeVolumes(.found(Self.facts { $0.ownersEnabled = true })),
            diskutil: FakeDiskutil())
        XCTAssertEqual(r.code, .alreadyEnabled, "the first call after the repair is not refused for the definition")
    }

    // MARK: - Reading the volume

    static func infoPlist(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var d: [String: Any] = [
            "VolumeUUID": uuid, "DeviceNode": "/dev/disk5s1", "MountPoint": "/Volumes/XCodeVault", "Internal": false, "BusProtocol": "USB",
            "WritableVolume": true, "GlobalPermissionsEnabled": false, "APFSContainerReference": "disk5",
        ]
        change(&d)
        return try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }

    func testTheThreeReadingsMustAgree() throws {
        let wanted = UUID(uuidString: Self.uuid)!
        let info = try XCTUnwrap(HelperOwnership.parseInfo(Self.infoPlist()))
        let local = UInt32(MNT_LOCAL)
        let ok = HelperOwnership.facts(
            wanted: wanted, mountPoint: "/Volumes/XCodeVault", statfsNode: "/dev/disk5s1", statfsType: "apfs",
            statfsFlags: local | UInt32(MNT_IGNORE_OWNERSHIP),
            info: info, bootNodes: ["/dev/disk3s1s1", "/dev/disk3s5"], hasTimeMachineMarker: false)
        XCTAssertEqual(ok, .found(Self.facts()))
        func with(_ i: HelperOwnership.InfoPlist, mp: String = "/Volumes/XCodeVault", node: String = "/dev/disk5s1") -> OwnershipVolumeLookup {
            HelperOwnership.facts(
                wanted: wanted, mountPoint: mp, statfsNode: node, statfsType: "apfs", statfsFlags: local, info: i, bootNodes: ["/dev/disk3s5"],
                hasTimeMachineMarker: false)
        }
        var other = info
        other.volumeUUID = UUID().uuidString
        guard case .unreadable = with(other) else { return XCTFail("a different UUID") }
        guard case .unreadable = with(info, mp: "/Volumes/Other") else { return XCTFail("a different mount point") }
        guard case .unreadable = with(info, node: "/dev/disk6s1") else { return XCTFail("a different device node") }
        // Ownership is on only when diskutil says so AND the mount does not ignore it.
        let on = try XCTUnwrap(HelperOwnership.parseInfo(Self.infoPlist { $0["GlobalPermissionsEnabled"] = true }))
        guard case .found(let f) = with(on) else { return XCTFail() }
        XCTAssertTrue(f.ownersEnabled)
        let readOnly = HelperOwnership.facts(
            wanted: wanted, mountPoint: "/Volumes/XCodeVault", statfsNode: "/dev/disk5s1", statfsType: "apfs", statfsFlags: local | UInt32(MNT_RDONLY),
            info: on, bootNodes: ["/dev/disk3s5"], hasTimeMachineMarker: false)
        guard case .found(let ro) = readOnly else { return XCTFail() }
        XCTAssertFalse(ro.isWritable)
        XCTAssertNil(HelperOwnership.parseInfo(Data("not a plist".utf8)))
        XCTAssertNil(HelperOwnership.parseInfo(Self.infoPlist { $0["DeviceNode"] = nil }))
    }

    func testAPlistMissingAKeyEligibilityRestsOnRefuses() {
        for key in ["Internal", "BusProtocol", "WritableVolume", "VolumeUUID", "DeviceNode", "MountPoint"] {
            XCTAssertNil(HelperOwnership.parseInfo(Self.infoPlist { $0[key] = nil }), "missing \(key) must not read as eligible (M2)")
        }
        XCTAssertNil(HelperOwnership.parseInfo(Self.infoPlist { $0["Internal"] = "No" }), "a wrongly typed Internal")
        let image = HelperOwnership.parseInfo(Self.infoPlist { $0["DiskImageURL"] = "file:///x.dmg" })
        XCTAssertEqual(image?.isDiskImageOrVirtual, true)
        XCTAssertEqual(HelperOwnership.parseInfo(Self.infoPlist { $0["VirtualOrPhysical"] = "Virtual" })?.isDiskImageOrVirtual, true)
        XCTAssertEqual(HelperOwnership.parseInfo(Self.infoPlist { $0["Virtual"] = true })?.isDiskImageOrVirtual, true, "Virtual as a Bool (N3)")
        XCTAssertEqual(HelperOwnership.parseInfo(Self.infoPlist { $0["Virtual"] = false })?.isDiskImageOrVirtual, false)
        XCTAssertEqual(HelperOwnership.parseInfo(Self.infoPlist { $0["VirtualOrPhysical"] = "Physical" })?.isDiskImageOrVirtual, false)
        XCTAssertNotNil(HelperOwnership.refusal(Self.facts { $0.isDiskImageOrVirtual = true }))
    }

    func testTheBootContainerIsRecognised() {
        XCTAssertEqual(HelperOwnership.diskOf("/dev/disk3s1s1"), "disk3")
        XCTAssertEqual(HelperOwnership.diskOf("disk12s4"), "disk12")
        XCTAssertNil(HelperOwnership.diskOf("/dev/rdisk"))
        XCTAssertTrue(HelperOwnership.sharesBoot(node: "/dev/disk3s7", container: nil, bootNodes: ["/dev/disk3s1s1"]))
        XCTAssertTrue(HelperOwnership.sharesBoot(node: "/dev/disk9s1", container: "disk3", bootNodes: ["/dev/disk3s5"]))
        XCTAssertFalse(HelperOwnership.sharesBoot(node: "/dev/disk5s1", container: "disk5", bootNodes: ["/dev/disk3s1s1", "/dev/disk3s5"]))
        XCTAssertTrue(HelperOwnership.sharesBoot(node: "/dev/disk5s1", container: "disk5", bootNodes: []), "unknown boot disk: refuse")
    }

    /// The helper duplicates Core's volume questions (it may not link Core). Over the same facts, both refuse.
    func testTheHelperAndCoreAgreeOnTheVolumesNeitherMayUse() {
        func core(_ change: (inout Volume) -> Void) -> Volume {
            var v = Volume(
                deviceNode: "/dev/disk5s1", volumeName: "XCodeVault", volumeUUID: Self.uuid, mountPoint: "/Volumes/XCodeVault",
                filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false, isEjectable: true, busProtocol: "USB",
                isSolidState: true, isWritable: true, ownersEnabled: true, totalBytes: 1 << 40, freeBytes: 1 << 39, isBootVolume: false)
            change(&v)
            return v
        }
        let pairs: [(Volume, OwnershipVolumeFacts)] = [
            (
                core {
                    $0.mountPoint = "/"; $0.isBootVolume = true
                }, Self.facts { $0.mountPoint = "/" }
            ),
            (core { $0.filesystemType = "smbfs" }, Self.facts { $0.filesystemType = "smbfs" }),
            (core { $0.isWritable = false }, Self.facts { $0.isWritable = false }),
            (
                core {
                    $0.filesystemType = "exfat"; $0.filesystemPersonality = "ExFAT"
                }, Self.facts { $0.filesystemType = "exfat" }
            ),
        ]
        for (v, f) in pairs {
            XCTAssertEqual(VolumeQualification.evaluate(v).verdict, .unsuitable, "\(v)")
            XCTAssertNotNil(HelperOwnership.refusal(f), "\(f)")
        }
    }

    // MARK: - The wire

    func testTheResultCodeCrossesTheWireAndAnUnknownOneIsNeverSuccess() throws {
        let sent = HelperResult(ok: true, message: "ownership is on", code: .enabled)
        let data = try NSKeyedArchiver.archivedData(withRootObject: sent, requiringSecureCoding: true)
        let back = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: HelperResult.self, from: data))
        XCTAssertEqual(back.code, .enabled)
        XCTAssertEqual(HelperResultCode(rawValue: "somethingNew"), nil)
        XCTAssertEqual(HelperResult(ok: true, message: "x").code, .none, "the older verbs set none")
    }
}
