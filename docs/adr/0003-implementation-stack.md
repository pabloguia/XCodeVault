# ADR 0003: Implementation stack — Swift 6 / SwiftPM monorepo, one domain library, SwiftUI GUI

- Status: accepted
- Date: 2026-09-06
- Related hypothesis: none (platform decision); constraints derive from
  `../architecture/SECURITY_MODEL.md`, `../product/UX_AND_CLI.md`, ADR-0001, ADR-0002.

## Context

Nothing in the spec mandates a language. The constraints that do bind, all non-negotiable:

1. Native macOS GUI **and** a first-class CLI (`xcodevaultctl`) calling **one shared
   domain layer**; the GUI never reimplements CLI logic.
2. A root privileged helper registered with `SMAppService.daemon`, validated with
   `NSXPCConnection.setCodeSigningRequirement`, exposing an allowlisted verb API. Minimum
   macOS 14 (ADR-0001). These APIs are Objective-C/Swift-only; there is no stable C ABI
   for `SMAppService` or `NSXPCConnection`.
3. Developer ID signing, hardened runtime, notarization, stapling; Homebrew Cask viable.
4. CI on GitHub-hosted `macos-15` and `macos-26` runners (Xcode 16.x and 26.x).
5. Filesystem primitives the product depends on are BSD/Darwin syscalls
   (`getattrlist` + `ATTR_DIR_MOUNTSTATUS`, `statfs`, `chflags`, `copyfile`, `clonefile`)
   and Apple frameworks (DiskArbitration, ServiceManagement, Security).

Machine reality at decision time: macOS 26.6.2 / Xcode 26.5 / Swift 6.3 on Intel; the
target population per ADR-0001 is macOS 14+ with Xcode 16/26.

## Options considered

- **Swift (SwiftPM) + SwiftUI/AppKit — chosen.** Native access to every framework in
  (2) and (5) with zero bridging; one language for helper, CLI, domain, GUI; `swift test`
  runs on both CI runners; swift-argument-parser gives a proper CLI; Swift 6 strict
  concurrency is a real asset in the one process where a data race is a root
  escalation (the helper).
- **Rust core + Swift shell.** Tempting for the migration engine (fault-injection
  testing, no ObjC runtime), but it splits the "one domain layer" across an FFI
  boundary: every catalog/journal/plan type would need a C ABI and two owners. The
  helper, XPC, SMAppService and the GUI must be Swift regardless, so Rust buys a second
  toolchain on CI for the least platform-specific 30% of the code. Rejected; may be
  revisited only for an isolated, pure-computation subsystem with a stable interface
  (e.g. a verification hasher) — and only with an ADR.
- **Objective-C.** Same platform access as Swift with none of the type/concurrency
  safety. Rejected.
- **Electron / Tauri / Go + webview.** Not native, no path to `SMAppService.daemon` or
  `NSXPCConnection` without a Swift/ObjC helper anyway, sandbox and notarization
  friction. Rejected.
- **Xcode project as the build system of record** vs. **SwiftPM package with a bundling
  script.** SwiftPM is the source of truth: `swift build`/`swift test` work on any runner
  without a checked-in `.xcodeproj`, and the CLI, helper and domain are plain SwiftPM
  targets. The GUI `.app` bundle (Info.plist, `Contents/Library/LaunchDaemons/*.plist`,
  helper inside the bundle, signing) is produced by `scripts/bundle-app.sh` from SwiftPM
  build products. If entitlements/signing ever require it, an `.xcodeproj` may be
  *generated* (XcodeGen) — never hand-maintained as a second build definition.

## Decision

- **Language/toolchain:** Swift, `swift-tools-version: 6.0`, Swift 6 language mode,
  `platforms: [.macOS(.v14)]`. Builds with Xcode 16.0+ (CI `macos-15`) and Xcode 26
  (CI `macos-26`).
- **Layout (single SwiftPM package at repo root):**
  - `XCodeVaultCore` — the domain: environment discovery (Xcodes, runtimes, volumes),
    storage catalog + strategies, doctor rules, migration engine + journal, report
    models. Pure Swift + Foundation/Darwin, no UI, no privileged calls. Everything
    user-visible in CLI and GUI is a projection of this module.
  - `XCodeVaultHelperProtocol` — the XPC `@objc` protocol and allowlisted verb value
    types shared by client and daemon. Nothing else crosses the XPC boundary.
  - `XCodeVaultHelper` — the root daemon executable (`SMAppService.daemon`). Depends on
    `XCodeVaultHelperProtocol` only; resolves every request against its own approved
    catalog. No `Process` with shell, no free-form paths.
  - `xcodevaultctl` — CLI on swift-argument-parser; every read verb has `--json`.
  - `XCodeVault` — SwiftUI app executable target (M4), bundled by `scripts/bundle-app.sh`.
  - `Tests/` — unit tests per module plus functional probes gated by environment
    variables so CI can run the pure tests and a developer Mac can run the probes.
- **Dependencies:** `apple/swift-argument-parser` only. Add nothing to the helper.
- **Process execution:** a single `CommandRunner` abstraction (array-argument
  `posix_spawn` via `Process`, no shell) in Core, injectable for tests. The helper never
  links it in a way that accepts client-supplied arguments.
- **Formatting:** `swift-format` from the Xcode toolchain, enforced by a hook.

## Consequences

- One toolchain, one test command, one CI matrix. Everything the security review needs
  to read is Swift in one repo.
- We accept SwiftUI's rough edges for table-heavy Mac UIs; AppKit interop is available
  where needed.
- The `.app` bundle is script-assembled; signing/notarization is scripted in M5 rather
  than driven by Xcode's archive UI.
- **What would make us reverse this:** a hard requirement that cannot be met from
  SwiftPM (e.g. an entitlement only Xcode can provision for the GUI target) — then
  generate an Xcode project for that target only, keeping SwiftPM authoritative for
  everything else. A second reversal trigger: the migration engine's verification/hash
  path proving too slow in Swift — then an isolated native module, with its own ADR.

## Evidence

Toolchain and runner facts: `../research/FINDINGS-2026-09-05.md` §F7, §F8;
`../research/evidence/e8-macos26.6.2-25G83-xcode26.5-x86_64.txt` (Xcode 26.5 flag
surface the CLI must feature-detect).
