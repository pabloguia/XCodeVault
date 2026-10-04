import AppKit
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

// R4: Health as cards, History as operations, Access registering the app before the pane opens. Nothing here scans this
// Mac, writes its journal, touches TCC, launchd or System Settings, or opens a window: the registration is a closure the
// tests replace, and the one live attempt below opens a temporary folder.

private func finding(
    _ id: String, _ severity: Finding.Severity, detail: String = "One sentence. Another.", bytes: UInt64? = nil, remediation: String? = nil,
    path: String? = nil, evidence: String? = nil, action: PrivilegedAction? = nil, parts: Finding.Parts? = nil
) -> Finding {
    Finding(
        id: id, severity: severity, title: id, detail: detail, path: path, remediation: remediation, evidence: evidence, action: action, bytes: bytes,
        parts: parts)
}

private func entry(
    _ id: String, _ sequence: Int, _ kind: JournalEntry.Kind, _ state: JournalEntry.State, summary: String = "s", at: Date = Date(timeIntervalSince1970: 0),
    bytes: UInt64? = nil, detail: [String: String] = [:]
) -> JournalEntry {
    JournalEntry(
        id: id, sequence: sequence, timestamp: at, kind: kind, state: state, summary: summary, paths: [], bytes: bytes, detail: detail, toolVersion: "t")
}

final class HealthCardTests: XCTestCase {
    func testTheFirstSentenceEndsAtTheFirstRealStop() {
        XCTAssertEqual(HealthCard.firstSentence("One. Two."), "One.")
        XCTAssertEqual(HealthCard.firstSentence("  Is it? Yes."), "Is it?")
        XCTAssertEqual(HealthCard.firstSentence("No stop at all"), "No stop at all")
        XCTAssertEqual(HealthCard.firstSentence("Line one\nLine two. More."), "Line one")
        // A period inside a name or a number, an abbreviation, or inside backticks does not end it.
        XCTAssertEqual(HealthCard.firstSentence("Opens TCC.db on 26.6.2 and stops. Then more."), "Opens TCC.db on 26.6.2 and stops.")
        XCTAssertEqual(HealthCard.firstSentence("Caches, e.g. dyld ones, grow. Later."), "Caches, e.g. dyld ones, grow.")
        XCTAssertEqual(HealthCard.firstSentence("Run `a. b` now. Then."), "Run `a. b` now.")
        XCTAssertEqual(HealthCard.firstSentence("Ends with a stop."), "Ends with a stop.")
        XCTAssertEqual(HealthCard.firstSentence(""), "")
    }

    func testCardsAreOrderedBySeverityThenSizeThenAsListed() {
        let findings = [
            finding("info-small", .info, bytes: 1), finding("warn-none", .warning), finding("info-big", .info, bytes: 9),
            finding("crit", .critical), finding("warn-big", .warning, bytes: 5), finding("warn-none-2", .warning),
        ]
        XCTAssertEqual(HealthCard.cards(findings).map(\.id), ["crit", "warn-big", "warn-none", "warn-none-2", "info-big", "info-small"])
    }

    func testTheSummaryCountsEachSeverityPresentMostSevereFirst() {
        let counts = HealthCard.counts([finding("a", .info), finding("b", .warning), finding("c", .info), finding("d", .info)])
        XCTAssertEqual(counts.map(\.severity), [.warning, .info])
        XCTAssertEqual(counts.map(\.count), [1, 3])
        XCTAssertTrue(HealthCard.counts([]).isEmpty)
    }

    func testACardShowsOneSentenceAndFoldsTheRest() throws {
        let card = HealthCard(finding("f", .warning, detail: "First. Second, longer.", remediation: "Fix it. Carefully.", path: "/p", evidence: "E1"))
        XCTAssertEqual(card.sentence, "First.")
        XCTAssertEqual(card.fixSentence, "Fix it.")
        let details = try XCTUnwrap(card.details)
        XCTAssertEqual(details.explanation, "First. Second, longer.")
        XCTAssertEqual(details.fix, "Fix it. Carefully.")
        XCTAssertEqual(details.path, "/p")
        XCTAssertEqual(details.evidence, "E1")
    }

