import Foundation
import XCTest

/// R8 (ADR-0014): `scripts/helper-invariants.sh` holds the shape of the two exceptions the maintainer approved — one
/// `posix_spawn` of `/usr/sbin/diskutil`, one `AuthorizationCopyRights` on the client's reference — and nothing wider.
///
/// Each case copies the files the script reads into a temporary directory, applies one mutation, and runs the script
/// there: a rule is only as good as the mutation it is shown to catch. The unmutated copy must pass first, or every
/// "caught" below would prove nothing. Runs `/bin/bash` on copies only; it reads nothing of this Mac's state.
final class R8HelperInvariantsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r8-inv-\(UUID().uuidString)")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for item in ["Package.swift", "Sources", "scripts", "Resources"] {
            try FileManager.default.copyItem(at: repo.appendingPathComponent(item), to: root.appendingPathComponent(item))
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func runScript() throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/helper-invariants.sh").path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func mutate(_ relative: String, _ old: String, _ new: String) throws {
        let url = root.appendingPathComponent(relative)
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains(old), "the mutation's anchor is gone from \(relative): \(old)")
        try s.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
    }

    private func assertCaught(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try runScript()
        XCTAssertEqual(r.status, 1, "\(name) was not caught:\n\(r.output)", file: file, line: line)
        XCTAssertTrue(r.output.contains("VIOLATION"), "\(name): \(r.output)", file: file, line: line)
    }

    static let spawn = "Sources/XCodeVaultHelperCore/HelperDiskutil.swift"
    static let authz = "Sources/XCodeVaultHelperCore/HelperAuthorizationRight.swift"
    static let service = "Sources/XCodeVaultHelperCore/HelperService.swift"

    func testTheTreeAsItIsPasses() throws {
        let r = try runScript()
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("helper invariants: ok"), r.output)
    }

    func testASpawnOutsideItsFileIsCaught() throws {
        try mutate(Self.service, "let privilegedWork", "let spawned = posix_spawn(nil, nil, nil, nil, nil, nil)\nlet privilegedWork")
        try assertCaught("posix_spawn in HelperService")
    }

    func testASecondSpawnIsCaught() throws {
        try mutate(
            Self.spawn, "        var pid: pid_t = 0\n",
            "        var pid: pid_t = 0\n        _ = posix_spawn(&pid, DiskutilInvocation.executable, &actions, &attributes, argv, envp)\n")
        try assertCaught("a second posix_spawn")
    }

    func testAPathSearchIsCaught() throws {
        try mutate(Self.spawn, "posix_spawn(&pid, DiskutilInvocation.executable", "posix_spawnp(&pid, DiskutilInvocation.executable")
        try assertCaught("posix_spawnp")
    }

    func testAShellIsCaught() throws {
        try mutate(Self.spawn, "\"/usr/sbin/diskutil\"", "\"/bin/sh\"")
        try assertCaught("a shell as the executable")
    }

    func testAVariableExecutableIsCaught() throws {
        try mutate(Self.spawn, "posix_spawn(&pid, DiskutilInvocation.executable", "posix_spawn(&pid, program")
        try assertCaught("a variable executable")
    }

    func testAnotherPathIsCaught() throws {
        try mutate(Self.spawn, "\"/dev/null\", O_WRONLY", "\"/tmp/diskutil.log\", O_WRONLY")
        try assertCaught("another path literal")
    }

    func testCheckingTheHelpersOwnReferenceIsCaught() throws {
        try mutate(Self.authz, "AuthorizationCopyRights(clientRef,", "AuthorizationCopyRights(writer,")
        try assertCaught("a right checked on the helper's own reference")
    }

    func testReassigningTheClientsReferenceIsCaught() throws {
        try mutate(Self.authz, "        // `.destroyRights`:", "        clientRef = writer\n        // `.destroyRights`:")
        try assertCaught("clientRef reassigned")
    }

    func testAnAuthorizationDialogInTheHelperIsCaught() throws {
        try mutate(Self.authz, "[.extendRights], nil)", "[.extendRights, .interactionAllowed], nil)")
        try assertCaught("interaction in the helper")
    }

    func testARightCheckOutsideItsFileIsCaught() throws {
        try mutate(Self.service, "let privilegedWork", "let checked = AuthorizationCopyRights(nil, nil, nil, [], nil)\nlet privilegedWork")
        try assertCaught("AuthorizationCopyRights in HelperService")
    }

    func testTheNewVerbWithoutTheGateIsCaught() throws {
        try mutate(Self.service, "if let denied = authorize() { return HelperResult(ok: false, message: denied.message, code: .unauthorized) }", "")
        try assertCaught("enableOwnership without authorize()")
    }

    func testTheAppCallingTheVerbOutsideLiveHelperIsCaught() throws {
        try mutate("Sources/XCodeVault/Operations/AppModel+Drives.swift", "self.turnOnOwnership(volumeUUID: uuid)", "client.enableOwnership(volumeUUID: uuid)")
        try assertCaught("the verb called outside LiveHelper")
    }

    // MARK: - Fix round 1 (M1): the routes the helper-security review found passing, each now caught

    func testAnAliasedSpawnIsCaught() throws {
        try mutate(
            Self.spawn, "        var pid: pid_t = 0\n",
            "        var pid: pid_t = 0\n        let sp = posix_spawn\n        var p2: pid_t = 0\n        _ = sp(&p2, argv[0], &actions, &attributes, argv, envp)\n"
        )
        try assertCaught("posix_spawn bound to a value")
    }

    func testASecondSpawnWrittenWithASpaceIsCaught() throws {
        try mutate(
            Self.spawn, "        var pid: pid_t = 0\n",
            "        var pid: pid_t = 0\n        var p2: pid_t = 0\n        _ = posix_spawn (&p2, argv[0], &actions, &attributes, argv, envp)\n")
        try assertCaught("posix_spawn with a space before the paren")
    }

    func testASymbolLookedUpAtRunTimeIsCaught() throws {
        try mutate(Self.service, "let privilegedWork", "let ex = dlsym(UnsafeMutableRawPointer(bitPattern: -2), \"execve\")\nlet privilegedWork")
        try assertCaught("dlsym")
    }

    func testAForkIsCaught() throws {
        try mutate(Self.service, "let privilegedWork", "let child = vfork()\nlet privilegedWork")
        try assertCaught("vfork")
    }

    func testASymbolBoundByNameIsCaught() throws {
        try mutate(
            Self.service, "let privilegedWork",
            "@_silgen_name(\"execv\") func run(_ p: UnsafePointer<CChar>, _ a: UnsafePointer<UnsafePointer<CChar>?>) -> Int32\nlet privilegedWork")
        try assertCaught("@_silgen_name")
    }

    func testAnAliasedRightsCallIsCaught() throws {
        try mutate(
            Self.authz, "        defer { AuthorizationFree(writer, []) }\n",
            "        defer { AuthorizationFree(writer, []) }\n        let cr = AuthorizationCopyRights\n        _ = cr(writer, nil, nil, [.extendRights], nil)\n"
        )
        try assertCaught("AuthorizationCopyRights bound to a value")
    }

    func testTheAsynchronousRightsCallIsCaught() throws {
        try mutate(
            Self.authz, "        defer { AuthorizationFree(writer, []) }\n",
            "        defer { AuthorizationFree(writer, []) }\n        AuthorizationCopyRightsAsync(writer, nil, nil, [], { _, _ in })\n")
        try assertCaught("AuthorizationCopyRightsAsync")
    }

    func testInteractionThroughARawValueIsCaught() throws {
        try mutate(Self.authz, "[.extendRights], nil)", "AuthorizationFlags(rawValue: 3), nil)")
        try assertCaught("flags from a raw value")
    }

    func testAnInheritedDescriptorIsCaught() throws {
        try mutate(
            Self.spawn, "            posix_spawn_file_actions_adddup2(&actions, writeEnd, 1),\n",
            "            posix_spawn_file_actions_adddup2(&actions, writeEnd, 1),\n            posix_spawn_file_actions_addinherit_np(&actions, 5),\n")
        try assertCaught("addinherit_np")
    }

    func testASpawnThatReplacesTheDaemonIsCaught() throws {
        try mutate(Self.spawn, "POSIX_SPAWN_CLOEXEC_DEFAULT |", "POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETEXEC |")
        try assertCaught("POSIX_SPAWN_SETEXEC")
    }

    func testAnExtraArgumentIsCaught() throws {
        try mutate(
            Self.spawn, "case .enableOwnership(let uuid): return [\"enableOwnership\", uuid.uuidString]",
            "case .enableOwnership(let uuid): return [\"enableOwnership\", \"-force\", uuid.uuidString]")
        try assertCaught("an extra argv element")
    }

    func testAStringCaseIsCaught() throws {
        try mutate(Self.spawn, "    case enableOwnership(volumeUUID: UUID)", "    case enableOwnership(volumeUUID: String)")
        try assertCaught("a case carrying a String")
    }

    func testAPathBuiltByConcatenationIsCaught() throws {
        try mutate(Self.spawn, "\"/dev/null\", O_RDONLY", "\"/dev/\" + \"null\", O_RDONLY")
        try assertCaught("a path built by concatenation")
    }
}
