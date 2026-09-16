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

    /// Found in real use, not by review: after the prior tool's data was deleted, the directory
    /// itself survived (the volume root is root-owned, so unlinking an entry needs sudo) and the
    /// rule rendered "contains: ." — an empty list — while still advising the user to compare
    /// before deleting. Advice about nothing, on a rule that talks about deletion.
    func testEmptiedPriorToolDirectoryIsNotDescribedAsHavingContents() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("ext/mac-ssd-rescue")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        let hit = f.first { $0.id.hasPrefix("prior-tool:mac-ssd-rescue") }
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit?.detail.contains("contains: .") == true, "empty list rendered as nothing: \(hit?.detail ?? "nil")")
        XCTAssertTrue(hit?.detail.contains("is empty") == true, "should say it is empty: \(hit?.detail ?? "nil")")
        XCTAssertFalse(hit?.remediation?.contains("Compare with the local copies") == true,
                       "nothing to compare when it is empty: \(hit?.remediation ?? "nil")")
        XCTAssertTrue(hit?.remediation?.contains("rmdir") == true, "should offer the safe removal: \(hit?.remediation ?? "nil")")
        XCTAssertTrue(hit?.remediation?.contains("not `rm -rf`") == true,
                      "must steer away from rm -rf explicitly: \(hit?.remediation ?? "nil")")
    }

    /// Blocking regression from review, and the same defect this rewrite was meant to close, one
    /// line lower: filtering dotfiles before the emptiness test. `rm -rf dir/*` in a shell without
    /// `dotglob` — exactly how this directory got emptied in practice — leaves `.DS_Store` behind,
    /// and `rmdir` then refuses. Calling it empty is a false all-clear from a rule whose whole job
    /// is deciding whether data is at risk.
    func testDirectoryHoldingOnlyHiddenFilesIsNotCalledEmpty() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("ext/mac-ssd-rescue")
        _ = t.file("ext/mac-ssd-rescue/.DS_Store", bytes: 8)
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        let hit = try? XCTUnwrap(f.first { $0.id.hasPrefix("prior-tool:mac-ssd-rescue") })
        XCTAssertFalse(hit?.detail.contains("is empty") == true,
                       "a .DS_Store is enough for rmdir to refuse: \(hit?.detail ?? "nil")")
        XCTAssertFalse(hit?.remediation?.contains("rmdir") == true,
                       "must not offer a removal that would refuse: \(hit?.remediation ?? "nil")")
        XCTAssertTrue(hit?.detail.contains("plus 1 hidden entry") == true,
                      "must state the count, not just the word: \(hit?.detail ?? "nil")")
    }

    /// An emptied directory that something still redirects into is not "nothing at risk" — it is a
    /// live redirect pointing at an empty tree.
    func testEmptyPriorToolDirectoryThatIsStillASymlinkTargetIsNotCalledSafe() {
        let t = TempDir()
        t.dir("ext/mac-ssd-rescue")
        t.symlink("Library/Developer/CoreSimulator", to: t.path + "/ext/mac-ssd-rescue")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        let hit = f.first { $0.id.hasPrefix("prior-tool:mac-ssd-rescue") }
        XCTAssertFalse(hit?.detail.contains("nothing at risk") == true,
                       "a live redirect target is not nothing at risk: \(hit?.detail ?? "nil")")
        XCTAssertFalse(hit?.remediation?.contains("sudo rmdir") == true,
                       "must not offer removal while a redirect still points here: \(hit?.remediation ?? "nil")")
    }

    /// The redirect check has to survive three shapes that a raw string compare misses, all of
    /// which leave a dangling symlink if the user follows the removal advice.
    func testRedirectDetectionSurvivesRelativeParentAndDeeperTargets() {
        // 1. relative destination — destinationOfSymbolicLink returns it unresolved
        // 2. destination that is a PARENT of the candidate (the mac-ssd-rescue layout)
        // 3. a redirect from a path deeper than the leftover directory itself
        let cases: [(name: String, link: String, target: (String) -> String)] = [
            ("relative", "Library/Developer/CoreSimulator", { _ in "../../ext/mac-ssd-rescue" }),
            ("parent", "Library/Developer", { root in root + "/ext" }),
            ("exact", "Library/Developer/CoreSimulator", { root in root + "/ext/mac-ssd-rescue" }),
        ]
        for c in cases {
            let t = TempDir()
            t.dir("ext/mac-ssd-rescue")
            t.symlink(c.link, to: c.target(t.path))
            let vol = Volume(
                deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
                filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
                isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
                totalBytes: 1, freeBytes: 1, isBootVolume: false)
            let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
            let hit = f.first { $0.id.hasPrefix("prior-tool:mac-ssd-rescue") }
            XCTAssertFalse(hit?.detail.contains("nothing at risk") == true,
                           "\(c.name) redirect must not read as safe: \(hit?.detail ?? "nil")")
            XCTAssertFalse(hit?.remediation?.contains("sudo rmdir") == true,
                           "\(c.name) redirect must not be offered for removal: \(hit?.remediation ?? "nil")")
        }
    }

    /// A symlinked candidate must not be followed: it would report some other tree's contents
    /// under this path, and the empty branch would offer `sudo rmdir` on a symlink (ENOTDIR).
    func testSymlinkedPriorToolCandidateIsNotFollowed() {
        let t = TempDir()
        t.dir("Library/Developer")
        t.dir("somewhere/else")
        t.symlink("ext/mac-ssd-rescue", to: t.path + "/somewhere/else")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        let hit = f.first { $0.id.hasPrefix("prior-tool:mac-ssd-rescue") }
        XCTAssertTrue(hit?.detail.contains("is a symlink") == true, "\(hit?.detail ?? "nil")")
        XCTAssertFalse(hit?.remediation?.contains("rmdir") == true, "rmdir on a symlink returns ENOTDIR")
    }

    /// Deeper-target redirect: the comment claims this shape is covered; pin it.
    func testRedirectDeeperThanTheCandidateIsAlsoDetected() {
        let t = TempDir()
        t.dir("ext/mac-ssd-rescue/Devices")
        t.symlink("Library/Developer/CoreSimulator", to: t.path + "/ext/mac-ssd-rescue/Devices")
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        let hit = f.first { $0.id.hasPrefix("prior-tool:mac-ssd-rescue") }
        XCTAssertFalse(hit?.remediation?.contains("sudo rmdir") == true,
                       "a redirect into a subdirectory still makes removal unsafe: \(hit?.remediation ?? "nil")")
    }

    func testUnreadablePriorToolDirectoryIsNotDescribedAsEmpty() throws {
        try XCTSkipIf(getuid() == 0, "root can read a 000 directory")
        let t = TempDir()
        t.dir("Library/Developer")
        let dir = t.dir("ext/mac-ssd-rescue")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        let vol = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "EXT", volumeUUID: "u", mountPoint: t.path + "/ext",
            filesystemPersonality: "APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: false,
            isEjectable: true, busProtocol: "USB", isSolidState: true, isWritable: true, ownersEnabled: true,
            totalBytes: 1, freeBytes: 1, isBootVolume: false)
        let f = Doctor(home: t.path, runner: quiet).diagnose(report: fakeReport(home: t.path, volumes: [vol]))
        let hit = try XCTUnwrap(f.first { $0.id.hasPrefix("prior-tool:mac-ssd-rescue") })
        XCTAssertTrue(hit.detail.contains("could not be read"), "unreadable must not read as empty: \(hit.detail)")
        XCTAssertFalse(hit.remediation?.contains("rmdir") == true, "never offer removal for something we could not inspect")
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

