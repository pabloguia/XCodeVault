import Foundation
import Security
import XCodeVaultHelperCore
import XCodeVaultHelperProtocol

// XCodeVault privileged helper — a root LaunchDaemon registered with SMAppService.daemon.
// This file is the bootstrap only; every verb, guard and identity check lives in
// XCodeVaultHelperCore, where it is reachable by tests. See that target's header for why.

// The requirement is baked in at bundle time: scripts/bundle-app.sh replaces the literal below,
// which is `HelperIdentity.teamIDPlaceholder`. A helper built without a real team ID refuses every
// connection rather than accepting any client.
//
// The line beneath must keep spelling the placeholder literally — the bundler's `sed` matches on it
// — which is why the constant is asserted against it by a test rather than substituted here.
let teamID = "TEAMID_PLACEHOLDER"
// `isUsableTeamID`, not `!= placeholder`. The placeholder is one way this can be wrong and not the
// likeliest: a `sed` that matched nothing, or matched oddly, leaves something malformed rather than
// the original token, and that produced a requirement no certificate satisfies while this guard said
// it was fine. A reviewer pointed out that the predicate had been written in the same pass and left
// with no caller — this is the caller. It mirrors `bundle-app.sh`'s own `^[A-Z0-9]{10}$` check.
guard HelperIdentity.isUsableTeamID(teamID) else {
    FileHandle.standardError.write(Data("xcodevault-helper: not bundled with a usable signing team id; refusing to serve\n".utf8))
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
