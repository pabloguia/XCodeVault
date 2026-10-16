import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// The Details fixture made long (R1): many planner warnings and skipped lines, the dyld cache's root-only row (already in
/// the bucket sample), many simulator runtimes and devices, and volumes with every warning. Never measured: made up.
func screenFitStressSurvey() -> AppModel.Survey {
    var survey = detailSampleSurvey()
    let gb: UInt64 = 1_000_000_000
    survey.3.warnings = (1...30).map { "Planner warning \($0): a sentence long enough to wrap at a narrow width, as the real ones do." }
    survey.3.skipped = (1...40).map { "/Users/tester/Library/Developer/fixture/skipped-\($0): not offered, and why, in one line." }
    survey.0.runtimes += (1...20).map { i in
        SimulatorRuntime(
            identifier: "S\(i)", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-\(i)", platformIdentifier: "com.apple.platform.iphonesimulator",
            version: "18.\(i)", build: "22A\(i)", state: "Ready", sizeBytes: UInt64(i) * gb, path: "/Library/Developer/CoreSimulator/Images/S\(i).dmg")
    }
    survey.0.devices += (1...60).map { i in
        SimulatorDevice(
            udid: "X\(i)", name: "iPhone \(i)", runtimeIdentifier: iOSRuntimeID, state: "Shutdown", isAvailable: true,
            dataPath: "/Users/tester/Library/Developer/CoreSimulator/Devices/X\(i)/data", dataPathSize: UInt64(i) * 100_000_000)
    }
    survey.0.volumes += (1...12).map { i in
        Volume(
            deviceNode: "/dev/disk\(10 + i)s1", volumeName: "USB \(i)", volumeUUID: "V\(i)", mountPoint: "/Volumes/USB \(i)",
            filesystemPersonality: "Case-sensitive APFS", filesystemType: "apfs", isInternal: false, isRemovableMedia: true, isEjectable: true,
            busProtocol: "USB", isSolidState: false, isWritable: true, ownersEnabled: true, totalBytes: 64 * gb, freeBytes: 1 * gb, isBootVolume: false)
    }
    // R4: Health's cards with long folded text and per-device lines, and a History of operations over many days.
    survey.1 += (1...25).map { i in
        Finding(
            id: "stress-\(i)", severity: [.info, .warning, .error, .critical][i % 4], title: "Stress finding \(i) with a title long enough to wrap",
            detail: String(repeating: "A sentence of explanation that goes on for a while. ", count: 8), path: "/Users/tester/Library/Developer/x\(i)",
            remediation: "Do the first thing. Then the second, which takes longer to say.", evidence: "fixture", bytes: UInt64(i) * gb,
            parts: Finding.Parts(
                explanation: "The explanation alone. More of it.", lines: (1...6).map { Finding.Line(label: "UDID-\(i)-\($0)", bytes: UInt64($0) * gb) },
                notOfferedByClean: "reported for accounting only."))
    }
    let kinds: [JournalEntry.Kind] = [.clean, .runtimeDelete, .runtimeOffload, .migration, .xcodeLocationChange]
    survey.4 += (1...120).flatMap { i -> [JournalEntry] in
        let at = Date(timeIntervalSince1970: 1_800_000_000 - Double(i) * 30_000)
        let kind = kinds[i % kinds.count]
        return [
            JournalEntry(
                id: "stress-op\(i)", sequence: 1000 + 2 * i, timestamp: at, kind: kind, state: .started,
                summary: "Stress operation \(i) with a summary long enough to be cut in its row and given whole in the tooltip", paths: [], bytes: nil,
                detail: kind == .migration ? ["direction": "externalize"] : [:], toolVersion: "t"),
            JournalEntry(
                id: "stress-op\(i)", sequence: 1001 + 2 * i, timestamp: at, kind: kind, state: i % 7 == 0 ? .failed : .completed, summary: "done",
                paths: [], bytes: UInt64(i) * 1_000_000, detail: [:], toolVersion: "t"),
        ]
    }
    return survey
}

/// The stress fixture with nothing the Delete table can list: the notes panel is the screen, so it starts open
/// (`DeleteNotes.startsExpanded`), and its bounded scroll is what is measured.
func screenFitNotesOnlySurvey() -> AppModel.Survey {
    var survey = screenFitStressSurvey()
    survey.3.actions = []
    return survey
}

