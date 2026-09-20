import Foundation

/// Capabilities of one Xcode's `xcodebuild`/`simctl`, **feature-detected from its own help
/// output** — never assumed from the version number (research F2: flags differ and some are
/// rejected on specific builds).
public struct XcodeCapabilities: Sendable, Codable, Equatable {
    public var downloadPlatform = false
    public var downloadAllPlatforms = false
    public var exportPath = false  // -downloadPlatform … -exportPath (Runtime Library export)
    public var buildVersion = false  // -downloadPlatform … -buildVersion
    public var architectureVariant = false  // -architectureVariant <universal|arm64>
    public var importPlatform = false
    public var downloadComponent = false  // Xcode 26: Metal toolchain
    public var importComponent = false
    public var deleteComponent = false
    public var showComponent = false
    public var checkForNewerComponents = false
    public var prepareDeviceSupport = false  // Xcode 26.5: pre-download device support symbols
    public var simctlRuntimeAdd = false
    public var simctlRuntimeDelete = false
    public var simctlRuntimeUnmount = false
    public var simctlRuntimeVerify = false
    public var simctlRuntimeMatch = false

    public init() {
        // Every capability defaults to `false`: absent until `parse(xcodebuildHelp:)` observes it.
        // Defaulting to "unsupported" is the fail-closed direction — a capability wrongly assumed
        // present would route a migration through a mechanism this Xcode does not have.
    }

    /// Parses `xcodebuild -help` text.
    public static func parse(xcodebuildHelp: String) -> XcodeCapabilities {
        var c = XcodeCapabilities()
        // Usage lines carry the optional flags in brackets; option lines carry the bare flag.
        c.downloadPlatform = xcodebuildHelp.contains("-downloadPlatform")
        c.downloadAllPlatforms = xcodebuildHelp.contains("-downloadAllPlatforms")
        c.importPlatform = xcodebuildHelp.contains("-importPlatform")
        c.downloadComponent = xcodebuildHelp.contains("-downloadComponent")
        c.importComponent = xcodebuildHelp.contains("-importComponent")
        c.deleteComponent = xcodebuildHelp.contains("-deleteComponent")
        c.showComponent = xcodebuildHelp.contains("-showComponent")
        c.checkForNewerComponents = xcodebuildHelp.contains("-checkForNewerComponents")
        c.prepareDeviceSupport = xcodebuildHelp.contains("-prepareDeviceSupport")
        // Sub-flags must be found on a -downloadPlatform / -downloadAllPlatforms usage line,
        // because `-exportPath` also exists for -exportArchive.
        for line in xcodebuildHelp.split(separator: "\n") where line.contains("-downloadPlatform") || line.contains("-downloadAllPlatforms") {
            if line.contains("-exportPath") { c.exportPath = true }
            if line.contains("-buildVersion") { c.buildVersion = true }
            if line.contains("-architectureVariant") { c.architectureVariant = true }
        }
        return c
    }

    /// Parses `xcrun simctl runtime` (no operation) usage text.
    public mutating func apply(simctlRuntimeHelp: String) {
        func has(_ verb: String) -> Bool {
            simctlRuntimeHelp.split(separator: "\n").contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(verb + " ") || $0.trimmingCharacters(in: .whitespaces) == verb
            }
        }
        simctlRuntimeAdd = has("add")
        simctlRuntimeDelete = has("delete")
        simctlRuntimeUnmount = has("unmount")
        simctlRuntimeVerify = has("verify")
        simctlRuntimeMatch = has("match list") || has("match")
    }

    /// Whether the external Runtime Library workflow (export installer, import later) is possible.
    public var supportsRuntimeLibrary: Bool { downloadPlatform && exportPath && importPlatform }
}

public struct XcodeInstallation: Sendable, Codable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String  // /Applications/Xcode.app
    public var developerDirectory: String
    public var version: String  // 26.5
    public var build: String  // 17F42
    public var isSelected: Bool  // xcode-select -p points here
    public var capabilities: XcodeCapabilities

    public var majorVersion: Int { Int(version.split(separator: ".").first ?? "0") ?? 0 }
}

public enum XcodeDiscovery {
    /// Finds Xcode bundles in the standard locations plus the `xcode-select`ed one.
    public static func discover(
        runner: CommandRunning = ProcessCommandRunner(),
        searchRoots: [String] = ["/Applications", NSHomeDirectory() + "/Applications"],
        detectCapabilities: Bool = true
    ) -> [XcodeInstallation] {
        let fm = FileManager.default
        var candidates = Set<String>()
        for root in searchRoots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names where n.hasPrefix("Xcode") && n.hasSuffix(".app") {
                candidates.insert(root + "/" + n)
            }
        }
        var selectedDev = ""
        if let r = try? runner.run(Tools.xcodeSelect, ["-p"]), r.succeeded {
            selectedDev = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if selectedDev.hasSuffix("/Contents/Developer") {
                candidates.insert(String(selectedDev.dropLast("/Contents/Developer".count)))
            }
        }
        var result: [XcodeInstallation] = []
        for app in candidates.sorted() {
            guard let inst = inspect(appPath: app, selectedDeveloperDir: selectedDev, runner: runner, detectCapabilities: detectCapabilities) else { continue }
            result.append(inst)
        }
        return result.sorted { ($0.isSelected ? 0 : 1, $0.version) < ($1.isSelected ? 0 : 1, $1.version) }
    }

    public static func inspect(appPath: String, selectedDeveloperDir: String, runner: CommandRunning, detectCapabilities: Bool) -> XcodeInstallation? {
        let dev = appPath + "/Contents/Developer"
        let infoPlist = appPath + "/Contents/Info.plist"
        let versionPlist = appPath + "/Contents/version.plist"
        guard let info = NSDictionary(contentsOfFile: infoPlist),
            (info["CFBundleIdentifier"] as? String)?.hasPrefix("com.apple.dt.Xcode") == true
        else { return nil }
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = (NSDictionary(contentsOfFile: versionPlist)?["ProductBuildVersion"] as? String) ?? "unknown"
        var caps = XcodeCapabilities()
        if detectCapabilities {
            let xb = dev + "/usr/bin/xcodebuild"
            if let r = try? runner.run(xb, ["-help"]) { caps = XcodeCapabilities.parse(xcodebuildHelp: r.stdout + r.stderr) }
            if let r = try? runner.run(Tools.xcrun, ["simctl", "runtime"], environment: ["DEVELOPER_DIR": dev]) {
                caps.apply(simctlRuntimeHelp: r.stdout + r.stderr)
            }
        }
        return XcodeInstallation(
            path: appPath, developerDirectory: dev, version: version, build: build,
            isSelected: dev == selectedDeveloperDir, capabilities: caps)
    }
}
