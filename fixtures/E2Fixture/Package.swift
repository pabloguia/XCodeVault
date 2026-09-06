// swift-tools-version:5.9
// E2 fixture: a dynamic library (built as a framework by xcodebuild) plus an XCTest bundle.
// Used by scripts/experiments/e2-external-xctest.sh to reproduce the "xctest cannot load a test
// bundle from an external volume" report (research finding F4) and isolate device vs. path.
import PackageDescription

let package = Package(
    name: "E2Fixture",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "E2Lib", type: .dynamic, targets: ["E2Lib"]),
    ],
    targets: [
        .target(name: "E2Lib"),
        .testTarget(name: "E2LibTests", dependencies: ["E2Lib"]),
    ]
)
