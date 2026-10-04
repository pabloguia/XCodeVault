import AppKit
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// Off-screen PNGs of Delete, Park, Run externally and Access for a visual review, written to `$TMPDIR/xcv-snapshots/` — never
/// the repository. Runs only with `XCV_SNAPSHOTS=1`; nothing here is an assertion about how they look. No window: an
/// `NSHostingView` drawn into a bitmap, like `OverviewSnapshotTests`.
@MainActor
final class BucketSnapshotTests: XCTestCase {
    nonisolated override func tearDown() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        super.tearDown()
    }

    func testWriteBucketSnapshots() async throws {
        // A return, not `XCTSkip`: the no-skips gate holds the suite to zero skipped tests.
        guard SnapshotWriter.isEnabled else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xcv-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        L10n.configure(override: "en", environment: [:], preferred: [])
        let t = TempDir()
        // Many skipped lines and warnings, as on a real Mac, to show the lower block at the window's minimum size.
        var survey = bucketSampleSurvey()
        survey.3.skipped = (1...8).map { "Category \($0): managed by Apple's tool, not deleted through the filesystem — use `xcrun simctl runtime`" }
        survey.3.warnings = ["DerivedData is rebuilt on the next build; the first build of each project will be a full build."]
        let model = makeModel(SwitchableHelper(.notInstalled), journal: t, survey: survey)
        await model.refresh()
        // Delete at the window's minimum (960×620) less the toolbar; the plans at the review size.
        // Access with both needs missing and folders refused: every part of a row shows.
        var refused = survey
        refused.0.summary.privacyRefusalCount = 4
        let access = makeModel(SwitchableHelper(.notInstalled), journal: t, fullDiskAccess: .notGranted, survey: refused)
        await access.refresh()
        let views: [(String, AnyView, NSSize)] = [
            ("access", AnyView(AccessView(model: access)), NSSize(width: 960, height: 568)),
            ("delete", AnyView(DeleteView(model: model)), NSSize(width: 960, height: 568)),
            (
                "park", AnyView(PlanView(bucket: .parkExternally, rows: model.rows(for: .parkExternally), vault: model.vaultStatus) { _ in }),
                NSSize(width: 1000, height: 760)
            ),
            (
                "run", AnyView(PlanView(bucket: .runFromExternal, rows: model.rows(for: .runFromExternal), vault: nil) { _ in }),
                NSSize(width: 1000, height: 760)
            ),
        ]
        var written: [String] = []
        for (name, view, size) in views {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(host.window)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = directory.appendingPathComponent("\(name)-en-light.png")
            try png.write(to: url)
            written.append(url.path)
        }
        XCTAssertEqual(written.count, 4)
        print("snapshots:\n" + written.joined(separator: "\n"))
    }
}
