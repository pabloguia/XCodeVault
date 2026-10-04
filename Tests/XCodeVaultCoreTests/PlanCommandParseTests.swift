import ArgumentParser
import XCTest

@testable import XCodeVaultCore
@testable import xcodevaultctl

/// Every `xcodevaultctl` command `plan` prints is parsed by the real CLI, with sample values for its placeholders
/// (final S3 review, Important 6). Until S3 the spellings were checked by hand because no test could import the
/// executable target; it is linked now (ADR-0008), so a renamed flag fails here instead of in a user's terminal. The
/// commands are previews: parsed, none of them may carry the flag that acts.
final class PlanCommandParseTests: XCTestCase {
    private let samples = ["<identifier>": "ABC", "<vault>": "Vault", "<dir>": "/tmp/x", "<platform>": "iOS"]

    private func arguments(_ command: String, categoryID: String) -> [String] {
        var c = command.replacingOccurrences(of: "<id>", with: categoryID)
        for (placeholder, value) in samples { c = c.replacingOccurrences(of: placeholder, with: value) }
        return Array(c.split(separator: " ").map(String.init).dropFirst())
    }

    func testEveryPlanCommandParsesAsAPreview() throws {
        var parsed = 0
        var seen = Set<String>()
        for c in StorageCatalog.all {
            for bucket in SavingsBucket.allCases {
                guard let command = SavingsPlanner.command(categoryID: c.id, bucket: bucket), command.hasPrefix("xcodevaultctl ") else { continue }
                let args = arguments(command, categoryID: c.id)
                XCTAssertFalse(args.contains { $0.hasPrefix("<") }, "an unsubstituted placeholder in \(command)")
                let root: ParsableCommand
                do { root = try XCodeVaultCTL.parseAsRoot(args) } catch {
                    XCTFail("\(c.id)/\(bucket): `\(command)` does not parse: \(XCodeVaultCTL.message(for: error))")
                    continue
                }
                parsed += 1
                switch root {
                case let clean as Clean:
                    seen.insert("clean")
                    XCTAssertFalse(clean.apply, command)
                    XCTAssertEqual(clean.category, [c.id], command)
                case let externalize as Externalize:
                    seen.insert("externalize")
                    XCTAssertFalse(externalize.apply, command)
                    XCTAssertFalse(externalize.removeSourceAfterVerify, command)
                case let delete as Runtime.Delete:
                    seen.insert("runtime delete")
                    XCTAssertTrue(delete.dryRun, command)
                    XCTAssertFalse(delete.yes, command)
                case let offload as Runtime.Offload:
                    seen.insert("runtime offload")
                    XCTAssertFalse(offload.yes, command)
                case let export as Runtime.Export:
                    seen.insert("runtime export")
                    XCTAssertTrue(export.preflight, command)
                case is Locations.SetDerivedData, is Locations.SetArchives:
                    seen.insert("locations")
                default:
                    XCTFail("\(c.id)/\(bucket): `\(command)` parsed as \(type(of: root)), which this test does not know")
                }
            }
        }
        // Positive control: every kind of command `plan` prints was reached, so a pass is not an empty loop.
        XCTAssertEqual(seen, ["clean", "externalize", "runtime delete", "runtime offload", "runtime export", "locations"])
        XCTAssertGreaterThan(parsed, 10)
    }
}
