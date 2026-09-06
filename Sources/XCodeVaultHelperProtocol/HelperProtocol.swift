import Foundation

/// The complete privileged API. Every verb names a closed set of resources; nothing here accepts a
/// path, a command, or an argument array from the client (SECURITY_MODEL.md). Both the app/CLI
/// and the daemon link this module and nothing else crosses the XPC boundary.
@objc public protocol XCodeVaultHelperXPC {
    /// Helper build identification, for version-skew checks.
    func version(reply: @escaping (String) -> Void)

    /// Deletes the contents of one root-owned, regenerable directory chosen from
    /// `HelperCleanupTarget`. The helper maps the raw value to a fixed absolute path itself.
    func removeRegenerableSystemDirectoryContents(target: String, reply: @escaping (HelperResult) -> Void)

    /// Deletes one stranded runtime download from a CoreSimulator Inbox directory. The name must be
    /// a single path component; the helper validates it, resolves it under the fixed Inbox paths,
    /// and refuses symlinks and anything not a regular file ending in .dmg.
    func removeStrandedRuntimeDownload(fileName: String, reply: @escaping (HelperResult) -> Void)

    /// Creates `<mount point>/XcodeVault` on a mounted external volume identified by UUID and
    /// hands ownership to the given uid/gid, so the unprivileged app can use it. The helper resolves
    /// the UUID through diskutil itself; the client cannot pass a path.
    func createVaultDirectory(volumeUUID: String, ownerUID: UInt32, ownerGID: UInt32, reply: @escaping (HelperResult) -> Void)
}

/// Allowlisted cleanup targets. The helper owns the path mapping; the enum exists so clients cannot
/// even express another path.
public enum HelperCleanupTarget: String, CaseIterable, Sendable {
    case coreSimulatorDyldCache = "coreSimulatorDyldCache"   // /Library/Developer/CoreSimulator/Caches/dyld
    case cryptexCaches = "cryptexCaches"                     // /Library/Developer/CoreSimulator/Cryptex/Caches

    public var path: String {
        switch self {
        case .coreSimulatorDyldCache: return "/Library/Developer/CoreSimulator/Caches/dyld"
        case .cryptexCaches: return "/Library/Developer/CoreSimulator/Cryptex/Caches"
        }
    }
}

public enum HelperInboxDirectory: String, CaseIterable, Sendable {
    case cryptexInbox = "/Library/Developer/CoreSimulator/Cryptex/Images/Inbox"
    case imagesInbox = "/Library/Developer/CoreSimulator/Images/Inbox"
}

/// Result envelope; `NSSecureCoding` so it can cross XPC.
@objc public final class HelperResult: NSObject, NSSecureCoding, Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let ok: Bool
    public let message: String
    public let bytesFreed: UInt64

    public init(ok: Bool, message: String, bytesFreed: UInt64 = 0) {
        self.ok = ok; self.message = message; self.bytesFreed = bytesFreed
    }
    public required init?(coder: NSCoder) {
        ok = coder.decodeBool(forKey: "ok")
        message = coder.decodeObject(of: NSString.self, forKey: "message") as String? ?? ""
        bytesFreed = UInt64(coder.decodeInt64(forKey: "bytesFreed"))
    }
    public func encode(with coder: NSCoder) {
        coder.encode(ok, forKey: "ok"); coder.encode(message as NSString, forKey: "message"); coder.encode(Int64(bytesFreed), forKey: "bytesFreed")
    }
}

public enum HelperIdentity {
    public static let machServiceName = "com.xcodevault.helper"
    public static let plistName = "com.xcodevault.helper.plist"
    public static let bundleIdentifier = "com.xcodevault.helper"
    /// Code-signing requirement the daemon enforces on every client (Developer ID team + bundle id).
    /// `TEAMID` is substituted at bundle time by scripts/bundle-app.sh; unsigned dev builds use
    /// the ad-hoc fallback and are refused by a release helper.
    public static func clientRequirement(teamID: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (identifier \"com.xcodevault.app\" or identifier \"com.xcodevault.xcodevaultctl\")"
    }
    public static let version = "0.1.0-dev"
}
