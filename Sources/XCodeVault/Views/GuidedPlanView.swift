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

    /// What deleting would lose for good, never in the headline (F1): its own line, as the Overview card has it.
    static func lostLine(_ s: PlanSummary) -> String? {
        s.lostIfDeleted > 0 ? L10n.tr("app.guide.summary.lost", ByteCount.format(s.lostIfDeleted)) : nil
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
        case .partly: (.info, L10n.tr("app.guide.state.partly"), "circle.lefthalf.filled")
        case .blocked: (.neutral, L10n.tr("app.guide.state.blocked"), "lock")
        case .notNeeded: (.neutral, L10n.tr("app.guide.state.notNeeded"), "minus.circle")
        }
    }

    /// The step's one-line explanation, for its state.
    static func explanation(_ step: PlanStep) -> String {
        let subject = step.subject ?? ""
        if case .blocked(let block) = step.state { return blockText(block, subject: subject) }
        switch (step.kind, step.state) {
        case (.chooseDrive, _):
            switch step.note {
            case .vaultWrongKind(let drive, let issue, let volume)?: return wrongKind(drive: drive, issue: issue, ownershipVolume: volume)
            case .otherVaultShadowed(let name, let bytes?)?:
                return L10n.tr("app.guide.chooseDrive.done", subject) + " "
                    + L10n.tr("app.guide.chooseDrive.otherShadowed", name, ByteCount.format(bytes))
            case .otherVaultShadowed(let name, nil)?:
                return L10n.tr("app.guide.chooseDrive.done", subject) + " " + L10n.tr("app.guide.chooseDrive.otherShadowed.unmeasured", name)
            default: return L10n.tr("app.guide.chooseDrive.done", subject)
            }
        case (.prepareDrive, .notNeeded): return L10n.tr("app.guide.prepareDrive.notNeeded", subject)
        case (.prepareDrive, .done):
            if case .suitableVolume(let drive, let volume)? = step.note { return L10n.tr("app.guide.prepareDrive.suitableVolume", drive, volume) }
            return L10n.tr("app.guide.prepareDrive.notNeeded", subject)
        case (.prepareDrive, _):
            if case .turnOnOwnership(let volume)? = step.note { return L10n.tr("app.guide.prepareDrive.ownership", volume) }
            return L10n.tr("app.guide.prepareDrive.next", subject)
        case (.registerVault, .done): return L10n.tr("app.guide.registerVault.done", subject)
        case (.registerVault, _):
            if case .secondVault(let existing)? = step.note { return L10n.tr("app.guide.registerVault.second", subject, existing) }
            return L10n.tr("app.guide.registerVault.next", subject)
        case (.moveItems, .done): return L10n.tr("app.guide.move.done")
        case (.moveItems, .partly): return L10n.tr("app.guide.move.waitsForVault")
        case (.moveItems, _): return L10n.tr("app.guide.move.next")
        case (.checkHealth, .done): return L10n.tr("app.guide.health.done")
        case (.checkHealth, _): return L10n.tr("app.guide.health.next", step.findingCount)
        }
    }

    /// Step 1 on a vault of the wrong kind: exactly what is wrong, and what the next step does (R7-D).
    static func wrongKind(drive: String, issue: VolumeIssue, ownershipVolume: String?) -> String {
        switch (issue, ownershipVolume) {
        case (.caseSensitive, nil): L10n.tr("app.guide.chooseDrive.wrongKind.caseSensitive", drive)
        case (.ownershipOff, nil): L10n.tr("app.guide.chooseDrive.wrongKind.ownershipOff", drive)
        case (.both, nil): L10n.tr("app.guide.chooseDrive.wrongKind.both", drive)
        case (.caseSensitive, let v?): L10n.tr("app.guide.chooseDrive.wrongKind.caseSensitive.ownership", drive, v)
        case (.ownershipOff, let v?): L10n.tr("app.guide.chooseDrive.wrongKind.ownershipOff.ownership", drive, v)
        case (.both, let v?): L10n.tr("app.guide.chooseDrive.wrongKind.both.ownership", drive, v)
        }
    }

    static func blockText(_ block: PlanBlock, subject: String) -> String {
        switch block {
        case .noExternalDrive: L10n.tr("app.guide.block.noExternalDrive")
        case .noUsableDrive: L10n.tr("app.guide.block.noUsableDrive")
        case .vaultOffline(let name): L10n.tr("app.guide.block.vaultOffline", name)
        case .vaultShadowed(let name, let bytes?): L10n.tr("app.guide.block.vaultShadowed", name, ByteCount.format(bytes))
        case .vaultShadowed(let name, nil): L10n.tr("app.guide.block.vaultShadowed.unmeasured", name)
        case .vaultReplaced(let name): L10n.tr("app.guide.block.vaultReplaced", name)
        case .chooseInDrives: L10n.tr("app.guide.block.chooseInDrives", subject)
        case .addVolumeFirst: L10n.tr("app.guide.block.addVolumeFirst")
        case .ownershipFirst(let volume): L10n.tr("app.guide.block.ownershipFirst", volume)
        case .needsEarlierStep: L10n.tr("app.guide.block.needsEarlierStep")
        }
    }

    /// The line above the move step's items: which outcomes need the drive connected, which leave their only copy on it.
    static var legend: String { L10n.tr("app.guide.move.legend") }

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
        case .showInFinder: L10n.tr("app.drives.ownership.show")
        case .copyOwnershipCommand: L10n.tr("app.plan.copyCommand")
        }
    }

    // MARK: - An item

    /// The outcome, in the user's question's terms: temporary copy or runs on the drive (I3).
    static func outcome(_ o: PlanOutcome) -> String {
        switch o {
        case .runsFromDrive: L10n.tr("app.guide.outcome.runsFromDrive")
        case .movedToDrive: L10n.tr("app.guide.outcome.movedToDrive")
        case .parkedOnDrive: L10n.tr("app.guide.outcome.parkedOnDrive")
        case .deletedRebuilt: L10n.tr("app.guide.outcome.deletedRebuilt")
        case .deletedLost: L10n.tr("app.guide.outcome.deletedLost")
        }
    }

    /// What the outcome means for the user, under the item.
    static func outcomeDetail(_ o: PlanOutcome) -> String {
        switch o {
        case .runsFromDrive: L10n.tr("app.guide.outcome.runsFromDrive.detail")
        case .movedToDrive: L10n.tr("app.guide.outcome.movedToDrive.detail")
        case .parkedOnDrive: L10n.tr("app.guide.outcome.parkedOnDrive.detail")
        case .deletedRebuilt: L10n.tr("app.guide.outcome.deletedRebuilt.detail")
        case .deletedLost: L10n.tr("app.guide.outcome.deletedLost.detail")
        }
    }

    /// The outcome's symbol: the bucket's own for those that are a bucket's (BRAND.md), an archive box for moved data.
    static func outcomeSymbol(_ o: PlanOutcome) -> String {
        switch o {
        case .runsFromDrive: SavingsBucket.runFromExternal.symbolName
        case .movedToDrive: "archivebox"
        case .parkedOnDrive: SavingsBucket.parkExternally.symbolName
        case .deletedRebuilt: SavingsBucket.deleteAndRegenerate.symbolName
        case .deletedLost: "trash"
        }
    }

    /// An item's name, localized: never the catalog's English name in another language. A parked runtime's name is a
    /// record ("iOS 26.5 (23F77)") and shown as recorded.
    static func name(_ n: PlanItemName) -> String {
        switch n {
        case .newDerivedData: L10n.tr("app.guide.name.newDerivedData")
        case .oldDerivedData: L10n.tr("app.guide.name.oldDerivedData")
        case .newArchives: L10n.tr("app.guide.name.newArchives")
        case .existingArchives: L10n.tr("app.guide.name.existingArchives")
        case .parkedRuntime(let name): name
        case .category(let id): categoryName(id) ?? StorageCatalog.category(id)?.name ?? id
        }
    }

    /// A catalog category's plain name; nil for an id the catalog does not have (a test holds every catalog id to one).
    static func categoryName(_ id: String) -> String? {
        switch id {
        case "derivedData": L10n.tr("app.guide.name.derivedData")
        case "archives": L10n.tr("app.guide.name.archives")
        case "deviceSupport": L10n.tr("app.guide.name.deviceSupport")
        case "previews": L10n.tr("app.guide.name.previews")
        case "xcodePackages": L10n.tr("app.guide.name.xcodePackages")
        case "xcodeCaches": L10n.tr("app.guide.name.xcodeCaches")
        case "deviceLogs": L10n.tr("app.guide.name.deviceLogs")
        case "swiftPMCaches": L10n.tr("app.guide.name.swiftPMCaches")
        case "simulatorDevices": L10n.tr("app.guide.name.simulatorDevices")
        case "simulatorDeadContainers": L10n.tr("app.guide.name.simulatorDeadContainers")
        case "simulatorMobileAssets": L10n.tr("app.guide.name.simulatorMobileAssets")
        case "simulatorLogStore": L10n.tr("app.guide.name.simulatorLogStore")
        case "simulatorUserCaches": L10n.tr("app.guide.name.simulatorUserCaches")
        case "xctestDevices": L10n.tr("app.guide.name.xctestDevices")
        case "playgroundDevices": L10n.tr("app.guide.name.playgroundDevices")
        case "coreSimulatorSystemCaches": L10n.tr("app.guide.name.coreSimulatorSystemCaches")
        case "runtimeInbox": L10n.tr("app.guide.name.runtimeInbox")
        case "runtimeBundles": L10n.tr("app.guide.name.runtimeBundles")
        case "runtimeMounts": L10n.tr("app.guide.name.runtimeMounts")
        case "simulatorRuntimeAssets": L10n.tr("app.guide.name.simulatorRuntimeAssets")
        case "runtimeLibrary": L10n.tr("app.guide.name.runtimeLibrary")
        case "developerDiskImages": L10n.tr("app.guide.name.developerDiskImages")
        case "coreDevice": L10n.tr("app.guide.name.coreDevice")
        case "toolchains": L10n.tr("app.guide.name.toolchains")
        case "commandLineTools": L10n.tr("app.guide.name.commandLineTools")
        default: nil
        }
    }

    /// What the item's line says on the right: done and where, its size, or that it is new data only.
    static func itemStatus(_ item: PlanItem) -> String {
        if item.isDone {
            switch item.outcome {
            case .runsFromDrive: return L10n.tr("app.guide.item.done.runsFromDrive")
            case .parkedOnDrive:
                return item.doneBytes > 0
                    ? L10n.tr("app.guide.item.done.parked", ByteCount.format(item.doneBytes)) : L10n.tr("app.guide.item.done.parkedUnmeasured")
            case .movedToDrive: return L10n.tr("app.guide.item.done.onVault", ByteCount.format(item.doneBytes))
            case .deletedRebuilt, .deletedLost: return L10n.tr("app.guide.item.done.noneHere")
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
                    GroupBox { StepView(number: index + 1, step: step, primary: plan.primary, act: act) }
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
            if let lost = GuideText.lostLine(plan.summary) {
                StatusLabel(.warning, lost).font(.callout)
            }
        }
    }
}

