import SwiftUI
import XCodeVaultCore

/// ADR-0015: what the vault folder's field shows and changes. Supplied by `AppModel`; empty by default, for renders.
struct VaultFolderField {
    var name: String = VaultFolderName.suggested
    var message: String?
    var set: @MainActor (String) -> Void = { _ in }
}

/// The words the field uses for a name that cannot be a folder's.
enum VaultFolderText {
    static func message(_ problem: VaultFolderName.Problem) -> String {
        switch problem {
        case .empty: L10n.tr("app.vaultFolder.problem.empty")
        case .notOneFolder: L10n.tr("app.vaultFolder.problem.notOneFolder")
        case .dotName: L10n.tr("app.vaultFolder.problem.dotName")
        case .tooLong: L10n.tr("app.vaultFolder.problem.tooLong")
        case .hiddenSystemName: L10n.tr("app.vaultFolder.problem.hiddenSystemName")
        }
    }
}

/// The vault folder's name, one per Mac on a drive: suggested, editable, checked as it is typed.
struct VaultFolderNameField: View {
    let field: VaultFolderField

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text.l10n(L10n.tr("app.vaultFolder.label")).foregroundStyle(.secondary)
                TextField(L10n.tr("app.vaultFolder.label"), text: Binding(get: { field.name }, set: { field.set($0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            if let message = field.message {
                StatusLabel(.warning, message).font(.callout)
            } else {
                Text.l10n(L10n.tr("app.vaultFolder.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
