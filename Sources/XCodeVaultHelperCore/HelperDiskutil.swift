// The privileged helper's ONE process execution (R8, ADR-0014; approved by the maintainer on 2026-10-05).
//
// Everything else in the helper targets is forbidden to start a process, and still is: this file is the single
// exemption in both `scripts/helper-invariants.sh` and the editor hook, and the script holds its shape — exactly one
// `posix_spawn` call, never the PATH-searching variant, no shell, and no absolute path literal but `/usr/sbin/diskutil`
// and `/dev/null`.
//
// **What can be run is a closed enum.** `DiskutilInvocation` has two cases and builds its own argv; nothing from the
// client reaches it as text. The UUID is a parsed `UUID`, re-serialized, so its bytes are the helper's. The device node
// is the one the helper read for itself (`OwnershipVolumeReader`), and is validated again here on bytes.

import Foundation
import XCodeVaultHelperProtocol

/// A `diskutil` command the helper may run. The executable is fixed; the arguments are built here, never passed in.
enum DiskutilInvocation: Equatable, Sendable {
    /// `diskutil info -plist <UUID>`: the volume's facts, read by the helper itself.
    case infoPlist(volumeUUID: UUID)
    /// `diskutil enableOwnership <deviceNode>`: the one state change. Turns ownership on; erases nothing.
    case enableOwnership(deviceNode: String)

    static let executable = "/usr/sbin/diskutil"

    /// The argv after the executable, or nil when the argument fails validation — then nothing runs.
    var arguments: [String]? {
        switch self {
        case .infoPlist(let uuid):
            return ["info", "-plist", uuid.uuidString]
        case .enableOwnership(let node):
            return Self.isVolumeDeviceNode(node) ? ["enableOwnership", node] : nil
        }
    }

    /// `/dev/disk<N>s<M>`, ASCII digits only, nothing else: the shape of a volume's device node. Checked on bytes,
    /// for the reason `doCreateVaultDirectory` gives — a grapheme-level check can be fooled by a combining mark, the
    /// kernel cannot. No whole disk (`/dev/disk4`), no snapshot (`/dev/disk3s1s1`), no raw node, no option text.
    static func isVolumeDeviceNode(_ node: String) -> Bool {
        let prefix = Array("/dev/disk".utf8)
        let b = Array(node.utf8)
        guard b.count > prefix.count, b.count <= 32, Array(b.prefix(prefix.count)) == prefix else { return false }
        let rest = b.dropFirst(prefix.count)
        let parts = rest.split(separator: UInt8(ascii: "s"), omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { p in !p.isEmpty && p.count <= 4 && p.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") } }
    }
}

/// What a run gave back. `exitStatus` is nil when the process did not exit normally (it could not start, it was
/// killed on timeout, or it died on a signal); `failure` says which, in fixed words.
struct DiskutilOutput: Equatable, Sendable {
    var exitStatus: Int32?
    var stdout: Data
    var failure: String?

    var succeeded: Bool { exitStatus == 0 }
}

/// The seam the verb runs `diskutil` through. Tests inject a recording fake; production uses `SpawnedDiskutil`.
protocol DiskutilRunning: Sendable {
    func run(_ invocation: DiskutilInvocation) -> DiskutilOutput
}

/// Runs `/usr/sbin/diskutil` with `posix_spawn`: absolute path, fixed argv, an environment of one PATH entry, stdin and
/// stderr on `/dev/null`, every other descriptor closed in the child, stdout read up to a cap, and a deadline after
/// which the child is killed. Never run by a test: it would touch this Mac's disks.
struct SpawnedDiskutil: DiskutilRunning {
    var timeoutSeconds: Int = 120
    /// A plist for one volume is a few kilobytes; anything near this cap is not `diskutil info`.
    var outputCap: Int = 1 << 20

    func run(_ invocation: DiskutilInvocation) -> DiskutilOutput {
        guard let args = invocation.arguments else { return DiskutilOutput(exitStatus: nil, stdout: Data(), failure: "argument rejected") }

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return DiskutilOutput(exitStatus: nil, stdout: Data(), failure: "pipe failed") }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Every descriptor the daemon holds — its XPC ports aside, its open files — is closed in the child, except the
        // three the file actions above set up.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([DiskutilInvocation.executable] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, DiskutilInvocation.executable, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard rc == 0 else {
            close(readEnd)
            return DiskutilOutput(exitStatus: nil, stdout: Data(), failure: "could not start diskutil (\(rc))")
        }

        var output = Data()
        var timedOut = false
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        readLoop: while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; break }
            var pfd = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
            switch n {
            case ..<0 where errno == EINTR: continue
            case ...0: break readLoop
            default:
                // Over the cap: stop reading. Closing the pipe below ends a child still writing (SIGPIPE), and the
                // truncated plist then fails to parse — which refuses, never guesses.
                guard output.count + n <= outputCap else { break readLoop }
                output.append(contentsOf: buffer[0..<n])
            }
        }
        close(readEnd)
        if timedOut { kill(pid, SIGKILL) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if timedOut { return DiskutilOutput(exitStatus: nil, stdout: output, failure: "diskutil timed out") }
        // `WIFEXITED` / `WEXITSTATUS`, which Swift does not import as macros.
        guard status & 0x7f == 0 else { return DiskutilOutput(exitStatus: nil, stdout: output, failure: "diskutil ended on a signal") }
        return DiskutilOutput(exitStatus: (status >> 8) & 0xff, stdout: output, failure: nil)
    }
}
