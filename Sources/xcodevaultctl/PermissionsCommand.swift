import ArgumentParser
import Foundation
import XCodeVaultCore
import XCodeVaultHelperClient

struct PermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Read-only. Full Disk Access and the privileged helper: the state of each, why, and the one next step.",
        discussion: """
            Nothing here asks for a permission or changes one: XCodeVault asks only when an action needs it (ADR-0007). \
            Full Disk Access is checked for this process, which macOS decides by the app you run xcodevaultctl from — \
            usually your terminal.
            """)
    @OptionGroup var global: GlobalOptions
    func run() throws {
        // Read-only state only: nothing here calls `connect()`.
        let client = HelperClient()
        let report = PermissionsReport(
            fullDiskAccess: FullDiskAccessProbe().state(),
            helper: HelperState(
                status: client.serviceStatus(), teamIDIsUsable: client.hasUsableTeamID, signedByThatTeam: client.isSignedByItsTeam,
                daemonIsBundled: client.bundlesDaemon))
        try emit(report, json: global.json) { TextRenderer.permissions(report) }
    }
}