    func testNothingIsFoldedWhenTheCardSaysItAll() {
        let card = HealthCard(finding("f", .info, detail: "Only one.", remediation: "Do it."))
        XCTAssertEqual(card.sentence, "Only one.")
        XCTAssertEqual(card.fixSentence, "Do it.")
        XCTAssertNil(card.details, "no Details disclosure for nothing")
    }

    func testTheStructuredPartsGoUnderDetails() throws {
        let lines = [Finding.Line(label: "UDID-B", bytes: 9), Finding.Line(label: "UDID-A", bytes: 2)]
        let card = HealthCard(
            finding(
                "per-device", .info, detail: "Explanation. More.\n  UDID-B: 9 B\n\nNot offered by `clean`: why.", bytes: 11,
                parts: Finding.Parts(explanation: "Explanation. More.", lines: lines, notOfferedByClean: "why.")))
        XCTAssertEqual(card.sentence, "Explanation.", "the sentence comes from the explanation, not the whole detail")
        XCTAssertEqual(card.bytes, 11)
        let details = try XCTUnwrap(card.details)
        XCTAssertEqual(details.explanation, "Explanation. More.")
        XCTAssertEqual(details.lines, lines)
        XCTAssertEqual(details.notOfferedByClean, "why.")
    }

    func testAFindingWithAnActionShowsItsControlNotItsFixSentence() throws {
        let card = HealthCard(finding("vault-dir:U", .error, remediation: "sudo mkdir it. Then retry.", action: .createVaultDirectory(volumeUUID: "U")))
        XCTAssertNil(card.fixSentence, "the action's control stands in its place")
        XCTAssertEqual(try XCTUnwrap(card.details).fix, "sudo mkdir it. Then retry.", "the text fallback is still there, folded")
    }

    func testEverySeverityHasItsOwnSymbol() {
        let all: [Finding.Severity] = [.critical, .error, .warning, .info]
        XCTAssertEqual(Set(all.map(\.symbolName)).count, all.count)
        for s in all { XCTAssertNotNil(NSImage(systemSymbolName: s.symbolName, accessibilityDescription: nil), s.symbolName) }
    }
}

