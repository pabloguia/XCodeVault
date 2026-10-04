import XCTest

@testable import XCodeVaultCore

/// R7-A: the fixes from the user's real-window check of R6 (2026-10-04), Core's part. Every decision is a Core function,
/// tested here from fixtures: nothing scans this Mac or touches a disk, a journal or a vault.
final class R7ACoreTests: XCTestCase {
    // MARK: 1. Chart labels in full

    func testABarIsScaledToTheLargestAndATinyOneIsStillSeen() {
        XCTAssertEqual(BarChartLayout.fraction(10, largest: 10), 1)
        XCTAssertEqual(BarChartLayout.fraction(5, largest: 10), 0.5)
        XCTAssertEqual(BarChartLayout.fraction(8_000, largest: 24_000_000_000), 0.01, "Park's 8 kB beside Delete's 23.94 GB")
        XCTAssertEqual(BarChartLayout.fraction(0, largest: 10), 0, "nothing measured, no bar")
        XCTAssertEqual(BarChartLayout.fraction(10, largest: 0), 0)
        XCTAssertEqual(BarChartLayout.fraction(20, largest: 10), 1, "never longer than the column")
    }

    func testTheBoxHoldsEveryRowUpToItsMostAndScrollsBeyond() {
        XCTAssertEqual(BarChartLayout.boxHeight(barCount: 4, maximum: 130), 4 * BarChartLayout.rowHeight)
        XCTAssertEqual(BarChartLayout.boxHeight(barCount: 0, maximum: 130), BarChartLayout.rowHeight, "one row's room for the empty case")
        XCTAssertEqual(BarChartLayout.boxHeight(barCount: 80, maximum: 140), 140)
    }

    // MARK: 2. Run Externally's suggested folder

    private func row(_ categoryID: String, _ bucket: SavingsBucket) throws -> SavingsPlanRow {
        let command = try XCTUnwrap(SavingsPlanner.command(categoryID: categoryID, bucket: bucket))
        return SavingsPlanRow(
            categoryID: categoryID, categoryName: categoryID, bytes: 1,
            option: SavingsOption(bucket: bucket, isExperimental: true, appliesToExistingData: true, losesUserData: false), command: command,
            itemCount: 1, actsImmediately: false, noteIDs: [])
    }

    func testTheDirOfEachRowIsTheVaultsStandardFolder() throws {
        XCTAssertEqual(try row("derivedData", .runFromExternal).folderPurpose, .derivedData)
        XCTAssertEqual(try row("archives", .runFromExternal).folderPurpose, .archives)
        XCTAssertEqual(try row("runtimeLibrary", .runFromExternal).folderPurpose, .runtimes)
        XCTAssertEqual(try row("simulatorRuntimeAssets", .parkExternally).folderPurpose, .runtimes)
        XCTAssertNil(try row("archives", .parkExternally).folderPurpose, "a vault, not a folder")
        XCTAssertNil(try row("simulatorDevices", .deleteAndRegenerate).folderPurpose)
    }

    func testTheFilledCommandIsTheRealCommandWithThePathQuotedWhenItNeedsIt() throws {
        let dd = try row("derivedData", .runFromExternal)
        XCTAssertEqual(
            dd.command(filling: "/Volumes/PABLO/XCodeVault/DerivedData"), "xcodevaultctl locations set-derived-data /Volumes/PABLO/XCodeVault/DerivedData")
        XCTAssertEqual(
            dd.command(filling: "/Volumes/USB 1/XCodeVault/DerivedData"), "xcodevaultctl locations set-derived-data '/Volumes/USB 1/XCodeVault/DerivedData'")
        XCTAssertEqual(
            try row("runtimeLibrary", .runFromExternal).command(filling: "/Volumes/V/XCodeVault/Runtimes"),
            "xcodevaultctl runtime export <platform> --to /Volumes/V/XCodeVault/Runtimes --preflight", "only <dir> is filled")
        XCTAssertNil(try row("archives", .parkExternally).command(filling: "/x"))
    }

    // MARK: 5. Where the new volume will appear

    func testANewVolumeAppearsUnderVolumesByItsName() throws {
        let free = try XCTUnwrap(VolumeConfiguration(name: "XCodeVault").mountPreview(mountedAt: ["/", "/Volumes/PABLO"]))
        XCTAssertEqual(free, MountPreview(mountPoint: "/Volumes/XCodeVault", isTaken: false, actualMountPoint: "/Volumes/XCodeVault", suggestedName: nil))
    }

    func testANameAlreadyMountedIsMountedWithANumberAndAnotherNameIsSuggested() throws {
        let mounted = ["/Volumes/xcodevault", "/Volumes/XCodeVault 1", "/Volumes/XCodeVault2"]
        let taken = try XCTUnwrap(VolumeConfiguration(name: "XCodeVault").mountPreview(mountedAt: mounted))
        XCTAssertTrue(taken.isTaken, "compared as the case-insensitive boot volume compares")
        XCTAssertEqual(taken.mountPoint, "/Volumes/XCodeVault")
        XCTAssertEqual(taken.actualMountPoint, "/Volumes/XCodeVault 2", "the first free numbered mount point")
        XCTAssertEqual(taken.suggestedName, "XCodeVault3", "a name whose mount point is free")
        let composed = try XCTUnwrap(VolumeConfiguration(name: "Cafe\u{301}").mountPreview(mountedAt: ["/Volumes/Caf\u{E9}"]))
        XCTAssertTrue(composed.isTaken, "canonically equal names are one mount point")
    }

