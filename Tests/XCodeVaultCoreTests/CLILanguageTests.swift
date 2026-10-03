import XCTest

@testable import XCodeVaultCore
@testable import xcodevaultctl

final class CLILanguageTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    func testTheFlagWinsOverTheEnvironmentAndIsRemoved() {
        let r = XCodeVaultCTL.prepareLanguage(arguments: ["status", "--lang", "ja"], environment: ["XCODEVAULT_LANG": "es"], preferred: ["pt-BR"])
        XCTAssertEqual(r.remaining, ["status"])
        XCTAssertNil(r.warning)
        XCTAssertEqual(L10n.locale, "ja")
    }

    func testJSONForcesEnglishWhateverTheFlag() {
        let r = XCodeVaultCTL.prepareLanguage(arguments: ["doctor", "--json", "--lang", "pt-BR"], environment: ["XCODEVAULT_LANG": "es"], preferred: ["ja"])
        XCTAssertEqual(L10n.locale, "en")
        XCTAssertEqual(r.remaining, ["doctor", "--json"])
    }

    func testAFlagNamedJSONAfterTheSeparatorIsNotTheFlag() {
        _ = XCodeVaultCTL.prepareLanguage(arguments: ["--lang", "ja", "x", "--", "--json"], environment: [:], preferred: [])
        XCTAssertEqual(L10n.locale, "ja")
    }

    func testReportIsAlwaysEnglish() {
        _ = XCodeVaultCTL.prepareLanguage(arguments: ["report", "--lang", "ja"], environment: [:], preferred: [])
        XCTAssertEqual(L10n.locale, "en")
        _ = XCodeVaultCTL.prepareLanguage(arguments: ["--lang", "ja", "report"], environment: [:], preferred: [])
        XCTAssertEqual(L10n.locale, "en")
    }

    func testTheLanguageFlagStillWorksWithoutJSON() {
        _ = XCodeVaultCTL.prepareLanguage(arguments: ["--lang", "ja", "status"], environment: [:], preferred: [])
        XCTAssertEqual(L10n.locale, "ja")
    }

    func testTheEnvironmentWinsOverPreferences() {
        _ = XCodeVaultCTL.prepareLanguage(arguments: ["status"], environment: ["XCODEVAULT_LANG": "es"], preferred: ["pt-BR"])
        XCTAssertEqual(L10n.locale, "es")
    }

    func testAnUnsupportedFlagWarnsAndFallsThrough() {
        let r = XCodeVaultCTL.prepareLanguage(arguments: ["--lang", "fr"], environment: [:], preferred: ["pt-BR"])
        XCTAssertEqual(L10n.locale, "pt-BR")
        XCTAssertEqual(r.warning, "xcodevaultctl: language 'fr' is not available; using pt-BR. Available: en, pt-BR, es, ja, zh-Hans")
    }

    func testJSONIsTheSameInEveryLanguage() throws {
        // `--json` is an API (spec §4.3): the same report encodes byte-identically whatever the locale. Non-zero
        // savings, so the localized vocabulary has something to leak into if it ever reached the encoder.
        var report = Fixtures.minimalReport()
        report.savings.deleteAndRegenerate.optionBytes = 42
        report.savings.temporaryBytes = 42
        L10n.configure(override: "en", environment: [:], preferred: [])
        let english = try JSONOutput.encode(report)
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            XCTAssertEqual(try JSONOutput.encode(report), english, locale)
        }
        XCTAssertTrue(english.contains("42"), "the savings were encoded")
    }

    func testDoctorAndPlanJSONAreTheSameInEveryLanguage() throws {
        // `doctor --json` encodes `Doctor().diagnoseAll`; `plan --json` encodes `[SavingsPlanRow]`. Both are APIs, so
        // neither may carry text that was localized on the way. A registry that does not exist keeps the doctor off the
        // real one.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("xcv-\(UUID().uuidString)/volumes.json")
        var report = Fixtures.minimalReport()
        report.savings.deleteAndRegenerate.optionBytes = 42
        func encoded() throws -> (doctor: String, plans: [String]) {
            let findings = Doctor().diagnoseAll(report: report, registry: VaultRegistry(url: missing))
            let plans = try SavingsBucket.allCases.map { try JSONOutput.encode(SavingsPlanner.rows(report: report, bucket: $0)) }
            return (try JSONOutput.encode(findings), plans)
        }
        L10n.configure(override: "en", environment: [:], preferred: [])
        let english = try encoded()
        XCTAssertFalse(english.plans.allSatisfy { $0 == "[]" || $0 == "[\n\n]" }, "some bucket has rows to compare")
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let other = try encoded()
            XCTAssertEqual(other.doctor, english.doctor, "doctor \(locale)")
            XCTAssertEqual(other.plans, english.plans, "plan \(locale)")
        }
    }

    func testTheShadowVaultCheckIsTheSameInEveryLanguage() throws {
        // The critical `vault-shadow:*` finding copies its detail from `VaultVerifier.check`, so the check is what must not localize.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcv-shadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("leftover"))
        let volume = VaultVolume(
            volumeUUID: "U-1", volumeName: "Vault", lastMountPoint: dir.path, registeredAt: Date(timeIntervalSince1970: 0), sentinelID: "s")
        let registry = VaultRegistry(url: dir.appendingPathComponent("none/volumes.json"))
        func encoded() throws -> String {
            let check = VaultVerifier(registry: registry, mountedVolumes: { [] }, isMountPoint: { _ in false }).check(volume)
            XCTAssertEqual(check.state, .ambiguous)
            return try JSONOutput.encode(check)
        }
        L10n.configure(override: "en", environment: [:], preferred: [])
        let english = try encoded()
        XCTAssertTrue(english.contains("0 bytes"), english)
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let other = try encoded()
            XCTAssertEqual(other, english, locale)
        }
    }

    func testPermissionsJSONIsTheSameInEveryLanguage() throws {
        // `permissions --json` encodes the `PermissionsReport` that `PermissionsCommand.report` builds; its texts are
        // taken when it is built, so it is built under each locale for every state it can report.
        func encodedReports() throws -> [String] {
            try FullDiskAccessState.allCases.flatMap { access in
                try HelperState.allCases.map { try JSONOutput.encode(PermissionsReport(fullDiskAccess: access, helper: $0)) }
            }
        }
        L10n.configure(override: "en", environment: [:], preferred: [])
        let english = try encodedReports()
        XCTAssertEqual(english.count, FullDiskAccessState.allCases.count * HelperState.allCases.count)
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            XCTAssertEqual(try encodedReports(), english, locale)
        }
    }

    func testTheHelpNamesTheLanguagesFromTheOneList() throws {
        let discussion = XCodeVaultCTL.configuration.discussion
        XCTAssertTrue(discussion.contains("--lang <code> (\(L10n.supportedLocales.joined(separator: ", ")))"), discussion)
    }
}