final class JournalTimelineTests: XCTestCase {
    func testAnOperationsRecordsBecomeOneRowWithItsFinalState() throws {
        let rows = JournalTimeline.rows([
            entry("a", 1, .clean, .planned, summary: "clean 2 path(s)", bytes: 10),
            entry("a", 2, .clean, .started, summary: "delete x", bytes: 4),
            entry("a", 3, .clean, .started, summary: "delete y", bytes: 6),
            entry("a", 4, .clean, .completed, summary: "freed 10 B, 0 failure(s)", bytes: 10),
        ])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.outcome, .completed)
        XCTAssertEqual(row.recordCount, 4)
        XCTAssertEqual(row.summary, "clean 2 path(s)", "what it set out to do")
        XCTAssertEqual(row.endSummary, "freed 10 B, 0 failure(s)", "how it ended")
        XCTAssertEqual(row.bytes, 10)
        XCTAssertEqual(row.kind, .clean)
    }

    func testFailedInterruptedAndInProgress() {
        let entries = [
            entry("failed", 1, .runtimeDelete, .started), entry("failed", 2, .runtimeDelete, .failed, summary: "failed: nope"),
            entry("orphan", 3, .runtimeOffload, .started),
            entry("planned-only", 4, .clean, .planned),
            entry("running", 5, .runtimeExport, .started),
        ]
        let rows = Dictionary(uniqueKeysWithValues: JournalTimeline.rows(entries, running: ["running"]).map { ($0.id, $0) })
        XCTAssertEqual(rows["failed"]?.outcome, .failed)
        XCTAssertEqual(rows["failed"]?.endSummary, "failed: nope")
        XCTAssertEqual(rows["orphan"]?.outcome, .interrupted, "a start with no end")
        XCTAssertEqual(rows["planned-only"]?.outcome, .planned, "recorded, never started: not a crash")
        XCTAssertEqual(rows["running"]?.outcome, .inProgress, "the caller knows it is running")
        XCTAssertEqual(JournalTimeline.rows([entry("x", 1, .clean, .rolledBack)]).first?.outcome, .rolledBack)
        XCTAssertEqual(JournalTimeline.rows([entry("x", 1, .clean, .skipped)]).first?.outcome, .skipped)
    }

    /// The same rule as `Journal.interrupted()`: what the doctor calls interrupted, History does too.
    func testInterruptedMatchesTheJournalsOwnRule() throws {
        let t = TempDir()
        let journal = Journal(url: URL(fileURLWithPath: t.path + "/j.jsonl"))
        try journal.record(id: "done", kind: .migration, state: .started, summary: "COPY")
        try journal.record(id: "done", kind: .migration, state: .completed, summary: "DONE")
        try journal.record(id: "cut", kind: .migration, state: .started, summary: "COPY")
        // A standalone plan, as the vault registry writes its durability warning: neither rule calls it interrupted.
        try journal.record(id: "note", kind: .migration, state: .planned, summary: "warning: vault directory is not durable")
        let rows = JournalTimeline.rows(try journal.entries())
        let interrupted = Set(rows.filter { $0.outcome == .interrupted }.map(\.id))
        XCTAssertEqual(interrupted, Set(try journal.interrupted().map(\.id)))
        XCTAssertEqual(interrupted, ["cut"])
        XCTAssertEqual(rows.first { $0.id == "note" }?.outcome, .planned)
    }

    /// The row's size is the operation's: the closing record's, else the opening record's — never one step's (review M4).
    func testTheSizeIsTheOperationsNotAStepsOne() {
        let cut = JournalTimeline.rows([entry("c", 1, .clean, .planned, bytes: 10), entry("c", 2, .clean, .started, bytes: 4)])
        XCTAssertEqual(cut.first?.bytes, 10, "interrupted mid-way: the planned total")
        let done = JournalTimeline.rows([
            entry("d", 1, .clean, .planned, bytes: 10), entry("d", 2, .clean, .started, bytes: 4), entry("d", 3, .clean, .completed, bytes: 6),
        ])
        XCTAssertEqual(done.first?.bytes, 6, "closed: what the end recorded")
        let failedNoSize = JournalTimeline.rows([entry("f", 1, .clean, .planned, bytes: 10), entry("f", 2, .clean, .failed)])
        XCTAssertEqual(failedNoSize.first?.bytes, 10)
        XCTAssertNil(JournalTimeline.rows([entry("n", 1, .runtimeDelete, .started), entry("n", 2, .runtimeDelete, .completed)]).first?.bytes)
    }

    /// How it ended shows under the summary only when it did not end well (review M5).
    func testTheEndSummaryShowsOnFailedAndInterruptedRows() {
        let rows = Dictionary(
            uniqueKeysWithValues: JournalTimeline.rows([
                entry("ok", 1, .clean, .started, summary: "a"), entry("ok", 2, .clean, .completed, summary: "b"),
                entry("bad", 3, .clean, .started, summary: "a"), entry("bad", 4, .clean, .failed, summary: "delete x: denied"),
                entry("cut", 5, .clean, .planned, summary: "a"), entry("cut", 6, .clean, .started, summary: "delete y"),
                entry("one", 7, .clean, .failed, summary: "same"),
            ]).map { ($0.id, $0) })
        XCTAssertEqual(rows["ok"]?.showsEndSummary, false)
        XCTAssertEqual(rows["bad"]?.showsEndSummary, true)
        XCTAssertEqual(rows["cut"]?.showsEndSummary, true)
        XCTAssertEqual(rows["one"]?.showsEndSummary, false, "nothing more to say")
    }

    func testRowsAreNewestFirstAndInterleavedRecordsStayTogether() {
        let rows = JournalTimeline.rows([
            entry("old", 1, .clean, .started), entry("new", 2, .runtimeDelete, .started), entry("old", 3, .clean, .completed),
            entry("new", 4, .runtimeDelete, .completed),
        ])
        XCTAssertEqual(rows.map(\.id), ["new", "old"])
        XCTAssertEqual(rows.map(\.recordCount), [2, 2])
        // The start time orders the rows, so the day sections run newest first even where the sequence disagrees.
        let byTime = JournalTimeline.rows([
            entry("later", 1, .clean, .completed, at: Date(timeIntervalSince1970: 200)),
            entry("earlier", 2, .clean, .completed, at: Date(timeIntervalSince1970: 100)),
        ])
        XCTAssertEqual(byTime.map(\.id), ["later", "earlier"])
    }

    func testKinds() {
        XCTAssertEqual(JournalTimeline.kind(of: [entry("h", 1, .clean, .started, summary: "helper: Empty the cache")]), .privileged)
        XCTAssertEqual(JournalTimeline.kind(of: [entry("h", 1, .migration, .planned, summary: "helper: Create the vault folder")]), .privileged)
        XCTAssertEqual(
            JournalTimeline.kind(of: [entry("m", 1, .migration, .planned, detail: ["direction": "restore"]), entry("m", 2, .migration, .started)]),
            .migration)
        XCTAssertEqual(JournalTimeline.kind(of: [entry("v", 1, .migration, .completed, summary: "registered vault volume D (U)")]), .other)
        XCTAssertEqual(JournalTimeline.kind(of: [entry("x", 1, .xcodeLocationChange, .started)]), .xcodeLocationChange)
        XCTAssertEqual(JournalTimeline.kind(of: [entry("i", 1, .runtimeImport, .started)]), .runtimeImport)
        XCTAssertEqual(JournalTimeline.kind(of: []), .other)
    }

    func testTheFilterHidesKindsAndOffersThoseThatAppear() {
        let rows = JournalTimeline.rows([entry("a", 1, .clean, .completed), entry("b", 2, .runtimeDelete, .completed), entry("c", 3, .clean, .failed)])
        XCTAssertEqual(JournalTimeline.kinds(in: rows), [.clean, .runtimeDelete])
        XCTAssertEqual(JournalTimeline.filter(rows, hiding: [.clean]).map(\.id), ["b"])
        XCTAssertEqual(JournalTimeline.filter(rows, hiding: []).map(\.id), ["c", "b", "a"])
        XCTAssertEqual(JournalTimeline.filter(rows, hiding: [.clean, .runtimeDelete]), [])
    }

    func testSectionsAreTodayYesterdayThenTheDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00 UTC
        let earlierToday = now.addingTimeInterval(-3600)
        let yesterday = now.addingTimeInterval(-86_400)
        let lastWeek = now.addingTimeInterval(-7 * 86_400)
        let rows = JournalTimeline.rows([
            entry("w", 1, .clean, .completed, at: lastWeek), entry("y", 2, .clean, .completed, at: yesterday),
            entry("t1", 3, .clean, .completed, at: earlierToday), entry("t2", 4, .clean, .completed, at: now),
        ])
        let sections = JournalTimeline.sections(rows, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.day), [.today, .yesterday, .date(calendar.startOfDay(for: lastWeek))])
        XCTAssertEqual(sections.map { $0.rows.map(\.id) }, [["t2", "t1"], ["y"], ["w"]])
    }

}

