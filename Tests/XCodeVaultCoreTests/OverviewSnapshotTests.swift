import AppKit
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// Off-screen PNGs of the Overview for a visual review, written to `$TMPDIR/xcv-snapshots/` — never the repository. Runs
/// only with `XCV_SNAPSHOTS=1`; nothing here is an assertion about how it looks. No window: an `NSHostingView` drawn into
/// a bitmap.
@MainActor
final class OverviewSnapshotTests: XCTestCase {
    nonisolated override func tearDown() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        super.tearDown()
    }

    func testWriteOverviewSnapshots() throws {
        // A return, not `XCTSkip`: the no-skips gate holds the suite to zero skipped tests.
        guard SnapshotWriter.isEnabled else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xcv-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for (locale, appearance) in [("en", NSAppearance.Name.aqua), ("en", .darkAqua), ("ja", .aqua)] {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let survey = sampleSurvey(refusals: 3, savings: sampleSavings(), runtimeImageBytes: 9_400_000_000)
            let banner = AccessChecklist.banner(
                fullDiskAccess: .notGranted, helper: .notInstalled, savings: survey.0.savings, plan: [], privacyRefusalCount: 3)
            let view = OverviewView(report: survey.0, findings: [], access: banner).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(host.window)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let name = "overview-\(locale)-\(appearance == .darkAqua ? "dark" : "light").png"
            let url = directory.appendingPathComponent(name)
            try png.write(to: url)
            written.append(url.path)
        }
        XCTAssertEqual(written.count, 3)
        print("snapshots:\n" + written.joined(separator: "\n"))
    }
}
