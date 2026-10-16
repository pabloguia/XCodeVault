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
            // The `perm.*` texts the CLI and `--json` share keep their evidence references (R5 review m2); the app shows its own
            // words for those, and the `perm.*` it does show are the titles and the actions'.
            .filter {
                $0.hasPrefix("app.") || $0.hasPrefix("savings.") || $0.hasPrefix("perm.action.") || $0 == "perm.fda.title" || $0 == "perm.helper.title"
            }
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
        XCTAssertEqual(L10n.tr("app.history.filter.allKinds"), "All Kinds")
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
                    XCTAssertFalse(AccessChecklist.offersRelaunch(row, openedSettings: false, busy: false), "never before the pane was opened")
                    XCTAssertFalse(AccessChecklist.offersRelaunch(row, openedSettings: true, busy: true), "never while something runs")
                    XCTAssertEqual(
                        AccessChecklist.offersRelaunch(row, openedSettings: true, busy: false), row.need == .fullDiskAccess && fda == .notGranted,
                        "\(fda) \(helper) \(row.need)")
                    XCTAssertEqual(row.helpKey != nil, row.action == .guidanceOnly, "the manual route is the guidance's tooltip only")
                }
            }
        }
    }
}

/// What the live environment's closures did, in order.
@MainActor final class EnvironmentLog {
    var events: [String] = []
}

/// A model whose terminate, new instance, guide panel and clean are recorded.
@MainActor
func r5Model(
    _ log: EnvironmentLog, access: AccessBox, journal: TempDir, survey: AppModel.Survey = sampleSurvey(),
    clean: @escaping @Sendable (CleanPlan, Bool) throws -> CleanResult = { _, _ in CleanResult(deleted: [], failedPairs: []) }
) -> AppModel {
    let journalURL = URL(fileURLWithPath: journal.path + "/j.jsonl")
    return AppModel(
        environment: AppEnvironment(
            survey: { survey }, fullDiskAccess: { access.state }, helper: SwitchableHelper(.notInstalled),
            approvalFlow: { HelperApprovalFlow(helper: $0) }, runner: { PrivilegedActionRunner(helper: $0, journal: Journal(url: journalURL)) },
            clean: clean, open: { _ in }, copy: { _ in }, terminate: { log.events.append("terminate") },
            launchNewInstance: { log.events.append("launch") }, showAccessGuide: { _ in log.events.append("show guide") },
            closeAccessGuide: { log.events.append("close guide") }))
}

@MainActor
final class R5RelaunchAppTests: XCTestCase {
    func testRelaunchQuitsOnlyWhenOfferedAndLaunchesNothingItself() async throws {
        let t = TempDir()
        let log = EnvironmentLog()
        let access = AccessBox(.notGranted)
        let model = r5Model(log, access: access, journal: t)
        model.refreshPermissions()
        XCTAssertFalse(model.offersRelaunch(try XCTUnwrap(model.accessRows.first)), "not before the user went to the pane")
        model.openFullDiskAccessSettings()
        await model.appDidBecomeActive()
        XCTAssertTrue(model.offersRelaunch(try XCTUnwrap(model.accessRows.first)), "back, and this process still lacks it")
        model.relaunch()
        XCTAssertTrue(model.relaunchRequested)
        XCTAssertEqual(log.events.filter { $0 != "show guide" }, ["terminate"], "it asks to quit; the new instance starts once the quit is approved")
        access.state = .granted
        await model.appDidBecomeActive()
        XCTAssertFalse(model.offersRelaunch(try XCTUnwrap(model.accessRows.first)), "granted and seen: nothing to relaunch for")
    }