/// `checkOrphanedDyldCaches` — the rule that separates "cache that will be rebuilt" from "cache
/// nothing will ever rebuild". The remediation is a shell command, so every test below that asserts
/// a finding is also asserting that a user will be told to run something.
///
/// The first suite of these passed while the rule still produced a deletion command for a plain
/// file, a symlink, a directory named `tmp`, and — with one upstream field renamed — every live
/// cache on the machine. Well-formed fixtures proved nothing about any of it. The malformed-input
/// cases below exist because of that, not for completeness.
final class OrphanedDyldCacheTests: XCTestCase {
    let hostBuild = "25G83"
    let iOSid = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    let tvOSid = "com.apple.CoreSimulator.SimRuntime.tvOS-26-5"

    func host(build: String = "25G83") -> HostEnvironment {
        HostEnvironment(
            macOSVersion: "26.6.2", macOSBuild: build, architecture: "x86_64", homeDirectory: "/Users/x",
            dataVolumeFreeBytes: 1, dataVolumeTotalBytes: 2, userName: "x", isRoot: false)
    }
    func runtime(_ rid: String, build: String? = nil) -> SimulatorRuntime {
        SimulatorRuntime(identifier: UUID().uuidString, runtimeIdentifier: rid, build: build)
    }

    /// `dirs` become cache directories with a file inside; `files` become plain files; `links`
    /// become symlinks. Returns the tree root.
    /// Everything is aged 26 h by default: a cache written seconds ago is treated as a build in
    /// flight at every level, so a test that means "this is an orphan" has to mean "and it is old".
    /// Pass `ageHours: 0` for the in-flight cases.
    func makeTree(_ dirs: [String], files: [String] = [], links: [String] = [], ageHours: Double = 26) throws -> String {
        let root = NSTemporaryDirectory() + "/dyldcache-" + UUID().uuidString
        for e in dirs {
            try FileManager.default.createDirectory(atPath: root + "/" + e, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root + "/" + e + "/dyld_sim_shared_cache_x86_64", contents: Data(repeating: 0, count: 4096))
        }
        for e in files {
            try FileManager.default.createDirectory(atPath: (root + "/" + e as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root + "/" + e, contents: Data(repeating: 0, count: 64))
        }
        for e in links {
            try FileManager.default.createDirectory(atPath: (root + "/" + e as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root + "/" + e, withDestinationPath: "/tmp")
        }
        if ageHours > 0 {
            let when = Date().addingTimeInterval(-3600 * ageHours)
            if let en = FileManager.default.enumerator(atPath: root) {
                for case let sub as String in en { try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: root + "/" + sub) }
            }
        }
        addTeardownBlock {
            // Chmod back first: an unreadable directory cannot be removed.
            if let en = FileManager.default.enumerator(atPath: root) {
                for case let sub as String in en { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/" + sub) }
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
            try? FileManager.default.removeItem(atPath: root)
        }
        return root
    }

    func check(
        _ root: String, runtimes: [SimulatorRuntime], devices: [SimulatorDevice] = [], host h: HostEnvironment? = nil, warnings: [String] = [],
        now: Date = Date()
    ) -> [Finding] {
        Doctor(dyldCacheRoot: root).checkOrphanedDyldCaches(runtimes: runtimes, host: h ?? host(), devices: devices, warnings: warnings, now: now)
    }
    func device(_ rid: String, available: Bool) -> SimulatorDevice {
        SimulatorDevice(udid: UUID().uuidString, name: "d", runtimeIdentifier: rid, state: "Shutdown", isAvailable: available)
    }

    /// Set an entry's mtime into the past. The rule must judge liveness by the newest write anywhere
    /// inside, not by the directory's own mtime, so tests that mean "old" have to age both.
    func age(_ path: String, hours: Double, filesToo: Bool = true) throws {
        let when = Date().addingTimeInterval(-3600 * hours)
        if filesToo, let children = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for c in children { try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: path + "/" + c) }
        }
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: path)
    }

