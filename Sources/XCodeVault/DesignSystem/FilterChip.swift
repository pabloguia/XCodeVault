import SwiftUI
import XCodeVaultCore

/// A toggleable filter (docs/design/DESIGN_SYSTEM.md §3.3, R7-B): the Storage legend. Distinct from a button — a capsule
/// outline and a checkmark when on — and from a tag, which has no container. Selected is a light accent fill under an
/// accent stroke with the checkmark, never a solid accent fill (that is the prominent button's).
struct FilterChipStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { FilterChip(configuration: configuration) }
}

private struct FilterChip: View {
    let configuration: ToggleStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Spacing.xs) {
                // Reserves its width when off, so turning a chip on does not move its neighbours.
                Image(systemName: "checkmark").opacity(configuration.isOn ? 1 : 0).accessibilityHidden(true)
                configuration.label
            }
            .font(.callout)
            .padding(.horizontal, Spacing.s + 2)
            .frame(minHeight: Tokens.minimumTarget)
            .background(FilterChip.fill(isOn: configuration.isOn, hovering: hovering), in: Capsule())
            // A capsule's outline as a rounded rectangle of half the chip's height: `Capsule().strokeBorder` drew stray
            // vertical segments at its ends when rendered off-screen (the R7-B gallery). Same shape, clean edges.
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.minimumTarget / 2, style: .circular)
                    .strokeBorder(configuration.isOn ? Tokens.chipSelectedStroke : Tokens.chipStroke, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && isEnabled }
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(verbatim: configuration.isOn ? L10n.tr("app.a11y.on") : L10n.tr("app.a11y.off")))
    }

    static func fill(isOn: Bool, hovering: Bool) -> Color {
        if isOn { return Tokens.chipSelectedFill }
        return hovering ? Tokens.chipHoverFill : .clear
    }
}
