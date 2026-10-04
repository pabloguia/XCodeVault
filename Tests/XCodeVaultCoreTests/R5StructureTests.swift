import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// R5, commit 3 of the HIG review (§5): the Mac-native structure — the window's subtitle, the filter's summary, the
/// Simulators table's words, the sidebar's symbols — over the made-up fixtures. No window.
@MainActor
final class R5StructureTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    func testTheSubtitleIsTheScanOrTheMac() async throws {
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: detailSampleSurvey())
        XCTAssertEqual(model.windowSubtitle, "", "nothing to say before the first scan")
        await model.refresh()
        let host = try XCTUnwrap(model.report?.host)
        XCTAssertTrue(model.windowSubtitle.contains(host.macOSVersion), model.windowSubtitle)
        XCTAssertTrue(model.windowSubtitle.contains(ByteCount.format(host.dataVolumeFreeBytes)), model.windowSubtitle)
    }

    func testTheFilterSummaryNamesTheBucketsAndTheSearch() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertEqual(AppText.storageFilterSummary([.deleteAndRegenerate, .parkExternally], query: ""), "Filtering: Delete and Park")
        XCTAssertEqual(AppText.storageFilterSummary([], query: " derived "), "Filtering: “derived”")
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for bucket in SavingsBucket.allCases {
                XCTAssertFalse(AppText.bucketShortName(bucket).hasPrefix("app."), "\(locale) \(bucket)")
            }
            XCTAssertFalse(AppText.storageFilterSummary(SavingsBucket.allCases, query: "x").contains("%"), locale)
        }
    }

    func testASimulatorRowsStateSaysMountedAndNeverAQuestionMark() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let mounted = SimulatorListRow(kind: .runtime, rowID: "R", name: "iOS 26.0", detail: "26.0", state: "Ready", isMounted: true, path: nil, bytes: nil)
        XCTAssertEqual(AppText.simulatorState(mounted), "Ready · Mounted")
        let unknown = SimulatorListRow(kind: .device, rowID: "D", name: "iPhone", detail: "iOS 26.0", state: nil, isMounted: nil, path: nil, bytes: nil)
        XCTAssertEqual(AppText.simulatorState(unknown), "—")
    }

    func testTheSidebarsDeleteIsTrashAndTheBucketKeepsItsSymbol() {
        XCTAssertEqual(SidebarSection.delete.symbol, "trash")
        XCTAssertEqual(SavingsBucket.deleteAndRegenerate.symbolName, "arrow.counterclockwise.circle", "the bucket's symbol is unchanged (BRAND.md)")
        XCTAssertEqual(SidebarSection.park.symbol, SavingsBucket.parkExternally.symbolName)
        XCTAssertNotNil(NSImage(systemSymbolName: SidebarSection.delete.symbol, accessibilityDescription: nil))
    }

    func testCopySummaryCopiesTheSelectedOperations() async {
        let t = TempDir()
        let copied = CopiedStrings()
        var survey = detailSampleSurvey()
        survey.4 = [
            JournalEntry(
                id: "op1", sequence: 1, timestamp: Date(timeIntervalSince1970: 1_000), kind: .clean, state: .completed, summary: "cleaned", paths: [],
                bytes: nil, detail: [:], toolVersion: "t")
        ]
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: survey, copied: copied)
        await model.refresh()
        model.copyHistorySummaries(["op1", "missing"])
        XCTAssertEqual(copied.strings.count, 1)
        XCTAssertTrue(copied.strings.first?.hasPrefix("cleaned") ?? false)
        model.copyHistorySummaries([])
        XCTAssertEqual(copied.strings.count, 1, "nothing selected, nothing copied")
    }
}

/// R5 review I2 and m7: the inline result and the helper sheet's two states fit, measured as `ScreenFitTests` and
/// `R3SheetFitTests` measure, in English and Japanese. No window.
@MainActor
final class R5FitTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func windowHeightAsked<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 560)
        host.layoutSubtreeIfNeeded()
        return host.intrinsicContentSize.height
    }

    private func minimumHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: width, height: 1)).height
    }

    func testALongInlineResultNeverAsksTheWindowForHeight() async throws {
        let long = String(repeating: "A long line from the helper that wraps at a narrow width, as `xcodevaultctl vault init` steps do. ", count: 12)
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            let t = TempDir()
            let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, fullDiskAccess: .notGranted, survey: screenFitStressSurvey())
            await model.refresh()
            model.feedback = AppFeedback(kind: .notice, title: long, detail: [long, long])
            for section in SidebarSection.allCases {
                model.section = section
                let asked = windowHeightAsked(MainView(model: model))
                XCTAssertLessThanOrEqual(asked, ScreenFitTests.ceiling, "\(language), \(section.rawValue): the window asks for \(asked) pt")
            }
        }
    }

    func testTheHelperSheetFitsInBothStates() async {
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            let t = TempDir()
            let model = makeModel(SwitchableHelper(.awaitingApproval), journal: t)
            model.refreshPermissions()
            model.request(.emptyCoreSimulatorDyldCache)
            XCTAssertTrue(model.helperSheetIsPresented)
            XCTAssertLessThanOrEqual(minimumHeight(HelperRequestSheet(model: model), width: 420), R3SheetFitTests.ceiling, "\(language) request")
            model.installHelper(then: model.pendingPrivilegedAction)
            XCTAssertNotNil(model.helperProgress)
            XCTAssertLessThanOrEqual(minimumHeight(HelperRequestSheet(model: model), width: 420), R3SheetFitTests.ceiling, "\(language) waiting")
            model.dismissHelperSheet()
        }
    }
}