    // MARK: the rule's actual job

    func testACacheWhoseRuntimeIsStillInstalledIsNotReported() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "a live runtime's cache is rebuilt on demand, not orphaned: \(f.map(\.title))")
    }

    func testACacheWhoseRuntimeIsGoneIsReported() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/\(tvOSid).23L470"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertEqual(f.count, 1)
        // XCTUnwrap, never `f[0]`: subscripting an empty array traps, and a trap takes down the whole
        // test process — every other test in the run reports nothing. Found while mutation-testing.
        let only = try XCTUnwrap(f.first)
        XCTAssertTrue(only.path?.hasSuffix("\(tvOSid).23L470") == true, "reported the wrong path: \(only.path ?? "nil")")
    }

    /// The case actually found on the machine: an interrupted build under `inc/` for a runtime that
    /// has since been removed — 2.3 GiB that survived the removal and later simulator boots.
    func testAnInterruptedBuildForARemovedRuntimeIsReported() throws {
        let root = try makeTree(["\(hostBuild)/inc/\(tvOSid).23L470"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertEqual(f.count, 1)
        XCTAssertTrue(try XCTUnwrap(f.first).id.hasPrefix("orphan-dyld-inc:"))
    }

    /// The most likely orphan on a machine that has taken a runtime update, and invisible while the
    /// rule matched on identifier alone: the superseded build's cache. `iOS-26-5` is still installed,
    /// but at build 23G99, so the 23F77 cache belongs to nothing.
    func testACacheForASupersededBuildOfAnInstalledRuntimeIsReported() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/\(iOSid).23G99"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23G99")])
        XCTAssertEqual(f.count, 1, "the superseded build's cache is orphaned: \(f.map(\.title))")
        XCTAssertTrue(try XCTUnwrap(f.first).path?.hasSuffix(".23F77") == true)
    }

    /// When the runtime reports no build the match must widen back to the identifier. Claiming more
    /// caches means reporting fewer, which is the direction that cannot hurt anyone.
    func testARuntimeWithNoBuildStillClaimsItsCaches() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77"])
        let f = check(root, runtimes: [runtime(iOSid, build: nil)])
        XCTAssertTrue(f.isEmpty, "a build-less runtime must claim its caches, not orphan them: \(f.map(\.title))")
    }

    // MARK: guards against reporting live data

    /// `runtimeIdentifier` is optional and the decoder enforces no required keys, so an upstream
    /// rename yields a non-empty array that claims nothing. Before the `installedPrefixes` guard this
    /// produced `sudo rm` for every live cache on the machine — the exact 9.4 GiB outcome the
    /// empty-list guard was written to prevent, reached through a different door.
    func testRuntimesWithNoIdentifierReportNothingRatherThanEverything() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/inc/\(tvOSid).23L470"])
        let f = check(root, runtimes: [SimulatorRuntime(identifier: "UUID-1", runtimeIdentifier: nil)])
        XCTAssertTrue(f.isEmpty, "undecodable identifiers must not read as 'nothing is installed': \(f.map(\.title))")
    }

    /// `Scanner` records a failed probe in `report.warnings`. Emptiness is the fallback; this is the
    /// real signal, and the doc comment used to claim it did not exist.
    func testAFailedSimctlProbeReportsNothing() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/\(tvOSid).23L470"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")], warnings: ["simctl runtime list failed: boom"])
        XCTAssertTrue(f.isEmpty, "a recorded probe failure must silence the rule: \(f.map(\.title))")
    }

    func testAnEmptyRuntimeListReportsNothingRatherThanEverything() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/inc/\(tvOSid).23L470"])
        XCTAssertTrue(check(root, runtimes: []).isEmpty)
    }

    func testAnUnknownHostBuildReportsNothing() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77"])
        XCTAssertTrue(check(root, runtimes: [runtime(iOSid, build: "23F77")], host: host(build: "unknown")).isEmpty)
    }

    /// An `inc/` entry may be a build in flight: CoreSimulator writes it before `simctl` reports the
    /// runtime, so "not installed" alone does not mean "dead". Age is the second, independent guard.
    func testARecentlyWrittenInterruptedBuildIsAssumedToBeInFlight() throws {
        let root = try makeTree(["\(hostBuild)/inc/\(tvOSid).23L470"], ageHours: 0)
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "a fresh inc/ entry may be live work: \(f.map(\.title))")
    }

    // MARK: malformed trees

    /// Every one of these produced a deletion command before the type checks were pushed down to
    /// levels 2 and 3. `update_dyld_sim_shared_cache-stderr.txt` is a real filename in this tree.
    func testFilesAndSymlinksAreNeverReported() throws {
        let root = try makeTree(
            ["\(hostBuild)/\(iOSid).23F77"],
            files: ["\(hostBuild)/update_dyld_sim_shared_cache-stderr.txt", "\(hostBuild)/inc/leftover.part"],
            links: ["\(hostBuild)/\(tvOSid).23L470", "\(hostBuild)/inc/\(tvOSid).23L999"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "only directories are caches: \(f.map { "\($0.title) @ \($0.path ?? "")" })")
    }

    /// An unrecognised sibling used to be reported as "built for macOS tmp" with a command attached.
    func testAnUnrecognisedSiblingIsNotCalledAStaleBuild() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "tmp/junk"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "`tmp` is not a macOS build: \(f.map(\.title))")
    }

    /// The stale-build branch fires only when the layout is recognisable — a build-shaped name AND a
    /// sibling equal to this machine's build, which is the proof we are reading the tree we think.
    /// It has never been observed in the field, so it carries no command.
    func testAStaleBuildTreeIsInformationalAndCarriesNoCommand() throws {
        let root = try makeTree(["24A335/\(iOSid).23F77", "\(hostBuild)/\(iOSid).23F77"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertEqual(f.count, 1)
        let only = try XCTUnwrap(f.first)
        XCTAssertEqual(only.severity, .info)
        XCTAssertFalse(only.remediation?.contains("rm ") == true, "an unverified branch must not hand out a delete: \(only.remediation ?? "")")
    }

    func testAStaleBuildIsNotReportedWhenNoSiblingMatchesThisMachine() throws {
        let root = try makeTree(["24A335/\(iOSid).23F77"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "without a sibling for this machine's build the layout is unrecognised: \(f.map(\.title))")
    }

    /// An unreadable cache directory is skipped outright: its age cannot be established, and "we
    /// cannot tell how old it is" must not resolve to "old enough to delete". This used to report the
    /// orphan with "size unknown"; the age guard at this level now refuses earlier, which is the
    /// stronger behaviour of the two.
    func testAnUnreadableCacheDirectoryIsSkippedRatherThanReported() throws {
        let root = try makeTree(["\(hostBuild)/\(tvOSid).23L470"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/\(hostBuild)/\(tvOSid).23L470")
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "an unreadable tree cannot be judged: \(f.map(\.title))")
    }

    /// A tree we could only partly measure must say so rather than print a confident total next to a
    /// deletion command. `DiskUsage` reports this as `isLowerBound`.
    func testAPartlyUnreadableTreeReportsALowerBoundNotATotal() throws {
        let root = try makeTree(["\(hostBuild)/\(tvOSid).23L470/sub"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/\(hostBuild)/\(tvOSid).23L470/sub")
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertEqual(f.count, 1, "\(f.map(\.title))")
        let title = try XCTUnwrap(f.first).title
        XCTAssertTrue(title.contains("at least") || title.contains("size unknown"), "must not state a total it could not measure: \(title)")
    }

    /// A directory that does not name a runtime is not a cache, and the rule cannot say what it is.
    /// Level 1 got this check; levels 2 and 3 had only a type check, so `tmp` was reported as "a
    /// finished cache for a runtime simctl no longer reports" — with a deletion command attached.
    func testDirectoriesThatDoNotNameARuntimeAreNeverReported() throws {
        let root = try makeTree([
            "\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/tmp", "\(hostBuild)/v2",
            "\(hostBuild)/inc/scratch", "\(hostBuild)/inc/inc",
        ])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "unrecognised names must not be described as caches: \(f.map { "\($0.title) @ \($0.path ?? "")" })")
    }

    /// A cache build writes hundreds of MB for many minutes while the *directory's* mtime stays
    /// frozen at the moment its entries were created — measured on this machine, the iOS rebuild
    /// spanned 06:47→07:06. Judging liveness by the directory alone reports a build that is running
    /// right now, for a runtime simctl does not report yet, as garbage to delete.
    func testASlowInFlightBuildIsNotReportedWhenOnlyTheDirectoryMtimeIsOld() throws {
        let root = try makeTree(["\(hostBuild)/inc/\(tvOSid).23L470"])
        let dir = root + "/\(hostBuild)/inc/\(tvOSid).23L470"
        // …but a file inside was written seconds ago: the build is alive.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir + "/dyld_sim_shared_cache_x86_64")
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "a fresh write inside means the build is live: \(f.map(\.title))")
    }

    /// "We cannot tell how old it is" must not resolve to "old enough to delete".
    func testAnUnreadableInFlightEntryIsNotReported() throws {
        let root = try makeTree(["\(hostBuild)/inc/\(tvOSid).23L470"])
        let dir = root + "/\(hostBuild)/inc/\(tvOSid).23L470"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "an unreadable mtime is unknown, not stale: \(f.map(\.title))")
    }

    /// Exact `<rid>.<build>` matching rests on a naming scheme observed on one machine. If a
    /// platform's directories are named differently, exact matching orphans every live cache — so it
    /// is used only when the tree itself contains at least one exactly-named installed runtime.
    func testExactBuildMatchingIsNotUsedWhenTheTreeDoesNotConfirmTheNamingScheme() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77-variant"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "unfamiliar naming must fall back to prefix matching, not orphan live caches: \(f.map(\.title))")
    }

    func testAnUnreadableHostBuildDirectoryIsNotTreatedAsEmpty() throws {
        let root = try makeTree(["\(hostBuild)/\(tvOSid).23L470"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/" + hostBuild)
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "unreadable is unknown, not empty: \(f.map(\.title))")
    }

    /// `simctl runtime list` covers disk-image runtimes only; one bundled inside an older Xcode does
    /// not appear there. An available device proves its runtime exists, so it claims the cache and
    /// the rule stays quiet rather than offering to delete something live.
    func testAnAvailableDeviceKeepsItsRuntimesCacheFromBeingCalledOrphaned() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/\(tvOSid).23L470"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")], devices: [device(tvOSid, available: true)])
        XCTAssertTrue(f.isEmpty, "an available device is a second witness that the runtime exists: \(f.map(\.title))")
    }

    /// A device whose runtime is gone reports `isAvailable == false` — exactly what E11 saw when a
    /// runtime was offloaded — so it must not keep the orphan alive.
    func testAnUnavailableDeviceDoesNotClaimACache() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/\(tvOSid).23L470"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")], devices: [device(tvOSid, available: false)])
        XCTAssertEqual(f.count, 1, "\(f.map(\.title))")
    }

    /// B1: the age guard existed on `inc/` only. Nothing establishes that a rebuild is staged through
    /// `inc/` rather than written straight into its final directory, so a cache being written right
    /// now — for a runtime `simctl` has not reported yet — was reported with a delete command at this
    /// level while the identical case was guarded one level down.
    func testAFinishedCacheBeingWrittenRightNowIsNotReported() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/\(tvOSid).23L470"], ageHours: 0)
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "a cache written seconds ago may be a live build: \(f.map(\.title))")
    }

    /// B2: naming confirmation was one Bool for the whole tree. iOS naming its directory
    /// `<rid>.<build>` then licensed exact matching for a visionOS runtime named some other way — and
    /// reported that live cache for deletion. Confirming one platform says nothing about another.
    func testOnePlatformsNamingSchemeDoesNotLicenseExactMatchingForAnother() throws {
        let visionID = "com.apple.CoreSimulator.SimRuntime.visionOS-26-5"
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/\(visionID).23X99-variant"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77"), runtime(visionID, build: "23X99")])
        XCTAssertTrue(f.isEmpty, "visionOS is installed; its cache must not be orphaned by iOS's naming: \(f.map(\.title))")
    }

    /// B3: this rule's own notes and `EXPERIMENTS.md` describe CoreSimulator writing `inc/<rid>` with
    /// no build suffix during an install. Without an equality test that live in-progress build was
    /// reported as "a runtime simctl no longer reports" while the runtime was installed.
    func testAnIncEntryNamedWithoutABuildSuffixIsClaimedByItsInstalledRuntime() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/inc/\(iOSid)"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "`inc/<rid>` belongs to the installed runtime: \(f.map(\.title))")
    }

    /// B4: a device knows its runtime exists but not which build, so a device entry can only
    /// prefix-match. Adding one for a runtime `simctl` already described precisely replaced a
    /// build-accurate claim with a vague one — and since every machine has devices for its installed
    /// runtimes, that silently disabled superseded-build detection everywhere.
    func testAnAvailableDeviceDoesNotSuppressASupersededBuildOrphan() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/\(iOSid).23G99"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23G99")], devices: [device(iOSid, available: true)])
        XCTAssertEqual(f.count, 1, "the 23F77 cache is still orphaned: \(f.map(\.title))")
        XCTAssertTrue(try XCTUnwrap(f.first).path?.hasSuffix(".23F77") == true)
    }

    /// B5: the displayed date came from the directory's own mtime — the same frozen value the age
    /// guard was fixed to stop trusting — so a tree written minutes ago was shown as last touched a
    /// year back, next to a deletion command.
    func testTheReportedDateIsTheNewestWriteNotTheFrozenDirectoryMtime() throws {
        let root = try makeTree(["\(hostBuild)/inc/\(tvOSid).23L470"])
        let dir = root + "/\(hostBuild)/inc/\(tvOSid).23L470"
        let old = Date().addingTimeInterval(-400 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir)
        let fileDay = Date().addingTimeInterval(-2 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: fileDay], ofItemAtPath: dir + "/dyld_sim_shared_cache_x86_64")
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertEqual(f.count, 1, "\(f.map(\.title))")
        let detail = try XCTUnwrap(f.first).detail
        let stale = Doctor.dayStamp.string(from: old)
        XCTAssertFalse(detail.contains(stale), "the frozen directory mtime must not be shown: \(detail)")
        XCTAssertTrue(detail.contains(Doctor.dayStamp.string(from: fileDay)), detail)
    }

    /// `.SimRuntime.` with the trailing dot. Without it a directory whose name merely *starts* with
    /// the marker is treated as a cache — and the finding carries a deletion command, so a name the
    /// rule cannot parse must not be described as a runtime's cache.
    func testANameThatOnlyResemblesTheRuntimeMarkerIsNotACache() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/com.apple.CoreSimulator.SimRuntimeBackup"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "`SimRuntimeBackup` is not a runtime cache: \(f.map(\.title))")
    }

    /// Hidden entries are skipped at every level, independently of whether the name looks like a
    /// runtime — otherwise the check depends on `namesARuntime` happening to reject them.
    func testHiddenDirectoriesAreSkippedEvenWhenTheyNameARuntime() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/.\(tvOSid).23L470", "\(hostBuild)/inc/.\(tvOSid).23L999"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        XCTAssertTrue(f.isEmpty, "hidden entries are not ours to judge: \(f.map(\.title))")
    }

    func testAMissingCacheRootIsNotAFinding() {
        XCTAssertTrue(check(NSTemporaryDirectory() + "/absent-" + UUID().uuidString, runtimes: [runtime(iOSid, build: "23F77")]).isEmpty)
    }

    // MARK: the advice itself

    /// The remediation must not promise a restart, because a restart was **measured** to do nothing
    /// here: E13 captured the tree before a reboot and again 5h46m after, and it came back
    /// byte-identical (2026-09-16).
    ///
    /// This test used to assert the opposite, in its name and its first assertion — `hasPrefix(
    /// "Restart the Mac")`, on the reasoning that the cheap unprivileged probe comes first. That
    /// reasoning was right and the advice was still wrong, because the premise underneath it was two
    /// timestamps ("created after the last boot, so it has never been through a restart") that stopped
    /// being true on their own. Nothing edited the claim; the machine rebooted. Kept as a rename
    /// rather than a new test so the diff shows the reversal.
    ///
    /// The `rm -rf` guard below is unchanged and unrelated to any of that: `rmdir` refuses when
    /// something unexpected is inside, which is the whole reason the suggested command ends in it.
    func testTheRemediationDoesNotPromiseARestartAndNeverSuggestsRmDashRf() throws {
        let root = try makeTree(["\(hostBuild)/\(tvOSid).23L470"])
        let f = check(root, runtimes: [runtime(iOSid, build: "23F77")])
        let r = try XCTUnwrap(f.first?.remediation)
        // Polarity is pinned structurally, not by the absence of one retired sentence: a rewrite that
        // reintroduces "Restart the Mac and re-check" in different words would slip past a blocklist.
        XCTAssertFalse(r.hasPrefix("Restart"), "the restart was measured to do nothing here: \(r)")
        XCTAssertFalse(
            r.contains("never been observed to survive"),
            "falsified 2026-09-16 — this orphan has now outlived two restarts: \(r)")
        // Not a style rule about the wording: naming the experiment is what forces the next person
        // rewriting this sentence to go and read the result before re-promising the fix.
        XCTAssertTrue(r.contains("E13"), "cite the experiment that settled it: \(r)")
        XCTAssertFalse(r.contains("rm -rf"), "rmdir refuses on surprises; rm -rf takes them with it: \(r)")
        XCTAssertTrue(r.contains("rmdir"))
    }

    func testThePathInTheRemediationIsShellQuoted() throws {
        let root = try makeTree(["\(hostBuild)/\(tvOSid).23L470"])
        let r = try XCTUnwrap(check(root, runtimes: [runtime(iOSid, build: "23F77")]).first?.remediation)
        XCTAssertTrue(r.contains("'\(root)/"), "the path must be single-quoted in every command: \(r)")
    }

    /// The wiring into `diagnose`. The earlier version of this test asserted the *absence* of a
    /// finding on a report that could not produce one anyway — it passed with the `diagnose` call
    /// deleted. This one fails if the rule is not called.
    func testTheRuleIsReachableThroughDiagnose() throws {
        let root = try makeTree(["\(hostBuild)/\(iOSid).23F77", "\(hostBuild)/\(tvOSid).23L470"])
        let report = ScanReport(
            generatedAt: Date(), toolVersion: "t", catalogVersion: "c", host: host(), xcodes: [],
            runtimes: [runtime(iOSid, build: "23F77")], devices: [], volumes: [], items: [], summary: ScanSummary(), warnings: [])
        let f = Doctor(home: NSTemporaryDirectory(), dyldCacheRoot: root).diagnose(report: report)
        XCTAssertTrue(f.contains { $0.id == "orphan-dyld:\(tvOSid).23L470" }, "\(f.map(\.id))")
    }
}

