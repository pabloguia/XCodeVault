import Foundation
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// Every string the app shows goes through the catalog (S4 Task 2). A SwiftUI initializer given a string literal
/// looks the literal up as a `LocalizedStringKey` in a bundle the app does not have, and re-interprets `%`; so the
/// app passes `L10n.tr` results to the `StringProtocol` initializers and renders text with `Text(verbatim:)`.
final class AppTextCoverageTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private var appSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/XCodeVault")
    }

    /// A view initializer or modifier whose first argument is a string literal, and any `Text(` that is not `Text(verbatim:`.
    /// `\s` spans newlines: the scan runs over whole files, so a literal on the line after the `(` is caught too.
    private static let literalUse = try! NSRegularExpression(
        pattern:
            #"\b(?:Button|Label|Toggle|TableColumn|GroupBox|Section|ContentUnavailableView|LabeledContent|CommandMenu|WindowGroup|Text"#
            + #"|Picker|Menu|Link|TextField|ProgressView)\(\s*""#
            + #"|\.(?:navigationTitle|navigationSubtitle|confirmationDialog|alert|help|accessibilityLabel)\(\s*""#
            + #"|\bText\((?!\s*verbatim:)"#)

    /// The hits in `text`, as `line: source line`. Comment lines are blanked first (keeping the line count), so a comment
    /// that quotes a forbidden form is not a hit.
    static func literalHits(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        let code = lines.map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0 }.joined(separator: "\n")
        return literalUse.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
            guard let range = Range(match.range, in: code) else { return nil }
            let number = code[..<range.lowerBound].filter { $0 == "\n" }.count
            return "\(number + 1): \(lines[number].trimmingCharacters(in: .whitespaces))"
        }
    }

    func testNoAppViewTakesAStringLiteral() throws {
        // Recursive: the views live in `Views/` (S4 Task 3), and a scan that stopped at the top folder would pass them unread.
        let files = try XCTUnwrap(FileManager.default.subpaths(atPath: appSources.path)).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 3, "the app's sources were found")
        XCTAssertTrue(files.contains("Views/OverviewView.swift"), "the scan reaches the Views folder")
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
            hits += Self.literalHits(in: text).map { "\(file):\($0)" }
        }
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }

    /// Control for the scan above: it does find the forms it forbids, including a literal on the next line.
    func testTheScanFindsALiteral() {
        let forbidden = [
            #"Text("Hi")"#, #"Button("OK") {}"#, #".navigationTitle("X")"#, #"Text(name)"#, #"TableColumn( "Size") {}"#,
            "Text(\n    \"Hi\"\n)", "Button(\n\"OK\") {}", ".confirmationDialog(\n    \"Sure?\", isPresented: $x)",
            #"Picker("P", selection: $x) {}"#, #"Menu("M") {}"#, #"Link("L", destination: url)"#, #"TextField("T", text: $x)"#,
            #"ProgressView("Loading")"#, #".navigationSubtitle("S")"#, #".accessibilityLabel("A")"#,
        ]
        for source in forbidden { XCTAssertEqual(Self.literalHits(in: source).count, 1, source) }
        let allowed = [
            #"Text(verbatim: name)"#, "Text(\n    verbatim: name)", #"Button(L10n.tr("app.action.ok")) {}"#, #"Text.l10n(L10n.tr("app.x"))"#,
            "ProgressView()", "// Text(\"in a comment\")",
        ]
        for source in allowed { XCTAssertEqual(Self.literalHits(in: source), [], source) }
        XCTAssertEqual(Self.literalHits(in: "let a = 1\nButton(\n  \"OK\")"), [#"2: Button("#])
    }

    // MARK: - Safety wording, pinned (S4 review): the old literals, verbatim

    func testTheCleanSafetyTextsKeepTheirEnglish() {
        let en = { (key: String) in L10n.string(key, in: .core, locale: "en", arguments: []) }
        // R5 (HIG review D3, D4): plain words, no hypothesis ids; the cache's confirmation keeps "experimental" (rule 10) and
        // still says it is deleted, not trashed, and refused while anything that uses it runs.
        XCTAssertEqual(
            en("app.clean.privileged.message"),
            "It’s deleted, not moved to the Trash. Simulators may run slower until the cache is rebuilt, and what rebuilds it isn’t known yet. "
                + "XCodeVault refuses while Xcode, a simulator or a build is running.")
        XCTAssertTrue(en("app.privileged.confirm.emptyDyldCache").contains("(experimental)"))
        XCTAssertEqual(en("app.clean.confirm.regenerable"), "Xcode rebuilds these when it needs them.")
        XCTAssertEqual(en("app.clean.confirm.userRecreatable"), "Some of these don’t come back: you recreate them yourself.")
        XCTAssertEqual(en("app.clean.useTrash"), "Move to Trash")
        XCTAssertTrue(en("app.clean.useTrash.help").contains("freed when you empty the Trash"))
        // Rule 7's cue stays visible in every language: a word beside the symbol, never the symbol alone.
        for locale in L10n.supportedLocales {
            XCTAssertFalse(L10n.string("app.storage.symlink", in: .core, locale: locale, arguments: []).isEmpty, locale)
        }
    }

    // MARK: - The Access checklist's keys (Task 1)

    func testEveryAccessChecklistKeyIsInTheCatalogInEveryLanguage() {
        XCTAssertEqual(AccessChecklist.allKeys.count, 27)
        for key in AccessChecklist.allKeys {
            let byLocale = L10nCatalog.core.strings[key] ?? L10nCatalog.core.plurals[key]?.mapValues { $0["other"] ?? "" }
            for locale in L10n.supportedLocales {
                XCTAssertFalse((byLocale?[locale] ?? "").isEmpty, "\(key) in \(locale)")
            }
        }
    }

    /// `AppText.access` renders each key with its literal `L10n` call; a typo there would show the key itself.
    func testTheAppRendersEveryAccessKey() {
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for key in AccessChecklist.allKeys {
                let text = AppText.access(key, bytes: 2_000_000, folders: 3)
                XCTAssertNotEqual(text, key, "\(key) in \(locale)")
                XCTAssertFalse(text.contains("%"), "\(key) in \(locale): \(text)")
            }
        }
        L10n.configure(override: "en", environment: [:], preferred: [])
        XCTAssertTrue(AppText.access(AccessChecklist.Key.fdaWhyUnreadableFolders, bytes: nil, folders: 3).contains("3"))
        XCTAssertTrue(AppText.access(AccessChecklist.Key.helperWhyRootOnlyBytes, bytes: 2_000_000, folders: nil).contains(ByteCount.format(UInt64(2_000_000))))
    }

    /// Review constraint: Full Disk Access is a "may", never a promise, and the unavailable helper says what to do.
    func testTheAccessWordingStaysConditionalAndActionable() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        for key in [AccessChecklist.Key.fdaWhyUnreadable, AccessChecklist.Key.fdaWhyUnreadableFolders, AccessChecklist.Key.fdaWhyProtected] {
            let text = AppText.access(key, bytes: nil, folders: 2)
            XCTAssertTrue(text.contains("may") || text.contains("only if"), text)
            XCTAssertFalse(text.contains("will"), text)
        }
        let guidance = AppText.access(AccessChecklist.Key.helperActionSignedReleaseOrCLI, bytes: nil, folders: nil)
        // A condition, never an instruction to use a release that does not exist (final review I1); one line (R5, X6).
        XCTAssertTrue(guidance.lowercased().contains("needs a signed build that includes the helper"), guidance)
        XCTAssertTrue(guidance.contains("none is released yet"), guidance)
        XCTAssertFalse(guidance.lowercased().contains("use the signed release"), guidance)
        // The manual route moved to the guidance's tooltip (`Row.helpKey`), hedged like `perm.helper.next.unavailableInThisBuild`.
        let route = AppText.access(AccessChecklist.Key.helperManualRoute, bytes: nil, folders: nil)
        XCTAssertTrue(route.lowercased().contains("where there is a manual route"), route)
        XCTAssertTrue(route.contains("`xcodevaultctl doctor`") && route.contains("`xcodevaultctl vault init`"), route)
    }

    /// The helper's status in a build without it never stands alone: its row's action says what to do instead (spec §6.3).
    func testTheUnavailableStatusComesWithWhatToDoInstead() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let row = AccessChecklist.rows(fullDiskAccess: .granted, helper: .unavailableInThisBuild, savings: SavingsSummary(), plan: [])[1]
        XCTAssertEqual(AppText.access(row.statusKey, bytes: nil, folders: nil), "Not in this build")
        XCTAssertEqual(row.actionKey, AccessChecklist.Key.helperActionSignedReleaseOrCLI)
        XCTAssertTrue(AppText.access(row.actionKey ?? "", bytes: nil, folders: nil).contains("none is released yet"))
        XCTAssertEqual(AppText.access(row.titleKey, bytes: nil, folders: nil), "Privileged helper")
    }

    // MARK: - Permission texts shared by the app and `xcodevaultctl permissions`

    func testPermissionTextsAreTranslatedAndTheRecordsStayEnglish() {
        for locale in L10n.supportedLocales where locale != "en" {
            for state in HelperState.allCases {
                XCTAssertNotEqual(state.why(in: locale), state.why(in: "en"), "\(state) \(locale)")
                XCTAssertNotEqual(state.displayName(in: locale), state.displayName(in: "en"), "\(state) \(locale)")
            }
            for state in FullDiskAccessState.allCases {
                XCTAssertNotEqual(state.why(in: locale), state.why(in: "en"), "\(state) \(locale)")
                XCTAssertTrue(FullDiskAccessState.notGranted.nextStep(in: locale).contains(FullDiskAccessProbe.settingsURL), locale)
            }
            for requirement in PrivilegeRequirement.allCases {
                XCTAssertNotEqual(requirement.label(in: locale), requirement.label(in: "en"), "\(requirement) \(locale)")
            }
            XCTAssertNotEqual(PrivilegedAction.emptyCoreSimulatorDyldCache.title(in: locale), PrivilegedAction.emptyCoreSimulatorDyldCache.title)
        }
        // The plain properties are the record's English, whatever the process locale: the journal and `--json` use them.
        L10n.configure(override: "ja", environment: [:], preferred: [])
        XCTAssertEqual(HelperState.notInstalled.why, HelperState.notInstalled.why(in: "en"))
        XCTAssertEqual(PrivilegedAction.createVaultDirectory(volumeUUID: "U").title, "Create the vault folder")
    }

    func testThePermissionsTextFollowsTheLanguage() {
        let report = PermissionsReport(fullDiskAccess: .notGranted, helper: .notInstalled)
        L10n.configure(override: "en", environment: [:], preferred: [])
        let english = TextRenderer.permissions(report)
        XCTAssertTrue(english.contains("Full Disk Access") && english.contains(HelperState.notInstalled.why), english)
        L10n.configure(override: "pt-BR", environment: [:], preferred: [])
        let portuguese = TextRenderer.permissions(report)
        XCTAssertTrue(portuguese.contains(HelperState.notInstalled.why(in: "pt-BR")), portuguese)
        XCTAssertFalse(portuguese.contains(HelperState.notInstalled.why), portuguese)
    }
}
