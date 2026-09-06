// swift-tools-version:6.0
// XCodeVault — see docs/adr/0003-implementation-stack.md for the layout rationale.
import PackageDescription

let package = Package(
    name: "XCodeVault",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XCodeVaultCore", targets: ["XCodeVaultCore"]),
        .executable(name: "xcodevaultctl", targets: ["xcodevaultctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // The single shared domain layer. No UI, no privileged calls, no shell.
        .target(
            name: "XCodeVaultCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "xcodevaultctl",
            dependencies: [
                "XCodeVaultCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "XCodeVaultCoreTests",
            dependencies: ["XCodeVaultCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