/// `checkUnavailableDevices` — the rule that decides whether the user is told to delete their
/// simulator devices. A device goes unavailable the moment its runtime leaves, including when
/// XCodeVault itself offloads it, and that case is reversible: the E8 round trip saw the devices
/// return to `Shutdown` with their data once the runtime was re-imported.
///
/// The invariant every test here defends: **the destructive suggestion comes from exactly one
/// state** — journal read in full, no offload on record. An installer we can see, an installer on an
/// unplugged volume, and a journal we could not read all withhold it. The second of those was a live
/// bug: unplug the vault, run `doctor`, get told to delete devices whose installers are in your
/// pocket.
final class UnavailableDeviceAdviceTests: XCTestCase {
    let iOSrid = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    let watchRid = "com.apple.CoreSimulator.SimRuntime.watchOS-26-5"

    func device(_ name: String, available: Bool, rid: String? = nil, bytes: UInt64 = 1_000_000) -> SimulatorDevice {
        SimulatorDevice(
            udid: UUID().uuidString, name: name, runtimeIdentifier: rid ?? iOSrid, state: "Shutdown", isAvailable: available, dataPathSize: bytes)
    }

    /// A sparse file above `installer(for:in:)`'s 500 MB floor. Sparse because the floor is about
    /// rejecting stubs, and a test should not write 600 MB to assert that.
    func installerFile(_ dir: String, _ name: String, bytes: UInt64 = 600_000_000) throws -> String {
        let path = dir + "/" + name
        FileManager.default.createFile(atPath: path, contents: nil)
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.truncate(atOffset: bytes)
        try fh.close()
        return path
    }

