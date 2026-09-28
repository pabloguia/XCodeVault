import XCodeVaultCore
import XCodeVaultHelperClient
import XCodeVaultHelperProtocol

/// The app's adapter from Core's `PrivilegedHelper` to `HelperClient`. Thin on purpose: every decision is in
/// Core (`HelperApprovalFlow`, `PrivilegedActionRunner`), where fakes test it, and every check that protects the
/// boundary is in `HelperClient`, which the security review reads. This file only forwards — it is the one
/// untested link, and it holds nothing that could be wrong in an interesting way.
///
/// `client` is private so the rest of the app reaches the verbs only through `perform`, which the runner calls
/// (`scripts/helper-invariants.sh`; migration-safety review of deliverable 4). The app uses the default; tests
/// hand in a client whose connection and launchd calls are fakes.
struct LiveHelper: PrivilegedHelper {
    private let client: HelperClient

    init(client: HelperClient = HelperClient()) { self.client = client }

    func state() -> HelperState {
        HelperState(
            status: client.serviceStatus(), teamIDIsUsable: client.hasUsableTeamID, signedByThatTeam: client.isSignedByItsTeam,
            daemonIsBundled: client.bundlesDaemon)
    }

    func register() throws { try client.register() }

    func openApprovalSettings() { client.openApprovalSettings() }

    func unregister() async throws { try await client.unregister() }

    func perform(_ action: PrivilegedAction) async throws -> PrivilegedActionReply {
        let result: HelperResult
        switch action {
        case .createVaultDirectory(let volumeUUID):
            result = try await client.createVaultDirectory(volumeUUID: volumeUUID)
        case .emptyCoreSimulatorDyldCache:
            result = try await client.removeRegenerableSystemDirectoryContents(target: .coreSimulatorDyldCache)
        }
        return PrivilegedActionReply(ok: result.ok, message: result.message, bytesFreed: result.bytesFreed)
    }
}
