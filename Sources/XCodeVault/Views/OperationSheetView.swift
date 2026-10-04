import AppKit
import SwiftUI
import XCodeVaultCore

/// The Run sheet (R3, ADR-0011; HIG review §4): review, running, finished, in one window-modal sheet. It decides nothing
/// — `AppModel` does (AppModel+Operations.swift) — and it has no Stop button: copy, verify and remove are not
/// interruptible from here (rule 4).
struct OperationSheetView: View {
    @Bindable var model: AppModel
    @State private var showsLog: Bool
    @State private var confirmsRemoval = false
    /// Whether the log follows its newest line (review M2): off, the user can read and select earlier lines.
    @State private var followsOutput = true

    /// `showsLog` is for `R3SheetFitTests`, which measures the log expanded; the app starts it folded.
    init(model: AppModel, showsLog: Bool = false) {
        _model = Bindable(model)
        _showsLog = State(initialValue: showsLog)
    }

    var body: some View {
        if let s = model.operationSheet {
            VStack(alignment: .leading, spacing: 14) {
                header(s)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch s.phase {
                        case .review: review(s)
                        case .running: running(s)
                        case .succeeded, .failed: finished(s)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if s.phase != .review || !s.log.lines.isEmpty { log(s) }
                buttons(s)
            }
            .padding(20)
            .frame(minWidth: 520, idealWidth: 560, minHeight: 260, idealHeight: 420)
            .interactiveDismissDisabled(model.isOperationRunning)
            .onChange(of: s.stage) { _, stage in
                // Phase changes and the end, never every line or percent (HIG review §4).
                AccessibilityNotification.Announcement(OperationText.stage(stage)).post()
                // The raw error is in the log, not the message (review M8): a failure opens it.
                if stage == .failed { showsLog = true }
            }
            .confirmationDialog(
                L10n.tr("app.run.removeOriginal.dialog", s.row?.categoryName ?? ""), isPresented: $confirmsRemoval
            ) {
                Button(L10n.tr("app.run.removeOriginal.action"), role: .destructive) { Task { await model.removeOriginal() } }
            } message: {
                Text.l10n(L10n.tr("app.run.removeOriginal.dialogMessage"))
            }
        }
    }

    // MARK: - Header

    private func header(_ s: OperationSheetState) -> some View {
        HStack(spacing: 10) {
            if let row = s.row {
                BucketSymbol(bucket: row.option.bucket, decorative: true).font(.title2)
            } else {
                Image(systemName: "externaldrive").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(verbatim: OperationText.title(s.kind)).font(.headline)
            // Rule 10: where the strategy is experimental, the badge is in the title, not a footnote. Every drive preparation
            // is experimental (R6, H17).
            if s.row?.option.isExperimental == true || s.kind.preparationAction != nil { MarkerBadges(markers: [.experimental]) }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Review

    @ViewBuilder
    private func review(_ s: OperationSheetState) -> some View {
        if s.kind.isDriveKind { driveControls(s) } else { controls(s) }
        if s.exportedFirst {
            Label(L10n.tr("app.run.exportedFirst"), systemImage: "checkmark.circle.fill").font(.callout)
        }
        if s.isPreviewing || s.preview == nil {
            HStack {
                ProgressView().controlSize(.small)
                Text(verbatim: OperationText.stage(.planning)).foregroundStyle(.secondary)
            }
        } else if let p = s.preview {
            facts(s, p)
            if s.kind.isDriveKind { drivePlan(s) }
            if !p.blockers.isEmpty {
                // The fix for a precondition the world changes — Xcode quit, the vault reconnected (review I3).
                Button(L10n.tr("app.run.checkAgain")) { model.checkOperationAgain() }
            }
            ForEach(Array(p.warnings.enumerated()), id: \.offset) { _, w in
                Label {
                    InlineCodeText(w).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            if p.installerMissing {
                VStack(alignment: .leading, spacing: 6) {
                    Text.l10n(L10n.tr("app.run.installerMissing")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.tr("app.run.exportInstallerFirst")) { model.exportInstallerFirst() }
                }
            }
        }
    }

    /// The CLI's flags, as choices.
    @ViewBuilder
    private func controls(_ s: OperationSheetState) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            if s.kind.usesDestination {
                GridRow {
                    Text.l10n(L10n.tr("app.run.label.destinationPicker")).foregroundStyle(.secondary)
                    Picker(L10n.tr("app.run.label.destinationPicker"), selection: destinationBinding) {
                        Text.l10n(s.inputs.folderIsCustom ? L10n.tr("app.run.destination.otherFolder") : L10n.tr("app.run.choose.none")).tag(String?.none)
                        ForEach(model.usableVaults, id: \.volume.volumeUUID) { c in
                            Text(verbatim: c.volume.volumeName + " — " + DriveText.verdict(.ready)).tag(String?.some(c.volume.volumeUUID))
                        }
                    }
                    .labelsHidden()
                    .disabled(s.offloadToReturnTo != nil)
                }
            }
            if s.kind.needsRuntime {
                GridRow {
                    Text.l10n(L10n.tr("app.run.label.runtime")).foregroundStyle(.secondary)
                    Picker(L10n.tr("app.run.label.runtime"), selection: inputBinding(\.runtimeID)) {
                        Text.l10n(L10n.tr("app.run.choose.none")).tag(String?.none)
                        ForEach(model.runtimesForPicker) { r in
                            Text(verbatim: OperationText.runtime(r) + (r.sizeBytes.map { "  " + ByteCount.format($0) } ?? "")).tag(String?.some(r.identifier))
                        }
                    }
                    .labelsHidden()
                }
            }
            if s.kind.needsPlatform {
                GridRow {
                    Text.l10n(L10n.tr("app.run.label.platform")).foregroundStyle(.secondary)
                    Picker(L10n.tr("app.run.label.platform"), selection: platformBinding) {
                        ForEach(OperationKind.exportPlatforms, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(s.offloadToReturnTo != nil)
                }
            }
            if s.kind.needsFolder {
                GridRow {
                    Text.l10n(L10n.tr("app.run.label.folder")).foregroundStyle(.secondary)
                    HStack {
                        Text(verbatim: s.inputs.folder ?? L10n.tr("app.run.choose.none"))
                            .font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(s.inputs.folder == nil ? .secondary : .primary)
                        Button(L10n.tr("app.run.destination.chooseFolder")) { Task { await model.chooseOperationFolder() } }
                            .disabled(s.offloadToReturnTo != nil)
                    }
                }
            }
        }
        if s.kind.usesDestination { otherDrives(s) }
        if s.kind.asksTestsAcknowledgement {
            Toggle(L10n.tr("app.run.acknowledgeTests"), isOn: ackBinding).toggleStyle(.checkbox)
        }
    }

    /// One to three facts (HIG review §4): from, to, size, what undo costs.
    private func facts(_ s: OperationSheetState, _ p: OperationPreview) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            // A drive operation names its drive above and what an erase destroys below, with sizes: no From or Size here.
            if let source = p.source, !s.kind.isDriveKind { fact(L10n.tr("app.run.label.source"), source, mono: true) }
            if let destination = p.destination { fact(L10n.tr("app.run.label.destination"), destination, mono: true) }
            if let bytes = p.bytes, !s.kind.isDriveKind { fact(L10n.tr("app.run.label.size"), ByteCount.format(bytes), mono: false) }
            GridRow {
                Text.l10n(L10n.tr("app.run.label.undo")).foregroundStyle(.secondary)
                Text.l10n(OperationText.undo(s.kind, current: p.source)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private func fact(_ label: String, _ value: String, mono: Bool) -> some View {
        GridRow {
            Text.l10n(label).foregroundStyle(.secondary)
            Text(verbatim: value).font(mono ? .system(.callout, design: .monospaced) : .callout).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
        }
    }

    // MARK: - Destination and drives (R6)

    /// The drives that can be used or need preparation, under the Destination picker: each with its verdict in words and
    /// **Prepare…** (`AppModel.prepareFromDestination`), which comes back to this sheet when it closes.
    @ViewBuilder
    private func otherDrives(_ s: OperationSheetState) -> some View {
        let drives = model.destinationChoices.compactMap { c -> DriveAssessment? in
            if case .drive(let a) = c.target { return a }
            return nil
        }
        ForEach(drives) { a in
            HStack(spacing: 8) {
                Label {
                    Text(verbatim: a.displayName + " — " + DriveText.verdict(a.verdict)).font(.callout)
                } icon: {
                    Image(systemName: DriveText.symbol(a.verdict)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Spacer()
                Button(L10n.tr("app.drives.prepare")) { model.prepareFromDestination(a) }.disabled(s.offloadToReturnTo != nil)
            }
        }
    }

    /// The preparation's choices: the drive, the action (least destructive first, the recommended one marked), and the new
    /// volume's settings.
    @ViewBuilder
    private func driveControls(_ s: OperationSheetState) -> some View {
        if let a = s.drive {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text.l10n(L10n.tr("app.prep.label.drive")).foregroundStyle(.secondary)
                    Text(verbatim: a.displayName + " (" + DriveText.facts(a) + ")").lineLimit(2)
                }
                if s.kind.preparationAction != nil {
                    GridRow {
                        Text.l10n(L10n.tr("app.prep.label.option")).foregroundStyle(.secondary)
                        Picker(L10n.tr("app.prep.label.option"), selection: optionBinding) {
                            ForEach(model.preparationChoices, id: \.self) { o in
                                Text(verbatim: DriveText.option(o) + (a.isRecommended(o) ? " — " + L10n.tr("app.prep.recommended") : "")).tag(Optional(o))
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text.l10n(L10n.tr("app.prep.label.name")).foregroundStyle(.secondary)
                        TextField(L10n.tr("app.prep.label.name"), text: volumeNameBinding).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    }
                }
            }
            if s.kind.preparationAction != nil {
                Toggle(L10n.tr("app.prep.caseSensitive"), isOn: caseSensitiveBinding).toggleStyle(.checkbox)
                if s.kind == .addVolume {
                    HStack {
                        Toggle(L10n.tr("app.prep.quota"), isOn: quotaOnBinding).toggleStyle(.checkbox)
                        if let q = s.inputs.volume.quotaGigabytes {
                            Stepper(L10n.tr("app.prep.quota.gb", q), value: quotaBinding, in: 1...100_000, step: 10)
                        }
                    }
                }
            } else {
                Text.l10n(L10n.tr("app.prep.useDrive.detail")).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The plan: the exact command (copyable), every volume an erase destroys, and the name to type.
    @ViewBuilder
    private func drivePlan(_ s: OperationSheetState) -> some View {
        if let plan = model.pendingDiskPlan {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: plan.command).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button(L10n.tr("app.plan.copyCommand")) { model.copyPreparationCommand() }
            }
            Text.l10n(L10n.tr("app.prep.notSudo")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !plan.destroys.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text.l10n(L10n.tr("app.prep.destroys.title")).bold()
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityHidden(true)
                        }
                        ForEach(plan.destroys, id: \.id) { v in Text(verbatim: "• " + DriveText.destroyed(v)).font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let name = plan.confirmationName {
                Text(verbatim: L10n.tr("app.prep.typeName.prompt", name)).font(.callout)
                TextField(L10n.tr("app.prep.typeName.field"), text: confirmationBinding).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    .accessibilityLabel(Text(verbatim: L10n.tr("app.prep.typeName.prompt", name)))
            }
        }
    }

    // MARK: - Running

    private func running(_ s: OperationSheetState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = model.operationProgressFraction {
                        ProgressView(value: fraction) {
                            Text(verbatim: OperationText.stage(s.stage))
                        } currentValueLabel: {
                            progressLine(context.date)
                        }
                    } else {
                        // No measure for this stage: indeterminate, and it says which stage (HIG review §4).
                        Text(verbatim: OperationText.stage(s.stage))
                        ProgressView().progressViewStyle(.linear)
                        progressLine(context.date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Label(L10n.tr("app.run.cannotStop"), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func progressLine(_ now: Date) -> some View {
        let elapsed = model.operationSheet?.startedAt.map { now.timeIntervalSince($0) } ?? 0
        let parts = [model.operationProgressText, L10n.tr("app.run.elapsed", Self.duration(elapsed))].compactMap { $0 }
        return Text(verbatim: parts.joined(separator: " — ")).monospacedDigit()
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        f.zeroFormattingBehavior = .pad
        f.unitsStyle = .positional
        return f.string(from: max(0, seconds)) ?? ""
    }

    // MARK: - Finished

    @ViewBuilder
    private func finished(_ s: OperationSheetState) -> some View {
        switch s.phase {
        case .failed:
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: OperationText.failedTitle(s.kind)).bold()
                    if s.kind == .externalizeArchives {
                        // copyAndVerify never touches the source; a failed copy leaves the original where it was.
                        Text.l10n(L10n.tr("app.run.failed.originalUntouched")).fixedSize(horizontal: false, vertical: true)
                    }
                    Text.l10n(L10n.tr("app.run.failed.seeDetails")).font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if let id = model.failedCopyLeftoverID {
                // The partial copy the failure left on the vault, and the exact command that removes it (review I4).
                let command = "xcodevaultctl migration abort \(id)"
                VStack(alignment: .leading, spacing: 4) {
                    Text.l10n(L10n.tr("app.run.failed.leftover")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(verbatim: command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button(L10n.tr("app.plan.copyCommand")) { model.environment.copy(command) }
                    }
                }
            }
        default:
            if let r = s.result {
                Label(OperationText.done(r), systemImage: "checkmark.circle.fill").fixedSize(horizontal: false, vertical: true)
            }
        }
        secondStep(s)
        if let url = s.logFileURL, s.phase != .running {
            Text(verbatim: L10n.tr("app.run.logFile", url.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func secondStep(_ s: OperationSheetState) -> some View {
        switch s.secondStep {
        case .removeOriginal, .removeFailed, .removingOriginal:
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text.l10n(L10n.tr("app.run.removeOriginal.detail")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if case .removeFailed = s.secondStep {
                        Label {
                            Text.l10n(L10n.tr("app.run.removeOriginal.failed") + " " + L10n.tr("app.run.failed.seeDetails")).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                    if model.removalNeedsConfirmation {
                        Toggle(L10n.tr("app.run.removeOriginal.confirm"), isOn: removalBinding).toggleStyle(.checkbox)
                            .disabled(model.isOperationRunning)
                    }
                    if s.secondStep == .removingOriginal {
                        Text(verbatim: OperationText.stage(.removing)).font(.callout)
                        ProgressView().progressViewStyle(.linear)
                    }
                    Button(L10n.tr("app.run.removeOriginal"), role: .destructive) { confirmsRemoval = true }
                        .disabled(!model.canRemoveOriginal)
                }
            }
        case .undo, .undoing, .undoFailed:
            let previous = model.undoRestores ?? nil
            HStack {
                if case .undoFailed = s.secondStep {
                    Text.l10n(L10n.tr("app.run.undoFailed") + " " + L10n.tr("app.run.failed.seeDetails")).font(.callout).foregroundStyle(.secondary)
                }
                Button(OperationText.undoAction(restoring: previous)) { Task { await model.undoLocation() } }.disabled(model.isOperationRunning)
            }
        case .undone:
            Label(OperationText.undone(restored: model.undoRestores ?? nil), systemImage: "arrow.uturn.backward.circle")
        case .originalRemoved, .none:
            EmptyView()
        }
    }

    // MARK: - Log

    /// Behind **Show Details**, collapsed by default (HIG review §4): monospaced, selectable, following the end while
    /// **Follow Output** is on. Each row is identified by its sequence number, which the cap never shifts (review I1).
    private func log(_ s: OperationSheetState) -> some View {
        DisclosureGroup(isExpanded: $showsLog) {
            VStack(alignment: .leading, spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(s.log.droppedCount..<s.log.total, id: \.self) { n in
                                let line = s.log.lines[n - s.log.droppedCount]
                                Text(verbatim: line.rendered).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.stream == .stderr ? Color.red : Color.primary)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                    .onChange(of: s.log.total) { _, total in
                        if followsOutput && total > 0 { proxy.scrollTo(total - 1, anchor: .bottom) }
                    }
                }
                HStack {
                    Toggle(L10n.tr("app.run.followOutput"), isOn: $followsOutput).toggleStyle(.checkbox)
                    Spacer()
                    Button(L10n.tr("app.run.copyLog")) { model.copyOperationLog() }
                }
            }
        } label: {
            Text.l10n(L10n.tr("app.run.showDetails"))
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private func buttons(_ s: OperationSheetState) -> some View {
        HStack {
            if !model.canConfirmOperation, s.phase == .review, let first = model.operationBlockers.first {
                Text(verbatim: AppModel.blockerText(first)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch s.phase {
            case .review:
                if s.kind.deletesData {
                    // Deletes data here: destructive, and not the default — Cancel is (HIG).
                    Button(L10n.tr("app.action.cancel")) { model.closeOperationSheet() }.keyboardShortcut(.defaultAction)
                    Button(model.operationConfirmTitle, role: .destructive) { Task { await model.runOperation() } }
                        .disabled(!model.canConfirmOperation)
                } else {
                    Button(L10n.tr("app.action.cancel")) { model.closeOperationSheet() }.keyboardShortcut(.cancelAction)
                    Button(model.operationConfirmTitle) { Task { await model.runOperation() } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!model.canConfirmOperation)
                }
            case .running:
                EmptyView()
            case .succeeded, .failed:
                if model.offersBackToOffload {
                    Button(L10n.tr("app.run.backToOffload")) { model.backToOffload() }
                }
                Button(L10n.tr("app.run.showInHistory")) { model.showHistoryFromOperation() }.disabled(model.isOperationRunning)
                Button(L10n.tr("app.run.done")) { model.closeOperationSheet() }.keyboardShortcut(.defaultAction).disabled(model.isOperationRunning)
            }
        }
    }

    // MARK: - Bindings

    private func inputBinding(_ key: WritableKeyPath<OperationInputs, String?>) -> Binding<String?> {
        Binding(get: { model.operationSheet?.inputs[keyPath: key] }, set: { v in model.updateOperationInputs { $0[keyPath: key] = v } })
    }

    private var platformBinding: Binding<String> {
        Binding(get: { model.operationSheet?.inputs.platform ?? "iOS" }, set: { v in model.updateOperationInputs { $0.platform = v } })
    }

    private var ackBinding: Binding<Bool> {
        Binding(get: { model.operationSheet?.inputs.acknowledgeTests ?? false }, set: { v in model.updateOperationInputs { $0.acknowledgeTests = v } })
    }

    private var destinationBinding: Binding<String?> {
        Binding(get: { model.operationSheet?.inputs.vaultUUID }, set: { model.chooseDestination(vaultUUID: $0) })
    }

    private var optionBinding: Binding<PreparationOption?> {
        Binding(get: { model.operationSheet?.inputs.driveOption }, set: { if let o = $0 { model.choosePreparationOption(o) } })
    }

    private var volumeNameBinding: Binding<String> {
        Binding(get: { model.operationSheet?.inputs.volume.name ?? "" }, set: { v in model.updateVolumeConfiguration { $0.name = v } })
    }

    private var caseSensitiveBinding: Binding<Bool> {
        Binding(get: { model.operationSheet?.inputs.volume.caseSensitive ?? false }, set: { v in model.updateVolumeConfiguration { $0.caseSensitive = v } })
    }

    private var quotaOnBinding: Binding<Bool> {
        Binding(
            get: { model.operationSheet?.inputs.volume.quotaGigabytes != nil },
            set: { on in model.updateVolumeConfiguration { $0.quotaGigabytes = on ? 100 : nil } })
    }

    private var quotaBinding: Binding<Int> {
        Binding(get: { model.operationSheet?.inputs.volume.quotaGigabytes ?? 100 }, set: { v in model.updateVolumeConfiguration { $0.quotaGigabytes = v } })
    }

    private var confirmationBinding: Binding<String> {
        Binding(get: { model.operationSheet?.confirmationText ?? "" }, set: { model.updateConfirmationText($0) })
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { model.operationSheet?.confirmRemoval ?? false }, set: { model.operationSheet?.confirmRemoval = $0 })
    }
}

/// The interrupted-migration banner (R3 §10): on Park, Run externally and History. The commands are for Terminal; the
/// app neither resumes nor aborts this round.
struct InterruptedMigrationsBanner: View {
    let items: [InterruptedMigration]
    let copy: @MainActor (String) -> Void

    var body: some View {
        if !items.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text.l10n(L10n.tr("app.run.interrupted.title")).bold()
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text.l10n(L10n.tr("app.run.interrupted.detail")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items) { item in
                                Text(verbatim: item.summary).font(.callout).lineLimit(2)
                                ForEach(item.commands, id: \.self) { command in
                                    HStack {
                                        Text(verbatim: command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                        Spacer()
                                        Button(L10n.tr("app.plan.copyCommand")) { copy(command) }
                                            .accessibilityLabel(Text(verbatim: L10n.tr("app.run.interrupted.copy.a11y", command)))
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }
}
