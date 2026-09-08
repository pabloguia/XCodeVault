import XCTest

@testable import XCodeVaultCore

final class DoctorTests: XCTestCase {
    private func fakeReport(
        home: String, volumes: [Volume] = [], runtimes: [SimulatorRuntime] = [], devices: [SimulatorDevice] = [], free: UInt64 = 100_000_000_000
    ) -> ScanReport {
        let host = HostEnvironment(
            macOSVersion: "26.6", macOSBuild: "25G83", architecture: "arm64", homeDirectory: home,
            dataVolumeFreeBytes: free, dataVolumeTotalBytes: 500_000_000_000, userName: "tester", isRoot: false)
        return ScanReport(
            generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: host, xcodes: [], runtimes: runtimes,
            devices: devices, volumes: volumes, items: [], summary: ScanSummary(), warnings: [])
    }
    private let quiet = FakeRunner(responses: [:])

    func testDetectsForbiddenCoreSimulatorSymlink() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("elsewhere/CoreSimulator")
        t.symlink("Library/Developer/CoreSimulator", to: t.path + "/elsewhere/CoreSimulator")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        let hit = f.first { $0.id == "forbidden-symlink:~/Library/Developer/CoreSimulator" }
        XCTAssertEqual(hit?.severity, .critical)
        XCTAssertTrue(hit?.detail.contains("Files app") == true)
    }

    func testDetectsWholeDeveloperSymlinkAndBrokenLinks() {
        let t = TempDir()
        t.dir("real/Developer/Xcode")
        t.symlink("Library/Developer", to: t.path + "/real/Developer")
        t.symlink("real/Developer/Xcode/DerivedData", to: "/Volumes/GONE/DerivedData")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        XCTAssertTrue(f.contains { $0.id == "forbidden-symlink:~/Library/Developer" && $0.severity == .critical })
        XCTAssertTrue(f.contains { $0.id.hasPrefix("broken-symlink:") && $0.severity == .error }, "\(f.map(\.id))")
    }

    func testDetectsPriorToolLeftoversOnExternalVolume() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("ext/mac-ssd-rescue/DerivedData")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        XCTAssertTrue(f.contains { $0.id.hasPrefix("prior-tool:mac-ssd-rescue") && $0.detail.contains("DerivedData") })
    }

    // E9 (2026-09-08) produced this on the internal disk with no external volume involved:
    // after a symlink was removed, a restarted CoreSimulatorService recreated an empty
    // device-set skeleton at the old resolved target.
    func testDetectsEmptyShadowCoreSimulatorRootInHome() {
        let t = TempDir()
        t.dir("Library/Developer/CoreSimulator/Devices")
        t.dir("CoreSimulator-real/Devices")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        let hit = f.first { $0.id == "shadow-coresimulator:home:CoreSimulator-real" }
        XCTAssertEqual(hit?.severity, .warning, "empty residue is a warning, not an error: \(f.map(\.id))")
        XCTAssertTrue(hit?.remediation?.contains("rmdir") == true, "empty residue may name rmdir")
        XCTAssertTrue(hit?.remediation?.contains("never `rm -rf`") == true, "must steer the user away from rm -rf explicitly: \(hit?.remediation ?? "nil")")
        XCTAssertTrue(hit?.remediation?.contains("empty as of this scan") == true || hit?.remediation?.contains("Empty as of this scan") == true,
                      "must not imply the emptiness is still guaranteed: \(hit?.remediation ?? "nil")")
    }

    /// The canonical path must never report itself. Asserting this from a plain home layout is
    /// vacuous — `~/Library/Developer/CoreSimulator` is 3 levels down and home is scanned 1 deep,
    /// so it is out of range whether or not the guard exists. The guard is only load-bearing when
    /// a volume is mounted *at* `~/Library/Developer` (the ADR-0004 canonical-mount R&D layout),
    /// where the depth-2 volume scan would otherwise produce exactly the canonical path.
    func testCanonicalCoreSimulatorIsExcludedEvenWhenReachableByAVolumeScan() {
        let t = TempDir()
        t.dir("Library/Developer/CoreSimulator/Devices/0F29E552-3BA3-413D-96ED-B810CD690DC4")
        let mountedAtDeveloper = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "VAULT", volumeUUID: "u", mountPoint: t.path + "/Library/Developer",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [mountedAtDeveloper]))
        XCTAssertFalse(
            f.contains { $0.id.hasPrefix("shadow-coresimulator") && $0.path == t.path + "/Library/Developer/CoreSimulator" },
            "the canonical device set must never be reported as its own shadow: \(f.map(\.id))")
    }

    /// A listing failure must never be reported as "empty" — that is the path that would offer to
    /// delete a real device set. Simulated with a mode-000 Devices directory.
    func testUnreadableDeviceSetIsNeverReportedAsEmptyResidue() throws {
        try XCTSkipIf(getuid() == 0, "root can read a 000 directory, so the failure cannot be simulated")
        let t = TempDir()
        t.dir("Library/Developer")
        let devices = t.dir("CoreSimulator-locked/Devices")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: devices)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devices) }
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        let hit = f.first { $0.id == "shadow-coresimulator:home:CoreSimulator-locked" }
        XCTAssertEqual(hit?.severity, .error, "unreadable must outrank empty residue: \(f.map { "\($0.id)=\($0.severity)" })")
        XCTAssertFalse(hit?.remediation?.contains("rmdir") == true, "never offer removal for a directory we could not read")
        XCTAssertTrue(hit?.detail.contains("could not be read") == true)
    }

    /// An empty `Devices/` inside a root that still holds caches is not removable residue.
    func testRootWithOtherContentIsNotDescribedAsRemovable() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("CoreSimulator-half/Devices")
        t.dir("CoreSimulator-half/Caches/dyld")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        let hit = f.first { $0.id == "shadow-coresimulator:home:CoreSimulator-half" }
        XCTAssertEqual(hit?.severity, .warning)
        XCTAssertTrue(hit?.detail.contains("Caches") == true, "should name what is actually left: \(hit?.detail ?? "nil")")
        XCTAssertFalse(hit?.remediation?.contains("rmdir") == true, "a root holding caches must not be called removable")
    }

    /// Regression for the bug that survived the first review round: the residue branch checked
    /// only for UUID-named entries and `device_set.plist`, so a `Devices/` holding anything else
    /// was still announced as "nothing but an empty Devices directory" and offered for removal.
    /// `rmdir` would then refuse, leaving the user in a loop against a false claim.
    /// Both halves of the gate are pinned: the leftover is placed once *inside* `Devices` and once
    /// *alongside* it at the candidate root. Testing only the first half let a mutant survive that
    /// weakened `rootIsOnlyDevices` back to a sibling check.
    func testDevicesHoldingNonUUIDEntriesIsNeverCalledEmptyResidue() {
        for leftover in [".DS_Store", "some-restored-device"] {
            for placeAtRoot in [false, true] {
                let t = TempDir()
                t.dir("Library/Developer")
                t.dir("CoreSimulator-odd/Devices")
                _ = t.file("CoreSimulator-odd/" + (placeAtRoot ? "" : "Devices/") + leftover, bytes: 4)
                let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
                let hit = f.first { $0.id == "shadow-coresimulator:home:CoreSimulator-odd" }
                let where_ = placeAtRoot ? "at the root" : "inside Devices"
                XCTAssertNotNil(hit, "still a CoreSimulator-shaped root (\(leftover) \(where_))")
                XCTAssertFalse(hit?.detail.contains("nothing but an empty") == true,
                               "must not claim emptiness with \(leftover) \(where_): \(hit?.detail ?? "nil")")
                XCTAssertFalse(hit?.remediation?.contains("rmdir") == true,
                               "must not offer rmdir when \(leftover) \(where_) would make it refuse")
                // NOT `detail.contains(leftover)`: the branch's own boilerplate mentions
                // ".DS_Store" as an example, so that assertion passes even when the message names
                // nothing at all. Assert on the rendered leftovers segment instead.
                let segment = placeAtRoot ? "alongside `Devices`: " : "inside `Devices`: "
                XCTAssertTrue(hit?.detail.contains(segment + leftover) == true,
                              "should name what is actually left (\(leftover) \(where_)): \(hit?.detail ?? "nil")")
                XCTAssertFalse(hit?.detail.contains("either — .") == true,
                               "must never render an empty leftovers list: \(hit?.detail ?? "nil")")
            }
        }
    }

    /// The exact shape of the E9 residue on a real machine: a CoreSimulator root carries
    /// `.metadata_never_index`, so a recreated skeleton is that dotfile plus an empty `Devices`.
    /// Dropping dot entries from the leftovers list made this render "not empty either — ." —
    /// naming nothing, while Finder (which hides dotfiles) shows an empty directory. That
    /// combination invites exactly the `rm -rf` this rule is meant to prevent.
    func testHiddenOnlyLeftoversAreNamedRatherThanRenderedAsNothing() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("CoreSimulator-real/Devices")
        _ = t.file("CoreSimulator-real/.metadata_never_index", bytes: 0)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        let hit = f.first { $0.id == "shadow-coresimulator:home:CoreSimulator-real" }
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit?.detail.contains("either — .") == true, "empty leftovers list: \(hit?.detail ?? "nil")")
        XCTAssertTrue(hit?.detail.contains(".metadata_never_index") == true,
                      "must name the hidden entry that will make rmdir refuse: \(hit?.detail ?? "nil")")
        XCTAssertFalse(hit?.remediation?.contains("rmdir") == true, "not removable while that file is there")
    }

    /// F2: hidden directories are scanned, only the unreadable-hidden *finding* is suppressed.
    func testReadableHiddenDirectoryOnAVolumeIsStillScanned() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("ext/.stash/CoreSimulator/Devices/15EA64C9-8286-40CC-881A-B19C606C7F88")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        XCTAssertTrue(f.contains { $0.path == t.path + "/ext/.stash/CoreSimulator" && $0.severity == .error },
                      "a readable hidden directory must still be scanned: \(f.map(\.id))")
    }

    /// A symlinked `Devices` must not reach the residue branch: `rmdir` returns ENOTDIR on a
    /// symlink, so calling it "an empty Devices directory" would be a false claim about the disk
    /// on the one branch that invites deletion.
    func testSymlinkedDevicesIsNotTreatedAsRemovableResidue() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("somewhere-empty")
        t.dir("CoreSimulator-linkdev")
        t.symlink("CoreSimulator-linkdev/Devices", to: t.path + "/somewhere-empty")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        let hit = f.first { $0.id == "shadow-coresimulator:home:CoreSimulator-linkdev" }
        XCTAssertFalse(hit?.remediation?.contains("rmdir") == true,
                       "a symlinked Devices must never be offered for rmdir: \(hit?.remediation ?? "nil")")
        XCTAssertFalse(hit?.detail.contains("nothing but an empty") == true,
                       "must not claim it is an empty Devices directory: \(hit?.detail ?? "nil")")
    }

    /// Regression: the first cut of the unreadable-intermediate check fired on every external
    /// volume's root-owned macOS metadata stores, producing three unactionable warnings per
    /// volume on every run. Verified against the real machine, which fixtures had not caught.
    func testHiddenSystemDirectoriesOnAVolumeProduceNoNoise() throws {
        try XCTSkipIf(getuid() == 0, "root can read a 000 directory, so the failure cannot be simulated")
        let t = TempDir()
        t.dir("Library/Developer")
        for meta in [".Spotlight-V100", ".DocumentRevisions-V100", ".TemporaryItems"] {
            let p = t.dir("ext/" + meta)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: p)
            addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p) }
        }
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        XCTAssertFalse(f.contains { $0.id.hasPrefix("shadow-coresimulator-unscannable:") },
                       "macOS metadata stores must not be reported every run: \(f.map(\.id))")
    }

    /// D2: an unreadable directory one level below a volume root would otherwise hide a whole
    /// device set and report nothing at all.
    func testUnreadableIntermediateDirectoryOnAVolumeIsReported() throws {
        try XCTSkipIf(getuid() == 0, "root can read a 000 directory, so the failure cannot be simulated")
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("ext/locked/CoreSimulator/Devices/15EA64C9-8286-40CC-881A-B19C606C7F88")
        let locked = t.path + "/ext/locked"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "extuuid", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        XCTAssertTrue(f.contains { $0.id == "shadow-coresimulator-unscannable:extuuid:locked" },
                      "an unreadable intermediate must not silently hide the set below it: \(f.map(\.id))")
    }

    /// H2: the canonical set reached through an aliased parent must not report itself.
    func testCanonicalSetReachedThroughASymlinkedParentIsStillExcluded() {
        let t = TempDir()
        t.dir("Library/Developer/CoreSimulator/Devices/0F29E552-3BA3-413D-96ED-B810CD690DC4")
        t.dir("ext")
        t.symlink("ext/dev", to: t.path + "/Library/Developer")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        XCTAssertFalse(f.contains { $0.id.hasPrefix("shadow-coresimulator:") && $0.id.contains("dev/CoreSimulator") },
                       "the live device set must not be reported as its own duplicate: \(f.map(\.id))")
    }

    /// H3: a root that cannot be enumerated must be reported as unknown, never passed over silently.
    func testUnscannableRootIsReportedRatherThanSkipped() {
        let t = TempDir()
        t.dir("Library/Developer")
        let vanished = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "GONE", volumeUUID: "vanished-uuid", mountPoint: t.path + "/not-mounted-anymore",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vanished]))
        let hit = f.first { $0.id == "shadow-coresimulator-unscannable:vanished-uuid" }
        XCTAssertEqual(hit?.severity, .warning, "\(f.map(\.id))")
        XCTAssertTrue(hit?.detail.contains("not as clean") == true, "must say unknown, not clean: \(hit?.detail ?? "nil")")
    }

    /// H4: the case we know least about escalates on the same signal as a populated one.
    func testUnreadableShadowSetPlusLiveRedirectEscalatesToCritical() throws {
        try XCTSkipIf(getuid() == 0, "root can read a 000 directory, so the failure cannot be simulated")
        let t = TempDir()
        t.dir("elsewhere/CoreSimulator")
        t.symlink("Library/Developer/CoreSimulator", to: t.path + "/elsewhere/CoreSimulator")
        let devices = t.dir("CoreSimulator-locked2/Devices")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: devices)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devices) }
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        XCTAssertEqual(f.first { $0.id == "shadow-coresimulator:home:CoreSimulator-locked2" }?.severity, .critical,
                       "\(f.map { "\($0.id)=\($0.severity)" })")
    }

    /// A shadow set holding devices *while* a live redirect exists means both can take writes.
    func testShadowSetPlusLiveRedirectEscalatesToCritical() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("elsewhere/CoreSimulator")
        t.symlink("Library/Developer/CoreSimulator", to: t.path + "/elsewhere/CoreSimulator")
        t.dir("CoreSimulator-shadow/Devices/15EA64C9-8286-40CC-881A-B19C606C7F88")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        let hit = f.first { $0.id == "shadow-coresimulator:home:CoreSimulator-shadow" }
        XCTAssertEqual(hit?.severity, .critical, "co-occurrence with a forbidden symlink is worse than a stale duplicate")
        XCTAssertTrue(hit?.detail.contains("taking writes right now") == true)
        // Without the redirect the same layout is only .error.
        let t2 = TempDir()
        t2.dir("Library/Developer")
        t2.dir("CoreSimulator-shadow/Devices/15EA64C9-8286-40CC-881A-B19C606C7F88")
        let f2 = Doctor(home: t2.path, runner: quiet).diagnose(report: fakeReport(home: t2.path))
        XCTAssertEqual(f2.first { $0.id == "shadow-coresimulator:home:CoreSimulator-shadow" }?.severity, .error)

        // The wider `~/Library/Developer` redirect must escalate too — that arm of the check was
        // otherwise unpinned, and a mutant dropping it passed the whole suite.
        let t3 = TempDir()
        t3.dir("real/Developer")
        t3.symlink("Library/Developer", to: t3.path + "/real/Developer")
        t3.dir("CoreSimulator-shadow/Devices/15EA64C9-8286-40CC-881A-B19C606C7F88")
        let f3 = Doctor(home: t3.path, runner: quiet).diagnose(report: fakeReport(home: t3.path))
        XCTAssertEqual(
            f3.first { $0.id == "shadow-coresimulator:home:CoreSimulator-shadow" }?.severity, .critical,
            "a ~/Library/Developer redirect is also a live redirect: \(f3.map { "\($0.id)=\($0.severity)" })")
    }

    func testShadowCoreSimulatorRootHoldingDevicesIsAnErrorAndNeverSuggestsDeletion() {
        let t = TempDir()
        t.dir("Library/Developer")
        // A UUID starting with "0" — the user's real Apple Watch device is 0F29E552-…, and an
        // early version of this rule filtered those out by mistake.
        t.dir("CoreSimulator-backup/Devices/0F29E552-3BA3-413D-96ED-B810CD690DC4")
        _ = t.file("CoreSimulator-backup/Devices/device_set.plist", bytes: 32)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        let hit = f.first { $0.id == "shadow-coresimulator:home:CoreSimulator-backup" }
        XCTAssertEqual(hit?.severity, .error, "a shadow root holding real devices outranks empty residue")
        XCTAssertTrue(hit?.detail.contains("1 device") == true, "must count the UUID-named device: \(hit?.detail ?? "nil")")
        XCTAssertTrue(hit?.detail.contains("device_set.plist") == true)
        XCTAssertTrue(hit?.remediation?.contains("Do not delete") == true, "rule 4/5: never suggest deleting data that was not verified")
        XCTAssertFalse(hit?.remediation?.contains("rmdir") == true, "must not offer a removal command for a set that holds devices")
    }

    func testShadowCoreSimulatorRuleIgnoresSymlinksAndUnrelatedDirectories() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("elsewhere/CoreSimulator/Devices")
        // A symlink named like a shadow root is checkForbiddenSymlinks' business, not ours.
        t.symlink("CoreSimulator-link", to: t.path + "/elsewhere/CoreSimulator")
        // Named like CoreSimulator but with no Devices/ — not a device set.
        t.dir("CoreSimulator-notes/SomethingElse")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path))
        XCTAssertFalse(f.contains { $0.id == "shadow-coresimulator:home:CoreSimulator-link" }, "symlinks are out of scope")
        XCTAssertFalse(f.contains { $0.id == "shadow-coresimulator:home:CoreSimulator-notes" }, "no Devices/ means not a device set")
    }

    func testDetectsShadowCoreSimulatorRootOnExternalVolume() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("ext/CoreSimulator/Devices/15EA64C9-8286-40CC-881A-B19C606C7F88")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        let hit = f.first { $0.id.hasPrefix("shadow-coresimulator:") && $0.path == t.path + "/ext/CoreSimulator" }
        XCTAssertEqual(hit?.severity, .error, "\(f.map(\.id))")
        XCTAssertTrue(hit?.title.contains("EXT") == true, "the finding should name the volume: \(hit?.title ?? "nil")")
    }

    /// The layout that actually occurs in the wild: mac-ssd-rescue puts the device set one level
    /// below the volume root, so a top-level-only scan would miss it entirely.
    func testDetectsNestedShadowCoreSimulatorRootFromPriorTool() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("ext/mac-ssd-rescue/CoreSimulator/Devices/0F29E552-3BA3-413D-96ED-B810CD690DC4")
        t.dir("ext/mac-ssd-rescue/CoreSimulator/Devices/855CCF05-5E74-4372-ADB5-7ADE52900AE8")
        _ = t.file("ext/mac-ssd-rescue/CoreSimulator/Devices/device_set.plist", bytes: 16)
        // A same-named directory three levels down must stay out of scope (depth cap).
        t.dir("ext/too/deep/CoreSimulator/Devices/15EA64C9-8286-40CC-881A-B19C606C7F88")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "VAULT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        let hit = f.first { $0.path == t.path + "/ext/mac-ssd-rescue/CoreSimulator" }
        XCTAssertEqual(hit?.severity, .error, "nested device set with real devices: \(f.map(\.id))")
        XCTAssertTrue(hit?.detail.contains("2 device") == true, "should count both UUIDs: \(hit?.detail ?? "nil")")
        XCTAssertTrue(hit?.id.contains("mac-ssd-rescue/CoreSimulator") == true, "id should carry the relative path: \(hit?.id ?? "nil")")
        XCTAssertFalse(f.contains { $0.path == t.path + "/ext/too/deep/CoreSimulator" }, "depth cap is 2 on volumes")
    }

    func testLowFreeSpaceSeverity() {
        let t = TempDir(); t.dir("Library/Developer")
        let d = Doctor(home: t.path, runner: quiet)
        XCTAssertEqual(d.diagnose(report: fakeReport(home: t.path, free: 5_000_000_000)).first { $0.id == "low-free-space" }?.severity, .critical)
        XCTAssertEqual(d.diagnose(report: fakeReport(home: t.path, free: 30_000_000_000)).first { $0.id == "low-free-space" }?.severity, .warning)
        XCTAssertNil(d.diagnose(report: fakeReport(home: t.path, free: 80_000_000_000)).first { $0.id == "low-free-space" })
    }

    func testRuntimeRegistryProblems() {
        let t = TempDir(); t.dir("Library/Developer")
        var rt = SimulatorRuntime(identifier: "ABC")
        rt.state = "Ready"; rt.mountPath = t.path + "/not-a-mount"; rt.signatureState = "Invalid"; rt.path = t.path + "/missing.dmg"
        t.dir("not-a-mount")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, runtimes: [rt]))
        XCTAssertTrue(f.contains { $0.id == "runtime-not-mounted:ABC" })
        XCTAssertTrue(f.contains { $0.id == "runtime-signature:ABC" })
        XCTAssertTrue(f.contains { $0.id == "runtime-image-missing:ABC" })
    }

    func testUnavailableDevices() {
        let t = TempDir(); t.dir("Library/Developer")
        let dev = SimulatorDevice(
            udid: "U", name: "iPhone X", runtimeIdentifier: "r", state: "Shutdown", isAvailable: false,
            availabilityError: "runtime profile not found", dataPath: nil, dataPathSize: 123, logPath: nil, lastBootedAt: nil)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, devices: [dev]))
        XCTAssertTrue(f.contains { $0.id == "unavailable-devices" && $0.remediation?.contains("simctl delete unavailable") == true })
    }

    func testFindingsAreSortedBySeverity() {
        let t = TempDir(); t.dir("Library/Developer")
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, free: 1_000_000_000))
        XCTAssertEqual(f.map(\.severity), f.map(\.severity).sorted(by: >))
    }
}

