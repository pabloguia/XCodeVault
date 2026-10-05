import AppKit
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// R7-B: the design system's decisions (docs/design/DESIGN_SYSTEM.md §5.2) — the status mapping, the tags, the chip's
/// contrast, the disabled reasons, the button titles and the chart's label column. No window, no disk, no scan.
@MainActor
final class DesignSystemTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    // MARK: Status

    func testEveryStatusKindHasItsOwnSymbolAndTintExceptBlockerAndDanger() {
        var pairs: [String: StatusKind] = [:]
        for kind in StatusKind.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil), kind.rawValue)
            let key = kind.symbol + "|" + String(describing: kind.tint)
            XCTAssertNil(pairs[key], "\(kind) and \(pairs[key].map(\.rawValue) ?? "") look the same")
            pairs[key] = kind
        }
        XCTAssertEqual(String(describing: StatusKind.blocker.tint), String(describing: StatusKind.danger.tint), "same tint")
        XCTAssertNotEqual(StatusKind.blocker.symbol, StatusKind.danger.symbol, "different symbol")
        XCTAssertTrue(StatusKind.allCases.allSatisfy { !$0.symbol.hasPrefix("exclamationmark.triangle") || $0.symbol.hasSuffix(".fill") }, "filled only")
    }

    func testTheDomainsStatesMapToKinds() {
        XCTAssertEqual(StatusKind.severity(.critical), .danger)
        XCTAssertEqual(StatusKind.severity(.error), .blocker)
        XCTAssertEqual(StatusKind.severity(.warning), .warning)
        XCTAssertEqual(StatusKind.severity(.info), .info)
        XCTAssertEqual(StatusKind.vaultVerdict(.ready), .success)
        XCTAssertEqual(StatusKind.vaultVerdict(.readyWithWarnings), .warning)
        XCTAssertEqual(StatusKind.vaultVerdict(.needsAttention), .warning)
        XCTAssertEqual(StatusKind.vaultVerdict(.notUsable), .blocker)
        XCTAssertEqual(DriveVerdict.allCases.map(StatusKind.driveVerdict), [.success, .neutral, .neutral, .neutral])
        XCTAssertEqual(StatusKind.historyOutcome(.failed), .blocker)
        XCTAssertEqual(StatusKind.historyOutcome(.interrupted), .warning)
        XCTAssertEqual(StatusKind.historyOutcome(.completed), .neutral, "a finished operation is not news")
        XCTAssertEqual(StatusKind.access(.granted, isNeeded: true), .success)
        XCTAssertEqual(StatusKind.access(.missing, isNeeded: true), .warning)
        XCTAssertEqual(StatusKind.access(.missing, isNeeded: false), .neutral, "an access nobody needs is not a failure")
        XCTAssertEqual(StatusKind.vaultStatus(.noVault), .neutral)
        XCTAssertEqual(StatusKind.vaultStatus(.ready(volumeName: "V")), .success)
        XCTAssertEqual(StatusKind.feedback(.success), .success)
        XCTAssertEqual(StatusKind.feedback(.notice), .info)
        XCTAssertEqual(StatusKind.offlineVault(R6DriveTests.vaultCheck()), .success)
        XCTAssertEqual(StatusKind.offlineVault(R6DriveTests.vaultCheck(state: .absent, mount: nil)), .blocker)
    }

    // MARK: Tags

    /// Rule 10 stays visible: the Experimental tag is the word and the flask, in every language.
    func testTheExperimentalTagIsTheWordAndTheFlask() {
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let tag = Tag.marker(.experimental)
            XCTAssertEqual(tag.symbol, "flask")
            XCTAssertEqual(tag.text, AppText.marker(.experimental))
            XCTAssertFalse(tag.text.hasPrefix("app.") || tag.text.isEmpty, locale)
            XCTAssertNil(tag.tint, "the experimental symbol is secondary like its word")
        }
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertEqual(Tag.marker(.experimental).text, "Experimental")
        for marker in DesignSystemGallery.markers {
            XCTAssertNotNil(NSImage(systemSymbolName: Tag.symbol(marker), accessibilityDescription: nil), "\(marker)")
        }
        for kind in JournalTimeline.Kind.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: Tag.historyKind(kind).symbol, accessibilityDescription: nil), kind.rawValue)
        }
    }

    // MARK: FilterChip contrast (WCAG 1.4.11)

    /// `color` drawn over `surface`, alpha composited, as sRGB components.
    private func composite(_ color: NSColor, over surface: NSColor, _ appearance: NSAppearance.Name) -> (Double, Double, Double, Double, Double, Double) {
        var out = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!, s = surface.usingColorSpace(.sRGB)!
            let a = Double(c.alphaComponent)
            func mix(_ x: CGFloat, _ y: CGFloat) -> Double { Double(x) * a + Double(y) * (1 - a) }
            out = (
                mix(c.redComponent, s.redComponent), mix(c.greenComponent, s.greenComponent), mix(c.blueComponent, s.blueComponent),
                Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent)
            )
        }
        return out
    }

    private func contrast(_ c: (Double, Double, Double, Double, Double, Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) }
        let (a, b) = (lum(c.0, c.1, c.2), lum(c.3, c.4, c.5))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The chip's outline is its only boundary: it clears 3:1 on the window and control backgrounds, light and dark — and
    /// so does the selected chip's accent stroke.
    func testTheChipStrokesClearThreeToOne() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for surface in [NSColor.windowBackgroundColor, .controlBackgroundColor] {
                for stroke in [Tokens.chipStrokeNS, NSColor.controlAccentColor] {
                    let ratio = contrast(composite(stroke, over: surface, appearance))
                    XCTAssertGreaterThanOrEqual(ratio, 3, "\(stroke) on \(surface) in \(appearance.rawValue): \(ratio)")
                }
            }
        }
    }

    // MARK: Disabled says why (ruling B-3)

    func testEveryBlockerHasVisibleWordsInEveryLanguage() {
        let blockers: [OperationBlocker] = [
            .chooseVault, .chooseFolder, .chooseRuntime, .acknowledgeTests, .simulatorWorkRunning, .driveGone, .typeName("PABLO"), .diskChanged,
            .core("Core says why."),
        ]
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for b in blockers {
                let text = AppModel.blockerText(b)
                XCTAssertFalse(text.isEmpty || text.hasPrefix("app."), "\(b) in \(locale)")
            }
        }
    }

    func testABlockedReviewSaysWhyInTheFooterAndOffersCheckAgain() async throws {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(blockers: [.simulatorWorkRunning]) }
        let m = makeR3Model(ops, survey: sampleSurvey(checks: [r3VaultCheck()]))
        await m.refresh()
        m.openRun(r3Row())
        await eventually("the review") { m.operationSheet?.preview != nil && m.operationSheet?.isPreviewing == false }
        XCTAssertFalse(m.canConfirmOperation)
        XCTAssertEqual(m.operationFooterReason, AppModel.blockerText(.simulatorWorkRunning))
        XCTAssertTrue(m.offersCheckAgain)
        ops.preview = { _, _ in OperationPreview(prepared: .migration(R3RunInAppTests.plan())) }
        m.checkOperationAgain()
        await eventually("ready") { m.canConfirmOperation }
        XCTAssertNil(m.operationFooterReason, "enabled: no reason")
        XCTAssertFalse(m.offersCheckAgain)
    }

    func testRemoveOriginalSaysWhyItIsDisabled() async throws {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview(prepared: .migration(R3RunInAppTests.plan())) }
        ops.result = .success(.copied(R3RunInAppTests.outcome()))
        let m = makeR3Model(ops, survey: sampleSurvey(checks: [r3VaultCheck()]))
        await m.refresh()
        m.openRun(r3Row())
        await eventually("the review") { m.canConfirmOperation }
        await m.runOperation()
        XCTAssertTrue(m.removalNeedsConfirmation, "Archives are not regenerable")
        XCTAssertFalse(m.canRemoveOriginal)
        XCTAssertEqual(m.removeOriginalDisabledReason, L10n.tr("app.run.removeOriginal.needsConfirm"))
        m.operationSheet?.confirmRemoval = true
        XCTAssertTrue(m.canRemoveOriginal)
        XCTAssertNil(m.removeOriginalDisabledReason)
    }

    // MARK: Button titles (audit rows 4, 16)

    func testButtonTitlesAreShortVerbsWithoutPaths() async throws {
        let options: [PreparationOption] = [
            .addVolume(container: "disk3"), .addPartition(after: "disk2s2", freeBytes: 499_980_000_000), .eraseVolume(volume: "disk6s1", name: "Transfer"),
            .eraseDisk(disk: "disk6"),
        ]
        for o in options {
            let t = DriveText.optionButton(o)
            XCTAssertFalse(t.contains("/"), t)
            XCTAssertLessThanOrEqual(t.count, 40, t)
            XCTAssertTrue(t.hasSuffix("…"), "opens a sheet: \(t)")
        }
        for kind in [OperationKind.setDerivedData, .setArchives] {
            let ops = ScriptedOperations()
            ops.preview = { _, _ in OperationPreview(destination: "/Volumes/PABLO/XCodeVault/Archives", prepared: .migration(R3RunInAppTests.plan())) }
            let m = makeR3Model(ops, survey: sampleSurvey(checks: [r3VaultCheck()]))
            await m.refresh()
            m.openRun(r3Row(categoryID: kind == .setArchives ? "archives" : "derivedData", bucket: .runFromExternal))
            await eventually("the review") { m.operationSheet?.preview?.prepared != nil }
            XCTAssertEqual(m.operationConfirmTitle, "Use This Folder", "\(kind)")
        }
        XCTAssertEqual(L10n.tr("app.run.confirm.exportInstaller", "watchOS"), "Export the watchOS Installer")
        XCTAssertLessThanOrEqual(L10n.tr("app.run.confirm.externalizeArchives", "18 GB", "PABLO").count, 40)
    }

    /// U7's premise: a drive row never has two prominent buttons — the recommended option and **Use This Drive** as the
    /// primary are exclusive, on every fixture drive.
    func testADriveRowHasAtMostOnePrimary() throws {
        for mediaOwners in [true, false] {
            let snap = try R6DriveTests.snapshot(mediaOwners: mediaOwners)
            for a in DriveEvaluation.assessAll(snap, vaults: [R6DriveTests.vaultCheck()]) {
                // The row's buttons, as the view draws them: each is prominent exactly when it is the one `primaryAction`.
                var buttons = a.commandOptions.map { DriveAssessment.PrimaryAction.option($0) }
                if a.verdict == .canBeUsed { buttons.append(.useDrive) }
                XCTAssertLessThanOrEqual(buttons.filter { $0 == a.primaryAction }.count, 1, a.disk.id)
                if let primary = a.primaryAction { XCTAssertTrue(buttons.contains(primary), "the primary is one of the row's buttons: \(a.disk.id)") }
            }
        }
    }

    func testTheOptionsFootnoteSaysWhatEachCosts() throws {
        let snap = try R6DriveTests.snapshot()
        let media = DriveEvaluation.assess(try XCTUnwrap(snap.disks.first { $0.id == "disk2" }), in: snap, vaults: [])
        let note = try XCTUnwrap(DriveText.optionsFootnote(media))
        XCTAssertTrue(note.contains("“Add a Case-insensitive Volume…” is recommended"), note)
        XCTAssertTrue(note.contains(L10n.tr("app.drives.options.eraseDeletes")), note)
        let vault = DriveEvaluation.assess(try XCTUnwrap(snap.disks.first { $0.id == "disk10" }), in: snap, vaults: [R6DriveTests.vaultCheck()])
        XCTAssertNil(DriveText.optionsFootnote(vault), "no options, no footnote")
    }

    // MARK: A+B fix round

    /// M3: every destructive kind leads with a symbol that exists; the others have none.
    func testEveryDestructiveKindHasItsSymbol() {
        for kind in OperationKind.allCases {
            if kind.deletesData {
                let symbol = try? XCTUnwrap(kind.destructiveSymbol, "\(kind)")
                XCTAssertNotNil(NSImage(systemSymbolName: symbol ?? "", accessibilityDescription: nil), "\(kind)")
            } else {
                XCTAssertNil(kind.destructiveSymbol, "\(kind)")
            }
        }
        for symbol in [DestructiveSymbol.delete, DestructiveSymbol.erase, DestructiveSymbol.uninstall] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    /// M6: a stderr line is never told by its red alone: it starts with "! ".
    func testAStderrLineHasAPrefixAsWellAsItsColor() {
        XCTAssertEqual(LogLine(.stderr, "failed").rendered, "! failed")
        XCTAssertFalse(LogLine(.stdout, "ok").rendered.hasPrefix("!"))
    }

    /// M4, M11: the statuses views used to choose inline.
    func testTheInlineStatusChoicesAreMappings() {
        XCTAssertEqual(StatusKind.operationDone(foldersError: nil), .success)
        XCTAssertEqual(StatusKind.operationDone(foldersError: "Cannot create"), .warning)
        XCTAssertNil(StatusKind.historyOutcomeSymbol(.failed), "a failure takes the blocker's own symbol")
        XCTAssertNil(StatusKind.historyOutcomeSymbol(.interrupted))
        XCTAssertEqual(StatusKind.historyOutcomeSymbol(.completed), JournalTimeline.Outcome.completed.symbolName)
        XCTAssertNotNil(NSImage(systemSymbolName: StatusKind.notQualifyingSymbol, accessibilityDescription: nil))
    }

    /// M2: while the review is being checked, the footer says so; the delete footer says why it is disabled.
    func testEveryDisabledControlSaysWhy() async throws {
        let ops = ScriptedOperations()
        ops.preview = { _, _ in OperationPreview() }
        let m = makeR3Model(ops, survey: sampleSurvey(checks: [r3VaultCheck()]))
        await m.refresh()
        m.openRun(r3Row())
        m.operationSheet?.isPreviewing = true
        XCTAssertEqual(m.operationFooterReason, OperationText.stage(.planning))
        m.operationSheet?.isPreviewing = false
        m.operationSheet?.preview = OperationPreview()
        XCTAssertEqual(m.operationFooterReason, L10n.tr("app.run.reason.notReady"), "nothing prepared, nothing blocking: still a reason")
        XCTAssertNil(m.operationChoicesLockedReason)
        m.operationSheet?.offloadToReturnTo = OperationInputs()
        XCTAssertEqual(m.operationChoicesLockedReason, L10n.tr("app.run.lockedForOffload"))
        XCTAssertEqual(m.deleteDisabledReason(selectedDeletable: 0), L10n.tr("app.clean.selectToDelete"))
        XCTAssertNil(m.deleteDisabledReason(selectedDeletable: 2))
        // While a cleanup runs (`isCleaning`, set only by `applyClean`) the reason is `app.clean.inProgress`, checked by its
        // key's presence here; running a real cleanup is out of a design test's reach.
        XCTAssertFalse(L10n.tr("app.clean.inProgress").hasPrefix("app."))
    }

    // MARK: The chart's label column (R7-B)

    func testTheLabelColumnIsTheLongestLabelUpToItsMaximum() {
        XCTAssertEqual(BarChartLayout.labelColumnWidth([80, 120]), 120)
        XCTAssertEqual(BarChartLayout.labelColumnWidth([900]), BarChartLayout.labelColumnMaxWidth, "a longer label wraps inside the maximum")
        XCTAssertEqual(BarChartLayout.labelColumnWidth([]), 40)
        let short = ChartLabelMetrics.width("Park"), long = ChartLabelMetrics.width("Run Externally")
        XCTAssertGreaterThan(long, short)
        let storage = BarChartLayout.labelColumnWidth(SavingsBucket.allCases.map { ChartLabelMetrics.width(AppText.bucketShortName($0)) })
        XCTAssertLessThan(storage, BarChartLayout.labelColumnMaxWidth, "Storage's short names leave no 260-pt gap")
    }
}

