import SwiftUI
import XCodeVaultCore

/// One `AccessChecklist` row (spec 2026-10-03 §6.3): the need, its status as a symbol and a word (never color alone), one
/// sentence of why in terms of what it holds back, and its one button — or, where there is no button to give, what to do
/// instead. The same view in the Access screen, the Overview's banner and above the Delete table. It decides nothing: the
/// row, its keys and its action are Core's, and the button hands the action to `AppModel.handle(_:)`.
struct AccessRowView: View {
    let row: AccessChecklist.Row
    /// The hint next to the Full Disk Access button, once the user opened the pane from the app (`AppModel.showsAccessHint`,
    /// HIG review A2). Off by default: the banner and Delete's row never show it.
    var showsHint = false
    /// **Relaunch XCodeVault** (R5, H16 verified on 2026-10-04): set only when `AppModel.offersRelaunch` says so — after
    /// the trip to the pane, while this process still lacks Full Disk Access.
    var relaunch: (@MainActor () -> Void)? = nil
    let act: @MainActor (AccessChecklist.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: text(row.titleKey)).font(.headline)
                    Label {
                        Text(verbatim: text(row.statusKey))
                    } icon: {
                        // The status word is next to it: the symbol is not said twice. Only the symbol is tinted (R7-B).
                        StatusIcon(.access(row.state, isNeeded: row.isNeeded), symbol: Self.symbol(for: row))
                    }
                    .font(.callout)
                }
                Spacer(minLength: 8)
                if let key = row.actionKey, let action = row.action, action != .guidanceOnly {
                    Button(text(key)) { act(action) }.actionButton()
                }
                if let relaunch {
                    Button(text(AccessChecklist.Key.fdaActionRelaunch), action: relaunch).actionButton()
                }
            }
            // Full width under the status, not a narrow column beside it (HIG review D5).
            Text(verbatim: text(row.whyKey)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let key = row.actionKey, row.action == .guidanceOnly {
                // What to do instead (spec §6.3), with its commands in monospace; text, never a button.
                // One line; the manual route is its tooltip (HIG review X6).
                InlineCodeText(text(key)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help(row.helpKey.map(text) ?? "")
            }
            // What is left after the button (R4): the user turns the app's switch on in the pane.
            if showsHint, let hint = row.hintKey {
                Label {
                    Text(verbatim: text(hint)).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.point.right").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            if relaunch != nil {
                Label {
                    Text(verbatim: text(AccessChecklist.Key.fdaHintRelaunch)).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.clockwise.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
        }
    }

    private func text(_ key: String) -> String { AppText.access(key, bytes: row.blocksBytes, folders: row.blocksFolders) }

    /// The status symbol: one per state, so a state is never told by color.
    static func symbol(_ state: AccessChecklist.State) -> String {
        switch state {
        case .granted: "checkmark.circle"
        case .missing: "xmark.circle"
        case .awaitingApproval: "clock"
        case .unknown: "questionmark.circle"
        case .unavailableInThisBuild: "minus.circle"
        }
    }

    /// A row's symbol: its state's, except a neutral one when the access is optional (`Row.isNeeded`, HIG review A1) —
    /// an xmark would read as a failure where nothing is missing.
    static func symbol(for row: AccessChecklist.Row) -> String { row.isNeeded ? symbol(row.state) : "circle.dashed" }
}

/// Access (spec §6.3): the checklist, one section per need, each with its one button; the helper, once enabled, can be
/// uninstalled (with a confirmation). The same flows as before (ADR-0007): the Settings pane, a re-check of the probe,
/// the `SMAppService` approval. XCodeVault never asks for the user's password itself.
struct AccessView: View {
    @Bindable var model: AppModel
    @State private var confirmUninstall = false

    /// **Relaunch XCodeVault** for the row that offers it (`AppModel.offersRelaunch`); nil for every other row.
    private func relaunchAction(_ row: AccessChecklist.Row) -> (@MainActor () -> Void)? {
        guard model.offersRelaunch(row) else { return nil }
        let model = self.model
        return { model.relaunch() }
    }

    var body: some View {
        Form {
            ForEach(model.accessRows, id: \.need) { row in
                Section {
                    AccessRowView(row: row, showsHint: model.showsAccessHint(row), relaunch: relaunchAction(row)) {
                        model.handle($0)
                    }
                    if model.offersUninstall(row) {
                        // Opens the confirmation; destructive in role, never the default (R7-B, §3.6).
                        DestructiveButton(L10n.tr("app.permissions.uninstallEllipsis"), symbol: DestructiveSymbol.uninstall) { confirmUninstall = true }
                    }
                }
            }
            Section {
                Text.l10n(L10n.tr("app.permissions.footer")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { model.refreshPermissions() }
        .confirmationDialog(L10n.tr("app.permissions.uninstall.confirm"), isPresented: $confirmUninstall) {
            Button(L10n.tr("app.permissions.uninstall"), role: .destructive) { Task { await model.uninstallHelper() } }  // U10: dialog
        } message: {
            Text.l10n(L10n.tr("app.permissions.uninstall.message"))
        }
    }
}
