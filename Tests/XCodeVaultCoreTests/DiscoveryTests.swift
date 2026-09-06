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
        let runner = FakeRunner(responses: ["xcrun simctl runtime list -j": CommandResult(status: 0, stdout: Fixtures.string("simctl-runtime-list-xcode26.5.json"), stderr: "")])
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

    func testQualificationBlockers() {
        var v = Volume(deviceNode: "/dev/disk9s1", volumeName: "STICK", volumeUUID: "X", mountPoint: "/Volumes/STICK",
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
        let runner = FakeRunner(responses: ["sw_vers -productVersion": .init(status: 0, stdout: "13.6.1\n", stderr: ""),
                                            "sw_vers -buildVersion": .init(status: 0, stdout: "22G313\n", stderr: "")])
        let h = HostEnvironment.discover(runner: runner, home: NSTemporaryDirectory())
        XCTAssertEqual(h.macOSVersion, "13.6.1"); XCTAssertFalse(h.meetsMinimumOS)
        XCTAssertGreaterThan(h.dataVolumeTotalBytes, 0)
    }
}
