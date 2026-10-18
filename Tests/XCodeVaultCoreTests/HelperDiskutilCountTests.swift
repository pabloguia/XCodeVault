import Foundation
import XCTest
import XCodeVaultHelperProtocol

@testable import XCodeVaultHelperCore

/// How many times `enableOwnership` runs `diskutil` on its success path, counted through the real `OwnershipVolumeReader`
/// and `HelperService.doEnableOwnership` over a scripted `diskutil` and mount table. The client's verb deadline is held
/// above that count times the daemon's per-run kill (`HelperClientTimeoutTests`), so a new run in the verb moves the bound
/// with it instead of slipping under a hand-counted ten (helper-security review of A2, L-b).
final class HelperDiskutilCountTests: XCTestCase {
    /// `diskutil` and the mount table of one external APFS volume whose ownership `enableOwnership` turns on: after the
    /// command, `info` reports it on and the mount no longer ignores it, as a real volume does.
    final class Scripted: DiskutilRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = false
        private var runs: [DiskutilInvocation] = []
        var invocations: [DiskutilInvocation] { lock.withLock { runs } }
        var mounts: [MountEntry] {
            let on = lock.withLock { enabled }
            let flags = on ? R8HelperOwnershipTests.apfsLocal & ~UInt32(MNT_IGNORE_OWNERSHIP) : R8HelperOwnershipTests.apfsLocal
            return [
                R8HelperOwnershipTests.entry("/", from: "/dev/disk3s1s1"),
                R8HelperOwnershipTests.entry("/System/Volumes/Data", from: "/dev/disk3s5", fsid: [1, 1]),
                R8HelperOwnershipTests.entry(flags: flags),
            ]
        }

        func run(_ invocation: DiskutilInvocation) -> DiskutilOutput {
            lock.withLock {
                runs.append(invocation)
                switch invocation {
                case .infoPlist:
                    let on = enabled
                    return DiskutilOutput(exitStatus: 0, stdout: R8HelperOwnershipTests.infoPlist { $0["GlobalPermissionsEnabled"] = on }, failure: nil)
                case .listPlist:
                    return DiskutilOutput(exitStatus: 0, stdout: R8HelperOwnershipTests.listPlist([R8HelperOwnershipTests.uuid]), failure: nil)
                case .apfsListPlist:
                    return DiskutilOutput(exitStatus: 0, stdout: R8HelperOwnershipTests.apfsList(["disk5s1": []]), failure: nil)
                case .enableOwnership:
                    enabled = true
                    return DiskutilOutput(exitStatus: 0, stdout: Data(), failure: nil)
                }
            }
        }
    }

    /// The runs of one successful `enableOwnership`, through the code that ships.
    static func enableOwnershipRuns() -> (result: HelperResult, runs: [DiskutilInvocation]) {
        let runner = Scripted()
        let reader = OwnershipVolumeReader(runner: runner, readMounts: { runner.mounts })
        let result = HelperService(callerUID: getuid(), callerGID: getgid()).doEnableOwnership(
            volumeUUID: R8HelperOwnershipTests.uuid, authorization: R8HelperOwnershipTests.form, rights: R8HelperOwnershipTests.FakeRights(),
            volumes: reader, diskutil: runner)
        return (result, runner.invocations)
    }

    func testTheSuccessPathIsWhatIsCounted() {
        let (result, runs) = Self.enableOwnershipRuns()
        XCTAssertEqual(result.code, .enabled, result.message)
        XCTAssertEqual(runs.filter { if case .enableOwnership = $0 { true } else { false } }.count, 1, "the command runs once")
        XCTAssertGreaterThan(runs.count, 1, "and is surrounded by the reads that pin and verify it: \(runs)")
    }
}
