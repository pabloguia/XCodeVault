import XCTest

/// The app icon ships: the plist names it, the file is in the repository, and the bundle script copies it.
final class BrandAssetTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testThePlistNamesTheIconAndTheIconExists() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("Resources/App/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        let icns = repo.appendingPathComponent("Resources/App/AppIcon.icns")
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: icns.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 50_000, "an icns with every size from 16 to 1024 is well over 50 KB")
        let head = try FileHandle(forReadingFrom: icns).read(upToCount: 4)
        XCTAssertEqual(head, Data("icns".utf8))
    }

    func testTheBundleScriptCopiesTheIcon() throws {
        let script = try String(contentsOf: repo.appendingPathComponent("scripts/bundle-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("Resources/App/AppIcon.icns"), "bundle-app.sh must copy the icon into Contents/Resources")
    }

    func testTheLogoHasNoAppleMarks() throws {
        let svg = try String(contentsOf: repo.appendingPathComponent("Resources/Brand/logo.svg"), encoding: .utf8)
        for word in ["apple", "xcode", "hammer"] { XCTAssertFalse(svg.lowercased().contains(word), word) }
    }
}
