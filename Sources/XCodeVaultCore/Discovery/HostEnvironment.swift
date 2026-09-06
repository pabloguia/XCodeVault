import Foundation

/// Facts about the machine the scan runs on. Everything here is read-only discovery.
public struct HostEnvironment: Sendable, Codable, Equatable {
    public var macOSVersion: String
    public var macOSBuild: String
    public var architecture: String
    public var homeDirectory: String
    public var dataVolumeFreeBytes: UInt64
    public var dataVolumeTotalBytes: UInt64
    public var userName: String
    public var isRoot: Bool

    public var isAppleSilicon: Bool { architecture == "arm64" }
    public var meetsMinimumOS: Bool {
        // ADR-0001: macOS 14.0 minimum.
        let major = Int(macOSVersion.split(separator: ".").first ?? "0") ?? 0
        return major >= 14
    }

    public static func discover(runner: CommandRunning = ProcessCommandRunner(), home: String = NSHomeDirectory()) -> HostEnvironment {
        let version = (try? runner.run(Tools.swVers, ["-productVersion"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
        let build = (try? runner.run(Tools.swVers, ["-buildVersion"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
        var uts = utsname(); uname(&uts)
        let arch = withUnsafePointer(to: &uts.machine) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let space = MountStatus.space(at: home) ?? (free: 0, total: 0)
        return HostEnvironment(
            macOSVersion: version, macOSBuild: build, architecture: arch, homeDirectory: home,
            dataVolumeFreeBytes: space.free, dataVolumeTotalBytes: space.total,
            userName: NSUserName(), isRoot: getuid() == 0)
    }
}
