// swift-tools-version:6.0
// XCodeVault — see docs/adr/0003-implementation-stack.md for the layout rationale.
import PackageDescription

let package = Package(
    name: "XCodeVault",
    platforms: [.macOS(.v14)],
    products: [
        // `XCodeVaultCore` is deliberately NOT a product (issue #15).
        //
        // It was declared `.library(name: "XCodeVaultCore", targets: ["XCodeVaultCore"])`, which
        // made its entire public surface — 502 declarations — a semver commitment from the day the
        // repository opened, when every actual consumer is inside this repository: the CLI, the
        // app, and the test target. Nothing distinguished the types a consumer is meant to depend
        // on from the ones that are `public` only because they had to cross a target boundary, so
        // the commitment was to a surface nobody had chosen.
        //
        // Removing the product is the part of the fix that closes the exposure, and it closes all
        // of it: the three in-repo consumers depend on the *target*, which still works, while an
        // external package can no longer depend on any of it. The `package`/`internal` narrowing
        // is hygiene that can now proceed incrementally instead of being one large break — and
        // narrowing a surface nobody can reach is not a breaking change at all.
        //
        // Re-adding it is a deliberate act with a precondition: decide first which types are the
        // API, mark only those `public`, and say so in a release note.
        .executable(name: "xcodevaultctl", targets: ["xcodevaultctl"]),
        .executable(name: "xcodevault-helper", targets: ["XCodeVaultHelper"]),
        .executable(name: "XCodeVault", targets: ["XCodeVault"]),
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
        // XPC protocol shared by client and daemon. Nothing else crosses the boundary.
        .target(
            name: "XCodeVaultHelperProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The privileged helper's logic. Depended on by the helper executable and the test target,
        // and deliberately by NOTHING else — not the app, not the CLI. It exists so the verbs, the
        // authorization gate and the path guards can be tested; an untestable gate in a root daemon
        // is how this project shipped a `getgrouplist` retry that could never run.
        .target(
            name: "XCodeVaultHelperCore",
            dependencies: ["XCodeVaultHelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Root LaunchDaemon (SMAppService.daemon). Allowlisted verbs only; no Process, no shell.
        // `scripts/helper-invariants.sh` checks that over a fixed list of helper directories, and
        // the helper-security review is what actually decides — the script is a lint that has been
        // defeated in every round it has been mutation-tested, and it does not read this file, so
        // nothing mechanical notices if this target gains a dependency. This target is the
        // bootstrap only.
        .executableTarget(
            name: "XCodeVaultHelper",
            dependencies: ["XCodeVaultHelperCore", "XCodeVaultHelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // SwiftUI app — a projection of XCodeVaultCore; bundled by scripts/bundle-app.sh.
        .executableTarget(
            name: "XCodeVault",
            dependencies: ["XCodeVaultCore", "XCodeVaultHelperProtocol"],
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
            dependencies: ["XCodeVaultCore", "XCodeVaultHelperProtocol", "XCodeVaultHelperCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
