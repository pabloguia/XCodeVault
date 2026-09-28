import ServiceManagement
import XCTest

@testable import XCodeVaultCore

/// Spec §2's permissions model: one source of truth for the CLI and the GUI. Each test pins a decision —
/// which state an input maps to — never the wording of a message.
final class FullDiskAccessProbeTests: XCTestCase {
    func testAFileThisProcessCanOpenMeansGranted() {
        let t = TempDir()
        let f = t.file("indicator.db", bytes: 1)
        XCTAssertEqual(FullDiskAccessProbe(path: f).state(), .granted, "the real open(2), on a file this process may read")
    }

    func testEPERMMeansNotGranted() {
        // No unit test can make macOS answer EPERM on demand — TCC is what returns it, and a CI runner
        // may hold the grant — so the refusal is injected at the open.
        XCTAssertEqual(FullDiskAccessProbe(path: "/unused", openReadOnly: { _ in EPERM }).state(), .notGranted)
        // Positive control: the same injected shape answering success is not a refusal.
        XCTAssertEqual(FullDiskAccessProbe(path: "/unused", openReadOnly: { _ in 0 }).state(), .granted)
    }

    func testOtherFailuresAreUnknownRatherThanNotGranted() {
        // EACCES is permission bits and ENOENT a missing file. Reading either as "not granted" would ask
        // the user for a permission nobody showed to be missing.
        for code in [EACCES, ENOENT, EIO, ENOTDIR] {
            XCTAssertEqual(FullDiskAccessProbe(path: "/unused", openReadOnly: { _ in code }).state(), .unknown, "errno \(code)")
        }
        let t = TempDir()
        XCTAssertEqual(FullDiskAccessProbe(path: t.path + "/absent.db").state(), .unknown, "the real open(2) on a missing file")
    }

    func testTheProbeOpensTheSameFileAsTheExperimentHarness() throws {
        XCTAssertEqual(FullDiskAccessProbe().path, "/Library/Application Support/com.apple.TCC/TCC.db")
        // H15's indicator lives in the harness too; the app and the experiments must measure the same thing.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let staging = try String(contentsOf: root.appendingPathComponent("scripts/experiments/mount-staging.sh"), encoding: .utf8)
        XCTAssertTrue(staging.contains(FullDiskAccessProbe.indicatorPath))
    }
}

final class HelperStateTests: XCTestCase {
    private let known: [SMAppService.Status] = [.notRegistered, .enabled, .requiresApproval, .notFound]

    func testEveryStatusMapsAsSpecifiedWhenTheBuildCanReachTheHelper() {
        XCTAssertEqual(HelperState(status: .enabled, teamIDIsUsable: true, signedByThatTeam: true, daemonIsBundled: true), .enabled)
        XCTAssertEqual(HelperState(status: .requiresApproval, teamIDIsUsable: true, signedByThatTeam: true, daemonIsBundled: true), .awaitingApproval)
        // Both mean "not installed" (HelperClient.serviceStatus() documents why both occur).
        XCTAssertEqual(HelperState(status: .notRegistered, teamIDIsUsable: true, signedByThatTeam: true, daemonIsBundled: true), .notInstalled)
        XCTAssertEqual(HelperState(status: .notFound, teamIDIsUsable: true, signedByThatTeam: true, daemonIsBundled: true), .notInstalled)
    }

    func testAnUnusableTeamIDMeansUnavailableWhateverLaunchdSays() {
        for s in known {
            XCTAssertEqual(
                HelperState(status: s, teamIDIsUsable: false, signedByThatTeam: true, daemonIsBundled: true), .unavailableInThisBuild, "status \(s.rawValue)")
        }
        // Positive control: the same status with a usable team is not unavailable.
        XCTAssertEqual(HelperState(status: .enabled, teamIDIsUsable: true, signedByThatTeam: true, daemonIsBundled: true), .enabled)
    }

    func testAMissingDaemonMeansUnavailableWhateverLaunchdSays() {
        // Operator decision 2026-09-27: a build without the daemon's plist has nothing to register.
        for s in known {
            XCTAssertEqual(
                HelperState(status: s, teamIDIsUsable: true, signedByThatTeam: true, daemonIsBundled: false), .unavailableInThisBuild, "status \(s.rawValue)")
        }
        XCTAssertEqual(HelperState(status: .requiresApproval, teamIDIsUsable: true, signedByThatTeam: true, daemonIsBundled: true), .awaitingApproval)
    }

    func testABuildNotSignedByItsTeamIsUnavailableWhateverLaunchdSays() {
        // Carried note 5 of the 2026-09-27 permissions plan: an unsigned `bundle-app.sh --team … --with-helper`
        // build has a usable team ID and the plist, and `register()` still cannot succeed for it.
        for s in known {
            XCTAssertEqual(
                HelperState(status: s, teamIDIsUsable: true, signedByThatTeam: false, daemonIsBundled: true), .unavailableInThisBuild, "status \(s.rawValue)")
        }
        // Positive control: signed by that team, the same status is not unavailable.
        XCTAssertEqual(HelperState(status: .notFound, teamIDIsUsable: true, signedByThatTeam: true, daemonIsBundled: true), .notInstalled)
    }

    func testAStatusNobodyHasSeenIsNeverEnabled() throws {
        // Measured 2026-09-27 with a scratch binary: `SMAppService.Status(rawValue: 99)` yields a value,
        // and it reaches `@unknown default`.
        let future = try XCTUnwrap(SMAppService.Status(rawValue: 99))
        XCTAssertEqual(HelperState(status: future, teamIDIsUsable: true, signedByThatTeam: true, daemonIsBundled: true), .notInstalled)
    }
}

final class PermissionsReportTests: XCTestCase {
    func testTheJSONCarriesEachStateWithWhyAndOneNextStep() throws {
        let json = try JSONOutput.encode(PermissionsReport(fullDiskAccess: .notGranted, helper: .unavailableInThisBuild))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: String]])
        XCTAssertEqual(object["fullDiskAccess"]?["state"], "notGranted")
        XCTAssertEqual(object["helper"]?["state"], "unavailableInThisBuild")
        for (name, entry) in object {
            XCTAssertFalse(entry["why"]?.isEmpty ?? true, name)
            XCTAssertFalse(entry["nextStep"]?.isEmpty ?? true, name)
        }
    }

    func testNotGrantedPointsAtTheExactSettingsPane() {
        XCTAssertTrue(FullDiskAccessState.notGranted.nextStep.contains(FullDiskAccessProbe.settingsURL))
        // Control: the pane is the next step only where there is something to switch on.
        XCTAssertFalse(FullDiskAccessState.granted.nextStep.contains(FullDiskAccessProbe.settingsURL))
    }

    func testEveryStateHasItsOwnText() {
        XCTAssertEqual(Set(FullDiskAccessState.allCases.map(\.why)).count, FullDiskAccessState.allCases.count)
        XCTAssertEqual(Set(HelperState.allCases.map(\.why)).count, HelperState.allCases.count)
        XCTAssertEqual(Set(HelperState.allCases.map(\.displayName)).count, HelperState.allCases.count)
    }
}