final class ScannerTests: XCTestCase {
    func testResolvesCatalogAgainstFakeHome() throws {
        let t = TempDir()
        t.file("Library/Developer/Xcode/DerivedData/Proj-abc/Build/x.o", bytes: 4096)
        t.file("Library/Developer/Xcode/DerivedData/Proj-abc/Index/y", bytes: 4096)
        t.symlink("Library/Developer/Xcode/Archives", to: "/Volumes/GONE/Archives")
        let cat = [StorageCatalog.category("derivedData")!, StorageCatalog.category("archives")!, StorageCatalog.category("previews")!]
        let scanner = XCodeVaultCore.Scanner(runner: FakeRunner(responses: [:]), home: t.path, catalog: cat)
        let items = scanner.resolveItems()
        let dd = try XCTUnwrap(items.first { $0.categoryID == "derivedData" })
        XCTAssertTrue(dd.exists); XCTAssertFalse(dd.isSymlink); XCTAssertEqual(dd.usage?.fileCount, 2)
        XCTAssertGreaterThanOrEqual(dd.allocatedBytes, 8192)
        XCTAssertTrue(dd.onBootVolume)
        let ar = try XCTUnwrap(items.first { $0.categoryID == "archives" })
        XCTAssertTrue(ar.isSymlink); XCTAssertEqual(ar.symlinkTarget, "/Volumes/GONE/Archives")
        let pv = try XCTUnwrap(items.first { $0.categoryID == "previews" })
        XCTAssertFalse(pv.exists); XCTAssertNil(pv.usage)
        let summary = scanner.summarize(items: items, runtimes: [])
        XCTAssertEqual(summary.relocatableBytes, dd.allocatedBytes)  // symlinked archives are not counted
        XCTAssertEqual(summary.cleanableBytes, dd.allocatedBytes)
        XCTAssertEqual(summary.estimatedInternalSavingsBytes, dd.allocatedBytes)
    }

