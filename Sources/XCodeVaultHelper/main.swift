import Foundation
import Security
import XCodeVaultHelperCore
import XCodeVaultHelperProtocol

// XCodeVault privileged helper — a root LaunchDaemon registered with SMAppService.daemon.
// This file is the bootstrap only; every verb, guard and identity check lives in
// XCodeVaultHelperCore, where it is reachable by tests. See that target's header for why.

// The requirement is baked in at bundle time (scripts/bundle-app.sh replaces TEAMID). A helper
// built without a real team ID refuses every connection rather than accepting any client.
let teamID = "TEAMID_PLACEHOLDER"
guard teamID != "TEAMID_PLACEHOLDER" else {
    FileHandle.standardError.write(Data("xcodevault-helper: not bundled with a signing team id; refusing to serve\n".utf8))
    exit(78)
}
// The requirement string is the whole of peer validation, and `setCodeSigningRequirement` does not
// report a malformed one in any way Swift can catch — it raises an Objective-C exception. Parse it
// here, before a listener exists, so that by the time a connection arrives it cannot be malformed.
var parsedRequirement: SecRequirement?
guard SecRequirementCreateWithString(HelperIdentity.clientRequirement(teamID: teamID) as CFString, [], &parsedRequirement) == errSecSuccess else {
    FileHandle.standardError.write(Data("xcodevault-helper: the client code-signing requirement does not parse; refusing to serve\n".utf8))
    exit(78)
}
let delegate = ListenerDelegate(teamID: teamID)
let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
