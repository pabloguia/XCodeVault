import Foundation

// What the app's three bucket views show (spec 2026-10-03 §6.4, S4 Task 4), decided here so the views only draw it.
// The facts come from the clean planner (Delete) and `SavingsPlanner.rows` (every bucket); nothing here re-derives them.

/// One marker beside a row: a fact the user needs before acting, in the words the CLI uses for it.
public enum SavingsMarker: Sendable, Equatable {
    /// Rule 10: wherever a row is experimental, it says so.
    case experimental
    /// Deleting it deletes data the user made (simulator devices: their apps and the apps' data).
    case losesUserData
    /// The command has no preview of its own.
    case actsImmediately
    /// The option moves where *new* data goes; existing data stays (no bytes counted).
    case newDataOnly
    /// The command names one item; this many items means this many commands.
    case perItem(Int)
    /// A root-owned row: what it lacks (`CleanAction.privilegeRequirement`).
    case needsRoot(PrivilegeRequirement)

    /// The marker in the chosen language: the `plan` command's words, or the requirement's own tag.
    public var localizedText: String {
        switch self {
        case .experimental: L10n.tr("cli.plan.marker.experimental")
        case .losesUserData: L10n.tr("cli.plan.marker.losesUserData")
        case .actsImmediately: L10n.tr("cli.plan.marker.actsImmediately")
        case .newDataOnly: L10n.tr("cli.plan.marker.newDataOnly")
        case .perItem(let count): L10n.plural("cli.plan.marker.perItem", count: count)
        case .needsRoot(let requirement): requirement.label(in: L10n.locale)
        }
    }

    /// The markers of a plan row, in the order `plan` prints them.
    public static func markers(for row: SavingsPlanRow) -> [SavingsMarker] {
        var markers: [SavingsMarker] = []
        if row.option.isExperimental { markers.append(.experimental) }
        if row.option.losesUserData { markers.append(.losesUserData) }
        if row.actsImmediately { markers.append(.actsImmediately) }
        if !row.option.appliesToExistingData { markers.append(.newDataOnly) }
        if row.isPerItem && row.itemCount > 0 { markers.append(.perItem(row.itemCount)) }
        return markers
    }
}

extension SavingsPlanRow {
    /// The row's notes in the chosen language, in reading order; an id this build does not know is left out.
    public var localizedNotes: [String] { noteIDs.compactMap(SavingsPlanner.noteText) }
}

/// The Delete view: the clean plan grouped by category, plus the delete-bucket rows that are not `clean`'s to do —
/// simulator devices (`simctl delete`) and runtimes (`runtime delete`) — listed with their command and never deletable
/// from the view.
public struct DeleteList: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public let categoryID: String
        public let categoryName: String
        /// In the plan's order (largest first).
        public let actions: [CleanAction]
        /// What getting it back costs: the category's regenerability.
        public let undo: Regenerability
        public var id: String { categoryID }
        public var bytes: UInt64 { actions.reduce(0) { $0 + $1.bytes } }
    }

    /// Largest group first, ties by name.
    public let groups: [Group]
    /// The delete-bucket rows that go through another tool, in `SavingsPlanner.rows` order.
    public let otherTools: [SavingsPlanRow]

    /// Archives, and anything else the catalog calls non-regenerable, never reach the list (CLAUDE.md rule 5). The
    /// clean planner already never plans them; this is the view's own guard, so a plan built elsewhere cannot show them.
    public static func make(plan: CleanPlan, report: ScanReport) -> DeleteList {
        var byCategory: [String: [CleanAction]] = [:]
        var order: [String] = []
        for action in plan.actions where isListable(action.categoryID) {
            if byCategory[action.categoryID] == nil { order.append(action.categoryID) }
            byCategory[action.categoryID, default: []].append(action)
        }
        let groups = order.compactMap { id -> Group? in
            guard let actions = byCategory[id], let first = actions.first else { return nil }
            let undo = StorageCatalog.category(id)?.regenerability ?? .regenerable
            return Group(categoryID: id, categoryName: first.categoryName, actions: actions, undo: undo)
        }
        .sorted { a, b in a.bytes != b.bytes ? a.bytes > b.bytes : a.categoryName < b.categoryName }
        let other = SavingsPlanner.rows(report: report, bucket: .deleteAndRegenerate).filter {
            !$0.command.hasPrefix("xcodevaultctl clean ") && isListable($0.categoryID)
        }
        return DeleteList(groups: groups, otherTools: other)
    }

    /// What **Delete Selected…** acts on: the selected listed rows that are not root-owned. One definition for the
    /// count in the confirmation and the set deleted, so the number a user agrees to is the number deleted. Root rows
    /// stay selectable and are never acted on here (`CleanAction.privilegeRequirement` says what they lack).
    public func deletable(selected: Set<String>) -> [CleanAction] {
        groups.flatMap(\.actions).filter { selected.contains($0.id) && !$0.requiresRoot }
    }

    /// The cost to undo deleting `action`: its group's. Nil for an action the list does not show.
    public func undo(of action: CleanAction) -> Regenerability? { groups.first { $0.categoryID == action.categoryID }?.undo }

    static func isListable(_ categoryID: String) -> Bool {
        categoryID != "archives" && StorageCatalog.category(categoryID)?.regenerability != .nonRegenerable
    }

    /// The markers of one action: experimental, deletes the apps' data, and what a root-owned row lacks.
    public static func markers(for action: CleanAction) -> [SavingsMarker] {
        var markers: [SavingsMarker] = []
        if action.isExperimental { markers.append(.experimental) }
        if StorageCatalog.category(action.categoryID)?.regenerability == .userRecreatable { markers.append(.losesUserData) }
        if let requirement = action.privilegeRequirement { markers.append(.needsRoot(requirement)) }
        return markers
    }
}

/// The vault line of the Park view, from `VaultVerifier`'s checks: none registered, none usable, or the first usable one.
public enum VaultStatus: Sendable, Equatable {
    case noVault
    /// Registered, but no registered vault is usable now (unplugged, or a state `doctor` explains).
    case offline
    case ready(volumeName: String)

    public static func make(_ checks: [VaultVolumeCheck]) -> VaultStatus {
        if checks.isEmpty { return .noVault }
        if let usable = checks.first(where: \.isUsable) { return .ready(volumeName: usable.volume.volumeName) }
        return .offline
    }
}

/// A localized sentence split at its backticks, so a view can set the commands in monospace instead of showing the
/// backticks (`Text(verbatim:)` has no Markdown).
public enum InlineCode {
    public struct Run: Sendable, Equatable {
        public let text: String
        public let isCode: Bool
        public init(_ text: String, isCode: Bool) {
            self.text = text
            self.isCode = isCode
        }
    }

    /// Alternating prose and code. Empty runs are dropped; an unmatched backtick stays as text.
    public static func runs(_ s: String) -> [Run] {
        let parts = s.components(separatedBy: "`")
        var runs: [Run] = []
        for (i, part) in parts.enumerated() {
            // An even number of parts means the last backtick has no partner: put it back on the last part.
            let isLastUnmatched = parts.count % 2 == 0 && i == parts.count - 1
            let text = isLastUnmatched ? "`" + part : part
            let isCode = i % 2 == 1 && !isLastUnmatched
            guard !text.isEmpty else { continue }
            if let last = runs.last, last.isCode == isCode {
                runs[runs.count - 1] = Run(last.text + text, isCode: isCode)
            } else {
                runs.append(Run(text, isCode: isCode))
            }
        }
        return runs
    }
}
