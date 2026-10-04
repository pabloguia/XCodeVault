import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// R5, commit 2 of the HIG review (§5): writing and typography, and the user's H16 check (Relaunch XCodeVault).
final class R5WritingTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    /// Every value of `key` in every language, plural categories included.
    private func values(_ key: String) -> [(String, String)] {
        if let byLocale = L10nCatalog.core.strings[key] { return byLocale.map { ($0.key, $0.value) } }
        return (L10nCatalog.core.plurals[key] ?? [:]).flatMap { locale, cases in cases.values.map { (locale, $0) } }
    }

    /// HIG review X1, X2: no project vocabulary and no ALL-CAPS words in what the app, the permissions and the savings
    /// texts say. Hypothesis and issue ids stay in the docs and `--json`.
    func testTheAppSpeaksTheUsersWords() {
        let keys = (Array(L10nCatalog.core.strings.keys) + Array(L10nCatalog.core.plurals.keys))
            .filter { $0.hasPrefix("app.") || $0.hasPrefix("perm.") || $0.hasPrefix("savings.") }
        XCTAssertGreaterThan(keys.count, 300, "the catalog was read")
        let jargon = try! NSRegularExpression(pattern: #"\bH\d{1,2}\b|#\d+|Definition of Done|journaled|sentinel|\bbuckets?\b"#)
        let caps = try! NSRegularExpression(pattern: #"\b[A-Z]{3,}\b"#)
        let acronyms: Set<String> = ["APFS", "USB", "UUID", "CLI", "URL", "IOPS", "PCI", "SSD", "UDID", "HFS"]
        var hits: [String] = []
        for key in keys {
            for (locale, value) in values(key) {
                let range = NSRange(value.startIndex..., in: value)
                if jargon.firstMatch(in: value, range: range) != nil { hits.append("\(key) \(locale): \(value)") }
                for match in caps.matches(in: value, range: range) {
                    let word = (value as NSString).substring(with: match.range)
                    if !acronyms.contains(word) { hits.append("\(key) \(locale): \(word)") }
                }
            }
        }
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }

    /// HIG review X5, N5, N7, A3, A4, D7: title case for buttons, menu items, column headers and sidebar labels.
    func testButtonsAndHeadersAreTitleCase() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let titled = [
            "app.section.runExternally", "app.sidebar.saveSpace", "app.access.fda.action.openSettings", "app.access.fda.action.recheck",
            "app.access.helper.action.install", "app.delete.column.undo", "app.history.filter.all", "app.helper.sheet.allow",
            "app.access.fda.action.relaunch", "app.overview.showInHealth", "app.action.showInFinder", "app.action.copyPath",
        ]
        for key in titled {
            let small: Set<String> = ["to", "in", "of", "a", "the", "and", "or"]
            for word in L10n.tr(key).split(separator: " ") where !small.contains(String(word)) {
                XCTAssertEqual(word.first.map { $0.isUppercase || !$0.isLetter }, true, "\(key): \(L10n.tr(key))")
            }
        }
        XCTAssertEqual(L10n.tr("app.section.access"), "Permissions", "the familiar name (HIG review N7)")
        XCTAssertEqual(AppText.severity(.critical), "Critical")
        XCTAssertEqual(L10n.tr("app.value.no"), "No")
    }

    /// HIG review ST4: a strategy shows its name, never its identifier, in every language.
    func testEveryStrategyHasAName() {
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let names = Strategy.allCases.map(AppText.strategy)
            XCTAssertEqual(Set(names).count, Strategy.allCases.count, locale)
            for (strategy, name) in zip(Strategy.allCases, names) {
                XCTAssertNotEqual(name, strategy.rawValue, "\(locale) \(strategy)")
                XCTAssertFalse(name.hasPrefix("app."), "\(locale) \(strategy)")
            }
        }
    }

    /// HIG review P3: one "Experimental" badge app-wide; the other markers start with a capital.
    func testTheBadgesReadAsLabels() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertEqual(AppText.marker(.experimental), "Experimental")
        XCTAssertEqual(AppText.marker(.actsImmediately), "Acts immediately")
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            XCTAssertFalse(AppText.marker(.experimental).isEmpty, locale)
            XCTAssertEqual(AppText.cardEyebrow(permanent: true) == AppText.cardEyebrow(permanent: false), false, locale)
        }
    }

    /// The user's H16 check: Relaunch XCodeVault only after the trip to the pane, while this process still lacks it.
    func testRelaunchIsOfferedOnlyAfterTheTripToTheSettings() {
        for fda in FullDiskAccessState.allCases {
            for helper in HelperState.allCases {
                for row in AccessChecklist.rows(fullDiskAccess: fda, helper: helper, savings: SavingsSummary(), plan: [], privacyRefusalCount: 1) {
                    XCTAssertFalse(AccessChecklist.offersRelaunch(row, openedSettings: false), "never before the pane was opened")
                    XCTAssertEqual(
                        AccessChecklist.offersRelaunch(row, openedSettings: true), row.need == .fullDiskAccess && fda == .notGranted,
                        "\(fda) \(helper) \(row.need)")
                    XCTAssertEqual(row.helpKey != nil, row.action == .guidanceOnly, "the manual route is the guidance's tooltip only")
                }
            }
        }
    }
}

@MainActor
final class R5RelaunchAppTests: XCTestCase {
    func testRelaunchGoesThroughTheEnvironmentAndOnlyWhenOffered() async throws {
        let t = TempDir()
        let relaunched = CopiedStrings()
        let access = AccessBox(.notGranted)
        let journalURL = URL(fileURLWithPath: t.path + "/j.jsonl")
        let model = AppModel(
            environment: AppEnvironment(
                survey: { sampleSurvey() }, fullDiskAccess: { access.state }, helper: SwitchableHelper(.notInstalled),
                approvalFlow: { HelperApprovalFlow(helper: $0) }, runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: journalURL)) },
                clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { _ in },
                relaunch: { relaunched.strings.append("relaunch") }))
        model.refreshPermissions()
        let row = try XCTUnwrap(model.accessRows.first)
        XCTAssertFalse(model.offersRelaunch(row), "not before the user went to the pane")
        model.openFullDiskAccessSettings()
        await model.appDidBecomeActive()
        XCTAssertTrue(model.offersRelaunch(try XCTUnwrap(model.accessRows.first)), "back, and this process still lacks it")
        model.relaunch()
        XCTAssertEqual(relaunched.strings, ["relaunch"])
        access.state = .granted
        await model.appDidBecomeActive()
        XCTAssertFalse(model.offersRelaunch(try XCTUnwrap(model.accessRows.first)), "granted and seen: nothing to relaunch for")
    }
}