/// One step: its number and title, its state, its explanation, its one button, and the move step's items.
private struct StepView: View {
    let number: Int
    let step: PlanStep
    let primary: PlanPrimary?
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
                Text.l10n(GuideText.legend).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(step.items) { item in ItemRow(item: item, isPrimary: primary == .item(item.id), act: act) }
                }
            }
            if let action = step.action, step.state != .done {
                HStack(spacing: Spacing.s) {
                    Button(GuideText.actionTitle(action)) { act(action) }.actionButton(prominent: primary == .step(step.kind))
                    if let secondary = step.secondaryAction {
                        if case .copyOwnershipCommand = secondary {
                            CopyCommandButton { act(secondary) }
                        } else {
                            Button(GuideText.actionTitle(secondary)) { act(secondary) }.actionButton()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xs)
    }
}

/// An item of the move step: its outcome, its name, its size or where it is, and its own button.
private struct ItemRow: View {
    let item: PlanItem
    let isPrimary: Bool
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
                        Text.l10n(GuideText.name(item.name))
                        if item.isExperimental { Tag.marker(.experimental) }
                        if item.losesUserData { Tag.marker(.losesUserData) }
                    }
                    Text.l10n(GuideText.outcome(item.outcome) + " — " + GuideText.outcomeDetail(item.outcome)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.s)
                Text.l10n(GuideText.itemStatus(item)).monospacedDigit().foregroundStyle(.secondary)
                if let action = item.action {
                    Button(GuideText.actionTitle(action)) { act(action) }.actionButton(prominent: isPrimary)
                }
            }
            ForEach(item.warnings, id: \.self) { id in
                if let text = GuideText.warning(id) { StatusLabel(.warning, text).font(.caption) }
            }
        }
    }
}
