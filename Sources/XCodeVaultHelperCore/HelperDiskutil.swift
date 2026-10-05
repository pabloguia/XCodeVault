// The privileged helper's ONE process execution (R8, ADR-0014; approved by the maintainer on 2026-10-05).
//
// Everything else in the helper targets is forbidden to start a process, and still is: this file is the single
// exemption in both `scripts/helper-invariants.sh` and the editor hook, and the script holds its shape — the spawn
// function named exactly once in this file's code, on `DiskutilInvocation.executable`; the argv built on one pinned
// line from `arguments`, whose two returns are pinned too; no other absolute path literal but `/usr/sbin/diskutil` and
// `/dev/null`; and none of the routes around those rules (a PATH search, an aliased function, an inherited descriptor,
// a fork, a symbol looked up at run time).
//
// **What can be run is a closed enum, and its only argument is a `UUID`.** Since the R8 fix round (L1) the command takes
// the volume's UUID rather than its device node: a device node is reassigned when a disk is ejected and another
// attached, a UUID is not. `diskutil(8)` (macOS 26.7.1, DEVICES) accepts "a UUID" as the device argument; that it
// resolves a *volume* UUID to its volume was measured read-only on 2026-10-05 (`diskutil info <Data volume UUID>` →
// `disk1s1`). The `UUID` value is the helper's own parse, re-serialized, so no byte of the client's string reaches argv.

import Foundation
import XCodeVaultHelperProtocol

/// A `diskutil` command the helper may run. The executable is fixed; the arguments are built here, never passed in.
enum DiskutilInvocation: Equatable, Sendable {
    /// `diskutil info -plist <UUID>`: the volume's facts, read by the helper itself.
    case infoPlist(volumeUUID: UUID)
    /// `diskutil enableOwnership <UUID>`: the one state change. Turns ownership on; erases nothing.
    case enableOwnership(volumeUUID: UUID)

    static let executable = "/usr/sbin/diskutil"

    /// The argv after the executable: a verb this enum names and a canonical UUID, nothing else.
    var arguments: [String] {
        switch self {
        case .infoPlist(let uuid): return ["info", "-plist", uuid.uuidString]
        case .enableOwnership(let uuid): return ["enableOwnership", uuid.uuidString]
        }
    }
}

/// What a run gave back. `exitStatus` is nil when the process did not exit normally (it could not start, it was
/// killed, or it died on a signal); `failure` says which, in fixed words.
struct DiskutilOutput: Equatable, Sendable {
    var exitStatus: Int32?
    var stdout: Data
    var failure: String?

    var succeeded: Bool { exitStatus == 0 && failure == nil }

    /// The outcome from how the run ended, separate from the spawning so it is tested. `waitStatus` is nil when the child
    /// could not be reaped. Anything but EOF on its output, a normal exit and a reap is a failure: a child that was cut
    /// off cannot have been understood, whatever its exit code.
    static func ended(output: Data, reachedEOF: Bool, timedOut: Bool, waitStatus: Int32?) -> DiskutilOutput {
        if timedOut { return DiskutilOutput(exitStatus: nil, stdout: output, failure: "diskutil timed out") }
        guard let status = waitStatus else { return DiskutilOutput(exitStatus: nil, stdout: output, failure: "diskutil could not be reaped") }
        // `WIFEXITED` / `WEXITSTATUS`, which Swift does not import as macros.
        guard status & 0x7f == 0 else { return DiskutilOutput(exitStatus: nil, stdout: output, failure: "diskutil ended on a signal") }
        guard reachedEOF else { return DiskutilOutput(exitStatus: nil, stdout: output, failure: "diskutil's output was cut off") }
        return DiskutilOutput(exitStatus: (status >> 8) & 0xff, stdout: output, failure: nil)
    }
}

/// The seam the verb runs `diskutil` through. Tests inject a recording fake; production uses `SpawnedDiskutil`.
protocol DiskutilRunning: Sendable {
    func run(_ invocation: DiskutilInvocation) -> DiskutilOutput
}

/// Runs `/usr/sbin/diskutil` with the spawn API: absolute path, fixed argv, an environment of one PATH entry, stdin and
/// stderr on `/dev/null`, every other descriptor closed in the child, an empty signal mask and default dispositions for
/// every signal, stdout read up to a cap, and a deadline after which the child is killed and reaped. Every attribute
/// and file action is checked; any failure refuses to spawn. Never run by a test: it would touch this Mac's disks.
struct SpawnedDiskutil: DiskutilRunning {
    var timeoutSeconds: Int = 120
    /// A plist for one volume is a few kilobytes; anything near this cap is not `diskutil info`.
    var outputCap: Int = 1 << 20

    func run(_ invocation: DiskutilInvocation) -> DiskutilOutput {
        let refused = { (why: String) in DiskutilOutput(exitStatus: nil, stdout: Data(), failure: why) }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return refused("pipe failed") }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(readEnd); close(writeEnd)
            return refused("spawn setup failed")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            close(readEnd); close(writeEnd)
            return refused("spawn setup failed")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var emptyMask = sigset_t()
        var everySignal = sigset_t()
        sigemptyset(&emptyMask)
        sigfillset(&everySignal)
        // Every descriptor the daemon holds — its XPC ports aside, its open files — is closed in the child, except the
        // three the file actions set up; the child starts with no signal blocked and every signal at its default.
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        let setup: [Int32] = [
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writeEnd, 1),
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0),
            posix_spawnattr_setflags(&attributes, flags),
            posix_spawnattr_setsigmask(&attributes, &emptyMask),
            posix_spawnattr_setsigdefault(&attributes, &everySignal),
        ]
        guard setup.allSatisfy({ $0 == 0 }) else {
            close(readEnd); close(writeEnd)
            return refused("spawn setup failed")
        }

        let argv: [UnsafeMutablePointer<CChar>?] = ([DiskutilInvocation.executable] + invocation.arguments).map { strdup($0) } + [nil]
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
            return refused("could not start diskutil (\(rc))")
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var output = Data()
        var reachedEOF = false
        var timedOut = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        readLoop: while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
                break
            }
            var pfd = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 {
                reachedEOF = true
                break
            }
            // Over the cap: stop reading. The child is killed below, and the output refuses.
            guard output.count + n <= outputCap else { break readLoop }
            output.append(contentsOf: buffer[0..<n])
        }
        close(readEnd)
        // Every way out of the loop but EOF leaves a child that must not outlive this call.
        if !reachedEOF { kill(pid, SIGKILL) }

        // Reaped without blocking past the deadline; past it, killed, and then reaped (SIGKILL cannot be ignored).
        var status: Int32 = 0
        var waitStatus: Int32?
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid {
                waitStatus = status
                break
            }
            if r < 0 && errno != EINTR { break }
            if Date() >= deadline {
                timedOut = true
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                break
            }
            usleep(10_000)
        }
        return DiskutilOutput.ended(output: output, reachedEOF: reachedEOF, timedOut: timedOut, waitStatus: waitStatus)
    }
}
