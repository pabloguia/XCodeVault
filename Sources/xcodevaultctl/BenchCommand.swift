import ArgumentParser
import Foundation
import XCodeVaultCore

struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Qualify a drive for developer workloads: 4 KiB random IOPS at QD1 and small-file metadata rate (E10), not sequential MB/s.",
                                                    discussion: "Creates and removes a temporary file (default 256 MB) in the directory. Run on the internal disk and on the candidate volume and compare.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Directory on the volume to test (must be writable).") var directory: String
    @Option(name: .long, help: "Test file size in MB.") var sizeMB: UInt64 = 256
    @Option(name: .long, help: "Seconds per phase.") var seconds: Double = 2
    func run() throws {
        let r = try DriveBenchmark(fileSizeBytes: sizeMB << 20, duration: seconds).run(in: directory)
        try emit(r, json: global.json) {
            String(format: "%@\n  4K random read:  %8.0f IOPS (median %.0f µs)\n  4K random write: %8.0f IOPS\n  sequential write: %7.0f MB/s\n  1 KiB create+fsync+delete: %.0f files/s\n  verdict: %@\n",
                   r.directory, r.random4KReadIOPS, r.random4KReadLatencyMicros, r.random4KWriteIOPS, r.sequentialWriteMBps, r.createDeleteFilesPerSecond, r.verdict)
        }
    }
}
