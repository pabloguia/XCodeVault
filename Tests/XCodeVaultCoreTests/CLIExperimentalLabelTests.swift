import Foundation
import XCTest

@testable import XCodeVaultCore

/// CLAUDE.md rule 10: a strategy below the Definition of Done is labelled experimental everywhere, CLI
/// help included. The label belongs in a command's `abstract`: that is the line its own `--help` opens
/// with and the only line of it the parent's command list shows. A `discussion:` reaches the command's
/// own help and nothing else, and a group's abstract never reaches its subcommands' help — which is why
/// `vault init --help` and `migration abort --help` said nothing while `vault` and `migration` said
/// "Experimental.", and `externalize` and `clean` said it only below the fold. Measured on the built
/// binary on 2026-09-27, together with the missing label on `runtime export` and `runtime import`.
///
/// `xcodevaultctl` is an executable target no test can import, so this reads its sources, as
/// `DoctorFamilyCompositionTests` does. It is a text check with a text check's limits: it reads the
/// string literals a declaration passes as its abstract, not the help ArgumentParser renders from them.
///
/// Every label is tied to the catalog entry that makes its strategy experimental, so the two move
/// together: when the catalog rates a strategy verified, its rows fail and say to remove the label — a
/// warning that outlives its reason is the other way this goes wrong.
final class CLIExperimentalLabelTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private let runtimeCommands = "Sources/xcodevaultctl/RuntimeCommands.swift"

    private struct ScanFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// The source of `struct <name>: ParsableCommand` in `file`, from its declaration to whichever comes
    /// first of its `func run(` and the next `struct `, without `//` comment lines. A name declared other
    /// than exactly once is an error, never a guess at which one was meant.
    private func declaration(of name: String, in file: String) throws -> Substring {
        let text = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
        let marker = "struct \(name): ParsableCommand"
        let count = text.components(separatedBy: marker).count - 1
        guard count == 1, let start = text.range(of: marker) else {
            throw ScanFailure(description: "\(file) declares `\(marker)` \(count) time(s); expected exactly one")
        }
        let rest = text[start.upperBound...]
        let ends = [rest.range(of: "func run(")?.lowerBound, rest.range(of: "struct ")?.lowerBound].compactMap { $0 }
        let kept = rest[..<(ends.min() ?? rest.endIndex)]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        return Substring(kept.joined(separator: "\n"))
    }

    /// The abstract `name` declares: the string literals after `abstract:`, joined where the source joins
    /// them with `+`, their contents as written. Anything else after the label is an error rather than an
    /// abstract read as empty, which would fail for the wrong reason, or read as the rest of the file,
    /// which could pass on a neighbour's label.
    private func abstract(of name: String, in file: String) throws -> String {
        let source = try declaration(of: name, in: file)
        guard let label = source.range(of: "abstract:") else {
            throw ScanFailure(description: "`\(name)` in \(file) declares no abstract, so its help has nowhere to carry the label")
        }
        var rest = source[label.upperBound...]
        var text = ""
        while true {
            rest = rest.drop(while: \.isWhitespace)
            let delimiter = rest.hasPrefix("\"\"\"") ? "\"\"\"" : "\""
            guard rest.hasPrefix(delimiter) else {
                throw ScanFailure(description: "the abstract of `\(name)` in \(file) is not a string literal")
            }
            rest = rest.dropFirst(delimiter.count)
            var end = rest.startIndex
            while end < rest.endIndex, !rest[end...].hasPrefix(delimiter) {
                // An escaped character, `\"` included, cannot end the literal.
                end = rest.index(end, offsetBy: rest[end] == "\\" ? 2 : 1, limitedBy: rest.endIndex) ?? rest.endIndex
            }
            guard end < rest.endIndex else {
                throw ScanFailure(description: "the abstract of `\(name)` in \(file) never closes its string literal")
            }
            text += rest[..<end]
            rest = rest[end...].dropFirst(delimiter.count).drop(while: \.isWhitespace)
            guard rest.first == "+" else { return text }
            rest = rest.dropFirst()
        }
    }

    /// Every `struct … : ParsableCommand` a file declares, so a subcommand added later is checked too.
    private func commands(in file: String) throws -> [String] {
        let text = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"struct (\w+): ParsableCommand"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private func assertLabelled(_ name: String, in file: String, because reason: String, line: UInt = #line) throws {
        let text = try abstract(of: name, in: file)
        XCTAssertNotNil(
            text.range(of: "experimental", options: .caseInsensitive),
            "the abstract of `\(name)` in \(file) does not say experimental (\(reason)): \(text)", line: line)
    }

    func testTheRuntimeLibraryCommandsSayExperimental() throws {
        let library = try XCTUnwrap(StorageCatalog.category("runtimeLibrary"))
        XCTAssertTrue(
            library.isExperimental,
            "the Runtime Library is no longer experimental: remove the label from export, import, library and offload, and these rows")
        for name in ["Export", "Import", "Library", "Offload"] {
            try assertLabelled(name, in: runtimeCommands, because: "Runtime Library, evidence \(library.evidenceStatus)")
        }
    }

    /// The control that gives the rows above their meaning: the check has to be able to say no. `runtime
    /// delete` deletes through Apple's own `simctl runtime delete`, whose category is Apple-managed and
    /// verified, and it sits in the same file as four labelled commands — an instrument that read past
    /// its own abstract would find their label here.
    func testRuntimeDeleteCarriesNoLabelBecauseItsStrategyIsApples() throws {
        XCTAssertFalse(try XCTUnwrap(StorageCatalog.category("simulatorRuntimeAssets")).isExperimental)
        let text = try abstract(of: "Delete", in: runtimeCommands)
        XCTAssertTrue(text.contains("simctl runtime delete"), "the scan did not read `Delete`'s own abstract: \(text)")
        XCTAssertNil(text.range(of: "experimental", options: .caseInsensitive), "found a label in `Delete`'s abstract: \(text)")
    }

    func testEveryVaultAndMigrationCommandSaysExperimental() throws {
        let archives = try XCTUnwrap(StorageCatalog.category("archives"))
        XCTAssertTrue(archives.allowedStrategies.contains(.coldStorage))
        XCTAssertTrue(
            archives.isExperimental,
            "cold storage of Archives is no longer experimental: remove the vault, externalize, restore and migration labels, and this test")
        for file in ["Sources/xcodevaultctl/VaultCommands.swift", "Sources/xcodevaultctl/MigrationCommands.swift"] {
            let names = try commands(in: file)
            XCTAssertFalse(names.isEmpty, "no command found in \(file)")
            for name in names {
                try assertLabelled(name, in: file, because: "cold storage of Archives, evidence \(archives.evidenceStatus)")
            }
        }
    }

    func testTheLocationsSettersAndCleanSayExperimental() throws {
        XCTAssertTrue(try XCTUnwrap(StorageCatalog.category("derivedData")).isExperimental)
        XCTAssertTrue(try XCTUnwrap(StorageCatalog.category("archives")).isExperimental)
        let locations = "Sources/xcodevaultctl/LocationsCommands.swift"
        try assertLabelled("SetDerivedData", in: locations, because: "derivedData")
        try assertLabelled("SetArchives", in: locations, because: "archives")
        // No catalog entry of its own: its abstract states the label on its own account.
        try assertLabelled("SetCompilationCache", in: locations, because: "compilation cache")
        XCTAssertTrue(
            StorageCatalog.all.contains { $0.allowedStrategies.contains(.safeCleanup) && $0.isExperimental },
            "no cleanable category is experimental any more: remove the label from clean, and this row")
        try assertLabelled("Clean", in: "Sources/xcodevaultctl/CleanCommand.swift", because: "the cleanable categories")
    }
}
