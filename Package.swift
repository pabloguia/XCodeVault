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
        // The XPC client — the only thing permitted to open a connection to the daemon, which
        // `scripts/helper-invariants.sh` holds as a prohibition with this file as its single
        // allowlist entry. It depends on the protocol and nothing else: it must not be able to
        // reach the daemon's own logic, and giving it `XCodeVaultHelperCore` would let a caller
        // execute the verbs in-process and mistake that for having exercised the boundary.
        //
        // Nothing in `Sources/` depends on it yet (issue #30). It is built and tested because the
        // test target depends on it; wiring it to the app is M4, gated on a signed bundle.
        .target(
            name: "XCodeVaultHelperClient",
            dependencies: ["XCodeVaultHelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Root LaunchDaemon (SMAppService.daemon). Allowlisted verbs only; no Process, no shell.
        // `scripts/helper-invariants.sh` checks that, and as of issue #7 it **does** read this
        // file: it parses the target graph, enforces that only the helper executable and the test
        // target depend on `XCodeVaultHelperCore`, holds each helper target to a dependency
        // allowlist, and derives its scan directories from that parse. Adding a dependency to this
        // target now turns the gate red rather than relying on a reviewer noticing.
        //
        // That is a mechanical check, not the control. The script is a text matcher that a
        // reviewer has defeated in every round it has been mutation-tested; the helper-security
        // review is what actually decides. This target is the bootstrap only.
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
            dependencies: ["XCodeVaultCore", "XCodeVaultHelperProtocol", "XCodeVaultHelperCore", "XCodeVaultHelperClient"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
