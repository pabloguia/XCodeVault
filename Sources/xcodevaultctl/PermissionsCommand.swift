import ArgumentParser
import Foundation
import XCodeVaultCore
import XCodeVaultHelperClient

struct PermissionsCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "permissions",
            abstract: L10n.tr("cli.cmd.permissions.abstract"),
            discussion: """
                Nothing here asks for a permission or changes one: XCodeVault asks only when an action needs it (ADR-0007). \
                Full Disk Access is checked for this process, which macOS decides by the app you run xcodevaultctl from — \
                usually your terminal.

                EXAMPLES:
                  xcodevaultctl permissions
                  xcodevaultctl permissions --json
                """)
    }
    @OptionGroup var global: GlobalOptions
    func run() throws {
        let report = Self.report(client: HelperClient(), fullDiskAccess: FullDiskAccessProbe().state())
        try emit(report, json: global.json) { TextRenderer.permissions(report) }
    }

    /// Read-only state only: nothing here calls `connect()`. Split out so a test can hand it a client whose
    /// answers it chose.
    static func report(client: HelperClient, fullDiskAccess: FullDiskAccessState) -> PermissionsReport {
        PermissionsReport(
            fullDiskAccess: fullDiskAccess,
            helper: HelperState(
                status: client.serviceStatus(), teamIDIsUsable: client.hasUsableTeamID, signedByThatTeam: client.isSignedByItsTeam,
                daemonIsBundled: client.bundlesDaemon))
    }
}
