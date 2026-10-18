import XCTest

@testable import XCodeVaultCore

final class XcodeCapabilitiesTests: XCTestCase {
    func testXcode26_5HelpDetectsEverything() {
        var c = XcodeCapabilities.parse(xcodebuildHelp: Fixtures.string("xcodebuild-help-xcode26.5.txt"))
        c.apply(simctlRuntimeHelp: Fixtures.string("simctl-runtime-help-xcode26.5.txt"))
        XCTAssertTrue(c.downloadPlatform); XCTAssertTrue(c.downloadAllPlatforms); XCTAssertTrue(c.importPlatform)
        XCTAssertTrue(c.exportPath); XCTAssertTrue(c.buildVersion); XCTAssertTrue(c.architectureVariant)
        XCTAssertTrue(c.downloadComponent); XCTAssertTrue(c.importComponent); XCTAssertTrue(c.deleteComponent); XCTAssertTrue(c.showComponent)
        XCTAssertTrue(c.checkForNewerComponents); XCTAssertTrue(c.prepareDeviceSupport)
        XCTAssertTrue(c.simctlRuntimeAdd); XCTAssertTrue(c.simctlRuntimeDelete); XCTAssertTrue(c.simctlRuntimeUnmount); XCTAssertTrue(c.simctlRuntimeVerify)
        XCTAssertTrue(c.supportsRuntimeLibrary)
    }

    func testOlderHelpWithoutRuntimeFlagsIsNotMisdetected() {
        // A synthetic Xcode 13-style usage: -exportPath exists only for -exportArchive.
        let help = """
            Usage: xcodebuild [-project <projectname>] ...
                   xcodebuild -exportArchive -archivePath <xcarchivepath> [-exportPath <destinationpath>] -exportOptionsPlist <plistpath>
            Options:
                -runFirstLaunch    install packages and agree to the license
            """
        let c = XcodeCapabilities.parse(xcodebuildHelp: help)
        XCTAssertFalse(c.downloadPlatform); XCTAssertFalse(c.exportPath); XCTAssertFalse(c.importPlatform)
        XCTAssertFalse(c.supportsRuntimeLibrary); XCTAssertFalse(c.prepareDeviceSupport)
    }

    func testXcode15StyleHelpDetectsPlatformButNotComponents() {
        let help = """
                   xcodebuild -downloadPlatform <iOS|watchOS|tvOS|visionOS>  [-exportPath <destinationpath> -buildVersion <osversion>]
                   xcodebuild -downloadAllPlatforms [-exportPath <destinationpath>]
                   xcodebuild -importPlatform <simruntimedmgpath>
            """
        let c = XcodeCapabilities.parse(xcodebuildHelp: help)
        XCTAssertTrue(c.supportsRuntimeLibrary); XCTAssertTrue(c.buildVersion)
        XCTAssertFalse(c.architectureVariant); XCTAssertFalse(c.downloadComponent); XCTAssertFalse(c.showComponent)
    }
}

final class SimulatorDiscoveryTests: XCTestCase {
    func testParsesRuntimeListFromXcode26_5() throws {
        let rts = try SimulatorDiscovery.parseRuntimes(json: Fixtures.data("simctl-runtime-list-xcode26.5.json"))
        XCTAssertEqual(rts.count, 2)
        let ios = try XCTUnwrap(rts.first { $0.platformName == "iphone" })
        XCTAssertEqual(ios.version, "26.5"); XCTAssertEqual(ios.build, "23F77"); XCTAssertEqual(ios.state, "Ready")
        XCTAssertEqual(ios.kind, "Patchable Cryptex Disk Image")
        XCTAssertTrue(ios.isMobileAssetBacked, "on Xcode 26 the bytes live in /System/Library/AssetsV2 (E1)")
        XCTAssertEqual(ios.mountPath, "/Library/Developer/CoreSimulator/Volumes/iOS_23F77")
        XCTAssertEqual(ios.sizeBytes, 10_597_197_700)
        XCTAssertEqual(ios.signatureState, "Verified")
    }

