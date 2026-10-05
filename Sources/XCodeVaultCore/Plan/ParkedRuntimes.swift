import Foundation

/// A simulator runtime that is parked on a drive now: offloaded (its installer kept, the runtime deleted here) and not
/// brought back since.
public struct ParkedRuntime: Sendable, Equatable {
    /// The offload's operation id in the journal.
    public var operationID: String
    /// "iOS 26.5 (23F77)", from the offload's record; the installer's file name when the record has no version.
    public var name: String
    public var runtimeIdentifier: String?
    public var build: String?
    public var installerPath: String
    /// The installer's size as the offload recorded it; nil for an offload recorded before the size was.
    public var bytes: UInt64?

    public init(operationID: String, name: String, runtimeIdentifier: String?, build: String?, installerPath: String, bytes: UInt64?) {
        self.operationID = operationID
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.build = build
        self.installerPath = installerPath
        self.bytes = bytes
    }
}

/// The runtimes parked now (R7-C fix round, F3/I2), from the WHOLE journal — never History's newest rows, which a busy
/// journal pushes an old offload out of.
///
/// - A completed `runtimeOffload` parks the runtime its record names; a later offload of the same runtime replaces it, so
///   each runtime is counted once.
/// - A later completed `runtimeImport` of that installer (its path, or a path inside an exported bundle) brings it back.
/// - A runtime the scan shows installed again is not parked, whatever the journal says: the journal can miss an import
///   made outside this tool.
///
/// A completed `runtimeExport` is not counted: its record names neither the runtime nor that the runtime left this Mac (an
/// export copies the installer and deletes nothing).
public enum ParkedRuntimes {
    public static func current(_ entries: [JournalEntry], installed: [SimulatorRuntime]) -> [ParkedRuntime] {
        var parked: [String: ParkedRuntime] = [:]
        var order: [String] = []
        for e in entries.sorted(by: { $0.sequence < $1.sequence }) where e.state == .completed {
            switch e.kind {
            case .runtimeOffload:
                let installer = e.detail["installer"] ?? e.paths.first ?? ""
                let rid = nonEmpty(e.detail["runtimeIdentifier"])
                let build = nonEmpty(e.detail["build"])
                let key = rid.map { $0 + "|" + (build ?? "") } ?? "installer:" + installer
                if parked[key] == nil { order.append(key) }
                parked[key] = ParkedRuntime(
                    operationID: e.id, name: name(rid: rid, version: nonEmpty(e.detail["version"]), build: build, installer: installer),
                    runtimeIdentifier: rid, build: build, installerPath: installer, bytes: e.detail["installerSizeBytes"].flatMap { UInt64($0) })
            case .runtimeImport:
                for path in e.paths {
                    for (key, r) in parked where !r.installerPath.isEmpty && (path == r.installerPath || path.hasPrefix(r.installerPath + "/")) {
                        parked[key] = nil
                    }
                }
            default:
                break
            }
        }
        return order.compactMap { parked[$0] }.filter { r in
            !installed.contains { i in
                guard let rid = r.runtimeIdentifier, i.runtimeIdentifier == rid else { return false }
                return r.build == nil || i.build == nil || i.build == r.build
            }
        }
    }

    /// "iOS 26.5 (23F77)" from `com.apple.CoreSimulator.SimRuntime.iOS-26-5`, version and build.
    static func name(rid: String?, version: String?, build: String?, installer: String) -> String {
        let platform = rid.flatMap { $0.split(separator: ".").last }.map { String($0.split(separator: "-").first ?? "") }
        guard let platform, !platform.isEmpty else { return (installer as NSString).lastPathComponent }
        let v = version ?? rid.flatMap { $0.split(separator: ".").last }.map { $0.split(separator: "-").dropFirst().joined(separator: ".") } ?? ""
        return [platform, v].filter { !$0.isEmpty }.joined(separator: " ") + (build.map { " (\($0))" } ?? "")
    }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
}
