import XCTest

@testable import XCodeVaultCore

/// R8 fix round 2, data-safety F1 and F5: two registered vaults on one disk. `drive.vault` names one vault per drive, so
/// every judgement here goes by the vault's OWN volume, found by UUID across the drives' volumes. Fixtures only.
extension PlanBuilderTests {
    static let pabloUUID = R6DriveTests.u(301)
    static let xcodeVaultUUID = R6DriveTests.u(302)
    static func xcodeVault() -> VaultVolumeCheck { R6DriveTests.vaultCheck(uuid: xcodeVaultUUID, mount: "/Volumes/XCodeVault") }

    /// Every action anywhere in the plan that would register `uuid` again.
    static func proposesRegistering(_ uuid: String, in plan: Plan) -> Bool {
        plan.steps.contains { step in
            [step.action, step.secondaryAction].contains { action in
                if case .useDrive(_, let v)? = action { return v == uuid }
                return false
            }
        }
    }

    func testPabloThenXCodeVaultRegisteredMakesXCodeVaultTheVault() throws {
        let vaults = [Self.mediaVault(), Self.xcodeVault()]
        let p = Self.plan(drives: Self.drives(try R7ACoreTests.snapshotWithMadeVolume(owners: true), vaults: vaults), vaults: vaults)
        XCTAssertEqual(p.vaultUUID, Self.xcodeVaultUUID, "the case-sensitive vault is never the one moves go to")
        XCTAssertEqual(p.step(.registerVault)?.state, .done)
        XCTAssertFalse(Self.proposesRegistering(Self.pabloUUID, in: p))
        XCTAssertFalse(Self.proposesRegistering(Self.xcodeVaultUUID, in: p))
    }

    func testTheReverseOrderGivesTheSamePlan() throws {
        let vaults = [Self.xcodeVault(), Self.mediaVault()]
        let p = Self.plan(drives: Self.drives(try R7ACoreTests.snapshotWithMadeVolume(owners: true), vaults: vaults), vaults: vaults)
        XCTAssertEqual(p.vaultUUID, Self.xcodeVaultUUID)
        XCTAssertFalse(Self.proposesRegistering(Self.pabloUUID, in: p))
        XCTAssertFalse(Self.proposesRegistering(Self.xcodeVaultUUID, in: p))
    }

    func testTwoCaseSensitiveVaultsGiveNoVaultAndNoReRegistration() throws {
        var s = try R7ACoreTests.snapshotWithMadeVolume(owners: true)
        s.volumes = s.volumes.map {
            var v = $0
            if v.volumeUUID == Self.xcodeVaultUUID { v.filesystemPersonality = "Case-sensitive APFS" }
            return v
        }
        let vaults = [Self.mediaVault(), Self.xcodeVault()]
        let p = Self.plan(drives: Self.drives(s, vaults: vaults), vaults: vaults)
        XCTAssertNil(p.vaultUUID, "neither vault's own volume is of the right kind")
        XCTAssertFalse(Self.proposesRegistering(Self.pabloUUID, in: p))
        XCTAssertFalse(Self.proposesRegistering(Self.xcodeVaultUUID, in: p), "a registered vault is never proposed for registration")
    }

    func testAVaultWhoseVolumeLostOwnershipIsNotTheVault() throws {
        let vaults = [Self.mediaVault(), Self.xcodeVault()]
        let p = Self.plan(drives: Self.drives(try R7ACoreTests.snapshotWithMadeVolume(owners: false), vaults: vaults), vaults: vaults)
        XCTAssertNil(p.vaultUUID, "XCodeVault ignores ownership now: nothing moves to it")
        XCTAssertEqual(p.step(.prepareDrive)?.state, .next)
        XCTAssertEqual(p.step(.prepareDrive)?.note, .turnOnOwnership(volume: "XCodeVault"))
        XCTAssertFalse(Self.proposesRegistering(Self.xcodeVaultUUID, in: p))
    }

    /// F5: a drive whose right volume is already there — here the registered vault — never falls through to its first
    /// command option, which can be an erase.
    func testARightVolumeAlreadyThereMeansNothingToPrepare() throws {
        let vaults = [Self.xcodeVault()]
        let disk2 = try XCTUnwrap(Self.drives(try R7ACoreTests.snapshotWithMadeVolume(owners: true), vaults: vaults).first { $0.disk.id == "disk2" })
        XCTAssertTrue(disk2.hasSuitableKindVolume)
        XCTAssertNil(disk2.recommendedOption)
        XCTAssertNotEqual(disk2.verdict, .canBeUsed, "the fixture must reach the branch under test")
        XCTAssertFalse(disk2.commandOptions.isEmpty, "there is a command option the old code would have fallen through to")
        XCTAssertEqual(disk2.prepareAction, .nothing)
    }

    /// Round 3: a usable vault whose volume no drive shows cannot be judged, and is not the vault moves go to.
    func testAVaultNoDriveShowsIsNotCountedGood() throws {
        let ghost = R6DriveTests.vaultCheck(uuid: R6DriveTests.u(999), mount: "/Volumes/Ghost")
        let p = Self.plan(drives: Self.drives(try R7ACoreTests.snapshotWithMadeVolume(owners: true), vaults: [ghost]), vaults: [ghost])
        XCTAssertNil(p.vaultUUID)
        XCTAssertNotEqual(p.step(.registerVault)?.state, .done)
    }
}