/// The kind badges' palette: one hue and one symbol per kind, each color clearing 3:1 on the system backgrounds in light
/// and dark (and on the values earlier macOS versions resolve them to), as the bucket tokens do (`BrandTokenTests`).
final class HistoryKindPaletteTests: XCTestCase {
    private func luminance(_ color: NSColor) throws -> Double {
        let c = try XCTUnwrap(color.usingColorSpace(.sRGB))
        func linear(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) throws -> Double {
        let (la, lb) = (try luminance(a), try luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testEveryKindHasADistinctColorAndSymbol() {
        let all = JournalTimeline.Kind.allCases
        XCTAssertEqual(all.count, 9)
        XCTAssertEqual(Set(all.map(\.lightColorHex)).count, all.count)
        XCTAssertEqual(Set(all.map(\.darkColorHex)).count, all.count)
        XCTAssertEqual(Set(all.map(\.symbolName)).count, all.count)
        for kind in all {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil), kind.symbolName)
            for hex in [kind.lightColorHex, kind.darkColorHex] {
                XCTAssertNotNil(hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression), hex)
            }
        }
        let outcomes = JournalTimeline.Outcome.allCases
        XCTAssertEqual(Set(outcomes.map(\.symbolName)).count, outcomes.count)
        for o in outcomes { XCTAssertNotNil(NSImage(systemSymbolName: o.symbolName, accessibilityDescription: nil), o.symbolName) }
    }

