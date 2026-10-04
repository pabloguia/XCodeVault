import AppKit
import SwiftUI
import XCodeVaultCore

// The Details screens' charts (R2; laid out by hand since R7-A). They draw what Core decided (`StorageTable.bucketBars`,
// `SimulatorsChart.bars`, `BarChartLayout`) and hand a click back as the bar's id; what that id filters or selects is
// Core's and the model's (`AppModel.clickStorageBar`, `AppModel.clickSimulatorBar`). Each chart has an equivalent control
// or table beside it, so nothing it shows is reachable only through it.
//
// R7-A (the user's check of R6: "Pa…", "Ke…", "iOS 26…" — "garanta que fiquem por extenso"): Swift Charts drew a category
// label no wider than its bar's band, and cut it. Here every label is spelled out in full at body size in a leading column
// sized to the longest label, wrapping when it is longer than the column; the bar is to its right and its size after it, on
// every row.

/// One bar of a `BarList`: what Core decided, in the words the screen shows.
struct ChartBar: Identifiable, Equatable {
    let id: String
    /// The label, in full: never cut, never shortened (R7-A).
    let label: String
    let bytes: UInt64
    let color: Color
    /// What VoiceOver says before the size: the kind and the label.
    let accessibilityLabel: String
}

/// A list of horizontal bars, largest first as given: the label column, the bar scaled to the largest
/// (`BarChartLayout.fraction`) and the size. A click reports the bar's id and whether ⌘ was held (R5: ⌘-click adds to the
/// Storage filter); the bar under the pointer is solid with its label bold, and the pointer is a pointing hand (R5, HIG
/// review SI3): the chart says it is clickable.
struct BarList<Icon: View>: View {
    let bars: [ChartBar]
    let isFilteredOut: (String) -> Bool
    let icon: (ChartBar) -> Icon
    let click: @MainActor (String?, Bool) -> Void
    /// The cells under the pointer, as "<bar id>|<cell>": a row's two cells report entering and leaving in either order,
    /// so the row is hovered while any of its cells is.
    @State private var pointerCells: Set<String> = []

    init(
        bars: [ChartBar], isFilteredOut: @escaping (String) -> Bool, @ViewBuilder icon: @escaping (ChartBar) -> Icon,
        click: @escaping @MainActor (String?, Bool) -> Void
    ) {
        self.bars = bars
        self.isFilteredOut = isFilteredOut
        self.icon = icon
        self.click = click
    }

    private var hovered: String? { pointerCells.first.map { String($0.prefix { $0 != "|" }) } }

    var body: some View {
        let largest = bars.map(\.bytes).max() ?? 0
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(bars) { bar in
                GridRow(alignment: .center) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        icon(bar).accessibilityHidden(true)
                        Text(verbatim: bar.label).fontWeight(hovered == bar.id ? .semibold : .regular)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: BarChartLayout.labelColumnMaxWidth, alignment: .leading)
                    .modifier(BarInteraction(id: bar.id, cell: "label", pointerCells: $pointerCells, click: click))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: bar.accessibilityLabel))
                    .accessibilityValue(Text(verbatim: ByteCount.format(bar.bytes)))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { click(bar.id, false) }
                    GeometryReader { geometry in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(bar.color)
                                .frame(
                                    width: max(0, geometry.size.width - BarChartLayout.sizeLabelWidth) * BarChartLayout.fraction(bar.bytes, largest: largest),
                                    height: 12)
                            Text(verbatim: ByteCount.format(bar.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        }
                        .frame(maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: BarChartLayout.sizeLabelWidth * 2, minHeight: 18)
                    .opacity(ChartEmphasis.opacity(isHovered: hovered == bar.id, isAnyHovered: hovered != nil, isFilteredOut: isFilteredOut(bar.id)))
                    .modifier(BarInteraction(id: bar.id, cell: "bar", pointerCells: $pointerCells, click: click))
                    .accessibilityHidden(true)
                }
            }
        }
    }
}

