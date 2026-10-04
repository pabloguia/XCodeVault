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

    /// The height the sheet opens at; a longer review scrolls inside it (`R3SheetFitTests`).
    static let idealHeight: CGFloat = 460

    /// `showsLog` is for `R3SheetFitTests`, which measures the log expanded; the app starts it folded.
    init(model: AppModel, showsLog: Bool = false) {
        _model = Bindable(model)
        _showsLog = State(initialValue: showsLog)
    }

    var body: some View {
        if let s = model.operationSheet {
            VStack(alignment: .leading, spacing: 0) {
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
                    // R7-A: the review can be longer than the sheet (the user's 19: a warning cut off at the bottom). It
                    // scrolls, with its scroller shown, and the footer below stays visible.
                    .scrollIndicators(.visible)
                    if s.phase != .review || !s.log.lines.isEmpty { log(s) }
                }
                .padding([.horizontal, .top], Spacing.xl)
                .padding(.bottom, Spacing.m)
                // R7-B (§3.7): a divider marks where the content ends and the footer begins.
                Divider()
                buttons(s).padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.m)
            }
            .frame(minWidth: 520, idealWidth: 560, minHeight: 260, idealHeight: Self.idealHeight)
            .interactiveDismissDisabled(model.isOperationRunning)
            // Ruling B-2: Escape always closes the sheet, also when Cancel is the default (a destructive review); never
            // while something runs (`closeOperationSheet` refuses then).
            .onExitCommand { model.closeOperationSheet() }
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
            if s.showsExperimentalBadge { Tag.marker(.experimental) }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Review

    @ViewBuilder
    private func review(_ s: OperationSheetState) -> some View {
        if s.kind.isDriveKind { driveControls(s) } else { controls(s) }
        if s.exportedFirst {
            StatusLabel(.success, L10n.tr("app.run.exportedFirst")).font(.callout)
        }
        if s.isPreviewing || s.preview == nil {
            HStack {
                ProgressView().controlSize(.small)
                Text(verbatim: OperationText.stage(.planning)).foregroundStyle(.secondary)
            }
        } else if let p = s.preview {
            facts(s, p)
            if s.kind.isDriveKind { drivePlan(s) }
            if let folder = p.willCreateFolder {
                Label {
                    Text(verbatim: L10n.tr("app.run.willCreateFolder", folder)).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "folder.badge.plus").accessibilityHidden(true)
                }
            }
            // Core's warnings gate the decision: never folded, never clipped (§3.5). **Check Again** is in the footer, beside
            // the reason it answers (R7-B, audit row 24).
            ForEach(Array(p.warnings.enumerated()), id: \.offset) { _, w in NoticeRow(.warning, w) }
            if p.installerMissing {
                NoticeRow(.info, L10n.tr("app.run.installerMissing")) {
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
                    HStack(spacing: 8) {
                        Picker(L10n.tr("app.run.label.destinationPicker"), selection: destinationBinding) {
                            Text.l10n(s.inputs.folderIsCustom ? L10n.tr("app.run.destination.otherFolder") : L10n.tr("app.run.choose.none"))
                                .tag(String?.none)
                            ForEach(model.usableVaults, id: \.volume.volumeUUID) { c in
                                Text(verbatim: c.volume.volumeName + " — " + DriveText.verdict(.ready)).tag(String?.some(c.volume.volumeUUID))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(s.offloadToReturnTo != nil)
                        // R7-A: the verdict is said once, in the picker. Beside it, only when the chosen drive has a fix to
                        // make, a button that says what the fix is (`AppModel.destinationFix`).
                        if let fix = model.destinationFix, let title = DriveText.prepareTitle(fix.prepareAction) {
                            Button(title) { model.prepareFromDestination(fix) }.actionButton().disabled(s.offloadToReturnTo != nil)
                        }
                    }
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
                    HStack(alignment: .firstTextBaseline) {
                        // R7-A: the folder in full, wrapping, shown once — the facts below do not repeat it as "To".
                        Text(verbatim: s.inputs.folder ?? L10n.tr("app.run.choose.none"))
                            .font(.system(.body, design: .monospaced)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .foregroundStyle(s.inputs.folder == nil ? .secondary : .primary)
                            .help(s.inputs.folder ?? "")
                        Spacer(minLength: 0)
                        Button(L10n.tr("app.run.destination.chooseFolder")) { Task { await model.chooseOperationFolder() } }
                            .actionButton().disabled(s.offloadToReturnTo != nil)
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
            if let destination = p.destination, s.showsDestinationFact(p) { fact(L10n.tr("app.run.label.destination"), destination, mono: true) }
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

    /// The drives that can be used or need preparation, under the Destination picker — never a ready vault, which is in
    /// the picker (R7-A) — each with its verdict in words and a button saying what it does (`DriveText.prepareTitle`,
    /// `AppModel.prepareFromDestination`); the sheet it opens comes back to this one when it closes.
    @ViewBuilder
    private func otherDrives(_ s: OperationSheetState) -> some View {
        let drives = model.destinationDrives
        ForEach(drives) { a in
            HStack(spacing: 8) {
                Label {
                    Text(verbatim: a.displayName + " — " + DriveText.verdict(a.verdict)).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: DriveText.symbol(a.verdict)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Spacer()
                if let title = DriveText.prepareTitle(a.prepareAction) {
                    Button(title) { model.prepareFromDestination(a) }.actionButton().disabled(s.offloadToReturnTo != nil)
                }
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
                    GridRow(alignment: .firstTextBaseline) {
                        Text.l10n(L10n.tr("app.prep.label.name")).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(L10n.tr("app.prep.label.name"), text: volumeNameBinding).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                            mountPreview
                        }
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

    /// R7-A (the user asked whether the name should be a path): diskutil takes only the name; this says where it will
    /// appear, and warns when that name is mounted already (`AppModel.newVolumeMountPreview`).
    @ViewBuilder
    private var mountPreview: some View {
        if let m = model.newVolumeMountPreview {
            Text(verbatim: L10n.tr("app.prep.mountsAs", m.mountPoint)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if m.isTaken {
                NoticeRow(.warning, L10n.tr("app.prep.mountsAs.taken", m.mountPoint, m.actualMountPoint, m.suggestedName ?? ""))
            }
        }
    }

    /// The plan: the exact command (copyable), every volume an erase destroys, and the name to type.
    @ViewBuilder
    private func drivePlan(_ s: OperationSheetState) -> some View {
        if let plan = model.pendingDiskPlan {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: plan.command).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer()
                CopyCommandButton { model.copyPreparationCommand() }
            }
            Text.l10n(L10n.tr("app.prep.notSudo")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !plan.destroys.isEmpty {
                // What the erase destroys, as a danger notice (§3.6): every volume, with what it holds.
                GroupBox {
                    NoticeRow(.danger, L10n.tr("app.prep.destroys.title"), detail: plan.destroys.map { "• " + DriveText.destroyed($0) }.joined(separator: "\n"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if model.previewedDiskIsIndistinguishable {
                NoticeRow(.warning, L10n.tr("app.prep.identityWeak"))
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
                StatusIcon(.blocker)
            }
            if let id = model.failedCopyLeftoverID {
                // The partial copy the failure left on the vault, and the exact command that removes it (review I4).
                let command = "xcodevaultctl migration abort \(id)"
                VStack(alignment: .leading, spacing: 4) {
                    Text.l10n(L10n.tr("app.run.failed.leftover")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(verbatim: command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        CopyCommandButton { model.environment.copy(command) }
                    }
                }
            }
        default:
            if let r = s.result {
                StatusLabel(model.registrationFoldersError == nil ? .success : .warning, OperationText.done(r))
            }
            if let why = model.registrationFoldersError {
                InlineCodeText(why).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            // R7-A: the volume a preparation made is not a vault yet. **Use This Drive** opens its own review; nothing is
            // registered from here, and nothing is chained after the preparation (rule 6, ADR-0012).
            if let made = model.madeVolume {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L10n.tr("app.run.done.useMadeVolume", made.volume.volumeName)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.tr("app.drives.useDrive")) { model.useMadeVolume() }.actionButton().disabled(model.isOperationRunning)
                }
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
                            StatusIcon(.blocker)
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
                        .actionButton().disabled(!model.canRemoveOriginal)
                    // Why it is disabled, in visible text (ruling B-3).
                    if let why = model.removeOriginalDisabledReason {
                        Text(verbatim: why).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .undo, .undoing, .undoFailed:
            let previous = model.undoRestores ?? nil
            HStack {
                if case .undoFailed = s.secondStep {
                    Text.l10n(L10n.tr("app.run.undoFailed") + " " + L10n.tr("app.run.failed.seeDetails")).font(.callout).foregroundStyle(.secondary)
                }
                Button(OperationText.undoAction(restoring: previous)) { Task { await model.undoLocation() } }.actionButton().disabled(model.isOperationRunning)
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
                                    .foregroundStyle(line.stream == .stderr ? Tokens.logStderr : Color.primary)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                    .background(Tokens.surfaceCode, in: RoundedRectangle(cornerRadius: Radius.code))
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

    /// The footer (R7-B, §3.7): the reason the primary is disabled (or that the run cannot be stopped) and tertiary actions
    /// on the leading side; Cancel, then the primary, rightmost. One default button at most.
    private func buttons(_ s: OperationSheetState) -> some View {
        SheetFooter(reason: model.operationFooterReason) {
            if model.offersCheckAgain {
                // The fix for a precondition the world changes — Xcode quit, the vault reconnected (review I3).
                Button(L10n.tr("app.run.checkAgain")) { model.checkOperationAgain() }.actionButton().controlSize(.small)
            }
            switch s.phase {
            case .running:
                StatusLabel(.neutral, L10n.tr("app.run.cannotStop"), symbol: "info.circle").font(.footnote)
            case .succeeded, .failed:
                if model.offersBackToOffload {
                    Button(L10n.tr("app.run.backToOffload")) { model.backToOffload() }.actionButton()
                }
                Button(L10n.tr("app.run.showInHistory")) { model.showHistoryFromOperation() }.actionButton().disabled(model.isOperationRunning)
            case .review:
                EmptyView()
            }
        } trailing: {
            switch s.phase {
            case .review:
                if s.kind.deletesData {
                    // Deletes data here (ruling B-2, ADR-0012): Cancel stays the default, so Return cancels; Escape closes
                    // the sheet too (`onExitCommand`). The destructive verb is bordered and never the default.
                    Button(L10n.tr("app.action.cancel")) { model.closeOperationSheet() }.keyboardShortcut(.defaultAction)
                    Button(model.operationConfirmTitle, role: .destructive) { Task { await model.runOperation() } }
                        .actionButton().disabled(!model.canConfirmOperation)
                } else {
                    Button(L10n.tr("app.action.cancel"), role: .cancel) { model.closeOperationSheet() }.keyboardShortcut(.cancelAction)
                    Button(model.operationConfirmTitle) { Task { await model.runOperation() } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!model.canConfirmOperation)
                }
            case .running:
                EmptyView()
            case .succeeded, .failed:
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
                    NoticeRow(.warning, L10n.tr("app.run.interrupted.title"), detail: L10n.tr("app.run.interrupted.detail"))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items) { item in
                                Text(verbatim: item.summary).font(.callout).lineLimit(2)
                                ForEach(item.commands, id: \.self) { command in
                                    HStack {
                                        Text(verbatim: command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                        Spacer()
                                        CopyCommandButton(copy: { copy(command) }, accessibilityLabel: L10n.tr("app.run.interrupted.copy.a11y", command))
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