    func testEveryKindClearsThreeToOneOnTheWindowBackgroundsInBothAppearances() throws {
        let earlier: [NSAppearance.Name: [String]] = [.aqua: ["#FFFFFF", "#ECECEC"], .darkAqua: ["#323232", "#1E1E1E"]]
        var checked = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for kind in JournalTimeline.Kind.allCases {
                var color = NSColor.clear
                var surfaces: [String: NSColor] = [:]
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    color = kind.nsColor.usingColorSpace(.sRGB)!
                    surfaces["windowBackgroundColor"] = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
                    surfaces["controlBackgroundColor"] = NSColor.controlBackgroundColor.usingColorSpace(.sRGB)!
                }
                for hex in earlier[appearance] ?? [] { surfaces[hex] = NSColor(hex: hex) }
                for (name, surface) in surfaces {
                    XCTAssertGreaterThanOrEqual(try contrast(color, surface), 3, "\(kind.rawValue) on \(name), \(appearance.rawValue)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 2 * JournalTimeline.Kind.allCases.count * 4)
    }
}

/// Access registers the app before it opens the pane (R4), and re-checks on every return.
final class FullDiskAccessRegistrationTests: XCTestCase {
    func testTheFolderIsSafariUnderTheGivenHome() {
        XCTAssertEqual(FullDiskAccessRegistration.path(home: "/Users/tester"), "/Users/tester/Library/Safari")
    }

    func testTheAttemptOnlyOpensThePath() {
        let seen = PathLog()
        let registration = FullDiskAccessRegistration(path: "/x/Library/Safari") { path in
            seen.append(path)
            return EPERM
        }
        XCTAssertEqual(registration.attempt(), EPERM)
        XCTAssertEqual(seen.paths, ["/x/Library/Safari"])
    }

    /// The live opener on a folder of the test's own: it opens and closes a directory, and leaves it as it was.
    func testTheLiveOpenerOpensADirectoryAndChangesNothing() throws {
        let t = TempDir()
        try "x".write(toFile: t.path + "/file", atomically: true, encoding: .utf8)
        let before = try FileManager.default.contentsOfDirectory(atPath: t.path)
        XCTAssertEqual(FullDiskAccessRegistration(path: t.path).attempt(), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: t.path), before)
    }

    func testTheHintStandsOnlyNextToTheSettingsButton() {
        for fda in FullDiskAccessState.allCases {
            for helper in HelperState.allCases {
                for row in AccessChecklist.rows(fullDiskAccess: fda, helper: helper, savings: SavingsSummary(), plan: []) {
                    XCTAssertEqual(row.hintKey != nil, row.action == .openFullDiskAccessSettings, "\(fda) \(helper) \(row.need)")
                }
            }
        }
        L10n.configure(override: "en", environment: [:], preferred: [])
        let hint = AppText.access(AccessChecklist.Key.fdaHintInList, bytes: nil, folders: nil)
        // H16 verified on macOS 26.7.1 (the user's check, 2026-10-04): no hedge; the + fallback stays for other versions.
        XCTAssertEqual(hint, "XCodeVault is now in the list — turn its switch on. If it isn’t there, click + and choose XCodeVault.")
        XCTAssertFalse(hint.contains("already"), "never states the unverified registration as fact")
        XCTAssertFalse(hint.lowercased().contains("turned on") || hint.lowercased().contains("will turn"), "never claims the app turns it on")
    }

    func testARescanFollowsOnlyANewGrant() {
        typealias A = AccessChecklist
        XCTAssertTrue(A.rescansOnActivation(before: .notGranted, after: .granted, hasScanned: true, returningFromSettings: false))
        XCTAssertTrue(A.rescansOnActivation(before: .unknown, after: .granted, hasScanned: false, returningFromSettings: true))
        XCTAssertFalse(A.rescansOnActivation(before: .unknown, after: .granted, hasScanned: false, returningFromSettings: false), "the launch's scan")
        XCTAssertFalse(A.rescansOnActivation(before: .granted, after: .granted, hasScanned: true, returningFromSettings: true), "nothing changed")
        XCTAssertFalse(A.rescansOnActivation(before: .notGranted, after: .notGranted, hasScanned: true, returningFromSettings: true))
        XCTAssertFalse(A.rescansOnActivation(before: .granted, after: .notGranted, hasScanned: true, returningFromSettings: true))
    }
}

/// Paths an opener saw, from any thread.
final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.withLock { _paths } }
    func append(_ path: String) { lock.withLock { _paths.append(path) } }
}

