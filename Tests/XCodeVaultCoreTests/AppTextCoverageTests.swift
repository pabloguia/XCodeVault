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
    private static let literalUse = try! NSRegularExpression(
        pattern:
            #"\b(?:Button|Label|Toggle|TableColumn|GroupBox|Section|ContentUnavailableView|LabeledContent|CommandMenu|WindowGroup|Text)\(\s*""#
            + #"|\.(?:navigationTitle|confirmationDialog|alert|help)\(\s*""#
            + #"|\bText\((?!verbatim:)"#)

    func testNoAppViewTakesAStringLiteral() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: appSources.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 3, "the app's sources were found")
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if Self.literalUse.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    hits.append("\(file):\(number + 1): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }

    /// Control for the scan above: it does find the forms it forbids.
    func testTheScanFindsALiteral() {
        for line in [#"Text("Hi")"#, #"Button("OK") {}"#, #".navigationTitle("X")"#, #"Text(name)"#, #"TableColumn( "Size") {}"#] {
            XCTAssertNotNil(Self.literalUse.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
        for line in [#"Text(verbatim: name)"#, #"Button(L10n.tr("app.action.ok")) {}"#, #"Text.l10n(L10n.tr("app.x"))"#] {
            XCTAssertNil(Self.literalUse.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
    }

    // MARK: - The Access checklist's keys (Task 1)

    func testEveryAccessChecklistKeyIsInTheCatalogInEveryLanguage() {
        XCTAssertEqual(AccessChecklist.allKeys.count, 13)
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
        XCTAssertTrue(guidance.contains("signed release") && guidance.contains("xcodevaultctl"), guidance)
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