/// Every screen fits any window (R1). A screen whose minimum height is taller than the window makes the split view taller
/// than the window: macOS centers it, the sidebar goes off the top and the table shows only empty stripes. This measures
/// each screen's minimum the way the window does — `NSHostingController.sizeThatFits` with a 1 pt proposed height — and
/// holds it to 300 pt: the 620 pt window minimum less the toolbar, with margin. It opens no window.
@MainActor
final class ScreenFitTests: XCTestCase {
    static let ceiling: CGFloat = 300

    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func minimumHeight<V: View>(_ view: V) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: 1000, height: 1)).height
    }

    /// The height the whole window's content asks for once laid out at a typical size: AppKit sizes and centres the
    /// window's split view on this, so a large value pushes the sidebar and the screen's top out of sight.
    private func windowHeightAsked<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 560)
        host.layoutSubtreeIfNeeded()
        return host.intrinsicContentSize.height
    }

    private func assertEveryScreenFits(_ survey: AppModel.Survey, _ fixture: String) async throws {
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            let t = TempDir()
            let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, fullDiskAccess: .notGranted, survey: survey)
            await model.refresh()
            let report = try XCTUnwrap(model.report)
            for section in SidebarSection.allCases {
                model.section = section
                let height = minimumHeight(MainView(model: model).detail(report))
                XCTAssertLessThanOrEqual(height, Self.ceiling, "\(fixture), \(language), \(section.rawValue): minimum height \(height)")
                // The whole window as well: the screen alone can fit while, inside the split view, its wrapped text is
                // measured at a near-zero width and the window asks for thousands of points. That is what the user saw on
                // Delete after the first R1 fix (4006 pt on this Mac's real scan; 16 pt on every other screen).
                let asked = windowHeightAsked(MainView(model: model))
                XCTAssertLessThanOrEqual(asked, Self.ceiling, "\(fixture), \(language), \(section.rawValue): the window asks for \(asked) pt")
            }
        }
    }

    func testEveryScreenFitsWithTheDetailSample() async throws {
        try await assertEveryScreenFits(detailSampleSurvey(), "detail sample")
    }

    func testEveryScreenFitsWithTheStressFixture() async throws {
        try await assertEveryScreenFits(screenFitStressSurvey(), "stress")
    }

    func testEveryScreenFitsWhenTheDeleteNotesStartOpen() async throws {
        let survey = screenFitNotesOnlySurvey()
        let t = TempDir()
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: survey)
        await model.refresh()
        XCTAssertEqual(model.deleteNotes?.startsExpanded, true, "the fixture measures the open panel")
        try await assertEveryScreenFits(survey, "notes only")
    }

    /// Delete with the helper's access row showing above the table (spec §6.3: never folded away) still fits, in en and ja.
    func testDeleteFitsWithTheAccessRowShowing() async throws {
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            let t = TempDir()
            let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, fullDiskAccess: .notGranted, survey: screenFitStressSurvey())
            await model.refresh()
            XCTAssertNotNil(model.deleteAccessRow, "the stress fixture shows the access row")
            model.section = .delete
            let height = minimumHeight(MainView(model: model).detail(try XCTUnwrap(model.report)))
            XCTAssertLessThanOrEqual(height, Self.ceiling, "\(language): Delete with the access row, minimum height \(height)")
        }
    }

    /// Review M5: the notes panel opened by the user while the table has rows, with the access row above the table — the
    /// tallest Delete there is — still fits, in en and ja.
    func testDeleteFitsWithTheNotesOpenOverATableWithRows() async throws {
        for language in ["en", "ja"] {
            L10n.configure(override: language, environment: [:], preferred: [])
            let t = TempDir()
            let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, fullDiskAccess: .notGranted, survey: screenFitStressSurvey())
            await model.refresh()
            XCTAssertEqual(model.deleteList?.groups.isEmpty, false, "the table has rows")
            XCTAssertNotNil(model.deleteAccessRow)
            let height = minimumHeight(DeleteView(model: model, notesInitiallyExpanded: true))
            XCTAssertLessThanOrEqual(height, Self.ceiling, "\(language): Delete with rows and the notes open, minimum height \(height)")
        }
    }

    /// Review M3: the measure catches the construct that regressed — a `Table` with a fixed floor inside a stack.
    func testTheMeasureCatchesATableWithAFloor() {
        struct Row: Identifiable {
            let id: Int
        }
        let rows = (0..<3).map(Row.init)
        let floored = VStack {
            Table(rows) { TableColumn("n") { Text(verbatim: String($0.id)) } }.frame(minHeight: 451)
        }
        XCTAssertGreaterThan(minimumHeight(floored), Self.ceiling)
        XCTAssertLessThanOrEqual(minimumHeight(VStack { Table(rows) { TableColumn("n") { Text(verbatim: String($0.id)) } } }), Self.ceiling)
    }

    /// Control: the measurement does catch a screen with a rigid floor, as Delete's `Table.frame(minHeight: 200)` was.
    func testTheMeasureCatchesARigidMinimum() {
        XCTAssertGreaterThan(minimumHeight(Color.clear.frame(minHeight: 451)), Self.ceiling)
        XCTAssertLessThanOrEqual(minimumHeight(ScrollView { Color.clear.frame(height: 2000) }), Self.ceiling)
    }
}
