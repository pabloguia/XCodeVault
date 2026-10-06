import Foundation
import XCTest

/// R8 (ADR-0014): `scripts/helper-invariants.sh` holds the shape of the two exceptions the maintainer approved — one
/// `posix_spawn` of `/usr/sbin/diskutil`, one `AuthorizationCopyRights` on the client's reference — and nothing wider.
///
/// Each mutation copies the files the script reads into its own temporary directory, applies one change, and runs the
/// script there: a rule is only as good as the mutation it is shown to catch. The unmutated copy must pass first, or
/// every "caught" below would prove nothing. The table includes every bypass the helper-security reviews' harnesses
/// (`mut.py`, fix round 1; `mut2.py`, fix round 2) found passing. Runs `/bin/bash` on copies only, several at a time;
/// it reads nothing of this Mac's state.
///
/// **A tripwire, not the control.** A source lint cannot prove the absence of every encoding of a forbidden call; the
/// mandatory helper-security review is the control (ADR-0014).
final class R8HelperInvariantsTests: XCTestCase {
    static let spawn = "Sources/XCodeVaultHelperCore/HelperDiskutil.swift"
    static let authz = "Sources/XCodeVaultHelperCore/HelperAuthorizationRight.swift"
    static let service = "Sources/XCodeVaultHelperCore/HelperService.swift"
    static let own = "Sources/XCodeVaultHelperCore/HelperOwnership.swift"
    static let recheck = "    func isUnchanged(_ pin: MountPin) -> Bool {\n"
    static let readerLine = "        let reader = volumes ?? OwnershipVolumeReader(runner: diskutil)\n"
    static let pid = "        var pid: pid_t = 0\n"
    static let writerFree = "        defer { AuthorizationFree(writer, []) }\n"
    static let check = "AuthorizationCopyRights(clientRef, &rights, nil, [.extendRights], nil)"
    static let work = "let privilegedWork"

    struct Mutation: Sendable {
        let name: String
        let file: String
        let old: String
        let new: String
        var appendToService: String? = nil
    }