    func testANameDiskutilWouldRefuseHasNoPath() {
        for name in ["", " x", "a/b", "-x", "a:b"] {
            XCTAssertNil(VolumeConfiguration(name: name).mountPreview(mountedAt: []), name)
        }
        XCTAssertNotNil(VolumeConfiguration(name: "Vault", quotaGigabytes: 0).mountPreview(mountedAt: []), "the quota is not the name's problem")
    }

    // MARK: 6. The volume a preparation made

    static func snapshotWithMadeVolume(name: String = "XCodeVault", uuid: String = R6DriveTests.u(302)) throws -> DriveSnapshot {
        var snap = try R6DriveTests.snapshot()
        let i = try XCTUnwrap(snap.disks.firstIndex { $0.id == "disk2" })
        let j = try XCTUnwrap(snap.disks[i].containers.firstIndex { $0.reference == "disk3" })
        snap.disks[i].containers[j].volumes.append(APFSVolumeInfo(id: "disk3s2", name: name, uuid: uuid))
        snap.volumes.append(R6DriveTests.volume("disk3s2", name, uuid: uuid, mount: "/Volumes/" + name))
        return snap
    }

    private func addVolumePlan() throws -> DiskPreparationPlan {
        let snap = try R6DriveTests.snapshot()
        let disk = try XCTUnwrap(snap.disks.first { $0.id == "disk2" })
        let a = DriveEvaluation.assess(disk, in: snap, vaults: [R6DriveTests.vaultCheck()])
        return try DiskPreparation.plan(
            .addVolume(container: "disk3"), configuration: VolumeConfiguration(), on: a, snapshot: snap, registeredVaultUUIDs: [R6DriveTests.u(1101)])
    }

    func testTheMadeVolumeIsTheNewOneOnThePlansDisk() throws {
        let plan = try addVolumePlan()
        let made = plan.madeVolume(in: try Self.snapshotWithMadeVolume(), registeredVaultUUIDs: [R6DriveTests.u(1101)])
        XCTAssertEqual(made?.volumeUUID, R6DriveTests.u(302))
        XCTAssertNil(plan.madeVolume(in: try R6DriveTests.snapshot(), registeredVaultUUIDs: []), "not there yet: nothing offered")
        XCTAssertNil(
            plan.madeVolume(in: try Self.snapshotWithMadeVolume(), registeredVaultUUIDs: [R6DriveTests.u(302)]), "already a vault: nothing to register")
        XCTAssertNil(plan.madeVolume(in: try Self.snapshotWithMadeVolume(name: "Other"), registeredVaultUUIDs: []), "another name is not the one made")
        XCTAssertNil(
            plan.madeVolume(in: try Self.snapshotWithMadeVolume(uuid: R6DriveTests.u(301)), registeredVaultUUIDs: []),
            "a UUID the disk had when previewed is not new")
        var two = try Self.snapshotWithMadeVolume()
        let i = try XCTUnwrap(two.disks.firstIndex { $0.id == "disk2" })
        let j = try XCTUnwrap(two.disks[i].containers.firstIndex { $0.reference == "disk3" })
        two.volumes.append(R6DriveTests.volume("disk3s3", "XCodeVault", uuid: R6DriveTests.u(303), mount: "/Volumes/XCodeVault 1"))
        two.disks[i].containers[j].volumes.append(APFSVolumeInfo(id: "disk3s3", name: "XCodeVault", uuid: R6DriveTests.u(303)))
        XCTAssertNil(plan.madeVolume(in: two, registeredVaultUUIDs: []), "two candidates: never guess")
    }

    // MARK: 4. Drives buttons

    private func assess(_ id: String, _ snap: DriveSnapshot) throws -> DriveAssessment {
        DriveEvaluation.assess(try XCTUnwrap(snap.disks.first { $0.id == id }), in: snap, vaults: [R6DriveTests.vaultCheck()])
    }

    func testTheRowsPrimaryIsTheRecommendedFixElseUseThisDrive() throws {
        let snap = try R6DriveTests.snapshot()
        let media = try assess("disk2", snap)
        XCTAssertEqual(media.verdict, .canBeUsed)
        XCTAssertNotNil(media.recommendedOption, "case-sensitive: the new volume comes first")
        XCTAssertEqual(media.primaryAction, .option(.addVolume(container: "disk3")))
        var plain = snap
        plain.volumes = plain.volumes.map {
            var v = $0; if v.volumeName == "Media" { v.filesystemPersonality = "APFS" }; return v
        }
        XCTAssertEqual(try assess("disk2", plain).primaryAction, .useDrive)
        XCTAssertNil(try assess("disk10", snap).primaryAction, "a ready vault is not offered")
    }
}
