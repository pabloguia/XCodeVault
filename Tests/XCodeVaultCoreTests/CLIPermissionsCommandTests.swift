import Foundation
import XCTest

@testable import XCodeVaultCore
@testable import XCodeVaultHelperClient
@testable import XCodeVaultHelperProtocol
@testable import xcodevaultctl

/// `xcodevaultctl permissions`, in process since the CLI target is linked into the test bundle (ADR-0008).
final class CLIPermissionsCommandTests: XCTestCase {
    private let team = "ABCDE12345"

    func testTheReportCombinesTheProbeWithEverythingTheClientSays() {
        let bundle = TempDir()
        _ = bundle.file("Contents/Library/LaunchDaemons/" + HelperIdentity.plistName, bytes: 1)
        let team = self.team
        let client = HelperClient(
            team: team, makeConnection: { _ in ProxyConnection(proxy: NSObject()) }, bundleURL: URL(fileURLWithPath: bundle.path),
            runningTeam: { team }, daemon: RecordingLaunchd(status: .requiresApproval).daemon)
        let report = PermissionsCommand.report(client: client, fullDiskAccess: .notGranted)
        XCTAssertEqual(report, PermissionsReport(fullDiskAccess: .notGranted, helper: .awaitingApproval))
        // The same answers from a build whose signature carries no team: the helper is unavailable to it.
        let adHoc = HelperClient(
            team: team, makeConnection: { _ in ProxyConnection(proxy: NSObject()) }, bundleURL: URL(fileURLWithPath: bundle.path),
            runningTeam: { nil }, daemon: RecordingLaunchd(status: .requiresApproval).daemon)
        XCTAssertEqual(PermissionsCommand.report(client: adHoc, fullDiskAccess: .granted).helper.state, .unavailableInThisBuild)
    }

    /// The command itself, read-only: launchd's status and one `open(2)`, then the JSON on standard output.
    func testTheCommandRunsReadOnly() throws {
        XCTAssertNoThrow(try PermissionsCommand.parse(["--json"]).run())
    }
}
