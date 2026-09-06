import AppKit
import Foundation

/// One deletion the cleaner proposes. Always a whole path; never a shell command.
public struct CleanAction: Sendable, Codable, Equatable, Identifiable {
    public var id: String { path }
    public var categoryID: String
    public var categoryName: String
    public var path: String
    public var bytes: UInt64
    public var isExperimental: Bool
    public var risk: RiskLevel
    public var requiresRoot: Bool
    public var notes: [String]
}

public struct CleanPlan: Sendable, Codable, Equatable {
    public var actions: [CleanAction]
    public var skipped: [String]          // human-readable reasons for things not planned
    public var warnings: [String]
    public var totalBytes: UInt64 { actions.reduce(0) { $0 + $1.bytes } }
    public var userActions: [CleanAction] { actions.filter { !$0.requiresRoot } }
    public var rootActions: [CleanAction] { actions.filter { $0.requiresRoot } }
}

/// Builds a cleanup plan from a scan. Only categories whose catalog entry allows `safeCleanup`
/// are eligible; non-regenerable data is structurally excluded (CatalogRules); Archives can
/// never appear here. Root-owned categories are listed but not executable until the
/// privileged helper exists (M3).
public struct CleanPlanner: Sendable {
    public var home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }

    /// - Parameters:
    ///   - report: a scan with sizes measured.
    ///   - categories: restrict to these category ids (empty = all eligible).
    ///   - granular: split DerivedData / Device Support into per-child actions so the user can keep some.
    public func plan(report: ScanReport, categories: Set<String> = [], granular: Bool = true) -> CleanPlan {
        var actions: [CleanAction] = [], skipped: [String] = [], warnings: [String] = []
        for item in report.items {
            guard let c = StorageCatalog.category(item.categoryID) else { continue }
            if !categories.isEmpty && !categories.contains(c.id) { continue }
            if let cmd = c.cleanupCommand { skipped.append("\(c.name): managed by Apple's tool, not deleted through the filesystem — use `\(cmd)`"); continue }
            guard c.allowedStrategies.contains(.safeCleanup) else { continue }
            guard c.regenerability != .nonRegenerable else { skipped.append("\(c.name): non-regenerable, never cleaned automatically"); continue }
            guard item.exists else { continue }
            if item.isSymlink { skipped.append("\(item.path): is a symlink (→ \(item.symlinkTarget ?? "?")) — fix with doctor first, nothing is deleted through symlinks"); continue }
            if item.isMountPoint { skipped.append("\(item.path): is a mount point — never cleaned"); continue }
            guard item.allocatedBytes > 0 else { continue }
            let children = granular && ["derivedData", "deviceSupport"].contains(c.id) ? childActions(of: item, category: c) : nil
            if let children, !children.isEmpty {
                actions += children
            } else {
                actions.append(CleanAction(categoryID: c.id, categoryName: c.name, path: item.path, bytes: item.allocatedBytes,
                                           isExperimental: c.isExperimental, risk: c.deletionRisk, requiresRoot: c.privilege == .root,
                                           notes: c.notes))
            }
        }
        if actions.contains(where: { $0.categoryID == "derivedData" }) {
            warnings.append("DerivedData is rebuilt on the next build; the first build of each project will be a full build.")
        }
        if actions.contains(where: { $0.categoryID == "deviceSupport" }) {
            warnings.append("Device Support symbols are re-copied (minutes) the next time a device with that OS build connects; keep the builds you still debug.")
        }
        if actions.contains(where: { $0.categoryID == "coreSimulatorSystemCaches" }) {
            warnings.append("CoreSimulator dyld caches are root-owned: listed for accounting, executable only through the privileged helper (M3).")
        }
        actions.sort { $0.bytes > $1.bytes }
        return CleanPlan(actions: actions, skipped: skipped, warnings: warnings)
    }

    func childActions(of item: StorageItem, category: StorageCategory) -> [CleanAction]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: item.path) else { return nil }
        var out: [CleanAction] = []
        for n in names.sorted() where !n.hasPrefix(".") {
            let p = item.path + "/" + n
            var st = stat(); guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            // Keep DerivedData's shared module cache & symbol cache out of granular lists (they are cheap and shared).
            let u = DiskUsage.measure(p)?.allocatedBytes ?? 0
            guard u > 0 else { continue }
            out.append(CleanAction(categoryID: category.id, categoryName: category.name, path: p, bytes: u,
                                   isExperimental: category.isExperimental, risk: category.deletionRisk,
                                   requiresRoot: category.privilege == .root, notes: []))
        }
        return out
    }
}

