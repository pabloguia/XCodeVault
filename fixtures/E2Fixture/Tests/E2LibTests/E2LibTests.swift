import XCTest
@testable import E2Lib

final class E2LibTests: XCTestCase {
    func testFrameworkLoads() {
        XCTAssertEqual(E2Lib.answer(), 42)
        // Emit the load location into the log so the evidence file shows which volume served it.
        print("E2-EVIDENCE framework-loaded-from: \(E2Lib.loadedFrom())")
        print("E2-EVIDENCE test-bundle: \(Bundle(for: E2LibTests.self).bundlePath)")
    }
}