@MainActor
final class R4AppModelTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    func testTheButtonRegistersTheAppThenOpensThePane() {
        let t = TempDir()
        let events = PathLog()
        let opened = OpenedURLs()
        let model = makeModel(
            SwitchableHelper(.notInstalled), journal: t, fullDiskAccess: .notGranted, opened: opened, registered: { events.append("register") })
        model.refreshPermissions()
        XCTAssertEqual(model.accessRows.first?.hintKey, AccessChecklist.Key.fdaHintInList)
        model.handle(.openFullDiskAccessSettings)
        XCTAssertEqual(events.paths, ["register"])
        XCTAssertEqual(opened.urls.map(\.absoluteString), [FullDiskAccessProbe.settingsURL])
        // The order: the registration had happened when the pane was asked for.
        let order = PathLog()
        let helper = SwitchableHelper(.notInstalled)
        let journalURL = URL(fileURLWithPath: t.path + "/j.jsonl")
        let ordered = AppModel(
            environment: AppEnvironment(
                survey: { sampleSurvey() }, fullDiskAccess: { .notGranted }, helper: helper, approvalFlow: { HelperApprovalFlow(helper: $0) },
                runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: journalURL)) },
                clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in order.append("open") }, copy: { _ in },
                registerForFullDiskAccess: { order.append("register") }))
        ordered.openFullDiskAccessSettings()
        XCTAssertEqual(order.paths, ["register", "open"])
    }

    func testReturningUpdatesTheRowTheBannerAndTheOverviewAndRescansOnce() async throws {
        let t = TempDir()
        let access = AccessBox(.notGranted)
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: sampleSurvey(refusals: 2), fullDiskAccessBox: access)
        await model.refresh()
        XCTAssertEqual(model.accessBanner?.need, .fullDiskAccess)
        XCTAssertEqual(model.accessRows.first?.state, .missing)
        model.openFullDiskAccessSettings()
        access.state = .granted
        model.report = nil
        await model.appDidBecomeActive()
        XCTAssertEqual(model.accessRows.first?.state, .granted, "the row follows")
        XCTAssertNil(model.accessBanner, "the banner and the Overview follow")
        XCTAssertNotNil(model.report, "the grant rescans")
        // Turned off again in Settings while the app was in the background: the row follows, and nothing rescans.
        access.state = .notGranted
        model.report = nil
        await model.appDidBecomeActive()
        XCTAssertEqual(model.accessRows.first?.state, .missing)
        XCTAssertNil(model.report)
    }

    func testHistoryListsOperationsAndTheFilterHidesKinds() async throws {
        let t = TempDir()
        var survey = detailSampleSurvey()
        survey.4 = [
            entry("op1", 1, .clean, .started, at: Date(timeIntervalSince1970: 1_000)),
            entry("op1", 2, .clean, .completed, at: Date(timeIntervalSince1970: 1_001)),
            entry("op2", 3, .runtimeDelete, .started, at: Date(timeIntervalSince1970: 2_000)),
        ]
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: survey)
        await model.refresh()
        XCTAssertEqual(model.historyRows.map(\.id), ["op2", "op1"], "one row per operation, newest first")
        XCTAssertEqual(model.historyRows.map(\.outcome), [.interrupted, .completed])
        XCTAssertEqual(model.historyKinds, [.clean, .runtimeDelete])
        model.toggleHistoryKind(.clean)
        XCTAssertFalse(model.historyShows(.clean))
        XCTAssertEqual(model.historySections(now: Date(timeIntervalSince1970: 3_000)).flatMap(\.rows).map(\.id), ["op2"])
        model.showAllHistoryKinds()
        XCTAssertEqual(model.historySections(now: Date(timeIntervalSince1970: 3_000)).flatMap(\.rows).count, 2)
        model.toggleHistoryKind(.clean)
        model.toggleHistoryKind(.clean)
        XCTAssertTrue(model.historyShows(.clean), "a second toggle shows it again")
    }

    func testHistoryKeepsTheNewestHundredOperationsWholeAcrossTheCut() async {
        let t = TempDir()
        var survey = sampleSurvey()
        survey.4 = (1...150).flatMap { i in [entry("op\(i)", 2 * i, .clean, .started), entry("op\(i)", 2 * i + 1, .clean, .completed)] }
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: survey)
        await model.refresh()
        XCTAssertEqual(model.historyRows.count, AppModel.historyLimit)
        XCTAssertEqual(model.historyRows.first?.id, "op150")
        XCTAssertTrue(model.historyRows.allSatisfy { $0.recordCount == 2 && $0.outcome == .completed }, "no operation lost its start")
    }

    func testHealthCardsAndCountsFollowTheFindings() async {
        let t = TempDir()
        var survey = detailSampleSurvey()
        survey.1 = [finding("small", .info, bytes: 1), finding("warn", .warning), finding("big", .info, bytes: 7)]
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: survey)
        await model.refresh()
        XCTAssertEqual(model.healthCards.map(\.id), ["warn", "big", "small"])
        XCTAssertEqual(model.healthCounts.map(\.count), [1, 2])
    }

    /// R5 (HIG review HI3): the kinds menu's title says the filter's state.
    func testTheKindsMenuSaysTheFiltersState() async {
        let t = TempDir()
        var survey = detailSampleSurvey()
        survey.4 = [entry("op1", 1, .clean, .completed), entry("op2", 2, .runtimeDelete, .completed)]
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: survey)
        await model.refresh()
        XCTAssertEqual(model.historyFilterTitle, "All Kinds")
        model.toggleHistoryKind(.clean)
        XCTAssertEqual(model.historyFilterTitle, "1 of 2 Kinds")
        model.showAllHistoryKinds()
        XCTAssertEqual(model.historyFilterTitle, "All Kinds")
    }

    /// Every new label renders as text, not as its key, in every language.
    func testEveryNewLabelIsTranslatedInEveryLanguage() {
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            var texts: [String] = JournalTimeline.Kind.allCases.map(AppText.historyKind) + JournalTimeline.Outcome.allCases.map(AppText.historyOutcome)
            texts += [Finding.Severity.critical, .error, .warning, .info].map { AppText.healthCount($0, 2) }
            texts += [AppText.historyDay(.today), AppText.historyDay(.yesterday), AppText.access(AccessChecklist.Key.fdaHintInList, bytes: nil, folders: nil)]
            texts += [
                "app.health.details", "app.health.fix", "app.health.notOffered", "app.history.filter.allKinds", "app.history.filter.all",
                "app.history.filter.none",
            ]
            .map { L10n.tr($0) }
            for text in texts {
                XCTAssertFalse(text.hasPrefix("app."), "\(locale): \(text)")
                XCTAssertFalse(text.isEmpty, locale)
                XCTAssertFalse(text.contains("%"), "\(locale): \(text)")
            }
            XCTAssertEqual(Set(JournalTimeline.Kind.allCases.map(AppText.historyKind)).count, JournalTimeline.Kind.allCases.count, locale)
            XCTAssertTrue(AppText.healthCount(.warning, 2).contains("2"), locale)
        }
    }

    /// Off-screen PNGs for the visual review, with `XCV_SNAPSHOTS=1` only (`SnapshotWriter`).
    func testWriteHealthAndHistorySnapshots() async throws {
        guard SnapshotWriter.isEnabled else { return }
        let t = TempDir()
        var written: [String] = []
        var survey = detailSampleSurvey()
        survey.1 = Array(screenFitStressSurvey().1.suffix(4)) + survey.1
        survey.4 = Array(screenFitStressSurvey().4.suffix(24))
        for locale in ["en", "ja"] {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, fullDiskAccess: .notGranted, survey: survey)
            await model.refresh()
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let tag = appearance == .aqua ? "light" : "dark"
                written.append(try SnapshotWriter.write(HealthView(model: model), name: "r4-health-\(locale)-\(tag)", appearance: appearance))
                // A `Table` draws no rows off-screen: the rows' cells themselves, under their day headers.
                let rows = VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.historySections()) { section in
                        Text(verbatim: AppText.historyDay(section.day)).font(.headline)
                        ForEach(section.rows) { row in
                            HStack(spacing: 10) {
                                Text(verbatim: AppText.time(row.started)).monospacedDigit()
                                HistoryKindBadge(kind: row.kind)
                                HistoryOutcomeLabel(outcome: row.outcome)
                                HistorySummaryCell(row: row)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                written.append(try SnapshotWriter.write(rows, name: "r4-history-rows-\(locale)-\(tag)", appearance: appearance))
                written.append(
                    try SnapshotWriter.write(
                        AccessRowView(row: try XCTUnwrap(model.accessRows.first)) { _ in }.padding(), name: "r4-access-fda-\(locale)-\(tag)",
                        size: NSSize(width: 900, height: 160), appearance: appearance))
            }
        }
        XCTAssertEqual(written.count, 2 * 2 * 3)
        print("snapshots:\n" + written.joined(separator: "\n"))
    }
}

