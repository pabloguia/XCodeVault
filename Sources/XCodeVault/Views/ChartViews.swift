import Charts
import SwiftUI
import XCodeVaultCore

// The Details screens' charts (R2). They draw what Core decided (`StorageTable.bucketBars`, `SimulatorsChart.bars`) and
// hand a click back as the chart's value under the pointer; what that value filters or selects is Core's and the model's
// (`AppModel.clickStorageBar`, `AppModel.clickSimulatorBar`). Each chart has an equivalent table under it, so nothing it
// shows is reachable only through it.

/// Turns a click on a chart into the category under it, read from the plot's y axis: the bar's id, or nil outside the
/// plot. A tap gesture over the plot, not `chartYSelection`, whose value is reset when the gesture ends on macOS.
private struct ChartClick: ViewModifier {
    let click: @MainActor (String?) -> Void

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return click(nil) }
                        let frame = geometry[plot]
                        guard location.y >= frame.minY, location.y <= frame.maxY else { return click(nil) }
                        click(proxy.value(atY: location.y - frame.minY, as: String.self))
                    }
            }
        }
    }
}

/// Storage: one horizontal bar per bucket with rows, in the bucket's color as a fill, labelled with its symbol and title,
/// its size at the end of the bar. The filtered bucket's bar stays solid; the others fade.
struct StorageBucketChart: View {
    let bars: [StorageTable.BucketBar]
    let selected: SavingsBucket?
    let click: @MainActor (String?) -> Void

    var body: some View {
        Chart(bars) { bar in
            BarMark(x: .value(L10n.tr("app.column.size"), Double(bar.bytes)), y: .value(L10n.tr("app.column.bucket"), bar.id))
                .foregroundStyle(bar.bucket.color)
                .opacity(selected == nil || selected == bar.bucket ? 1 : 0.35)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(verbatim: ByteCount.format(bar.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text(verbatim: bar.bucket.localizedTitle))
                .accessibilityValue(Text(verbatim: ByteCount.format(bar.bytes)))
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let bucket = StorageTable.bucket(forBarID: value.as(String.self)) {
                        HStack(spacing: 4) {
                            BucketSymbol(bucket: bucket, decorative: true)
                            Text(verbatim: bucket.localizedTitle).foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) { Text(verbatim: ByteCount.format(UInt64(max(bytes, 0)))) }
                }
            }
        }
        .modifier(ChartClick(click: click))
    }
}

/// Simulators: one horizontal bar per measured runtime and device, colored by kind and labelled with the kind's symbol
/// and the name; the selected row's bar stays solid while a row is selected.
struct SimulatorsChartView: View {
    let bars: [SimulatorBar]
    let selection: SimulatorSelection
    let click: @MainActor (String?) -> Void

    static func kindTitle(_ kind: SimulatorBar.Kind) -> String {
        switch kind {
        case .runtime: L10n.tr("app.simulators.chart.kind.runtime")
        case .device: L10n.tr("app.simulators.chart.kind.device")
        }
    }

    private func isSelected(_ bar: SimulatorBar) -> Bool {
        switch bar.kind {
        case .runtime: selection.runtimeID == bar.rowID
        case .device: selection.deviceID == bar.rowID
        }
    }

    var body: some View {
        let anySelected = bars.contains(where: isSelected)
        let names = Dictionary(bars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        Chart(bars) { bar in
            BarMark(x: .value(L10n.tr("app.column.size"), Double(bar.bytes)), y: .value(L10n.tr("app.column.name"), bar.id))
                .foregroundStyle(by: .value(L10n.tr("app.simulators.chart.kind"), Self.kindTitle(bar.kind)))
                .opacity(!anySelected || isSelected(bar) ? 1 : 0.35)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(verbatim: ByteCount.format(bar.bytes)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text(verbatim: Self.kindTitle(bar.kind) + ", " + bar.name))
                .accessibilityValue(Text(verbatim: ByteCount.format(bar.bytes)))
        }
        .chartForegroundStyleScale([Self.kindTitle(.runtime): Color.indigo, Self.kindTitle(.device): Color.teal])
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let id = value.as(String.self), let bar = names[id] {
                        HStack(spacing: 4) {
                            Image(systemName: bar.symbolName).accessibilityHidden(true)
                            Text(verbatim: bar.name)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) { Text(verbatim: ByteCount.format(UInt64(max(bytes, 0)))) }
                }
            }
        }
        .modifier(ChartClick(click: click))
    }
}
