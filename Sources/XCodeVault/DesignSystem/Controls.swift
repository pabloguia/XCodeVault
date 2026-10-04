import Accessibility
import SwiftUI
import XCodeVaultCore

// Buttons, notices and the sheet footer (docs/design/DESIGN_SYSTEM.md §3.1, §3.5, §3.7; R7-B). Only things you can click
// look clickable, and everything that looks clickable is.

/// A secondary action, or the one primary action of an object row (a drive in Drives): bordered, or bordered and
/// prominent. Set explicitly in `List` and `Form` rows, where the automatic style renders as a grey fill that reads like
/// a tag (the root cause of the user's screenshot 17).
struct ActionButtonStyle: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

extension View {
    /// `ActionButtonStyle`: `.bordered`, or `.borderedProminent` for the surface's (or the object row's) primary action.
    func actionButton(prominent: Bool = false) -> some View { modifier(ActionButtonStyle(prominent: prominent)) }

    /// An icon-only button's hit area: at least 24×24 pt (WCAG 2.5.8).
    func minimumTarget() -> some View {
        frame(minWidth: Tokens.minimumTarget, minHeight: Tokens.minimumTarget).contentShape(Rectangle())
    }
}

/// **Copy Command** everywhere (§3.1, audit row 22): bordered, small, `doc.on.doc`, and a moment of "Copied" after the
/// click, said to VoiceOver too. `a11yName` says whose command it copies when a screen has several.
struct CopyCommandButton: View {
    let copy: @MainActor () -> Void
    var accessibilityLabel: String? = nil
    var title: String = L10n.tr("app.plan.copyCommand")
    @State private var copied = false
    /// Counts the clicks: each one restarts the moment, and nothing outlives the view.
    @State private var copies = 0

    var body: some View {
        Button {
            copy()
            copied = true
            copies += 1
            AccessibilityNotification.Announcement(L10n.tr("app.plan.copied")).post()
        } label: {
            Label(copied ? L10n.tr("app.plan.copied") : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .accessibilityLabel(Text(verbatim: accessibilityLabel ?? title))
        .task(id: copies) {
            guard copies > 0 else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }  // cancelled: a newer click, or the view went away
            copied = false
        }
    }
}

/// A notice (§3.5): a status line, its detail wrapping under it, and its actions as small bordered buttons. Text never has
/// a line limit; a notice that gates a decision is never folded or clipped.
struct NoticeRow<Actions: View>: View {
    let kind: StatusKind
    let title: String
    var detail: String? = nil
    @ViewBuilder var actions: () -> Actions

    init(_ kind: StatusKind, _ title: String, detail: String? = nil, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label {
                InlineCodeText(title).foregroundStyle(kind.textIsSecondary ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
            } icon: {
                StatusIcon(kind)
            }
            .font(.callout)
            .bold(detail != nil)
            if let detail {
                InlineCodeText(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
            HStack(spacing: Spacing.s) { actions() }.buttonStyle(.bordered).controlSize(.small).padding(.leading, 28)
        }
    }
}

/// A sheet's layout (§3.7): the content scrolls, with its scroller shown, so a long review is never clipped; a divider marks
/// the boundary; the footer is always visible — the reason the primary is disabled (or tertiary actions) on the leading
/// side, then Cancel, then the primary, rightmost.
struct SheetFooter<Leading: View, Trailing: View>: View {
    /// Why the primary is disabled, in visible text: never only a tooltip. Nil when it is enabled.
    var reason: String? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(reason: String? = nil, @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.reason = reason
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            if let reason {
                Text(verbatim: reason).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            leading()
            Spacer(minLength: Spacing.m)
            trailing()
        }
    }
}