/// The design system's gallery (docs/design/DESIGN_SYSTEM.md §5.3): every component and state — buttons enabled and
/// disabled, tags, filter chips on and off, every status label, a notice with actions, a sheet footer with a disabled
/// reason — in light and dark, en and ja. `XCV_SNAPSHOTS=1` only; reviewers compare this, not twenty screens. Off-screen:
/// no window. Not Increase Contrast: off-screen, the high-contrast appearance names do not change SwiftUI's rendering
/// (its renders were byte-identical to these, A+B review I1) and `colorSchemeContrast` cannot be set, so increased
/// contrast is a real-window check.
@MainActor
final class DesignSystemSnapshotTests: XCTestCase {
    nonisolated override func tearDown() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        super.tearDown()
    }

    func testWriteTheGallery() throws {
        guard SnapshotWriter.isEnabled else { return }
        var written: [String] = []
        let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        for locale in ["en", "ja"] {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for (appearance, tag) in appearances {
                written.append(
                    try SnapshotWriter.write(
                        DesignSystemGallery().padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                        name: "r7b-design-system-\(locale)-\(tag)", size: NSSize(width: 1200, height: 900), appearance: appearance))
            }
        }
        print("snapshots:\n" + written.joined(separator: "\n"))
    }
}

/// Every component in every state, for the gallery snapshot.
@MainActor
struct DesignSystemGallery: View {
    static let markers: [SavingsMarker] = [.experimental, .losesUserData, .actsImmediately, .newDataOnly, .perItem(3), .needsRoot(.helper)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(verbatim: "Buttons").font(.headline)
            HStack(spacing: Spacing.s) {
                Button(L10n.tr("app.drives.useDrive")) {}.buttonStyle(.borderedProminent)
                Button(L10n.tr("app.drives.useDrive")) {}.buttonStyle(.borderedProminent).disabled(true)
                Button(L10n.tr("app.run.checkAgain")) {}.actionButton()
                Button(L10n.tr("app.run.checkAgain")) {}.actionButton().disabled(true)
            }
            .fixedSize()
            HStack(spacing: Spacing.s) {
                // The real helper (A+B review M3, R7-C review M-f): its danger symbol shows in the gallery.
                DestructiveButton(L10n.tr("app.clean.deleteSelected"), symbol: DestructiveSymbol.delete) {}
                DestructiveButton(L10n.tr("app.clean.deleteSelected"), symbol: DestructiveSymbol.delete) {}.disabled(true)
                Button(L10n.tr("app.overview.showInHealth")) {}.buttonStyle(.link)
                CopyCommandButton {}
            }
            .fixedSize()
            Text(verbatim: "Tags").font(.headline)
            HStack(spacing: Spacing.m) {
                ForEach(Array(Self.markers.enumerated()), id: \.offset) { _, m in Tag.marker(m) }
            }
            HStack(spacing: Spacing.m) {
                Tag.historyKind(.migration)
                Tag.historyKind(.diskPreparation)
                Tag.historyKind(.clean)
            }
            Text(verbatim: "Filter chips").font(.headline)
            HStack(spacing: Spacing.s) {
                Toggle(isOn: .constant(false)) { Label(AppText.bucketShortName(.parkExternally), systemImage: "shippingbox") }.toggleStyle(FilterChipStyle())
                Toggle(isOn: .constant(true)) { Label(AppText.bucketShortName(.keepLocal), systemImage: "internaldrive") }.toggleStyle(FilterChipStyle())
                Toggle(isOn: .constant(true)) { Label(AppText.bucketShortName(.deleteAndRegenerate), systemImage: "trash") }
                    .toggleStyle(FilterChipStyle()).disabled(true)
            }
            Text(verbatim: "Status").font(.headline)
            HStack(spacing: Spacing.m) {
                ForEach(StatusKind.allCases, id: \.self) { k in StatusLabel(k, k.rawValue.capitalized) }
            }
            .font(.callout)
            Text(verbatim: "Notices").font(.headline)
            NoticeRow(.warning, L10n.tr("app.run.interrupted.title"), detail: L10n.tr("app.run.interrupted.detail")) {
                CopyCommandButton {}
            }
            GroupBox { NoticeRow(.danger, L10n.tr("app.prep.destroys.title"), detail: "• STICK (12 GB)") }
            Text(verbatim: "Sheet footer").font(.headline)
            VStack(spacing: 0) {
                Divider()
                SheetFooter(reason: AppModel.blockerText(.acknowledgeTests)) {
                    Button(L10n.tr("app.run.checkAgain")) {}.actionButton().controlSize(.small)
                } trailing: {
                    Button(L10n.tr("app.action.cancel"), role: .cancel) {}.keyboardShortcut(.cancelAction)
                    Button(L10n.tr("app.run.confirm.useFolder")) {}.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(true)
                }
                .padding(.top, Spacing.m)
            }
            .frame(width: 560)
        }
    }
}
