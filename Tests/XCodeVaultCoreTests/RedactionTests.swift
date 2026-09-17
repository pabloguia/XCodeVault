import XCTest

@testable import XCodeVaultCore

/// `report` is the one command whose output is meant to be pasted somewhere public, so its
/// redaction is the one that has to be right. Until 2026-09-17 it was a pair of unanchored
/// `replacingOccurrences` calls, which was simultaneously the weakest redactor in the repository
/// and the most destructive one.
///
/// These cases mirror `scripts/experiments/test-common.sh`. The two redactors are kept in step
/// deliberately; every defect found in one has also been present in the other.
final class RedactionTests: XCTestCase {
    private func vol(_ name: String, uuid: String? = nil, boot: Bool = false) -> Volume {
        Volume(
            deviceNode: "/dev/disk99s1", volumeName: name, volumeUUID: uuid, mountPoint: "/Volumes/" + name,
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: boot, isRemovableMedia: false,
            isEjectable: !boot, busProtocol: boot ? "PCI-Express" : "USB", isSolidState: true, isWritable: true,
            ownersEnabled: true, totalBytes: 10, freeBytes: 5, isBootVolume: boot)
    }

    private func make(home: String = "/Users/dev", user: String = "dev", volumes: [Volume] = []) -> Redaction {
        Redaction(home: home, user: user, volumes: volumes)
    }

    // MARK: the identity

    func testTheHomeDirectoryIsRedacted() {
        XCTAssertEqual(make().redact("/Users/dev/Library/Developer"), "~/Library/Developer")
    }

    /// A home is a path prefix, not a word. Unanchored, this produced `~ops/x` — corrupting output
    /// rather than protecting anything.
    func testALongerPathThatMerelyStartsTheSameIsLeftAlone() {
        XCTAssertEqual(make().redact("/Users/devops/x"), "/Users/devops/x")
    }

    func testTheHomeIsRedactedAtEndOfInput() {
        XCTAssertEqual(make().redact("cd /Users/dev"), "cd ~")
    }

    /// The defect this shipped with: an account named `dev` rewrote every `devicectl` in a report
    /// headed for a bug tracker.
    func testAShortAccountNameDoesNotEatTheWordsContainingIt() {
        XCTAssertEqual(make().redact("devicectl ran as dev"), "devicectl ran as <user>")
    }

    /// `root` is a subject in this project's output — "root-owned", `/var/root` — not an identity.
    func testRootIsNeverSubstitutedAsAName() {
        let r = make(home: "/var/root", user: "root")
        XCTAssertEqual(r.redact("root-owned file at /var/root/x"), "root-owned file at ~/x")
    }

    // MARK: volumes

    func testAVolumeLabelIsRedactedInPathAndBareForm() {
        let r = make(volumes: [vol("VAULT")])
        XCTAssertEqual(r.redact("/Volumes/VAULT/XCodeVault"), "/Volumes/<vault>/XCodeVault")
        XCTAssertEqual(r.redact("Volume VAULT on disk3s1"), "Volume <vault> on disk3s1")
    }

    func testAVolumeLabelDoesNotEatALongerWordContainingIt() {
        XCTAssertEqual(make(volumes: [vol("VAULT")]).redact("the VAULTED archive"), "the VAULTED archive")
    }

    /// `\b` sits between a word and a non-word character, so a label ending in punctuation has no
    /// boundary after it and a naive `\bBackup\.\b` matches nothing at all.
    func testALabelEndingInANonWordCharacterIsStillRedacted() {
        let r = make(volumes: [vol("Trailing.")])
        XCTAssertEqual(r.redact("Trailing. is mounted"), "<vault> is mounted")
        XCTAssertEqual(r.redact("/Volumes/Trailing./x"), "/Volumes/<vault>/x")
    }

    func testAVolumeUUIDIsRedacted() {
        let r = make(volumes: [vol("VAULT", uuid: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")])
        XCTAssertEqual(r.redact("Volume UUID: A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"), "Volume UUID: <vault-uuid>")
    }

    /// The finding that made this a separate rule: on a machine whose boot volume is called
    /// `MacOS`, a bare-label rule rewrites `Contents/MacOS/` in every application bundle — which is
    /// the *content* of several experiments' evidence.
    func testTheBootVolumeNameIsNotRedactedAsAPathComponent() {
        let r = make(volumes: [vol("MacOS", boot: true)])
        XCTAssertEqual(r.redact("/Applications/X.app/Contents/MacOS/X"), "/Applications/X.app/Contents/MacOS/X")
    }

    func testTheBootVolumeIsStillRedactedUnderVolumes() {
        let r = make(volumes: [vol("MacOS", boot: true)])
        XCTAssertEqual(r.redact("/Volumes/MacOS/Users"), "/Volumes/<bootvolume>/Users")
    }

    /// A boot volume can be named after its owner, so its name still has to go where it appears as
    /// a *name* — the `volumeName` field of the JSON report, or prose. What distinguishes that from
    /// a path component is the preceding slash, and nothing else.
    func testTheBootVolumeNameIsRedactedWhereItIsANameRatherThanAPathComponent() {
        let r = make(volumes: [vol("MacOS", boot: true)])
        XCTAssertEqual(r.redact("\"volumeName\" : \"MacOS\""), "\"volumeName\" : \"<bootvolume>\"")
        XCTAssertEqual(r.redact("the MacOS volume"), "the <bootvolume> volume")
        XCTAssertEqual(r.redact("/Applications/X.app/Contents/MacOS/X"), "/Applications/X.app/Contents/MacOS/X")
    }

    // MARK: what must survive

    /// These belong to CoreSimulator and to Apple, not to a person, and several findings are
    /// unreadable without them — the E8 round-trip *is* one of these identifiers changing.
    func testCoreSimulatorAndAppleIdentifiersSurvive() {
        let r = make(volumes: [vol("VAULT", uuid: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")])
        let keep = [
            "iOS 26.5 (23F77) - 90F2566D-F038-4CF6-A8FF-0A9CC9C1F0BE",
            "41504653-0000-11AA-AA11-00306543ECAC",
            "/Library/Developer/CoreSimulator/Volumes/iOS_23F77",
            "macOS 26.7 (25G229)",
        ]
        for s in keep { XCTAssertEqual(r.redact(s), s, s) }
    }

    /// Regex metacharacters in a label must be matched literally, not interpreted.
    func testMetacharactersInALabelAreEscaped() {
        let r = make(volumes: [vol("Weird.Name+1")])
        XCTAssertEqual(r.redact("/Volumes/Weird.Name+1/x"), "/Volumes/<vault>/x")
        XCTAssertEqual(r.redact("/Volumes/WeirdXName+1/x"), "/Volumes/WeirdXName+1/x")
    }

    /// A template must not be re-read as a template: a `$` or `\` arriving from a volume label
    /// would otherwise be interpreted by the replacement engine.
    func testAReplacementIsNotReinterpreted() {
        let r = make(volumes: [vol("A$1B")])
        XCTAssertEqual(r.redact("/Volumes/A$1B/x"), "/Volumes/<vault>/x")
    }
}