/// A cell's click and hover: the click reports the bar with ⌘'s state; the hover marks the row and shows the pointing
/// hand while the pointer is over any cell of any row.
private struct BarInteraction: ViewModifier {
    let id: String
    let cell: String
    @Binding var pointerCells: Set<String>
    let click: @MainActor (String?, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { click(id, NSEvent.modifierFlags.contains(.command)) }
            .onHover { inside in
                let key = id + "|" + cell
                if inside { pointerCells.insert(key) } else { pointerCells.remove(key) }
                (pointerCells.isEmpty ? NSCursor.arrow : NSCursor.pointingHand).set()
            }
    }
}

/// Storage: one bar per bucket with rows, in the bucket's color as a fill, labelled with its symbol and short name, its
/// size after it. The buckets in the filter stay solid while there is a filter; the others fade.
struct StorageBucketChart: View {
    let bars: [StorageTable.BucketBar]
    let selected: Set<SavingsBucket>
    let click: @MainActor (String?, Bool) -> Void

    /// The rows the chart draws: the bucket's short name in full (R7-A).
    static func chartBars(_ bars: [StorageTable.BucketBar]) -> [ChartBar] {
        bars.map { bar in
            ChartBar(
                id: bar.id, label: AppText.bucketShortName(bar.bucket), bytes: bar.bytes, color: bar.bucket.color,
                accessibilityLabel: bar.bucket.localizedTitle)
        }
    }

    var body: some View {
        BarList(
            bars: Self.chartBars(bars),
            isFilteredOut: { id in !selected.isEmpty && !(StorageTable.bucket(forBarID: id).map(selected.contains) ?? false) },
            icon: { bar in
                if let bucket = StorageTable.bucket(forBarID: bar.id) { BucketSymbol(bucket: bucket, decorative: true) }
            },
            click: click
        )
        .help(L10n.tr("app.storage.chart.caption"))
    }
}

/// Simulators: one bar per measured runtime and device, colored by kind, labelled with the kind's symbol and the name in
/// full; the selected rows' bars stay solid while a row is selected. The legend above says which color is which kind, and
/// the symbol says it too: never color alone.
struct SimulatorsChartView: View {
    let bars: [SimulatorBar]
    let selection: Set<String>
    let click: @MainActor (String?, Bool) -> Void

    static func kindTitle(_ kind: SimulatorBar.Kind) -> String {
        switch kind {
        case .runtime: L10n.tr("app.simulators.chart.kind.runtime")
        case .device: L10n.tr("app.simulators.chart.kind.device")
        }
    }

    /// System indigo and teal (BRAND.md: the brand teal is not for light surfaces); the legend and the symbols say the kind.
    static func color(_ kind: SimulatorBar.Kind) -> Color {
        switch kind {
        case .runtime: .indigo
        case .device: .teal
        }
    }

    /// The rows the chart draws: simctl's name in full (R7-A).
    static func chartBars(_ bars: [SimulatorBar]) -> [ChartBar] {
        bars.map { bar in
            ChartBar(
                id: bar.id, label: bar.name, bytes: bar.bytes, color: color(bar.kind), accessibilityLabel: kindTitle(bar.kind) + ", " + bar.name)
        }
    }

    var body: some View {
        let anySelected = bars.contains { selection.contains($0.id) }
        let kinds = Dictionary(bars.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        BarList(
            bars: Self.chartBars(bars), isFilteredOut: { anySelected && !selection.contains($0) },
            icon: { bar in Image(systemName: (kinds[bar.id] ?? .device).symbolName) }, click: click)
    }

    /// The legend: each kind's color beside its symbol and name.
    static var legend: some View {
        HStack(spacing: 12) {
            ForEach(SimulatorBar.Kind.allCases, id: \.self) { kind in
                Label {
                    Text(verbatim: kindTitle(kind))
                } icon: {
                    HStack(spacing: 3) {
                        Circle().fill(color(kind)).frame(width: 8, height: 8)
                        Image(systemName: kind.symbolName)
                    }
                    .accessibilityHidden(true)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