    func testReportRoundTripsThroughJSON() throws {
        let t = TempDir(); t.dir("Library/Developer")
        let runner = FakeRunner(responses: [
            "sw_vers -productVersion": .init(status: 0, stdout: "26.6\n", stderr: ""),
            "sw_vers -buildVersion": .init(status: 0, stdout: "25G83\n", stderr: ""),
            "xcrun simctl runtime list -j": .init(status: 0, stdout: Fixtures.string("simctl-runtime-list-xcode26.5.json"), stderr: ""),
            "xcrun simctl list devices -j": .init(status: 0, stdout: Fixtures.string("simctl-list-devices-xcode26.5.json"), stderr: ""),
            "diskutil list -plist": .init(
                status: 0, stdout: "<plist version=\"1.0\"><dict><key>AllDisksAndPartitions</key><array/></dict></plist>", stderr: ""),
            "xcode-select -p": .init(status: 0, stdout: "/nonexistent/Xcode.app/Contents/Developer\n", stderr: ""),
        ])
        let report = XCodeVaultCore.Scanner(
            runner: runner, home: t.path, catalog: [StorageCatalog.category("derivedData")!], measureSizes: false, detectXcodeCapabilities: false
        ).scan()
        XCTAssertEqual(report.runtimes.count, 2)
        XCTAssertEqual(report.devices.count, 3)
        let json = try JSONOutput.encode(report)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(ScanReport.self, from: Data(json.utf8))
        XCTAssertEqual(back.runtimes, report.runtimes)
        XCTAssertEqual(back.items.count, 1)
        XCTAssertFalse(TextRenderer.scan(report).isEmpty)
    }
}