    /// R5 review I1, safety LOW-2, and the pre-existing gap: while a clean runs, quitting only keeps running, Relaunch is
    /// not offered, and pressing it anyway quits and launches nothing.
    func testNothingRelaunchesOrQuitsWhileACleanRuns() async throws {
        let t = TempDir()
        let log = EnvironmentLog()
        let gate = DispatchSemaphore(value: 0)
        let action = CleanAction(
            categoryID: "derivedData", categoryName: "DerivedData", path: "/tmp/dd", bytes: 1, isExperimental: false, risk: .low, requiresRoot: false,
            notes: [])
        let model = r5Model(
            log, access: AccessBox(.notGranted), journal: t, survey: sampleSurvey(actions: [action]),
            clean: { plan, _ in
                gate.wait()
                return CleanResult(deleted: plan.actions, failedPairs: [])
            })
        await model.refresh()
        model.openFullDiskAccessSettings()
        XCTAssertEqual(model.quitChoice, .quitNow)
        let cleaning = Task { await model.applyClean(actions: [action], useTrash: true) }
        await eventually("cleaning") { model.isCleaning }
        XCTAssertEqual(model.quitChoice, .keepRunningOnly(.clean), "a clean is never cut short by quitting")
        XCTAssertFalse(model.offersRelaunch(try XCTUnwrap(model.accessRows.first)))
        model.relaunch()
        XCTAssertFalse(model.relaunchRequested)
        XCTAssertFalse(log.events.contains("terminate") || log.events.contains("launch"), "\(log.events)")
        XCTAssertEqual(model.lastError?.title, L10n.tr("app.error.relaunch.title"), "it says why")
        // R5 re-review NEW-1: no second clean can start, or be confirmed, while one runs, so none can clear the guard early.
        XCTAssertNil(model.deletionToConfirm([action.path]), "nothing to confirm while a clean runs")
        await model.applyClean(actions: [action], useTrash: true)
        XCTAssertTrue(model.isCleaning, "the refused second clean did not reset the flag")
        XCTAssertEqual(model.quitChoice, .keepRunningOnly(.clean))
        gate.signal()
        await cleaning.value
        XCTAssertFalse(model.isCleaning)
        XCTAssertEqual(model.quitChoice, .quitNow)
    }

    func testACleanKeepsRunningWhateverTheOperationAllows() {
        typealias M = AppModel
        XCTAssertEqual(M.quitChoice(operation: .quitNow, cleaning: false), .quitNow)
        XCTAssertEqual(M.quitChoice(operation: .quitNow, cleaning: true), .keepRunningOnly(.clean))
        XCTAssertEqual(M.quitChoice(operation: .stopThenQuit, cleaning: true), .keepRunningOnly(.clean), "Stop and Quit would leave the clean half done")
        XCTAssertEqual(M.quitChoice(operation: .stopThenQuit, cleaning: false), .stopThenQuit)
        XCTAssertEqual(M.quitChoice(operation: .keepRunningOnly(.migration), cleaning: true), .keepRunningOnly(.migration))
    }

    /// The user's real-window feedback: the guide opens with the pane, once, and closes on Done or once the grant is seen.
    func testTheGuideOpensWithThePaneAndClosesOnDoneOrTheGrant() async {
        let t = TempDir()
        let log = EnvironmentLog()
        let access = AccessBox(.notGranted)
        let model = r5Model(log, access: access, journal: t)
        model.openFullDiskAccessSettings()
        XCTAssertTrue(model.showsAccessGuide)
        model.openFullDiskAccessSettings()
        XCTAssertEqual(log.events, ["show guide"], "one panel, not one per click")
        await model.appDidBecomeActive()
        XCTAssertTrue(model.showsAccessGuide, "back without the grant: it stays")
        access.state = .granted
        await model.appDidBecomeActive()
        XCTAssertFalse(model.showsAccessGuide)
        XCTAssertEqual(log.events, ["show guide", "close guide"])
        model.closeAccessGuide()
        XCTAssertEqual(log.events.count, 2, "closing twice does nothing")
        // Done: the closure the environment received.
        var done: (@MainActor () -> Void)?
        let other = AppModel(
            environment: AppEnvironment(
                survey: { sampleSurvey() }, fullDiskAccess: { .notGranted }, helper: SwitchableHelper(.notInstalled),
                approvalFlow: { HelperApprovalFlow(helper: $0) }, runner: { PrivilegedActionRunner(helper: $0) },
                clean: { _, _ in CleanResult(deleted: [], failedPairs: []) }, open: { _ in }, copy: { _ in },
                showAccessGuide: { done = $0 }, closeAccessGuide: { log.events.append("closed by done") }))
        other.openFullDiskAccessSettings()
        done?()
        XCTAssertFalse(other.showsAccessGuide)
        XCTAssertEqual(log.events.last, "closed by done")
    }
}