    struct Offload { var installer: String; var rid: String?; var reimported = false }

    /// A Doctor whose journal contains the given completed offloads, and nothing else.
    func doctor(_ offloads: [Offload], extra: [(JournalEntry.Kind, JournalEntry.State, [String])] = [], corruptLine: Bool = false) throws -> (Doctor, String) {
        let dir = NSTemporaryDirectory() + "/j-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/journal.jsonl")
        let journal = Journal(url: url)
        for o in offloads {
            var detail = ["installer": o.installer]
            if let r = o.rid { detail["runtimeIdentifier"] = r }
            _ = try journal.record(kind: .runtimeOffload, state: .completed, summary: "offloaded", paths: [o.installer], detail: detail)
            if o.reimported {
                _ = try journal.record(kind: .runtimeImport, state: .completed, summary: "imported", paths: [o.installer])
            }
        }
        for (k, st, paths) in extra { _ = try journal.record(kind: k, state: st, summary: "x", paths: paths) }
        // Appended, not written. `String.write(to:)` replaces the file, so this used to discard every
        // entry recorded above it — harmless only because the one caller passes no offloads. The
        // signature invites `doctor([...offloads...], corruptLine: true)`, and that call would have
        // silently tested an empty journal instead of a journal with one bad line in it.
        if corruptLine {
            // The journal file only exists once something has been recorded, so a caller passing no
            // offloads has nothing to append to yet.
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{not json\n".utf8))
            try handle.close()
        }
        return (Doctor(home: dir, journal: journal), dir)
    }

