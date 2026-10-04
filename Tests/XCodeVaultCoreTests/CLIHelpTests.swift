import ArgumentParser
import Foundation
import XCTest

@testable import XCodeVaultCore
@testable import xcodevaultctl

/// The help as rendered (spec 2026-10-03 §5, §5.1): commands grouped by task, examples on the root, and
/// abstracts that read as sentences in every language — no experiment ids and no catalog keys.
final class CLIHelpTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    /// Every command in the tree, the root included.
    private func allCommands(_ command: ParsableCommand.Type = XCodeVaultCTL.self) -> [ParsableCommand.Type] {
        [command] + command.configuration.subcommands.flatMap { allCommands($0) }
    }

    private func english(_ key: String) -> String { L10n.string(key, in: .core, locale: "en", arguments: []) }

    func testNoAbstractNamesAnExperimentHypothesisOrADR() throws {
        let ids = try NSRegularExpression(pattern: #"\b(E|H|F)\d+[a-z]?\b|ADR-\d+"#)
        let commands = allCommands()
        XCTAssertGreaterThan(commands.count, 30, "the walk found too few commands: \(commands.count)")
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for command in commands {
                let text = command.configuration.abstract
                let found = ids.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
                XCTAssertNil(found, "[\(locale)] `\(command)` names an id in its abstract (move it to a Background line): \(text)")
            }
        }
    }

    func testNoAbstractIsACatalogKey() {
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for command in allCommands() {
                let text = command.configuration.abstract
                XCTAssertFalse(text.contains("savings.") || text.contains("cli."), "[\(locale)] `\(command)` shows a catalog key: \(text)")
            }
        }
    }

    func testTheRootHelpGroupsCommandsByTaskAndShowsExamples() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        let help = XCodeVaultCTL.helpMessage(columns: 200)
        for key in ["cli.group.see", "cli.group.save", "cli.group.drives", "cli.group.recover", "cli.group.diagnose"] {
            let name = english(key)
            XCTAssertNotEqual(name, key, "\(key) is not in the catalog")
            // ArgumentParser heads a group "<NAME, UPPERCASED> SUBCOMMANDS:".
            XCTAssertTrue(help.contains(name.uppercased() + " SUBCOMMANDS:"), "the root help has no group \"\(name)\":\n\(help)")
        }
        XCTAssertTrue(help.contains("EXAMPLES:"), help)
        XCTAssertTrue(help.contains("xcodevaultctl plan delete"), help)
    }

    func testTheRootHelpIsInTheChosenLanguage() {
        let japanese = L10n.string("cli.group.save", in: .core, locale: "ja", arguments: [])
        XCTAssertNotEqual(japanese, english("cli.group.save"), "cli.group.save has no Japanese text")
        L10n.configure(override: "ja", environment: [:], preferred: [])
        let help = XCodeVaultCTL.helpMessage(columns: 200)
        XCTAssertTrue(help.contains(japanese), "the Japanese root help has no \"\(japanese)\":\n\(help)")
        XCTAssertNil(help.range(of: english("cli.group.save"), options: .caseInsensitive), help)
    }

    /// A mount point names a drive, not a vault: the examples show the identifier `vault status` prints.
    func testTheExternalizeExamplesNameTheVaultByItsUUID() {
        let discussion = Externalize.configuration.discussion
        XCTAssertTrue(discussion.contains("--vault <UUID from vault status>"), discussion)
        XCTAssertFalse(discussion.contains("/Volumes/MyDrive"), discussion)
    }

    func testNoArgumentsStillRunsStatus() throws {
        XCTAssertTrue(try XCodeVaultCTL.parseAsRoot([]) is Status)
    }
}
