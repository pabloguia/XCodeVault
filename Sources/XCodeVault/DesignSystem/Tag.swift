import SwiftUI
import XCodeVaultCore

/// Metadata about a row, a sheet or a drive (docs/design/DESIGN_SYSTEM.md §3.2, R7-B). Not a control: no container, no
/// background, no hover, no pointer, not focusable — so it never looks like a button. The symbol may be tinted; the text is
/// always `.secondary`.
struct Tag: View {
    let text: String
    let symbol: String
    var tint: Color? = nil
    var help: String? = nil

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint ?? .secondary)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .help(help ?? text)
    }
}

extension Tag {
    /// A savings marker in Core's words (`SavingsMarker`). **Experimental** is always this: the word and `flask`, wherever
    /// a strategy is experimental (rule 10).
    static func marker(_ m: SavingsMarker) -> Tag {
        Tag(text: AppText.marker(m), symbol: symbol(m), tint: m == .losesUserData ? StatusKind.warning.tint : nil)
    }

    static func symbol(_ marker: SavingsMarker) -> String {
        switch marker {
        case .experimental: "flask"
        case .losesUserData: "exclamationmark.triangle.fill"
        case .actsImmediately: "bolt"
        case .newDataOnly: "arrow.forward.circle"
        case .perItem: "number"
        case .needsRoot: "lock"
        }
    }

    /// A History operation's kind: its symbol in its color (Brand.swift) and its short name.
    static func historyKind(_ k: JournalTimeline.Kind) -> Tag { Tag(text: AppText.historyKind(k), symbol: k.symbolName, tint: k.color) }
}

/// A row's markers, in Core's order, as tags on one line.
struct MarkerTags: View {
    let markers: [SavingsMarker]
    var body: some View {
        HStack(spacing: Spacing.s) {
            ForEach(Array(markers.enumerated()), id: \.offset) { _, m in Tag.marker(m) }
        }
    }
}