    static let mutations: [Mutation] = [
        // Round one: the self-test's own cases.
        Mutation(name: "posix_spawn outside its file", file: service, old: work, new: "let spawned = posix_spawn(nil, nil, nil, nil, nil, nil)\n" + work),
        Mutation(
            name: "a second posix_spawn", file: spawn, old: pid,
            new: pid + "        _ = posix_spawn(&pid, DiskutilInvocation.executable, &actions, &attributes, argv, envp)\n"),
        Mutation(
            name: "posix_spawnp", file: spawn, old: "posix_spawn(&pid, DiskutilInvocation.executable", new: "posix_spawnp(&pid, DiskutilInvocation.executable"),
        Mutation(name: "a shell as the executable", file: spawn, old: "\"/usr/sbin/diskutil\"", new: "\"/bin/sh\""),
        Mutation(name: "a variable executable", file: spawn, old: "posix_spawn(&pid, DiskutilInvocation.executable", new: "posix_spawn(&pid, program"),
        Mutation(name: "another path literal", file: spawn, old: "\"/dev/null\", O_WRONLY", new: "\"/tmp/diskutil.log\", O_WRONLY"),
        Mutation(
            name: "a right checked on the helper's own reference", file: authz, old: "AuthorizationCopyRights(clientRef,",
            new: "AuthorizationCopyRights(writer,"),
        Mutation(
            name: "clientRef reassigned", file: authz, old: "        // `.destroyRights`:", new: "        clientRef = writer\n        // `.destroyRights`:"),
        Mutation(name: "interaction in the helper", file: authz, old: "[.extendRights], nil)", new: "[.extendRights, .interactionAllowed], nil)"),
        Mutation(
            name: "AuthorizationCopyRights outside its file", file: service, old: work,
            new: "let checked = AuthorizationCopyRights(nil, nil, nil, [], nil)\n" + work),
        Mutation(
            name: "enableOwnership without authorize()", file: service,
            old: "if let denied = authorize() { return HelperResult(ok: false, message: denied.message, code: .unauthorized) }", new: ""),
        Mutation(
            name: "the verb called outside LiveHelper", file: "Sources/XCodeVault/Operations/AppModel+Drives.swift",
            old: "self.turnOnOwnership(volumeUUID: uuid, mountPoint: mp)", new: "client.enableOwnership(volumeUUID: uuid)"),
        // Fix round 1 (M1): mut.py.
        Mutation(
            name: "posix_spawn bound to a value", file: spawn, old: pid,
            new: pid + "        let sp = posix_spawn\n        var p2: pid_t = 0\n        _ = sp(&p2, argv[0], &actions, &attributes, argv, envp)\n"),
        Mutation(
            name: "posix_spawn with a space before the paren", file: spawn, old: pid,
            new: pid + "        var p2: pid_t = 0\n        _ = posix_spawn (&p2, argv[0], &actions, &attributes, argv, envp)\n"),
        Mutation(name: "dlsym", file: service, old: work, new: "let ex = dlsym(UnsafeMutableRawPointer(bitPattern: -2), \"execve\")\n" + work),
        Mutation(name: "vfork", file: service, old: work, new: "let child = vfork()\n" + work),
        Mutation(
            name: "@_silgen_name", file: service, old: work,
            new: "@_silgen_name(\"execv\") func run(_ p: UnsafePointer<CChar>, _ a: UnsafePointer<UnsafePointer<CChar>?>) -> Int32\n" + work),
        Mutation(
            name: "AuthorizationCopyRights bound to a value", file: authz, old: writerFree,
            new: writerFree + "        let cr = AuthorizationCopyRights\n        _ = cr(writer, nil, nil, [.extendRights], nil)\n"),
        Mutation(
            name: "AuthorizationCopyRightsAsync", file: authz, old: writerFree,
            new: writerFree + "        AuthorizationCopyRightsAsync(writer, nil, nil, [], { _, _ in })\n"),
        Mutation(name: "flags from AuthorizationFlags(rawValue:)", file: authz, old: "[.extendRights], nil)", new: "AuthorizationFlags(rawValue: 3), nil)"),
        Mutation(
            name: "addinherit_np", file: spawn, old: "            posix_spawn_file_actions_adddup2(&actions, writeEnd, 1),\n",
            new: "            posix_spawn_file_actions_adddup2(&actions, writeEnd, 1),\n            posix_spawn_file_actions_addinherit_np(&actions, 5),\n"),
        Mutation(name: "POSIX_SPAWN_SETEXEC", file: spawn, old: "POSIX_SPAWN_CLOEXEC_DEFAULT |", new: "POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETEXEC |"),
        Mutation(
            name: "an extra argv element", file: spawn, old: "return [\"enableOwnership\", disk.value]",
            new: "return [\"enableOwnership\", \"-force\", disk.value]"),
        Mutation(
            name: "a case carrying a String", file: spawn, old: "    case enableOwnership(disk: DiskIdentifier)", new: "    case enableOwnership(disk: String)"),
        Mutation(name: "a path built by concatenation", file: spawn, old: "\"/dev/null\", O_RDONLY", new: "\"/dev/\" + \"null\", O_RDONLY"),
        // Fix round 2 (N1): mut2.py.
        Mutation(name: "flags from .init(rawValue:)", file: authz, old: "[.extendRights], nil)", new: ".init(rawValue: 3), nil)"),
        Mutation(
            name: "a flag declared in another file", file: authz, old: "[.extendRights], nil)", new: "[.extendRights, .ask], nil)",
            appendToService: "\nextension AuthorizationFlags { static let ask = Self(rawValue: 1 << 1) }\n"),
        Mutation(
            name: "clientRef shadowed by a closure parameter", file: authz, old: "                return " + check,
            new: "                return { (clientRef: AuthorizationRef) in " + check + " }(writerShadow)"),
        Mutation(
            name: "clientRef rebound by if case", file: authz, old: "        let status = rightName",
            new: "        if case let clientRef? = Optional(clientRef) { _ = clientRef }\n        let status = rightName"),
        Mutation(
            name: "clientRef rebound by for", file: authz, old: "        let status = rightName",
            new: "        for clientRef in [clientRef] { _ = clientRef }\n        let status = rightName"),
        Mutation(
            name: "a local type shadowing the executable", file: spawn, old: "        let refused =",
            new: "        enum DiskutilInvocation { static let executable = \"bin/sh\" }\n        let refused ="),
        Mutation(
            name: "an injected environment", file: spawn, old: "strdup(\"PATH=/usr/bin:/bin:/usr/sbin:/sbin\")",
            new: "strdup(\"DYLD_INSERT_LIBRARIES=tmp/x.dylib\")"),
        Mutation(
            name: "Process.run", file: service, old: work, new: "_ = try? Process.run(URL(fileURLWithPath: \"/usr/sbin/diskutil\"), arguments: [])\n" + work),
        Mutation(name: "execve with a space", file: service, old: work, new: "_ = execve (nil, nil, nil)\n" + work),
        Mutation(name: "execvP", file: service, old: work, new: "_ = execvP(nil, nil, nil)\n" + work),
        Mutation(name: "NSAppleScript", file: service, old: work, new: "_ = NSAppleScript(source: \"do shell script\")\n" + work),
        Mutation(name: "NSClassFromString", file: service, old: work, new: "_ = NSClassFromString(\"NS\" + \"Task\")\n" + work),
        Mutation(
            name: "the reference not destroyed", file: authz, old: "AuthorizationFree(clientRef, [.destroyRights])", new: "AuthorizationFree(clientRef, [])"),
        Mutation(name: "the pinned-mount check removed", file: service, old: "guard reader.isUnchanged(pin) else", new: "guard true else"),
        Mutation(
            name: "the writer check removed", file: authz,
            old: "        guard d[\"identifier\"] as? String == HelperIdentity.bundleIdentifier else { return false }\n", new: ""),
        // Fix round 3 (L1): mut3.py B and O.
        Mutation(
            name: "the command site takes the client's string", file: service, old: "diskutil.run(.enableOwnership(disk: pin.disk))",
            new: "diskutil.run(.enableOwnership(disk: DiskIdentifier(volumeUUID) ?? pin.disk))"),
        Mutation(
            name: "the pin rebound and written to", file: service, old: "        guard reader.isUnchanged(pin) else",
            new: "        var pin = pin; pin.disk = DiskIdentifier(\"disk0s1\")!\n        guard reader.isUnchanged(pin) else"),
        // Fix round 4 (H18 measured): the right's own definition.
        Mutation(name: "a credential that lives 31 s", file: authz, old: "            \"timeout\": 10,", new: "            \"timeout\": 31,"),
        Mutation(name: "a shared credential", file: authz, old: "            \"shared\": false,", new: "            \"shared\": true,"),
        Mutation(name: "a credential root satisfies", file: authz, old: "            \"allow-root\": false,", new: "            \"allow-root\": true,"),
        Mutation(
            name: "the stock admin rule again", file: authz, old: "OwnershipRightRule.definition as CFDictionary",
            new: "\"authenticate-admin\" as CFString"),
        Mutation(name: "a long read-back timeout", file: authz, old: "    static let timeoutSeconds = 10", new: "    static let timeoutSeconds = 300"),
        // Fix round 5 (F4): the read-back check is pinned whole. B4 — an early way to be "ours"; B6 — a safe default
        // changed; and the checks of rounds 4 and 5 weakened one at a time.
        Mutation(
            name: "B4: an early return true", file: authz, old: "        guard Set(d.keys).isSubset(",
            new: "        if d[\"k\"] != nil { return true }\n        guard Set(d.keys).isSubset("),
        Mutation(
            name: "B4: a second way out without the word true", file: authz, old: "        guard Set(d.keys).isSubset(",
            new: "        if d[\"k\"] != nil { return d[\"class\"] != nil }\n        guard Set(d.keys).isSubset("),
        Mutation(name: "B6: session-owner accepted on", file: authz, old: "\"session-owner\": false,", new: "\"session-owner\": true,"),
        Mutation(name: "B6: authenticate-user accepted off", file: authz, old: "[\"authenticate-user\": true,", new: "[\"authenticate-user\": false,"),
        Mutation(name: "a stock rule key allowed", file: authz, old: "\"requirement\", \"tries\"]", new: "\"requirement\", \"tries\", \"rule\"]"),
        Mutation(name: "tries of 0 accepted", file: authz, old: "n.int64Value >= 1", new: "n.int64Value >= 0"),
        Mutation(
            name: "any prompt accepted", file: authz, old: "allSatisfy({ $0 as? String == OwnershipRightRule.prompt })", new: "allSatisfy({ _ in true })"),
        Mutation(
            name: "the team check bypassed", file: authz, old: "namesTeam(requirement, teamID: teamID) else", new: "!requirement.isEmpty else"),
        Mutation(
            name: "the placeholder team accepted", file: authz,
            old: "        guard HelperIdentity.isUsableTeamID(teamID) else { return false }\n", new: ""),
        // Fix round 5 (N1): ensureDefinition keeps a definition only after asking isOurDefinition, and reads back after a write.
        Mutation(
            name: "N1: any existing definition kept", file: authz,
            old: "        if existed, let dict = current as? [String: Any], Self.isOurDefinition(dict, teamID: teamID) { return .unchanged }",
            new: "        if existed { return .unchanged }"),
        Mutation(
            name: "N1: the read-back no longer asks isOurDefinition", file: authz,
            old: "let back = written as? [String: Any],\n            Self.isOurDefinition(back, teamID: teamID)\n",
            new: "let back = written as? [String: Any], !back.isEmpty\n"),
        // Fix round 6 (H18 re-test, TCC): no file access on the volume, in the reader or in the verb; diskutil closed.
        Mutation(name: "an open of the mount point", file: own, old: recheck, new: recheck + "        _ = open(pin.mountPoint, O_RDONLY)\n"),
        Mutation(
            name: "a getattrlist on the mount point", file: own, old: recheck,
            new: recheck + "        var a = attrlist()\n        _ = getattrlist(pin.mountPoint, &a, nil, 0, 0)\n"),
        Mutation(
            name: "the UUID read through HelperService", file: own, old: recheck,
            new: recheck + "        _ = HelperService.volumeUUID(ofMountPoint: pin.mountPoint)\n"),
        Mutation(name: "a statfs of the mount point", file: own, old: recheck, new: recheck + "        _ = statfs(pin.mountPoint, nil)\n"),
        Mutation(
            name: "a marker file looked at", file: own, old: recheck,
            new: recheck + "        _ = FileManager.default.fileExists(atPath: pin.mountPoint + \"/.timemachine\")\n"),
        Mutation(
            name: "file access in the verb", file: service, old: readerLine,
            new: readerLine + "        _ = Self.volumeUUID(ofMountPoint: \"/Volumes\")\n"),
        Mutation(
            name: "a descriptor opened in the verb", file: service, old: readerLine, new: readerLine + "        let fd = open(\"/Volumes\", O_RDONLY); close(fd)\n"),
        Mutation(
            name: "an ownership type extended elsewhere", file: service, old: "final class HelperService: NSObject",
            new: "extension OwnershipVolumeReader { func peek() {} }\nfinal class HelperService: NSObject"),
        Mutation(name: "the list argv takes an argument", file: spawn, old: "return [\"list\", \"-plist\"]", new: "return [\"list\", \"-plist\", \"disk0\"]"),
        Mutation(
            name: "a fourth diskutil invocation", file: spawn, old: "    case listPlist\n", new: "    case listPlist\n    case unmount(disk: DiskIdentifier)\n"),
        // Fix round 2 (N2): the identifier is built only by its validating initialiser.
        Mutation(
            name: "DiskIdentifier.value assigned twice", file: spawn, old: "        value = raw\n", new: "        value = raw\n        value = \"disk0s1\"\n"),
    ]

