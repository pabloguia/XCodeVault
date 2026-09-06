import Foundation

/// One installed simulator runtime as reported by `simctl runtime list -j`. On Xcode 26 these
/// are sealed cryptex disk images whose bytes live under `/System/Library/AssetsV2/…` (E1).
public struct SimulatorRuntime: Sendable, Codable, Equatable, Identifiable {
    public var id: String { identifier }
    public var identifier: String          // image UUID
    public var runtimeIdentifier: String?  // com.apple.CoreSimulator.SimRuntime.iOS-26-5
    public var platformIdentifier: String?
    public var version: String?
    public var build: String?
    public var kind: String?               // "Patchable Cryptex Disk Image", "Disk Image", …
    public var state: String?              // Ready / Unusable / …
    public var signatureState: String?
    public var deletable: Bool?
    public var sizeBytes: UInt64?
    public var path: String?               // the .dmg inside the MobileAsset store
    public var mountPath: String?          // /Library/Developer/CoreSimulator/Volumes/<Platform>_<Build>
    public var parentMountPath: String?
    public var runtimeBundlePath: String?
    public var lastUsedAt: String?
    public var supportedArchitectures: [String]?

    public var platformName: String {
        guard let p = platformIdentifier else { return "unknown" }
        return p.replacingOccurrences(of: "com.apple.platform.", with: "").replacingOccurrences(of: "simulator", with: "")
    }
    /// True when the image file is under the MobileAsset store rather than CoreSimulator's own Cryptex dir.
    public var isMobileAssetBacked: Bool { path?.hasPrefix("/System/Library/AssetsV2/") == true }
    public var isMounted: Bool { mountPath.map { MountStatus.isMountPoint($0) } ?? false }
}

public struct SimulatorDevice: Sendable, Codable, Equatable, Identifiable {
    public var id: String { udid }
    public var udid: String
    public var name: String
    public var runtimeIdentifier: String
    public var state: String
    public var isAvailable: Bool
    public var availabilityError: String?
    public var dataPath: String?
    public var dataPathSize: UInt64?
    public var logPath: String?
    public var lastBootedAt: String?
}

public enum SimulatorDiscovery {
    public static func runtimes(runner: CommandRunning = ProcessCommandRunner(), developerDir: String? = nil) throws -> [SimulatorRuntime] {
        let env = developerDir.map { ["DEVELOPER_DIR": $0] }
        let r = try runner.check(Tools.xcrun, ["simctl", "runtime", "list", "-j"], environment: env)
        return try parseRuntimes(json: Data(r.stdout.utf8))
    }

    public static func parseRuntimes(json: Data) throws -> [SimulatorRuntime] {
        let raw = try JSONDecoder().decode([String: SimulatorRuntime].self, from: json)
        return raw.values.sorted { ($0.platformName, $0.version ?? "") < ($1.platformName, $1.version ?? "") }
    }

    public static func devices(runner: CommandRunning = ProcessCommandRunner(), developerDir: String? = nil) throws -> [SimulatorDevice] {
        let env = developerDir.map { ["DEVELOPER_DIR": $0] }
        let r = try runner.check(Tools.xcrun, ["simctl", "list", "devices", "-j"], environment: env)
        return try parseDevices(json: Data(r.stdout.utf8))
    }

    public static func parseDevices(json: Data) throws -> [SimulatorDevice] {
        struct Raw: Decodable {
            struct Dev: Decodable {
                let udid: String; let name: String; let state: String; let isAvailable: Bool?
                let availabilityError: String?; let dataPath: String?; let dataPathSize: UInt64?
                let logPath: String?; let lastBootedAt: String?
            }
            let devices: [String: [Dev]]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: json)
        var out: [SimulatorDevice] = []
        for (runtime, devs) in raw.devices {
            for d in devs {
                out.append(SimulatorDevice(udid: d.udid, name: d.name, runtimeIdentifier: runtime, state: d.state,
                                           isAvailable: d.isAvailable ?? true, availabilityError: d.availabilityError,
                                           dataPath: d.dataPath, dataPathSize: d.dataPathSize, logPath: d.logPath,
                                           lastBootedAt: d.lastBootedAt))
            }
        }
        return out.sorted { ($0.runtimeIdentifier, $0.name) < ($1.runtimeIdentifier, $1.name) }
    }
}