    func testParsesDeviceList() throws {
        let devs = try SimulatorDiscovery.parseDevices(json: Fixtures.data("simctl-list-devices-xcode26.5.json"))
        XCTAssertEqual(devs.count, 3)
        XCTAssertTrue(devs.allSatisfy { $0.isAvailable })
        XCTAssertTrue(devs.allSatisfy { $0.dataPath?.hasPrefix("/Users/tester/Library/Developer/CoreSimulator/Devices/") == true })
        XCTAssertTrue(devs.contains { $0.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-26-5" })
    }

    func testRuntimesUseInjectedRunner() throws {
        let runner = FakeRunner(responses: [
            "xcrun simctl runtime list -j": CommandResult(status: 0, stdout: Fixtures.string("simctl-runtime-list-xcode26.5.json"), stderr: "")
        ])
        XCTAssertEqual(try SimulatorDiscovery.runtimes(runner: runner).count, 2)
        let failing = FakeRunner(responses: [:])
        XCTAssertThrowsError(try SimulatorDiscovery.runtimes(runner: failing))
    }
}

final class VolumeTests: XCTestCase {
    func testParsesExternalUSBAPFS() throws {
        let v = try VolumeDiscovery.parse(diskutilInfoPlist: Fixtures.data("diskutil-info-external-usb-apfs.plist"))
        XCTAssertEqual(v.volumeName, "EXTDRIVE"); XCTAssertEqual(v.volumeUUID, "00000000-1111-2222-3333-444444444444")
        XCTAssertEqual(v.busProtocol, "USB"); XCTAssertFalse(v.isInternal); XCTAssertTrue(v.isAPFS)
        XCTAssertTrue(v.ownersEnabled); XCTAssertTrue(v.isWritable); XCTAssertFalse(v.isBootVolume)
        XCTAssertEqual(v.filesystemPersonality, "Case-sensitive APFS")
        let q = VolumeQualification.evaluate(v)
        XCTAssertEqual(q.verdict, .suitableWithWarnings, "\(q)")
        XCTAssertTrue(q.warnings.contains { $0.contains("USB") })
        XCTAssertTrue(q.warnings.contains { $0.contains("Case-sensitive") })
    }

    func testBootVolumeIsNeverADestination() throws {
        let v = try VolumeDiscovery.parse(diskutilInfoPlist: Fixtures.data("diskutil-info-boot-data.plist"))
        XCTAssertTrue(v.isBootVolume); XCTAssertTrue(v.isInternal)
        XCTAssertEqual(VolumeQualification.evaluate(v).verdict, .unsuitable)
    }

    /// The repo's two macOS 26 fixtures, `info` without the key (asserted) and `apfs list` with it, aligned in-test: the
    /// listing's UUIDs are redacted, so the volume's is set to the listing's, and the mount point is moved off the boot
    /// paths so that only the role can mark it (migration-safety review, finding b).
    func testRolesComeFromAPFSListWhenInfoHasNone() throws {
        let listed = try VolumeDiscovery.apfsVolumes(Fixtures.data("diskutil-apfs-list-r8-macos26.plist"))
        XCTAssertEqual(listed["disk1s1"]?.roles, ["Data"])
        XCTAssertEqual(listed["disk1s4"]?.roles, ["System"])
        XCTAssertEqual(listed["disk3s1"]?.roles, [])
        var raw = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Fixtures.data("diskutil-info-boot-data.plist"), format: nil) as? [String: Any])
        XCTAssertNil(raw["APFSVolumeRoles"], "the fixture must stay role-less, or this test proves nothing")
        XCTAssertEqual(raw["DeviceIdentifier"] as? String, "disk1s1")
        raw["MountPoint"] = "/Volumes/Elsewhere"
        raw["VolumeUUID"] = listed["disk1s1"]?.uuid
        let info = try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
        XCTAssertFalse(try VolumeDiscovery.parse(diskutilInfoPlist: info).isBootVolume, "without the listing nothing marks it")
        XCTAssertTrue(try VolumeDiscovery.parse(diskutilInfoPlist: info, apfsVolumes: listed).isBootVolume, "the Data role does")
    }

