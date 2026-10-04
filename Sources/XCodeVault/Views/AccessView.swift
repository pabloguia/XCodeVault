import SwiftUI
import XCodeVaultCore

/// One `AccessChecklist` row (spec 2026-10-03 §6.3): the need, its status as a symbol and a word (never color alone), one
/// sentence of why in terms of what it holds back, and its one button — or, where there is no button to give, what to do
/// instead. The same view in the Access screen, the Overview's banner and above the Delete table. It decides nothing: the
/// row, its keys and its action are Core's, and the button hands the action to `AppModel.handle(_:)`.
struct AccessRowView: View {
    let row: AccessChecklist.Row
    let act: @MainActor (AccessChecklist.Action) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: text(row.titleKey)).bold()
                Label {
                    Text(verbatim: text(row.statusKey))
                } icon: {
                    // The status word is next to it: the symbol is not said twice.
                    Image(systemName: Self.symbol(row.state)).accessibilityHidden(true)
                }
                .font(.callout)
                Text(verbatim: text(row.whyKey)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let key = row.actionKey, let action = row.action {
                if action == .guidanceOnly {
                    // What to do instead (spec §6.3), with its commands in monospace; text, never a button.
                    InlineCodeText(text(key)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 300, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button(text(key)) { act(action) }
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
}

/// Access (spec §6.3): the checklist, one section per need, each with its one button; the helper, once enabled, can be
/// uninstalled (with a confirmation). The same flows as before (ADR-0007): the Settings pane, a re-check of the probe,
/// the `SMAppService` approval. XCodeVault never asks for the user's password itself.
struct AccessView: View {
    @Bindable var model: AppModel
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            ForEach(model.accessRows, id: \.need) { row in
                Section {
                    AccessRowView(row: row) { model.handle($0) }
                    if model.offersUninstall(row) {
                        Button(L10n.tr("app.permissions.uninstallEllipsis")) { confirmUninstall = true }
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
            Button(L10n.tr("app.permissions.uninstall"), role: .destructive) { Task { await model.uninstallHelper() } }
        } message: {
            Text.l10n(L10n.tr("app.permissions.uninstall.message"))
        }
    }
}
