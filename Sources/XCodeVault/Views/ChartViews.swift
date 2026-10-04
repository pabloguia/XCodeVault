import AppKit
import Charts
import SwiftUI
import XCodeVaultCore

// The Details screens' charts (R2). They draw what Core decided (`StorageTable.bucketBars`, `SimulatorsChart.bars`) and
// hand a click back as the chart's value under the pointer; what that value filters or selects is Core's and the model's
// (`AppModel.clickStorageBar`, `AppModel.clickSimulatorBar`). Each chart has an equivalent control or table beside it, so
// nothing it shows is reachable only through it.

/// Turns a click on a chart into the category under it, read from the plot's y axis: the bar's id, or nil outside the
/// plot, and whether ⌘ was held (R5: ⌘-click adds to the Storage filter). A tap gesture over the plot, not
/// `chartYSelection`, whose value is reset when the gesture ends on macOS. While the pointer is over a bar it reports the
/// bar for a hover highlight and shows the pointing hand (R5, HIG review SI3, the user's feedback): the chart says it is
/// clickable.
private struct ChartClick: ViewModifier {
    let click: @MainActor (String?, Bool) -> Void
    let hover: @MainActor (String?) -> Void

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        click(Self.value(at: location, proxy: proxy, geometry: geometry), NSEvent.modifierFlags.contains(.command))
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let id = Self.value(at: location, proxy: proxy, geometry: geometry)
                            hover(id)
                            (id == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
                        case .ended:
                            hover(nil)
                            NSCursor.arrow.set()
                        }
                    }
            }
        }
    }

    /// The bar's id under `location`; nil outside the plot (`ChartHit`, in Core).
    @MainActor
    static func value(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        guard let y = ChartHit.plotY(clickY: location.y, plotMinY: frame.minY, plotMaxY: frame.maxY) else { return nil }
        return proxy.value(atY: y, as: String.self)
    }
}

/// A bar's opacity: the bar under the pointer solid, the others a little lighter while one is hovered, and those outside
/// the filter or selection faded (the hover highlight, R5).
private func barOpacity(isHovered: Bool, isAnyHovered: Bool, isFilteredOut: Bool) -> Double {
    if isHovered { return 1 }
    if isFilteredOut { return 0.35 }
    return isAnyHovered ? 0.7 : 1
}

/// An axis label for a size: "0" at the origin rather than "0 bytes" (R5, HIG review C2).
private func axisSize(_ bytes: Double) -> String { bytes <= 0 ? "0" : ByteCount.format(UInt64(bytes)) }

/// Storage: one horizontal bar per bucket with rows, in the bucket's color as a fill, labelled on the leading axis with its
/// symbol and short name, its size at the end of the bar. The buckets in the filter stay solid while there is a filter; the
/// others fade. The bar under the pointer is solid and its label bold.
struct StorageBucketChart: View {
    let bars: [StorageTable.BucketBar]
    let selected: Set<SavingsBucket>
    let click: @MainActor (String?, Bool) -> Void
    @State private var hovered: String?

    var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value(L10n.tr("app.column.size"), Double(bar.bytes)), y: .value(L10n.tr("app.column.bucket"), bar.id))
                .foregroundStyle(bar.bucket.color)
                .opacity(
                    barOpacity(
                        isHovered: hovered == bar.id, isAnyHovered: hovered != nil, isFilteredOut: !selected.isEmpty && !selected.contains(bar.bucket))
                )
                .annotation(position: .trailing, alignment: .leading) {
                    Text(verbatim: ByteCount.format(bar.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text(verbatim: bar.bucket.localizedTitle))
                .accessibilityValue(Text(verbatim: ByteCount.format(bar.bytes)))
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let bucket = StorageTable.bucket(forBarID: value.as(String.self)) {
                        HStack(spacing: 4) {
                            BucketSymbol(bucket: bucket, decorative: true)
                            Text(verbatim: AppText.bucketShortName(bucket)).foregroundStyle(.primary)
                        }
                        .fontWeight(hovered == bucket.rawValue ? .semibold : .regular)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) { Text(verbatim: axisSize(bytes)) }
                }
            }
        }
        .modifier(ChartClick(click: click, hover: { hovered = $0 }))
        .help(L10n.tr("app.storage.chart.caption"))
    }
}

/// Simulators: one horizontal bar per measured runtime and device, colored by kind and labelled with the kind's symbol
/// and the name; the selected rows' bars stay solid while a row is selected, and the bar under the pointer is bold in its
/// label.
struct SimulatorsChartView: View {
    let bars: [SimulatorBar]
    let selection: Set<String>
    let click: @MainActor (String?, Bool) -> Void
    @State private var hovered: String?

    static func kindTitle(_ kind: SimulatorBar.Kind) -> String {
        switch kind {
        case .runtime: L10n.tr("app.simulators.chart.kind.runtime")
        case .device: L10n.tr("app.simulators.chart.kind.device")
        }
    }

    var body: some View {
        let anySelected = bars.contains { selection.contains($0.id) }
        let names = Dictionary(bars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        Chart(bars) { bar in
            BarMark(x: .value(L10n.tr("app.column.size"), Double(bar.bytes)), y: .value(L10n.tr("app.column.name"), bar.id))
                .foregroundStyle(by: .value(L10n.tr("app.simulators.chart.kind"), Self.kindTitle(bar.kind)))
                .opacity(barOpacity(isHovered: hovered == bar.id, isAnyHovered: hovered != nil, isFilteredOut: anySelected && !selection.contains(bar.id)))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(verbatim: ByteCount.format(bar.bytes)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text(verbatim: Self.kindTitle(bar.kind) + ", " + bar.name))
                .accessibilityValue(Text(verbatim: ByteCount.format(bar.bytes)))
        }
        // System indigo and teal (BRAND.md: the brand teal is not for light surfaces); the legend and the symbols say the kind.
        .chartForegroundStyleScale([Self.kindTitle(.runtime): Color.indigo, Self.kindTitle(.device): Color.teal])
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let id = value.as(String.self), let bar = names[id] {
                        HStack(spacing: 4) {
                            Image(systemName: bar.symbolName).accessibilityHidden(true)
                            Text(verbatim: bar.name)
                        }
                        .foregroundStyle(.primary)
                        .fontWeight(hovered == id ? .semibold : .regular)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) { Text(verbatim: axisSize(bytes)) }
                }
            }
        }
        .modifier(ChartClick(click: click, hover: { hovered = $0 }))
    }
}