    private static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func copyTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "xcv-r8-inv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for item in ["Package.swift", "Sources", "scripts", "Resources"] {
            try FileManager.default.copyItem(at: repo.appendingPathComponent(item), to: root.appendingPathComponent(item))
        }
        return root
    }

    private static func runScript(in root: URL) throws -> (status: Int32, output: String) {
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

    /// Nil when the mutation was caught; otherwise why not.
    private static func outcome(_ m: Mutation) -> String? {
        do {
            let root = try copyTree()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent(m.file)
            let s = try String(contentsOf: url, encoding: .utf8)
            guard let range = s.range(of: m.old) else { return "anchor missing in \(m.file): \(m.old)" }
            try s.replacingCharacters(in: range, with: m.new).write(to: url, atomically: true, encoding: .utf8)
            if let extra = m.appendToService {
                let svc = root.appendingPathComponent(service)
                try (String(contentsOf: svc, encoding: .utf8) + extra).write(to: svc, atomically: true, encoding: .utf8)
            }
            let r = try runScript(in: root)
            return r.status == 1 && r.output.contains("VIOLATION") ? nil : "not caught (status \(r.status)):\n\(r.output)"
        } catch {
            return "\(error)"
        }
    }

    func testTheTreeAsItIsPasses() throws {
        let root = try Self.copyTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try Self.runScript(in: root)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("helper invariants: ok"), r.output)
    }

    func testEveryMutationIsCaught() {
        let lock = NSLock()
        nonisolated(unsafe) var misses: [String] = []
        DispatchQueue.concurrentPerform(iterations: Self.mutations.count) { i in
            let m = Self.mutations[i]
            if let why = Self.outcome(m) { lock.withLock { misses.append("\(m.name): \(why)") } }
        }
        XCTAssertGreaterThanOrEqual(Self.mutations.count, 48)
        XCTAssertEqual(misses, [], misses.joined(separator: "\n\n"))
    }
}