public struct CleanResult: Sendable, Codable, Equatable {
    public var deleted: [CleanAction]
    public var failed: [(String, String)] { failedPairs.map { ($0.path, $0.error) } }
    public var failedPairs: [FailedAction]
    public var bytesFreed: UInt64 { deleted.reduce(0) { $0 + $1.bytes } }
    public struct FailedAction: Sendable, Codable, Equatable { public var path: String; public var error: String }
}

public struct CleanError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Executes a plan's user-level actions. Every action is journaled before and after.
/// Refuses symlinks, mount points, anything outside the home directory or the catalog paths,
/// and (unless forced) refuses DerivedData deletion while Xcode.app is running.
public struct CleanExecutor: Sendable {
    public var journal: Journal
    public var home: String
    public var useTrash: Bool
    public var isXcodeRunning: @Sendable () -> Bool

    public init(journal: Journal = Journal(), home: String = NSHomeDirectory(), useTrash: Bool = false,
                isXcodeRunning: @escaping @Sendable () -> Bool = CleanExecutor.xcodeIsRunning) {
        self.journal = journal; self.home = home; self.useTrash = useTrash; self.isXcodeRunning = isXcodeRunning
    }

    public static func xcodeIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.dt.Xcode" }
    }

    public func execute(_ plan: CleanPlan, force: Bool = false) throws -> CleanResult {
        let actions = plan.userActions
        if !force && isXcodeRunning() && actions.contains(where: { $0.categoryID == "derivedData" || $0.categoryID == "previews" }) {
            throw CleanError("Xcode.app is running. Quit Xcode before cleaning DerivedData/previews, or pass --force.")
        }
        let opID = UUID().uuidString
        try journal.record(id: opID, kind: .clean, state: .planned, summary: "clean \(actions.count) path(s)", paths: actions.map(\.path), bytes: plan.totalBytes)
        var deleted: [CleanAction] = [], failed: [CleanResult.FailedAction] = []
        for a in actions {
            do {
                try preflight(a)
                try journal.record(id: opID, kind: .clean, state: .started, summary: "delete \(a.path)", paths: [a.path], bytes: a.bytes)
                let url = URL(fileURLWithPath: a.path)
                if useTrash { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                else { try FileManager.default.removeItem(at: url) }
                deleted.append(a)
            } catch {
                failed.append(.init(path: a.path, error: "\(error)"))
                try journal.record(id: opID, kind: .clean, state: .failed, summary: "delete \(a.path): \(error)", paths: [a.path])
            }
        }
        try journal.record(id: opID, kind: .clean, state: .completed, summary: "freed \(ByteCount.format(deleted.reduce(0) { $0 + $1.bytes })), \(failed.count) failure(s)",
                           paths: deleted.map(\.path), bytes: deleted.reduce(0) { $0 + $1.bytes })
        return CleanResult(deleted: deleted, failedPairs: failed)
    }

    func preflight(_ a: CleanAction) throws {
        guard !a.requiresRoot else { throw CleanError("\(a.path) requires the privileged helper (not available yet)") }
        var st = stat()
        guard lstat(a.path, &st) == 0 else { throw CleanError("\(a.path) no longer exists") }
        guard (st.st_mode & S_IFMT) != S_IFLNK else { throw CleanError("\(a.path) is a symlink — refusing") }
        guard !MountStatus.isMountPoint(a.path) else { throw CleanError("\(a.path) is a mount point — refusing") }
        guard st.st_uid == getuid() else { throw CleanError("\(a.path) is not owned by the current user — refusing") }
        // The path must be inside a catalog template for its category (defense in depth against a corrupted plan).
        guard let c = StorageCatalog.category(a.categoryID), c.allowedStrategies.contains(.safeCleanup),
              c.pathTemplates.map({ $0.expandingTilde(home: home) }).contains(where: { a.path == $0 || a.path.hasPrefix($0 + "/") })
        else { throw CleanError("\(a.path) is not inside an approved cleanup category path — refusing") }
        let forbidden = CatalogRules.neverSymlink.map { $0.expandingTilde(home: home) }
        guard !forbidden.contains(a.path) else { throw CleanError("\(a.path) is a protected directory — refusing") }
    }
}