    func remediation(_ d: Doctor, _ devices: [SimulatorDevice]) throws -> String {
        try XCTUnwrap(d.checkUnavailableDevices(devices: devices).first?.remediation)
    }

    // MARK: the one state that may recommend deletion

    func testWithNoOffloadOnRecordDeletionIsAdvisedAndCalledPermanent() throws {
        let (d, _) = try doctor([])
        let r = try remediation(d, [device("iPhone", available: false)])
        XCTAssertTrue(r.hasPrefix("`xcrun simctl delete unavailable`"), r)
        XCTAssertTrue(r.contains("permanent"), r)
    }

    func testAvailableDevicesProduceNoFinding() throws {
        let (d, _) = try doctor([])
        XCTAssertTrue(d.checkUnavailableDevices(devices: [device("iPhone", available: true)]).isEmpty)
    }

    // MARK: states that must never recommend deletion

    func testDevicesLeftUnavailableByOurOwnOffloadAreNotProposedForDeletion() throws {
        let dir = NSTemporaryDirectory() + "/inst-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let installer = try installerFile(dir, "iphonesimulator_26.5_23F77.dmg")
        let (d, _) = try doctor([Offload(installer: installer, rid: iOSrid)])
        let r = try remediation(d, [device("iPhone 17 Pro Max", available: false)])
        XCTAssertTrue(r.hasPrefix("Do NOT run `xcrun simctl delete unavailable`"), r)
        XCTAssertTrue(r.contains(installer), r)
    }