    /// A device identifier reused by another drive between the two reads must not carry the first drive's roles: the
    /// listing's entry counts only when its UUID is the volume's (finding d).
    func testTheListingsRolesNeedTheSameVolumeUUID() throws {
        let plain = try Self.info(["VolumeUUID": "11111111-2222-3333-4444-555555555555"])
        let other = APFSVolumeInfo(id: "disk9s1", name: "Other", uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", roles: ["System"])
        XCTAssertFalse(try VolumeDiscovery.parse(diskutilInfoPlist: plain, apfsVolumes: ["disk9s1": other]).isBootVolume)
        let same = APFSVolumeInfo(id: "disk9s1", name: "Other", uuid: "11111111-2222-3333-4444-555555555555", roles: ["System"])
        XCTAssertTrue(try VolumeDiscovery.parse(diskutilInfoPlist: plain, apfsVolumes: ["disk9s1": same]).isBootVolume)
        let lowercase = APFSVolumeInfo(id: "disk9s1", name: "Other", uuid: "11111111-2222-3333-4444-555555555555".lowercased(), roles: ["System"])
        XCTAssertTrue(try VolumeDiscovery.parse(diskutilInfoPlist: plain, apfsVolumes: ["disk9s1": lowercase]).isBootVolume, "UUIDs compare by value")
        // One side without a UUID cannot be compared, and the listing only ever adds a role, so it applies (re-review, nit 1).
        let listingWithout = APFSVolumeInfo(id: "disk9s1", name: "Other", uuid: nil, roles: ["System"])
        XCTAssertTrue(try VolumeDiscovery.parse(diskutilInfoPlist: plain, apfsVolumes: ["disk9s1": listingWithout]).isBootVolume)
        XCTAssertTrue(try VolumeDiscovery.parse(diskutilInfoPlist: try Self.info([:]), apfsVolumes: ["disk9s1": same]).isBootVolume, "info without one")
        // An empty UUID is a missing one, not a mismatch (nit 2).
        let empty = APFSVolumeInfo(id: "disk9s1", name: "Other", uuid: "", roles: ["System"])
        XCTAssertTrue(try VolumeDiscovery.parse(diskutilInfoPlist: plain, apfsVolumes: ["disk9s1": empty]).isBootVolume)
        XCTAssertTrue(try VolumeDiscovery.parse(diskutilInfoPlist: try Self.info(["VolumeUUID": ""]), apfsVolumes: ["disk9s1": same]).isBootVolume)
    }

    /// The two sources are joined, so neither takes a role away (finding c): a role only ever marks a volume.
    func testRolesAreTheUnionOfInfoAndTheListing() throws {
        let entry = { (roles: [String]) in ["disk9s1": APFSVolumeInfo(id: "disk9s1", name: "Other", roles: roles)] }
        let plain = try Self.info([:])
        XCTAssertFalse(try VolumeDiscovery.parse(diskutilInfoPlist: plain).isBootVolume, "no role anywhere: a candidate")
        let data = try VolumeDiscovery.parse(diskutilInfoPlist: plain, apfsVolumes: entry(["Data"]))
        XCTAssertTrue(data.isBootVolume, "an internal Data volume mounted elsewhere")
        XCTAssertEqual(VolumeQualification.evaluate(data).verdict, .unsuitable)
        XCTAssertTrue(try VolumeDiscovery.parse(diskutilInfoPlist: plain, apfsVolumes: entry(["System"])).isBootVolume)
        let infoSaysSystem = try Self.info(["APFSVolumeRoles": ["System"]])
        XCTAssertTrue(try VolumeDiscovery.parse(diskutilInfoPlist: infoSaysSystem).isBootVolume, "info's roles still count")
        XCTAssertTrue(
            try VolumeDiscovery.parse(diskutilInfoPlist: infoSaysSystem, apfsVolumes: entry([])).isBootVolume,
            "an empty listing entry does not take info's System away")
    }

    /// The wiring, through `mountedVolumes` with a fake `diskutil` (finding a): the listing's roles reach `parse`, and a
    /// listing that cannot be read falls back to `info` without losing the enumeration.
    func testMountedVolumesPassesTheListingsRolesAndSurvivesItsFailure() throws {
        let list = try PropertyListSerialization.data(
            fromPropertyList: ["AllDisksAndPartitions": [["APFSVolumes": [["DeviceIdentifier": "disk9s1"]]]]], format: .xml, options: 0)
        let apfs = try PropertyListSerialization.data(
            fromPropertyList: [
                "Containers": [
                    [
                        "ContainerReference": "disk9", "PhysicalStores": [["DeviceIdentifier": "disk8s2"]],
                        "Volumes": [["DeviceIdentifier": "disk9s1", "Name": "Other", "Roles": ["Data"]]],
                    ]
                ]
            ], format: .xml, options: 0)
        let text = { (d: Data) in String(decoding: d, as: UTF8.self) }
        func runner(apfs apfsResult: CommandResult, info extra: [String: Any] = [:]) throws -> FakeRunner {
            FakeRunner(responses: [
                "diskutil list -plist": CommandResult(status: 0, stdout: text(list), stderr: ""),
                "diskutil apfs list -plist": apfsResult,
                "diskutil info -plist disk9s1": CommandResult(status: 0, stdout: text(try Self.info(extra)), stderr: ""),
            ])
        }
        let withRoles = try VolumeDiscovery.mountedVolumes(runner: try runner(apfs: CommandResult(status: 0, stdout: text(apfs), stderr: "")))
        XCTAssertEqual(withRoles.map(\.volumeName), ["Other"])
        XCTAssertEqual(withRoles.first?.isBootVolume, true, "the Data role from apfs list reached parse")
        for broken in [CommandResult(status: 1, stdout: "", stderr: "busy"), CommandResult(status: 0, stdout: "not a plist", stderr: "")] {
            let fallback = try VolumeDiscovery.mountedVolumes(runner: try runner(apfs: broken))
            XCTAssertEqual(fallback.map(\.volumeName), ["Other"], "the enumeration survives an unreadable listing")
            XCTAssertEqual(fallback.first?.isBootVolume, false, "and falls back to info, which has no role here")
            // The fallback really reads info's roles (re-review, nit 3).
            let fromInfo = try VolumeDiscovery.mountedVolumes(runner: try runner(apfs: broken, info: ["APFSVolumeRoles": ["Data"]]))
            XCTAssertEqual(fromInfo.first?.isBootVolume, true)
        }
    }

    /// An internal APFS volume mounted outside the boot paths, as `diskutil info -plist` gives it, without roles.
    static func info(_ extra: [String: Any]) throws -> Data {
        var d: [String: Any] = [
            "DeviceIdentifier": "disk9s1", "DeviceNode": "/dev/disk9s1", "VolumeName": "Other", "MountPoint": "/Volumes/Other",
            "FilesystemType": "apfs", "Internal": true, "WritableVolume": true,
        ]
        d.merge(extra) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }

    func testQualificationBlockers() {
        var v = Volume(
            deviceNode: "/dev/disk9s1", volumeName: "STICK", volumeUUID: "X", mountPoint: "/Volumes/STICK",
            filesystemPersonality: "ExFAT", filesystemType: "exfat", isInternal: false, isRemovableMedia: true,
            isEjectable: true, busProtocol: "USB", isSolidState: nil, isWritable: true, ownersEnabled: false,
            totalBytes: 64_000_000_000, freeBytes: 60_000_000_000, isBootVolume: false)
        var q = VolumeQualification.evaluate(v)
        XCTAssertEqual(q.verdict, .unsuitable)
        XCTAssertTrue(q.blockers.contains { $0.contains("APFS") })
        XCTAssertTrue(q.blockers.contains { $0.contains("Ownership") })
        v.filesystemPersonality = "APFS"; v.filesystemType = "apfs"; v.ownersEnabled = true; v.busProtocol = "Thunderbolt"
        q = VolumeQualification.evaluate(v)
        XCTAssertEqual(q.verdict, .suitable, "\(q)")
        v.freeBytes = 1_000_000_000
        XCTAssertEqual(VolumeQualification.evaluate(v).verdict, .suitableWithWarnings)
    }
}

final class HostEnvironmentTests: XCTestCase {
    func testMinimumOSRule() {
        let runner = FakeRunner(responses: [
            "sw_vers -productVersion": .init(status: 0, stdout: "13.6.1\n", stderr: ""),
            "sw_vers -buildVersion": .init(status: 0, stdout: "22G313\n", stderr: ""),
        ])
        let h = HostEnvironment.discover(runner: runner, home: NSTemporaryDirectory())
        XCTAssertEqual(h.macOSVersion, "13.6.1"); XCTAssertFalse(h.meetsMinimumOS)
        XCTAssertGreaterThan(h.dataVolumeTotalBytes, 0)
    }
}
