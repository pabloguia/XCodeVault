import AppKit
import SwiftUI
import XCodeVaultCore

/// The Overview (spec 2026-10-03 §6.2): the disk bar, three cards — Delete and Park (the space comes back), Run
/// Externally (the space stays free) — the note that they are alternatives with the union total, at most one access banner and the
/// critical findings. Every number comes from Core (`OverviewCards`, `DiskBar`, `AccessChecklist.banner`); this only
/// draws them.
struct OverviewView: View {
    let report: ScanReport
    let findings: [Finding]
    /// `AppModel.accessBanner`.
    let access: AccessChecklist.Row?
    var act: @MainActor (AccessChecklist.Action) -> Void = { _ in }
    var review: @MainActor (SavingsBucket) -> Void = { _ in }
    /// **Show in Health** beside the critical findings (R5, HIG review O4).
    var showHealth: @MainActor () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The host line is the window's subtitle (HIG review N2): what can be reclaimed comes first.
                if let access { GroupBox { AccessRowView(row: access, act: act) } }
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
                            // Primary text; only the symbol is tinted (HIG review O3).
                            ForEach(report.warnings, id: \.self) { warning in
                                StatusLabel(.warning, warning)
                            }
                        }
                    }
                }
                let critical = findings.filter { $0.severity >= .error }
                if !critical.isEmpty {
                    // Health, as the sidebar calls it, with a way to go there; each severity as its symbol (HIG review O4).
                    GroupBox(L10n.plural("app.overview.doctor.issues", count: critical.count)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(critical) { finding in
                                // The severity's word is not shown beside the title: VoiceOver hears it with the title.
                                StatusLabel(.severity(finding.severity), finding.title)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(Text(verbatim: AppText.severity(finding.severity) + ", " + finding.title))
                            }
                            // Navigation inside a notice: a link (R7-B, §3.1).
                            Button(L10n.tr("app.overview.showInHealth"), action: showHealth).buttonStyle(.link)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                OverviewCardView(card: card) { review(card.bucket) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)  // one height for the three cards
        VStack(alignment: .leading, spacing: 4) {
            Text.l10n(L10n.tr("app.overview.total", Self.text(overview.total))).bold()
            Text.l10n(L10n.tr("savings.alternativesNote")).font(.callout).foregroundStyle(.secondary)
            // The runtime `.dmg` store is not a catalog category yet (S3 C5): its own line, as `scan` prints it. The same
            // number as the Simulators screen's (`SimulatorsTable.runtimesBytes`).
            let runtimes = SimulatorsTable.runtimesBytes(report: report)
            if runtimes > 0 {
                Text.l10n(L10n.tr("app.overview.runtimes", ByteCount.format(runtimes)))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// The words for an `OverviewCards.Amount`, which Core decided.
    static func text(_ amount: OverviewCards.Amount) -> String {
        switch amount {
        case .none: L10n.tr("app.overview.card.nothing")
        case .upTo(let bytes): L10n.tr("savings.upTo", ByteCount.format(bytes))
        case .atLeast(let bytes): L10n.tr("savings.atLeast", ByteCount.format(bytes))
        }
    }
}

/// One card: the bucket's symbol, color and title, its "up to" amount, the verified share, the promise and the cost to
/// undo, and **Review**.
struct OverviewCardView: View {
    let card: OverviewCards.Card
    let review: @MainActor () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BucketSymbol(bucket: card.bucket, decorative: true).font(.title3)
                Text.l10n(AppText.cardEyebrow(permanent: card.isPermanent)).font(.caption).bold().foregroundStyle(.secondary)
            }
            // What it promises and what undoing it costs are the title's tooltip and the bucket view's header (HIG review O2).
            Text(verbatim: card.bucket.localizedTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
                .help(card.bucket.localizedPromise + "\n" + card.bucket.localizedUndoCost)
            switch card.amount {
            case .none: Text(verbatim: OverviewView.text(card.amount)).font(.title3).foregroundStyle(.secondary)
            case .upTo, .atLeast: Text(verbatim: OverviewView.text(card.amount)).font(.title2).bold().monospacedDigit()
            }
            switch card.verified {
            case .all: Text.l10n(L10n.tr("app.overview.card.allVerified")).font(.caption).foregroundStyle(.secondary)
            case .share(let bytes): Text.l10n(L10n.tr("savings.verifiedShare", ByteCount.format(bytes))).font(.caption).foregroundStyle(.secondary)
            case .none: EmptyView()
            }
            if let lossy = card.losesUserDataBytes {
                // The Temporary headline is not all recoverable (S3 review): what deleting loses for good, on the card.
                StatusLabel(.warning, L10n.tr("app.overview.card.losesUserData", ByteCount.format(lossy))).font(.callout)
            }
            Spacer(minLength: 0)
            // Three cards, three secondary buttons: no card's Review is the screen's one primary (R7-B, §1.2).
            Button(L10n.tr("app.overview.card.review"), action: review).actionButton()
                // Three cards, three buttons: VoiceOver hears which bucket each one reviews.
                .accessibilityLabel(Text(verbatim: L10n.tr("app.overview.card.review.a11y", card.bucket.localizedTitle)))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(alignment: .top) {
            // The bucket color as a fill, never as text.
            UnevenRoundedRectangle(topLeadingRadius: Radius.card, topTrailingRadius: Radius.card).fill(card.bucket.color)
                .frame(height: contrast == .increased ? 6 : 4)
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Tokens.strokeHairline))
    }
}

/// The internal disk as one horizontal bar: other data, developer data by primary bucket, free — and a legend that
/// names every segment with a symbol, a title and a size, so no segment is told by color alone.
struct DiskBarView: View {
    let bar: DiskBar
    /// Increase Contrast outlines every segment and chip (R5, HIG review X9).
    @Environment(\.colorSchemeContrast) private var contrast
    /// Under the bar; the Overview's says the bar counts each item once. Nil for none.
    var caption: String? = L10n.tr("app.overview.bar.caption")
    var accessibilityTitle: String = L10n.tr("app.overview.bar.a11y")
    var barHeight: CGFloat = 18

    var body: some View {
        let total = max(bar.segments.reduce(UInt64(0)) { $0 + $1.bytes }, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(Array(bar.segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle().fill(Self.fill(segment.kind))
                            .overlay { if contrast == .increased { Rectangle().strokeBorder(Tokens.strokeHairline) } }
                            .frame(width: max(geometry.size.width * Double(segment.bytes) / Double(total) - 1, 0))
                    }
                }
            }
            .frame(height: barHeight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.bar))
            // A hairline around the bar, so the Free part never disappears into a dark window (HIG review O6).
            .overlay(RoundedRectangle(cornerRadius: Radius.bar).strokeBorder(Tokens.strokeHairline))
            // The legend says the same thing in words.
            .accessibilityHidden(true)
            // The bar counts each item once, the cards every option: say so, or the same title shows two numbers.
            if let caption {
                Text.l10n(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Wraps into as many columns as fit instead of truncating at narrow widths; in the cards' order.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Array(bar.legend.enumerated()), id: \.offset) { _, segment in legendItem(segment) }
            }
            .font(.caption)
            if bar.isClamped {
                Text.l10n(L10n.tr("app.overview.bar.clamped")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: accessibilityTitle))
    }

    private func legendItem(_ segment: DiskBar.Segment) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: Radius.swatch).fill(Self.fill(segment.kind)).frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: Radius.swatch).strokeBorder(Tokens.strokeHairline))
                .accessibilityHidden(true)
            switch segment.kind {
            case .bucket(let bucket): BucketSymbol(bucket: bucket, decorative: true)
            case .otherData: Image(systemName: "doc.on.doc").foregroundStyle(.secondary).accessibilityHidden(true)
            case .free: Image(systemName: "circle.dashed").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(verbatim: Self.title(segment.kind)).fixedSize(horizontal: false, vertical: true)
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
        case .otherData: Tokens.otherDataFill
        case .free: Tokens.freeFill
        }
    }
}
