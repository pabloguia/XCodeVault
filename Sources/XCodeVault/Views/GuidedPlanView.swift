import SwiftUI
import XCodeVaultCore

/// The words and status kinds of the guided Plan (R7-C): every choice the screen shows is made here, in tested functions,
/// from what `PlanBuilder` decided. The view only draws them.
enum GuideText {
    // MARK: - The header

    /// The header's sentence: never "up to 0 bytes" nor "0 bytes is done" — a part with nothing in it is left out.
    static func summary(_ s: PlanSummary) -> String {
        switch (s.upTo > 0, s.done > 0) {
        case (true, true): L10n.tr("app.guide.summary", ByteCount.format(s.upTo), ByteCount.format(s.done))
        case (true, false): L10n.tr("app.guide.summary.nothingDone", ByteCount.format(s.upTo))
        case (false, true): L10n.tr("app.guide.summary.allDone", ByteCount.format(s.done))
        case (false, false): L10n.tr("app.guide.summary.nothing")
        }
    }

    /// The breakdown under the header, in the outcomes' order, only those with something left.
    static func breakdown(_ s: PlanSummary) -> [(outcome: PlanOutcome, text: String)] {
        PlanOutcome.allCases.compactMap { o in
            guard let bytes = s.byOutcome[o], bytes > 0 else { return nil }
            return (o, L10n.tr("app.guide.breakdown", outcome(o), ByteCount.format(bytes)))
        }
    }

    // MARK: - A step

    static func title(_ kind: PlanStep.Kind) -> String {
        switch kind {
        case .chooseDrive: L10n.tr("app.guide.step.chooseDrive")
        case .prepareDrive: L10n.tr("app.guide.step.prepareDrive")
        case .registerVault: L10n.tr("app.guide.step.registerVault")
        case .moveItems: L10n.tr("app.guide.step.moveItems")
        case .checkHealth: L10n.tr("app.guide.step.checkHealth")
        }
    }

    /// The step's state as a status: its kind, its word, and its own symbol when it has one.
    static func state(_ s: PlanStep.State) -> (kind: StatusKind, text: String, symbol: String?) {
        switch s {
        case .done: (.success, L10n.tr("app.guide.state.done"), nil)
        case .next: (.info, L10n.tr("app.guide.state.next"), "arrow.right.circle.fill")
        case .blocked: (.neutral, L10n.tr("app.guide.state.blocked"), "lock")
        case .notNeeded: (.neutral, L10n.tr("app.guide.state.notNeeded"), "minus.circle")
        }
    }

    /// The step's one-line explanation, for its state.
    static func explanation(_ step: PlanStep) -> String {
        let subject = step.subject ?? ""
        if case .blocked(let block) = step.state {
            switch block {
            case .noExternalDrive: return L10n.tr("app.guide.block.noExternalDrive")
            case .noUsableDrive: return L10n.tr("app.guide.block.noUsableDrive")
            case .vaultOffline(let name): return L10n.tr("app.guide.block.vaultOffline", name)
            case .chooseInDrives: return L10n.tr("app.guide.block.chooseInDrives", subject)
            case .needsEarlierStep:
                // Deleting needs no drive: the move step says so when it still has something to open.
                if step.kind == .moveItems && step.items.contains(where: { $0.action != nil }) { return L10n.tr("app.guide.move.waitsForVault") }
                return L10n.tr("app.guide.block.needsEarlierStep")
            }
        }
        switch (step.kind, step.state) {
        case (.chooseDrive, _): return L10n.tr("app.guide.chooseDrive.done", subject)
        case (.prepareDrive, .notNeeded): return L10n.tr("app.guide.prepareDrive.notNeeded", subject)
        case (.prepareDrive, .done): return L10n.tr("app.guide.prepareDrive.done", subject)
        case (.prepareDrive, _): return L10n.tr("app.guide.prepareDrive.next", subject)
        case (.registerVault, .done): return L10n.tr("app.guide.registerVault.done", subject)
        case (.registerVault, _): return L10n.tr("app.guide.registerVault.next", subject)
        case (.moveItems, .done): return L10n.tr("app.guide.move.done")
        case (.moveItems, _): return L10n.tr("app.guide.move.next")
        case (.checkHealth, .done): return L10n.tr("app.guide.health.done")
        case (.checkHealth, _): return L10n.tr("app.guide.health.next", step.findingCount)
        }
    }

    // MARK: - Buttons

