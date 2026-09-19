import XCTest

@testable import XCodeVaultCore

/// Pins the property that made issue #17 worth fixing: every rule family is reachable from the one
/// composed entry point.
///
/// The defect was not that composing two families by hand is verbose. It was that the failure mode
/// is silent — a third family added without updating all three call sites drops its findings with
/// no compile error and no failing test. Moving the composition into `diagnoseAll` removes two of
/// the three places to forget; this test removes the third, by failing when a family exists in the
/// Doctor directory and `diagnoseAll` does not call it.
///
/// It reads source text, which is a weak instrument — it cannot tell a call from a mention in a
/// comment, and a family whose name does not start with `diagnose` is invisible to it. That is why
/// the naming convention is asserted too: the convention is what makes the scan work at all.
final class DoctorFamilyCompositionTests: XCTestCase {
    private var doctorDirectory: URL {
        // …/Tests/XCodeVaultCoreTests/<this file> → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/XCodeVaultCore/Doctor")
    }

    /// Every `public func diagnose…(report:…)` declared anywhere under `Sources/…/Doctor`, minus
    /// the composed entry point itself.
    private func declaredFamilies() throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(at: doctorDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "Found no Swift files under \(doctorDirectory.path); the path this test scans has moved.")

        var names: Set<String> = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("public func diagnose") else { continue }
                // `public func diagnoseVault(report: …` → `diagnoseVault`
                guard let open = trimmed.firstIndex(of: "(") else { continue }
                let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: "public func ".count)..<open])
                // A family takes the scan report. A helper that happens to be named `diagnose…`
                // and does not is not a family, and composing it would be wrong.
                guard trimmed[open...].hasPrefix("(report:") else { continue }
                names.insert(name)
            }
        }
        return names.subtracting(["diagnoseAll"])
    }

    /// The scan is only as good as its premise. If the two families known today stop matching the
    /// naming convention, the scan silently finds nothing and this file starts passing vacuously.
    func testTheScanFindsTheFamiliesThatAreKnownToExist() throws {
        let families = try declaredFamilies()
        XCTAssertTrue(
            families.contains("diagnose"),
            "The scan did not find `diagnose`. Either it was renamed, or the convention this test relies on changed.")
        XCTAssertTrue(
            families.contains("diagnoseVault"),
            "The scan did not find `diagnoseVault`. Either it was renamed, or the convention this test relies on changed.")
    }

    func testEveryRuleFamilyIsReachableFromTheComposedEntryPoint() throws {
        let composed = try String(
            contentsOf: doctorDirectory.appendingPathComponent("Doctor+Composed.swift"), encoding: .utf8)
        // Only the body, so a family named in the doc comment above it does not count as composed.
        guard let bodyStart = composed.range(of: "public func diagnoseAll") else {
            return XCTFail("`diagnoseAll` is not declared in Doctor+Composed.swift.")
        }
        let body = String(composed[bodyStart.lowerBound...])

        for family in try declaredFamilies() {
            XCTAssertTrue(
                body.contains("\(family)(report:"),
                """
                Rule family `\(family)` is declared under Sources/XCodeVaultCore/Doctor but is not \
                called from `diagnoseAll`. Its findings would never reach a user: `doctor`, the \
                `--json` report and the GUI all go through `diagnoseAll` and nothing else. Add it \
                there — that is the one place, and this test exists so it is not also a fourth \
                place to forget.
                """)
        }
    }

    /// The call sites this issue was about. A regression here is a client quietly going back to
    /// composing families by hand, which is the state the composed entry point replaced.
    func testNoClientComposesTheFamiliesByHand() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for target in ["Sources/xcodevaultctl", "Sources/XCodeVault"] {
            let directory = repoRoot.appendingPathComponent(target)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(
                    text.contains("diagnoseVault("),
                    """
                    \(file.lastPathComponent) calls `diagnoseVault` directly. Clients should call \
                    `diagnoseAll`, so that adding a rule family does not mean editing every client.
                    """)
            }
        }
    }
}