    /// The blocker this rule was rewritten for. The vault is unplugged, so the installer is not
    /// reachable — but it exists, and the journal says where. Telling the user to delete here is the
    /// original bug with an extra step.
    func testAnInstallerOnAnUnmountedVolumeWithholdsTheDeleteAdvice() throws {
        let absent = "/Volumes/XCVGhost-\(UUID().uuidString)/RuntimeLibrary/iphonesimulator_26.5_23F77.dmg"
        let (d, _) = try doctor([Offload(installer: absent, rid: iOSrid)])
        let r = try remediation(d, [device("iPhone", available: false)])
        XCTAssertFalse(r.contains("`xcrun simctl delete unavailable` removes"), "never the destructive form here: \(r)")
        XCTAssertTrue(r.contains("not mounted"), r)
        XCTAssertTrue(r.contains("Reconnect"), r)
    }

    /// A journal we could not read in full cannot testify that no offload happened. `entries()` reads
    /// a corrupt line as no line at all, which is why the rule uses `read()`.
    func testACorruptJournalWithholdsTheDeleteAdvice() throws {
        let (d, _) = try doctor([], corruptLine: true)
        let r = try remediation(d, [device("iPhone", available: false)])
        XCTAssertTrue(r.hasPrefix("Not advising deletion"), r)
        XCTAssertFalse(r.contains("removes devices whose runtime is gone"), r)
    }

