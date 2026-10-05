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

    /// Answers each lookup from a queue (the last answer repeats), and counts them.
    final class FakeVolumes: OwnershipVolumeReading, @unchecked Sendable {
        let lock = NSLock()
        var answers: [OwnershipVolumeLookup]
        private(set) var lookups: [UUID] = []
        init(_ answers: OwnershipVolumeLookup...) { self.answers = answers }
        func lookup(volumeUUID: UUID) -> OwnershipVolumeLookup {
            lock.withLock {
                lookups.append(volumeUUID)
                return answers.count > 1 ? answers.removeFirst() : answers[0]
            }
        }
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
        XCTAssertEqual(du.runs, [.enableOwnership(deviceNode: "/dev/disk5s1")])
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

    func testOnlyAVolumeDeviceNodeIsEverAnArgument() {
        XCTAssertEqual(DiskutilInvocation.enableOwnership(deviceNode: "/dev/disk5s1").arguments, ["enableOwnership", "/dev/disk5s1"])
        let uuid = UUID(uuidString: Self.uuid)!
        XCTAssertEqual(DiskutilInvocation.infoPlist(volumeUUID: uuid).arguments, ["info", "-plist", Self.uuid])
        XCTAssertEqual(DiskutilInvocation.executable, "/usr/sbin/diskutil")
        for bad in [
            "/dev/disk5", "/dev/disk3s1s1", "/dev/rdisk5s1", "disk5s1", "/dev/disk5s1 ", "/dev/disk5s1;reboot", "/dev/disk5s", "/dev/disks1",
            "/dev/disk5s1\u{0301}", "/dev/disk٥s1", "-plist", "/Volumes/XCodeVault", "",
        ] {
            XCTAssertNil(DiskutilInvocation.enableOwnership(deviceNode: bad).arguments, bad)
        }
    }

    func testAnExternalFormOfTheWrongLengthIsRefusedBeforeTheAuthorizationServiceIsAsked() {
        XCTAssertNotNil(SecurityRightAuthority.externalForm(from: Data(repeating: 1, count: 32)))
        for n in [0, 1, 31, 33, 64] { XCTAssertNil(SecurityRightAuthority.externalForm(from: Data(repeating: 1, count: n)), "\(n)") }
        let form = SecurityRightAuthority.externalForm(from: Data((0..<32).map { UInt8($0) }))!
        let back = withUnsafeBytes(of: form.bytes) { Data($0) }
        XCTAssertEqual(back, Data((0..<32).map { UInt8($0) }), "the bytes are copied as given")
    }

    func testOnlyTheAdminRuleCountsAsOurDefinition() {
        XCTAssertTrue(SecurityRightAuthority.isOurDefinition(["class": "rule", "rule": "authenticate-admin", "version": 1, "created": 1.0]))
        XCTAssertTrue(SecurityRightAuthority.isOurDefinition(["class": "rule", "rule": ["authenticate-admin"], "default-prompt": ["": "x"]]))
        XCTAssertFalse(SecurityRightAuthority.isOurDefinition(["class": "rule", "rule": "allow"]), "a squatter's allow")
        XCTAssertFalse(SecurityRightAuthority.isOurDefinition(["class": "allow"]))
        XCTAssertFalse(SecurityRightAuthority.isOurDefinition(["class": "rule", "rule": ["authenticate-admin", "allow"], "k": 1]))
        XCTAssertFalse(SecurityRightAuthority.isOurDefinition(["class": "rule", "rule": "authenticate-admin", "allow-root": true]), "anything that widens it")
        XCTAssertFalse(SecurityRightAuthority.isOurDefinition(["class": "user", "group": "staff"]))
        XCTAssertEqual(HelperIdentity.enableOwnershipRight, "com.xcodevault.helper.enable-ownership")
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
