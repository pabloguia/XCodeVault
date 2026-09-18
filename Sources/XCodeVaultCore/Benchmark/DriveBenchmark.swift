import Foundation

/// E10 drive qualification: 4 KiB random reads/writes at queue depth 1 and small-file metadata
/// latency — the numbers that predict Xcode/DerivedData behaviour (research F9), not sequential MB/s.
/// Writes only inside a temp file it creates in the target directory and removes afterwards.
public struct DriveBenchmark: Sendable {
    public struct Result: Sendable, Codable, Equatable {
        public var directory: String
        public var fileSizeBytes: UInt64
        public var random4KReadIOPS: Double
        public var random4KWriteIOPS: Double
        public var random4KReadLatencyMicros: Double  // median
        public var sequentialWriteMBps: Double
        public var createDeleteFilesPerSecond: Double  // 1 KiB files: create+write+fsync+delete
        public var seconds: Double
        public var verdict: String
    }

    public var fileSizeBytes: UInt64
    public var duration: TimeInterval
    public init(fileSizeBytes: UInt64 = 256 << 20, duration: TimeInterval = 2.0) { self.fileSizeBytes = fileSizeBytes; self.duration = duration }

    public func run(in directory: String) throws -> Result {
        let start = Date()
        let dir = directory
        let path = dir + "/.xcodevault-bench-\(getpid())"
        let fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        guard fd >= 0 else { throw CleanError("cannot create benchmark file in \(dir): \(String(cString: strerror(errno)))") }
        defer { close(fd); unlink(path) }
        // Bypass the unified buffer cache so we measure the device. The result is checked rather
        // than discarded: if F_NOCACHE does not take, every number below is the page cache's
        // throughput rather than the drive's — wrong by orders of magnitude, and wrong in the
        // flattering direction, presented as a measurement. A benchmark that cannot measure must
        // say so, not return a good-looking number.
        guard fcntl(fd, F_NOCACHE, 1) != -1 else {
            throw CleanError(
                "cannot disable the buffer cache for \(dir) (\(String(cString: strerror(errno)))); a benchmark here would measure the cache, not the drive")
        }

        // Sequential write to size the file.
        let chunk = 1 << 20
        var buf = [UInt8](repeating: 0, count: chunk)
        for i in 0..<chunk { buf[i] = UInt8(truncatingIfNeeded: i &* 2654435761) }
        let wStart = Date()
        var written: UInt64 = 0
        while written < fileSizeBytes {
            let n = buf.withUnsafeBytes { pwrite(fd, $0.baseAddress, chunk, off_t(written)) }
            guard n > 0 else { throw CleanError("write failed: \(String(cString: strerror(errno)))") }
            written += UInt64(n)
        }
        fsync(fd)
        let seqMBps = Double(written) / 1_048_576 / max(Date().timeIntervalSince(wStart), 0.001)

        // Random 4K reads, QD1.
        var rng = SystemRandomNumberGenerator()
        let blocks = written / 4096
        var rbuf = [UInt8](repeating: 0, count: 4096)
        var reads = 0
        var latencies: [Double] = []
        let rDeadline = Date().addingTimeInterval(duration)
        while Date() < rDeadline {
            let off = off_t(UInt64.random(in: 0..<blocks, using: &rng) * 4096)
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = rbuf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 4096, off) }
            latencies.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
            reads += 1
        }
        let readIOPS = Double(reads) / duration
        latencies.sort()
        let medianLat = latencies.isEmpty ? 0 : latencies[latencies.count / 2]

        // Random 4K writes, QD1 (each followed by nothing; F_NOCACHE keeps them honest-ish, fsync at end).
        var writes = 0
        let wDeadline = Date().addingTimeInterval(duration)
        while Date() < wDeadline {
            let off = off_t(UInt64.random(in: 0..<blocks, using: &rng) * 4096)
            _ = rbuf.withUnsafeBytes { pwrite(fd, $0.baseAddress, 4096, off) }
            writes += 1
        }
        fsync(fd)
        let writeIOPS = Double(writes) / duration

        // Metadata: create + write 1 KiB + fsync + unlink small files (what a build does thousands of times).
        let mdDir = dir + "/.xcodevault-bench-md-\(getpid())"
        try FileManager.default.createDirectory(atPath: mdDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: mdDir) }
        var files = 0
        let small = [UInt8](repeating: 0x41, count: 1024)
        let mDeadline = Date().addingTimeInterval(duration)
        while Date() < mDeadline {
            let p = mdDir + "/f\(files)"
            let f = open(p, O_CREAT | O_WRONLY, 0o600)
            guard f >= 0 else { break }
            _ = small.withUnsafeBytes { write(f, $0.baseAddress, 1024) }
            fsync(f); close(f); unlink(p)
            files += 1
        }
        let mdRate = Double(files) / duration

        let verdict: String
        switch (readIOPS, mdRate) {
        case (20_000..., 2_000...): verdict = "internal-class (heuristic thresholds, E10 pending): fine for DerivedData, simulators, everything"
        case (5_000..., 500...): verdict = "fast (heuristic thresholds, E10 pending): usable for DerivedData; expect slower incremental builds than internal"
        case (1_000..., 100...):
            verdict = "moderate (heuristic thresholds, E10 pending): fine for Archives, Runtime Library and cold storage; DerivedData will feel slow"
        default: verdict = "slow (heuristic thresholds, E10 pending): use only for cold storage and installers"
        }
        return Result(
            directory: dir, fileSizeBytes: written, random4KReadIOPS: readIOPS, random4KWriteIOPS: writeIOPS,
            random4KReadLatencyMicros: medianLat, sequentialWriteMBps: seqMBps, createDeleteFilesPerSecond: mdRate,
            seconds: Date().timeIntervalSince(start), verdict: verdict)
    }
}
