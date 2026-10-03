import ArgumentParser
import XCTest

@testable import XCodeVaultCore
@testable import xcodevaultctl

/// CLAUDE.md rule 10: a strategy below the Definition of Done is labelled experimental everywhere, CLI
/// help included. The label belongs in a command's `abstract`: that is the line its own `--help` opens
/// with and the only line of it the parent's command list shows. A `discussion:` reaches the command's
/// own help and nothing else, and a group's abstract never reaches its subcommands' help — which is why
/// `vault init --help` and `migration abort --help` said nothing while `vault` and `migration` said
/// "Experimental.", and `externalize` and `clean` said it only below the fold. Measured on the built
/// binary on 2026-09-27, together with the missing label on `runtime export` and `runtime import`.
///
/// This reads the help as rendered, per language (spec 2026-10-03 §5.1). Until S3 it read the string
/// literals in `Sources/xcodevaultctl`, because no test could import an executable target; the test
/// target now links the CLI (ADR-0008), and the abstracts became catalog keys, so a literal no longer
/// says what any language shows. Each command's `configuration` is computed, so reading it after
/// `L10n.configure` gives exactly the abstract `--lang <code> --help` prints. The label is one key,
/// `cli.label.experimental`, put in front by one helper (`HelpText.experimental`), and every row below is
/// checked in every shipped language: a translation that drops it fails here, not in a user's terminal.
///
/// Every label is tied to the catalog entry that makes its strategy experimental, so the two move
/// together: when the catalog rates a strategy verified, its rows fail and say to remove the label — a
/// warning that outlives its reason is the other way this goes wrong.
final class CLIExperimentalLabelTests: XCTestCase {
    override func tearDown() { L10n.configure(override: "en", environment: [:], preferred: []) }

    private func label(_ locale: String) -> String {
        L10n.string("cli.label.experimental", in: .core, locale: locale, arguments: [])
    }

    /// `command`'s abstract in every shipped language, rendered under that language.
    private func abstracts(of command: ParsableCommand.Type) -> [(locale: String, text: String)] {
        L10n.supportedLocales.map { locale in
            L10n.configure(override: locale, environment: [:], preferred: [])
            return (locale, command.configuration.abstract)
        }
    }

    private func assertLabelled(_ command: ParsableCommand.Type, because reason: String, line: UInt = #line) {
        for (locale, text) in abstracts(of: command) {
            let label = label(locale)
            // No ASCII space after a full-width "。"; one after every other label.
            let separator = label.hasSuffix("。") ? "" : " "
            XCTAssertTrue(
                text.hasPrefix(label + separator) && text.count > label.count + separator.count,
                "[\(locale)] the abstract of `\(command)` does not open with \"\(label)\" (\(reason)): \(text)", line: line)
            if separator.isEmpty {
                XCTAssertFalse(text.hasPrefix(label + " "), "[\(locale)] an ASCII space follows the full-width full stop: \(text)", line: line)
            }
        }
    }

    /// The label itself, pinned: a key missing from the catalog would come back as the key, and every row
    /// below would then compare abstracts against a string no user sees.
    func testTheLabelIsTranslatedInEveryLanguage() {
        let expected = ["en": "Experimental.", "pt-BR": "Experimental.", "es": "Experimental.", "ja": "実験的。", "zh-Hans": "实验性。"]
        XCTAssertEqual(Set(expected.keys), Set(L10n.supportedLocales), "a language was added: pin its label here")
        for locale in L10n.supportedLocales {
            XCTAssertEqual(label(locale), expected[locale], locale)
        }
    }

    func testTheRuntimeLibraryCommandsSayExperimental() throws {
        let library = try XCTUnwrap(StorageCatalog.category("runtimeLibrary"))
        XCTAssertTrue(
            library.isExperimental,
            "the Runtime Library is no longer experimental: remove the label from export, import, library and offload, and these rows")
        let commands: [ParsableCommand.Type] = [Runtime.Export.self, Runtime.Import.self, Runtime.Library.self, Runtime.Offload.self]
        for command in commands {
            assertLabelled(command, because: "Runtime Library, evidence \(library.evidenceStatus)")
        }
    }

    /// The control that gives the rows above their meaning: the check has to be able to say no. `runtime
    /// delete` deletes through Apple's own `simctl runtime delete`, whose category is Apple-managed and
    /// verified, and it is a sibling of four labelled commands — an instrument that read a neighbour's
    /// abstract would find their label here.
    func testRuntimeDeleteCarriesNoLabelBecauseItsStrategyIsApples() throws {
        XCTAssertFalse(try XCTUnwrap(StorageCatalog.category("simulatorRuntimeAssets")).isExperimental)
        for (locale, text) in abstracts(of: Runtime.Delete.self) {
            // The typed command is never translated, so it identifies `Delete`'s own abstract in every language.
            XCTAssertTrue(text.contains("simctl runtime delete"), "[\(locale)] did not read `Delete`'s own abstract: \(text)")
            XCTAssertFalse(text.contains(label(locale)), "[\(locale)] found a label in `Delete`'s abstract: \(text)")
            XCTAssertNil(text.range(of: "experimental", options: .caseInsensitive), "[\(locale)] found a label in `Delete`'s abstract: \(text)")
        }
    }

    /// Every command in the `vault` and `migration` trees, walked rather than listed, so a subcommand added
    /// later is checked too; `externalize` and `restore` are the two top-level commands of the same strategy.
    func testEveryVaultAndMigrationCommandSaysExperimental() throws {
        let archives = try XCTUnwrap(StorageCatalog.category("archives"))
        XCTAssertTrue(archives.allowedStrategies.contains(.coldStorage))
        XCTAssertTrue(
            archives.isExperimental,
            "cold storage of Archives is no longer experimental: remove the vault, externalize, restore and migration labels, and this test")
        func tree(_ command: ParsableCommand.Type) -> [ParsableCommand.Type] {
            [command] + command.configuration.subcommands.flatMap(tree)
        }
        let commands = tree(Vault.self) + tree(Migration.self) + [Externalize.self, Restore.self]
        XCTAssertGreaterThanOrEqual(commands.count, 11, "the walk lost commands: \(commands)")
        for command in commands {
            assertLabelled(command, because: "cold storage of Archives, evidence \(archives.evidenceStatus)")
        }
    }

    func testTheLocationsSettersAndCleanSayExperimental() throws {
        XCTAssertTrue(try XCTUnwrap(StorageCatalog.category("derivedData")).isExperimental)
        XCTAssertTrue(try XCTUnwrap(StorageCatalog.category("archives")).isExperimental)
        assertLabelled(Locations.SetDerivedData.self, because: "derivedData")
        assertLabelled(Locations.SetArchives.self, because: "archives")
        // No catalog entry of its own: its abstract states the label on its own account.
        assertLabelled(Locations.SetCompilationCache.self, because: "compilation cache")
        XCTAssertTrue(
            StorageCatalog.all.contains { $0.allowedStrategies.contains(.safeCleanup) && $0.isExperimental },
            "no cleanable category is experimental any more: remove the label from clean, and this row")
        assertLabelled(Clean.self, because: "the cleanable categories")
    }
}