    /// A button's title, in the words the sheet or screen it opens uses.
    static func actionTitle(_ action: PlanAction) -> String {
        switch action {
        case .showDrives: L10n.tr("app.guide.action.showDrives")
        case .prepareDrive(_, let option): DriveText.optionButton(option)
        case .useDrive: L10n.tr("app.drives.useDrive")
        case .run: L10n.tr("app.plan.run")
        case .showBucket: L10n.tr("app.overview.card.review")
        case .showHealth: L10n.tr("app.guide.action.showHealth")
        }
    }

    // MARK: - An item

    static func outcome(_ o: PlanOutcome) -> String {
        switch o {
        case .runsFromDrive: L10n.tr("app.guide.outcome.runsFromDrive")
        case .movedToDrive: L10n.tr("app.guide.outcome.movedToDrive")
        case .leavesAndComesBack: L10n.tr("app.guide.outcome.leavesAndComesBack")
        case .deletedRecreated: L10n.tr("app.guide.outcome.deletedRecreated")
        }
    }

    /// The outcome's symbol: the bucket's own for the three that are a bucket's (BRAND.md), an arrow for new data.
    static func outcomeSymbol(_ o: PlanOutcome) -> String {
        switch o {
        case .runsFromDrive: SavingsBucket.runFromExternal.symbolName
        case .movedToDrive: "archivebox"
        case .leavesAndComesBack: SavingsBucket.parkExternally.symbolName
        case .deletedRecreated: SavingsBucket.deleteAndRegenerate.symbolName
        }
    }

    /// What the item's line says on the right: done and where, its size, or that it waits for the vault.
    static func itemStatus(_ item: PlanItem) -> String {
        if item.isDone {
            switch item.outcome {
            case .runsFromDrive: return L10n.tr("app.guide.item.done.runsFromDrive")
            case .leavesAndComesBack: return L10n.tr("app.guide.item.done.parked", ByteCount.format(item.doneBytes))
            default: return L10n.tr("app.guide.item.done.onVault", ByteCount.format(item.doneBytes))
            }
        }
        if item.bytes == 0 { return L10n.tr("app.guide.item.newDataOnly") }
        return ByteCount.format(item.bytes)
    }

    static func warning(_ id: String) -> String? { id == "derivedDataTests" ? L10n.tr("app.guide.warning.derivedDataTests") : nil }
}

/// The guided Plan (R7-C, ADR-0013): the best path for this Mac as ordered steps, drawn from `AppModel.plan`. Every button
/// opens an existing sheet or screen through `AppModel.performPlanAction`; nothing here runs anything.
struct GuidedPlanView: View {
    let plan: Plan
    var act: @MainActor (PlanAction) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    GroupBox { StepView(number: index + 1, step: step, isPrimary: plan.primaryStepKind == step.kind, act: act) }
                }
                Text.l10n(L10n.tr("app.guide.footer")).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text.l10n(GuideText.summary(plan.summary)).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
            ForEach(GuideText.breakdown(plan.summary), id: \.outcome) { line in
                Label {
                    Text.l10n(line.text)
                } icon: {
                    Image(systemName: GuideText.outcomeSymbol(line.outcome)).foregroundStyle(.secondary)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// One step: its number and title, its state, its explanation, its one button, and the move step's items.
private struct StepView: View {
    let number: Int
    let step: PlanStep
    let isPrimary: Bool
    let act: @MainActor (PlanAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text.l10n("\(number). " + GuideText.title(step.kind)).font(.headline)
                if step.isExperimental { Tag.marker(.experimental) }
                Spacer(minLength: Spacing.s)
                let s = GuideText.state(step.state)
                StatusLabel(s.kind, s.text, symbol: s.symbol).font(.callout)
            }
            Text.l10n(GuideText.explanation(step)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !step.items.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(step.items) { item in ItemRow(item: item, act: act) }
                }
            }
            if let action = step.action, step.state != .done {
                Button(GuideText.actionTitle(action)) { act(action) }.actionButton(prominent: isPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xs)
    }
}

/// An item of the move step: its outcome, its name, its size or where it is, and its own button.
private struct ItemRow: View {
    let item: PlanItem
    let act: @MainActor (PlanAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                if item.isDone {
                    StatusIcon(.success)
                } else {
                    Image(systemName: GuideText.outcomeSymbol(item.outcome)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.s) {
                        Text.l10n(item.name)
                        if item.isExperimental { Tag.marker(.experimental) }
                    }
                    Text.l10n(GuideText.outcome(item.outcome)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s)
                Text.l10n(GuideText.itemStatus(item)).monospacedDigit().foregroundStyle(.secondary)
                if let action = item.action {
                    Button(GuideText.actionTitle(action)) { act(action) }.actionButton()
                }
            }
            ForEach(item.warnings, id: \.self) { id in
                if let text = GuideText.warning(id) { StatusLabel(.warning, text).font(.caption) }
            }
        }
    }
}
