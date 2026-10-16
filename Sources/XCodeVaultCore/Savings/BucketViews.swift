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

    /// The view's own guards, on top of the clean planner's, so a plan built elsewhere cannot widen what is deletable:
    /// a group needs a catalog category that `clean` deletes through the filesystem (`isDeletableHere`), which keeps
    /// out Archives and everything non-regenerable (CLAUDE.md rule 5), devices and runtimes (another tool's), and ids the
    /// catalog does not know (fails closed). The other-tool rows are the planner's, with rule 5 applied again.
    public static func make(plan: CleanPlan, report: ScanReport) -> DeleteList {
        var byCategory: [String: [CleanAction]] = [:]
        var order: [String] = []
        for action in plan.actions where isDeletableHere(action.categoryID) {
            if byCategory[action.categoryID] == nil { order.append(action.categoryID) }
            byCategory[action.categoryID, default: []].append(action)
        }
        let groups = order.compactMap { id -> Group? in
            // The undo cost is the catalog's; there is no default, and `isDeletableHere` already required the category.
            guard let actions = byCategory[id], let first = actions.first, let category = StorageCatalog.category(id) else { return nil }
            return Group(categoryID: id, categoryName: first.categoryName, actions: actions, undo: category.regenerability)
        }
        .sorted { a, b in a.bytes != b.bytes ? a.bytes > b.bytes : a.categoryName < b.categoryName }
        let other = SavingsPlanner.rows(report: report, bucket: .deleteAndRegenerate).filter {
            !$0.command.hasPrefix("xcodevaultctl clean ") && isOfferedForDeletion($0.categoryID)
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

    /// Re-applies a rescan to a selection: only rows still listed stay selected, so a path that comes back later is not
    /// silently selected again (migration-safety review LOW-1).
    public func retained(_ selection: Set<String>) -> Set<String> {
        selection.intersection(groups.flatMap(\.actions).map(\.id))
    }

    /// `clean` deletes this category through the filesystem: the catalog knows it, allows `.safeCleanup`, names no
    /// Apple tool for it, and it is not non-regenerable. The clean planner's rule, restated as the view's guard.
    static func isDeletableHere(_ categoryID: String) -> Bool {
        guard isOfferedForDeletion(categoryID), let c = StorageCatalog.category(categoryID) else { return false }
        return c.allowedStrategies.contains(.safeCleanup) && c.cleanupCommand == nil
    }

    /// Rule 5 on its own: a known category that is neither Archives nor non-regenerable. Unknown ids fail closed.
    static func isOfferedForDeletion(_ categoryID: String) -> Bool {
        guard categoryID != "archives", let c = StorageCatalog.category(categoryID) else { return false }
        return c.regenerability != .nonRegenerable
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

/// The vault line of the Park view, from `VaultVerifier`'s checks: none registered, the first usable one, one that is
/// there but not usable, or every one unplugged.
public enum VaultStatus: Sendable, Equatable {
    case noVault
    /// Every registered vault is absent: unplugged.
    case offline
    /// Not absent, not usable (foreign, ambiguous, sentinel missing): connecting it again will not help; `doctor` says why.
    case needsAttention(volumeName: String)
    case ready(volumeName: String)

    public static func make(_ checks: [VaultVolumeCheck]) -> VaultStatus {
        if checks.isEmpty { return .noVault }
        if let usable = checks.first(where: \.isUsable) { return .ready(volumeName: usable.volume.volumeName) }
        if let odd = checks.first(where: { $0.state != .absent }) { return .needsAttention(volumeName: odd.volume.volumeName) }
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

/// The Delete screen's one notes panel below the table (R1): the planner's warnings, the root rows the helper acts on, the
/// rows another tool deletes, and what the planner skipped. The helper's access row is not a note: it stays above the
/// table, where access is asked for (spec §6.3). Folded by default so the table
/// keeps the window's height; open from the start only when the table is empty, when the notes are all there is.
public struct DeleteNotes: Sendable, Equatable {
    /// How many notes the panel holds: one per warning, root row, other-tool row and skipped line.
    public let count: Int
    /// The planner's warnings among them (a full rebuild, a re-copy, a root-only row): the panel's label names them, so a
    /// folded panel never hides that there are warnings inside.
    public let warningCount: Int
    public let startsExpanded: Bool
    /// Nothing to note: the screen shows no panel.
    public var isEmpty: Bool { count == 0 }
    /// The notes that are not warnings.
    public var otherCount: Int { count - warningCount }

    /// What the panel's label says: the plain count when there is no warning, else the warnings first.
    public enum Title: Sendable, Equatable {
        case notes(Int)
        case warnings(Int)
        case warningsAndMore(warnings: Int, more: Int)
    }

    public var title: Title {
        if warningCount == 0 { return .notes(count) }
        return otherCount == 0 ? .warnings(warningCount) : .warningsAndMore(warnings: warningCount, more: otherCount)
    }

    public static func make(plan: CleanPlan, list: DeleteList) -> DeleteNotes {
        let root = plan.actions.filter { $0.privilegedAction != nil }.count
        let count = plan.warnings.count + root + list.otherTools.count + plan.skipped.count
        return DeleteNotes(count: count, warningCount: plan.warnings.count, startsExpanded: count > 0 && list.groups.isEmpty)
    }
}
