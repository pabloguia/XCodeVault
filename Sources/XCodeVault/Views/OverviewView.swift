import AppKit
import SwiftUI
import XCodeVaultCore

/// The Overview (spec 2026-10-03 §6.2): the disk bar, three cards — Temporary (delete), Temporary (park), Permanent
/// (run externally) — the note that they are alternatives with the union total, at most one access banner and the
/// critical findings. Every number comes from Core (`OverviewCards`, `DiskBar`, `AccessChecklist.banner`); this only
/// draws them.
struct OverviewView: View {
    let report: ScanReport
    let findings: [Finding]
    /// `AppModel.accessBanner`.
    let access: AccessChecklist.Row?
    var act: @MainActor (AccessChecklist.Action) -> Void = { _ in }
    var review: @MainActor (SavingsBucket) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text.l10n(
                    L10n.tr(
                        "app.overview.host", report.host.macOSVersion, report.host.architecture, ByteCount.format(report.host.dataVolumeFreeBytes),
                        ByteCount.format(report.host.dataVolumeTotalBytes))
                ).font(.headline)
                if let access { AccessBannerView(row: access, act: act) }
                if report.sizesMeasured {
                    DiskBarView(bar: DiskBar(host: report.host, savings: report.savings))
                    savings(OverviewCards.make(savings: report.savings))
                } else {
                    // `scan --no-sizes` has no GUI equivalent, but a stored report can lack sizes: say so, show no zeros.
                    Label {
                        Text.l10n(L10n.tr("app.overview.notMeasured"))
                    } icon: {
                        Image(systemName: "ruler")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                if !report.warnings.isEmpty {
                    GroupBox(L10n.tr("app.overview.warnings.title")) {
                        VStack(alignment: .leading) {
                            ForEach(report.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        }
                    }
                }
                let critical = findings.filter { $0.severity >= .error }
                if !critical.isEmpty {
                    GroupBox(L10n.plural("app.overview.doctor.issues", count: critical.count)) {
                        VStack(alignment: .leading) {
                            ForEach(critical) { Text.l10n(L10n.tr("app.overview.doctor.issue", AppText.severity($0.severity), $0.title)) }
                        }
                    }
                }
                Text.l10n(L10n.tr("app.overview.footer")).font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
    }

    @ViewBuilder
    private func savings(_ overview: OverviewCards) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(overview.cards, id: \.bucket) { card in
                OverviewCardView(card: card, isLowerBound: overview.isLowerBound) { review(card.bucket) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)  // one height for the three cards
        VStack(alignment: .leading, spacing: 4) {
            Text.l10n(L10n.tr("app.overview.total", Self.amount(overview.reclaimableBytes, lowerBound: overview.isLowerBound))).bold()
            Text.l10n(L10n.tr("savings.alternativesNote")).font(.callout).foregroundStyle(.secondary)
            if report.summary.runtimeImageBytes > 0 {
                // The runtime `.dmg` store is not a catalog category yet (S3 C5): its own line, as `scan` prints it.
                Text.l10n(L10n.tr("app.overview.runtimes", ByteCount.format(report.summary.runtimeImageBytes)))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// "up to X", or "at least X" when something counted could not be fully read.
    static func amount(_ bytes: UInt64, lowerBound: Bool) -> String {
        let formatted = ByteCount.format(bytes)
        return lowerBound ? L10n.tr("savings.atLeast", formatted) : L10n.tr("savings.upTo", formatted)
    }
}

/// One card: the bucket's symbol, color and title, its "up to" amount, the verified share, the promise and the cost to
/// undo, and **Review**.
struct OverviewCardView: View {
    let card: OverviewCards.Card
    let isLowerBound: Bool
    let review: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BucketSymbol(bucket: card.bucket).font(.title3)
                Text.l10n(card.isPermanent ? L10n.tr("savings.permanent.title") : L10n.tr("savings.temporary.title"))
                    .font(.caption).bold().foregroundStyle(.secondary)
            }
            Text(verbatim: card.bucket.localizedTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
            if card.bytes == 0 && !isLowerBound {
                Text.l10n(L10n.tr("app.overview.card.nothing")).font(.title3).foregroundStyle(.secondary)
            } else {
                Text(verbatim: OverviewView.amount(card.bytes, lowerBound: isLowerBound)).font(.title2).bold().monospacedDigit()
                Text.l10n(
                    card.verifiedBytes >= card.bytes
                        ? L10n.tr("app.overview.card.allVerified") : L10n.tr("savings.verifiedShare", ByteCount.format(card.verifiedBytes))
                ).font(.caption).foregroundStyle(.secondary)
            }
            if let lossy = card.losesUserDataBytes {
                // The Temporary headline is not all recoverable (S3 review): what deleting loses for good, on the card.
                Label {
                    Text.l10n(L10n.tr("app.overview.card.losesUserData", ByteCount.format(lossy))).font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
            Text(verbatim: card.bucket.localizedPromise).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: card.bucket.localizedUndoCost).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L10n.tr("app.overview.card.review"), action: review)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .top) {
            // The bucket color as a fill, never as text.
            UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10).fill(card.bucket.color).frame(height: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// The internal disk as one horizontal bar: other data, developer data by primary bucket, free — and a legend that
/// names every segment with a symbol, a title and a size, so no segment is told by color alone.
struct DiskBarView: View {
    let bar: DiskBar

    var body: some View {
        let total = max(bar.segments.reduce(UInt64(0)) { $0 + $1.bytes }, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(Array(bar.segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle().fill(Self.fill(segment.kind))
                            .frame(width: max(geometry.size.width * Double(segment.bytes) / Double(total) - 1, 0))
                    }
                }
            }
            .frame(height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            // The legend says the same thing in words.
            .accessibilityHidden(true)
            HStack(spacing: 14) {
                ForEach(Array(bar.segments.enumerated()), id: \.offset) { _, segment in legendItem(segment) }
            }
            .font(.caption)
            if bar.isClamped {
                Text.l10n(L10n.tr("app.overview.bar.clamped")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func legendItem(_ segment: DiskBar.Segment) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(Self.fill(segment.kind)).frame(width: 10, height: 10).accessibilityHidden(true)
            switch segment.kind {
            case .bucket(let bucket): BucketSymbol(bucket: bucket)
            case .otherData: Image(systemName: "doc.on.doc").foregroundStyle(.secondary).accessibilityHidden(true)
            case .free: Image(systemName: "circle.dashed").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(verbatim: Self.title(segment.kind))
            Text(verbatim: ByteCount.format(segment.bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func title(_ kind: DiskBar.Kind) -> String {
        switch kind {
        case .bucket(let bucket): bucket.localizedTitle
        case .otherData: L10n.tr("app.overview.bar.other")
        case .free: L10n.tr("app.overview.bar.free")
        }
    }

    /// Buckets in their color; other data neutral; free space light.
    static func fill(_ kind: DiskBar.Kind) -> Color {
        switch kind {
        case .bucket(let bucket): bucket.color
        case .otherData: Color(nsColor: .systemGray).opacity(0.55)
        case .free: Color(nsColor: .quaternaryLabelColor)
        }
    }
}

/// The one access row the Overview shows: what it holds back, and its one button (or what to do instead).
struct AccessBannerView: View {
    let row: AccessChecklist.Row
    let act: @MainActor (AccessChecklist.Action) -> Void

    var body: some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text.l10n(row.need == .fullDiskAccess ? L10n.tr("perm.fda.title") : L10n.tr("perm.helper.title")).bold()
                        Text(verbatim: AppText.access(row.whyKey, bytes: row.blocksBytes, folders: row.blocksFolders)).font(.callout)
                    }
                } icon: {
                    Image(systemName: "lock")
                }
                Spacer()
                if let key = row.actionKey, let action = row.action {
                    let text = AppText.access(key, bytes: row.blocksBytes, folders: row.blocksFolders)
                    if action == .guidanceOnly {
                        Text(verbatim: text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 280, alignment: .trailing)
                    } else {
                        Button(text) { act(action) }
                    }
                }
            }
        }
    }
}