/// R4 review, fix round 1: the minors that a test can hold.
@MainActor
final class R4ReviewFixTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    /// M1: `Finding`'s new fields are optional on the wire both ways, and a per-device finding round-trips.
    func testFindingsNewFieldsAreAdditiveInJSON() throws {
        let old = #"{"id":"low-free-space","severity":"warning","title":"t","detail":"d","path":"/p","remediation":"r","evidence":"e"}"#
        let decoded = try JSONDecoder().decode(Finding.self, from: Data(old.utf8))
        XCTAssertNil(decoded.bytes)
        XCTAssertNil(decoded.parts)
        let encoded = try XCTUnwrap(String(data: try JSONEncoder().encode(decoded), encoding: .utf8))
        XCTAssertFalse(encoded.contains("\"bytes\"") || encoded.contains("\"parts\""), encoded)
        let perDevice = finding(
            "perDeviceRegenerable.x", .info, bytes: 11,
            parts: Finding.Parts(explanation: "E.", lines: [Finding.Line(label: "U", bytes: 11)], notOfferedByClean: "why"))
        XCTAssertEqual(try JSONDecoder().decode(Finding.self, from: try JSONEncoder().encode(perDevice)), perDevice)
    }

    /// M7: the header names the day the rows were grouped in, in the grouping calendar's time zone.
    func testTheDayHeaderUsesTheGroupingCalendarsTimeZone() throws {
        L10n.configure(override: "en", environment: [:], preferred: [])
        for zone in ["UTC", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
            let expected = calendar.component(.day, from: day)
            let header = AppText.historyDay(.date(day), calendar: calendar)
            XCTAssertTrue(header.contains(" \(expected),"), "\(zone): \(header)")
        }
    }

    /// M8: a kind hidden before a rescan that no longer has it is not left hidden.
    func testAHiddenKindTheRowsNoLongerHaveIsCleared() async {
        let t = TempDir()
        var survey = sampleSurvey()
        survey.4 = [entry("a", 1, .clean, .completed)]
        let model = makeModel(SwitchableHelper(.unavailableInThisBuild), journal: t, survey: survey)
        await model.refresh()
        model.toggleHistoryKind(.clean)
        model.toggleHistoryKind(.runtimeDelete)
        await model.refresh()
        XCTAssertEqual(model.historyHiddenKinds, [.clean], "the kind still listed stays hidden; the gone one is cleared")
    }
}
