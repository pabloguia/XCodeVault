import SwiftUI
import XCodeVaultCore

// Status symbols and labels (docs/design/DESIGN_SYSTEM.md §3.4, R7-B): every symbol–tint pair lives here, and each state of
// the app's domain maps to one kind in a tested function. Never color alone: the symbol stands beside a word, and only the
// symbol is tinted.

/// What a status says, and so which symbol and tint it shows.
enum StatusKind: String, CaseIterable, Sendable {
    case success, warning, blocker, danger, info, neutral

    /// The kind's symbol: always the filled variant, one warning glyph app-wide.
    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocker: "xmark.octagon.fill"
        case .danger: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .neutral: "circle.dashed"
        }
    }

    /// The symbol's tint. System colors, appearance- and contrast-aware.
    var tint: Color {
        switch self {
        case .success: .green
        case .warning: .orange
        case .blocker, .danger: .red
        case .info: .accentColor
        case .neutral: .secondary
        }
    }

    /// Whether the text beside it is secondary: a neutral state is not news.
    var textIsSecondary: Bool { self == .neutral }
}

/// A status symbol, tinted, hidden from VoiceOver: the word beside it says it. `symbol` overrides the kind's own glyph for
/// a neutral state that has its own (a clock while waiting, a drive badge) — the tint is still the kind's.
struct StatusIcon: View {
    let kind: StatusKind
    var symbol: String? = nil

    init(_ kind: StatusKind, symbol: String? = nil) {
        self.kind = kind
        self.symbol = symbol
    }

    var body: some View {
        Image(systemName: symbol ?? kind.symbol).foregroundStyle(kind.tint).accessibilityHidden(true)
    }
}

/// A status symbol and its word. The word is `.primary` (`.secondary` for neutral); only the symbol is tinted.
struct StatusLabel: View {
    let kind: StatusKind
    let text: String
    var symbol: String? = nil

    init(_ kind: StatusKind, _ text: String, symbol: String? = nil) {
        self.kind = kind
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(verbatim: text).foregroundStyle(kind.textIsSecondary ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            StatusIcon(kind, symbol: symbol)
        }
    }
}

// MARK: - The domain's states, as kinds (tested: `DesignSystemTests`)

extension StatusKind {
    /// A doctor finding's severity.
    static func severity(_ s: Finding.Severity) -> StatusKind {
        switch s {
        case .critical: .danger
        case .error: .blocker
        case .warning: .warning
        case .info: .info
        }
    }

    /// A registered vault's verdict on its own Drives row.
    static func vaultVerdict(_ v: DriveRow.VaultVerdict) -> StatusKind {
        switch v {
        case .ready: .success
        case .readyWithWarnings, .needsAttention: .warning
        case .notUsable: .blocker
        }
    }

    /// An external drive's verdict: only a ready vault is news; the others say what can be done, neutrally.
    static func driveVerdict(_ v: DriveVerdict) -> StatusKind { v == .ready ? .success : .neutral }

    /// A registered vault that is not connected, or connected and usable.
    static func offlineVault(_ c: VaultVolumeCheck) -> StatusKind { c.isUsable ? .success : .blocker }

    /// Park's vault line.
    static func vaultStatus(_ s: VaultStatus) -> StatusKind {
        switch s {
        case .ready: .success
        case .needsAttention: .warning
        case .noVault, .offline: .neutral
        }
    }

    /// A History row's state: a failure and an interruption are news; the rest is neutral.
    static func historyOutcome(_ o: JournalTimeline.Outcome) -> StatusKind {
        switch o {
        case .failed: .blocker
        case .interrupted: .warning
        default: .neutral
        }
    }

    /// An access row: granted is good, missing needs the user, the rest waits or does not apply. An access the user does
    /// not need is neutral whatever its state (`AccessChecklist.Row.isNeeded`).
    static func access(_ state: AccessChecklist.State, isNeeded: Bool) -> StatusKind {
        guard isNeeded else { return .neutral }
        switch state {
        case .granted: return .success
        case .missing: return .warning
        case .awaitingApproval, .unknown, .unavailableInThisBuild: return .neutral
        }
    }

    /// A History row's symbol: a failure and an interruption take their status kind's own (filled) symbol, every other
    /// state its own neutral symbol from Core.
    static func historyOutcomeSymbol(_ o: JournalTimeline.Outcome) -> String? { historyOutcome(o) == .neutral ? o.symbolName : nil }

    /// A finished operation: done, or done with a part left over — registered but the standard folders not created.
    static func operationDone(foldersError: String?) -> StatusKind { foldersError == nil ? .success : .warning }

    /// The neutral mark beside a reason a volume does not qualify: not an error, the drive just cannot be a vault as it is.
    static let notQualifyingSymbol = "xmark.octagon"

    /// An action's result banner.
    static func feedback(_ k: AppFeedback.Kind) -> StatusKind { k == .success ? .success : .info }
}
