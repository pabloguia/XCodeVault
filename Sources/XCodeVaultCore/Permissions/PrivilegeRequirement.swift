/// What a privileged action needs, stated once so the CLI tag, the GUI column, the executor's refusal
/// and the permissions texts cannot drift apart (spec §2; the rule moved here from `CleanAction`, a942c02).
public enum PrivilegeRequirement: String, Sendable, Codable, CaseIterable {
    /// Root, reached only through the privileged helper's allowlisted verbs.
    case helper
    /// Root inside `Caches/dyld`, where root itself was refused without Full Disk Access (H15). Whether the
    /// helper — a launchd daemon, a different TCC context from a granted terminal — has that access is
    /// unmeasured until its first live run (#30).
    case helperWithFullDiskAccess
    /// Full Disk Access for XCodeVault itself: reading what macOS privacy protection hides from it.
    case appFullDiskAccess

    /// The one path H15's Full Disk Access finding was measured on. Mirrors
    /// `HelperCleanupTarget.coreSimulatorDyldCache.path`, which this module cannot see;
    /// `HelperContractTests` holds the two equal.
    public static let coreSimulatorDyldCachePath = "/Library/Developer/CoreSimulator/Caches/dyld"

    /// The requirement of a root-owned path. Full Disk Access is named for the dyld cache and what is
    /// inside it only: a sibling that shares the prefix string, or another root path — the Inbox
    /// included, whose refusal was never re-tested with the grant (F1) — must not inherit a requirement
    /// nobody measured for it.
    public static func forRootPath(_ path: String) -> PrivilegeRequirement {
        let dyld = coreSimulatorDyldCachePath
        return (path == dyld || path.hasPrefix(dyld + "/")) ? .helperWithFullDiskAccess : .helper
    }

    /// The short tag for lists, in English (Core prose, the clean plan); a screen uses `label(in: L10n.locale)`.
    public var label: String { label(in: L10n.baseLocale) }
    /// One sentence of why, in English; a screen uses `why(in: L10n.locale)`.
    public var why: String { why(in: L10n.baseLocale) }

    public func label(in locale: String) -> String {
        switch self {
        case .helper: return L10n.tr("perm.requirement.helper.label", locale: locale)
        case .helperWithFullDiskAccess: return L10n.tr("perm.requirement.helperWithFullDiskAccess.label", locale: locale)
        case .appFullDiskAccess: return L10n.tr("perm.requirement.appFullDiskAccess.label", locale: locale)
        }
    }

    public func why(in locale: String) -> String {
        switch self {
        case .helper: return L10n.tr("perm.requirement.helper.why", locale: locale)
        case .helperWithFullDiskAccess: return L10n.tr("perm.requirement.helperWithFullDiskAccess.why", locale: locale)
        case .appFullDiskAccess: return L10n.tr("perm.requirement.appFullDiskAccess.why", locale: locale)
        }
    }
}

/// A privileged step the product can offer as a button instead of a command to paste (spec §2). The text
/// remediation always stays beside it as the fallback: this is an addition, never a replacement.
public enum PrivilegedAction: Sendable, Codable, Hashable {
    /// The helper's `createVaultDirectory(volumeUUID:)`: creates `<mount>/XCodeVault` owned by the caller.
    /// The helper resolves the UUID to a mount point itself; no path crosses the wire.
    case createVaultDirectory(volumeUUID: String)
    /// The helper's `removeRegenerableSystemDirectoryContents(coreSimulatorDyldCache)`: empties `Caches/dyld`,
    /// leaving the directory itself (operator decision 2026-09-27). Experimental: what rebuilds a deleted cache
    /// is not identified (H14).
    case emptyCoreSimulatorDyldCache

    public var requirement: PrivilegeRequirement {
        switch self {
        case .createVaultDirectory: return .helper
        case .emptyCoreSimulatorDyldCache: return .helperWithFullDiskAccess
        }
    }

    /// The button's title. The cache's says experimental in the title itself (rule 10): the title is what the
    /// helper's sheet and the confirmation lead with. The plain property is English: the journal records it.
    public var title: String { title(in: L10n.baseLocale) }

    public func title(in locale: String) -> String {
        switch self {
        case .createVaultDirectory: return L10n.tr("perm.action.createVaultDirectory.title", locale: locale)
        case .emptyCoreSimulatorDyldCache: return L10n.tr("perm.action.emptyCoreSimulatorDyldCache.title", locale: locale)
        }
    }

    /// What is left to do after the helper reports success, shown with its reply; nil when nothing is. The vault
    /// folder is only the step `vault init` could not take: registering the vault is still `vault init`'s, as the
    /// finding's own remediation says.
    public var afterSuccess: String? { afterSuccess(in: L10n.baseLocale) }

    public func afterSuccess(in locale: String) -> String? {
        switch self {
        case .createVaultDirectory: return L10n.tr("perm.action.createVaultDirectory.afterSuccess", locale: locale)
        case .emptyCoreSimulatorDyldCache: return nil
        }
    }

    /// Only the cache is in use while Xcode or a simulator runs; the runner refuses it then.
    var usesTheSimulatorCaches: Bool {
        if case .emptyCoreSimulatorDyldCache = self { return true }
        return false
    }

    /// The cache is cleanup, and opens `.started` so a crash mid-call shows as an interrupted clean. The vault
    /// folder is recorded like `vault init`'s own records, and opens `.planned` so it is never listed as an
    /// interrupted migration with `migration abort` suggested for it.
    var journalKind: JournalEntry.Kind {
        switch self {
        case .createVaultDirectory: return .migration
        case .emptyCoreSimulatorDyldCache: return .clean
        }
    }

    var openingState: JournalEntry.State {
        switch self {
        case .createVaultDirectory: return .planned
        case .emptyCoreSimulatorDyldCache: return .started
        }
    }

    var journalPaths: [String] {
        switch self {
        case .createVaultDirectory: return []
        case .emptyCoreSimulatorDyldCache: return [PrivilegeRequirement.coreSimulatorDyldCachePath]
        }
    }

    var journalDetail: [String: String] {
        switch self {
        case .createVaultDirectory(let volumeUUID): return [VaultDirectoryRefusal.volumeUUIDKey: volumeUUID]
        case .emptyCoreSimulatorDyldCache: return [:]
        }
    }
}