    /// Entries written before the journal recorded which runtime was offloaded cannot be matched to
    /// these devices — so the advice is neutral, never an affirmative recovery promise and never a
    /// deletion.
    func testALegacyEntryWithoutRuntimeIdentityGivesNeutralAdvice() throws {
        let dir = NSTemporaryDirectory() + "/inst-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let installer = try installerFile(dir, "iphonesimulator_26.5_23F77.dmg")
        let (d, _) = try doctor([Offload(installer: installer, rid: nil)])
        let r = try remediation(d, [device("iPhone", available: false)])
        XCTAssertTrue(r.contains("predates recording which runtime it was"), r)
        XCTAssertFalse(r.contains("should return to Shutdown"), "no promise it cannot support: \(r)")
    }

    // MARK: false promises

    /// An installer for a runtime the unavailable devices do not use recovers nothing for them.
    /// Promising otherwise sends the user to import 10 GB and find the devices still unavailable.
    func testAnInstallerForADifferentRuntimeDoesNotPromiseRecovery() throws {
        let dir = NSTemporaryDirectory() + "/inst-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let installer = try installerFile(dir, "watchsimulator_26.5_23T570.dmg")
        let (d, _) = try doctor([Offload(installer: installer, rid: watchRid)])
        let r = try remediation(d, [device("iPhone", available: false, rid: iOSrid)])
        XCTAssertFalse(r.contains("Re-import instead"), "a watchOS installer does not restore an iOS device: \(r)")
    }

    /// After a re-import the offload entry is stale: the runtime is back, and whatever leaves these
    /// devices unavailable is something else.
    func testAnOffloadFollowedByAReimportNoLongerClaimsRecoverability() throws {
        let dir = NSTemporaryDirectory() + "/inst-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let installer = try installerFile(dir, "iphonesimulator_26.5_23F77.dmg")
        let (d, _) = try doctor([Offload(installer: installer, rid: iOSrid, reimported: true)])
        let r = try remediation(d, [device("iPhone", available: false)])
        XCTAssertFalse(r.contains("Re-import instead"), r)
    }

    /// `fileExists` says true for a directory and for a 16-byte stub. Neither can restore a runtime,
    /// and calling one recoverable is a promise the user acts on.
    func testAStubOrDirectoryIsNotAcceptedAsAnInstaller() throws {
        let t = TempDir()
        let stub = t.file("iphonesimulator_26.5_23F77.dmg", bytes: 16)
        let (d1, _) = try doctor([Offload(installer: stub, rid: iOSrid)])
        XCTAssertFalse(try remediation(d1, [device("iPhone", available: false)]).contains("Re-import instead"), "a 16-byte stub is not an installer")
        t.dir("bundle.dmg")
        let (d2, _) = try doctor([Offload(installer: t.path + "/bundle.dmg", rid: iOSrid)])
        XCTAssertFalse(try remediation(d2, [device("iPhone", available: false)]).contains("Re-import instead"), "a directory is not an installer")
    }

    /// The journal records many kinds of operation, most carrying paths that exist. Only a completed
    /// offload means "a runtime left the machine and its installer is over there".
    func testOnlyCompletedOffloadsCountAsRecoverableInstallers() throws {
        let dir = NSTemporaryDirectory() + "/inst-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let unrelated = try installerFile(dir, "DerivedData-leftover")
        let (d, _) = try doctor([], extra: [(.clean, .completed, [unrelated]), (.runtimeOffload, .started, [unrelated])])
        let r = try remediation(d, [device("iPhone", available: false)])
        XCTAssertFalse(r.contains("Do NOT run"), "a cleanup path is not a runtime installer: \(r)")
        XCTAssertFalse(r.contains(unrelated), r)
    }

    /// An offload → import → offload cycle records the same installer twice; naming it twice reads
    /// like two separate recoveries.
    func testARepeatedInstallerIsNamedOnce() throws {
        let dir = NSTemporaryDirectory() + "/inst-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let installer = try installerFile(dir, "iphonesimulator_26.5_23F77.dmg")
        let (d, _) = try doctor([Offload(installer: installer, rid: iOSrid), Offload(installer: installer, rid: iOSrid)])
        let r = try remediation(d, [device("iPhone", available: false)])
        let occurrences = r.components(separatedBy: installer).count - 1
        XCTAssertEqual(occurrences, 1, r)
    }

    /// The claim is one observation on one configuration, and the same-version precondition is what
    /// makes it true. Stating it unqualified is how a user re-imports a different version and
    /// concludes the tool lied.
    func testTheRecoveryPromiseCarriesItsPreconditionAndCitesTheRightExperiment() throws {
        let dir = NSTemporaryDirectory() + "/inst-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let installer = try installerFile(dir, "iphonesimulator_26.5_23F77.dmg")
        let (d, _) = try doctor([Offload(installer: installer, rid: iOSrid)])
        let f = try XCTUnwrap(d.checkUnavailableDevices(devices: [device("iPhone", available: false)]).first)
        let r = try XCTUnwrap(f.remediation)
        XCTAssertTrue(r.contains("same version"), "the precondition is load-bearing: \(r)")
        XCTAssertTrue(r.contains("one configuration"), "the qualifier is the point, not the count: \(r)")
        // E11 is the staging-space experiment; device return belongs to the E8 import round trip.
        XCTAssertFalse(f.evidence?.contains("E11") == true, "wrong experiment cited: \(f.evidence ?? "")")
        XCTAssertTrue(f.evidence?.contains("H4") == true, f.evidence ?? "")
    }
}
