import Foundation
import Compression

/// One deadlock-free way to run a short-lived helper process.
///
/// Every ad-hoc `Process` call site in this app used to read one pipe to
/// EOF before the other (or write all of stdin before reading stdout).
/// Once a pipe's 64 KB kernel buffer fills, both sides block forever —
/// which is exactly what froze the UI on large rotated logs. Here stdin
/// is fed, and stdout/stderr are drained, concurrently on background
/// queues, and the wait is bounded.
///
/// Synchronous by design (callers are already off the main actor or wrap
/// it in `Task.detached`); use `runAsync` from main-actor code.
nonisolated enum Subprocess {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let cwd { proc.currentDirectoryURL = cwd }
        if let environment { proc.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        proc.standardInput = inPipe ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        try proc.run()

        let group = DispatchGroup()
        let box = Box()
        let q = DispatchQueue.global(qos: .utility)
        q.async(group: group) { box.out = outPipe.fileHandleForReading.readDataToEndOfFile() }
        q.async(group: group) { box.err = errPipe.fileHandleForReading.readDataToEndOfFile() }
        if let inPipe, let stdin {
            q.async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if let timeout, exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            proc.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                exited.wait()
            }
        } else if timeout == nil {
            exited.wait()
        }
        // Grandchildren may hold the pipes open; don't wait on them forever.
        _ = group.wait(timeout: .now() + 5)
        return Result(status: proc.terminationStatus, stdout: box.out, stderr: box.err, timedOut: timedOut)
    }

    /// `run` on a background thread, for callers on the main actor.
    static func runAsync(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Result {
        try await Task.detached(priority: .utility) {
            try run(executable, arguments, cwd: cwd, stdin: stdin, environment: environment, timeout: timeout)
        }.value
    }

    private final class Box: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}

/// Native gzip decoding (RFC 1952 wrapper around raw DEFLATE), replacing
/// `/usr/bin/gunzip` subprocesses. Single-member only — which is what
/// Minecraft's log rotation writes. (Apple's decoder consumes input past the
/// end of the DEFLATE stream, so member boundaries can't be located.) The
/// trailer's ISIZE is checked against the output as an integrity guard.
nonisolated enum Gzip {
    static func decompress(_ data: Data) -> Data? {
        let d = [UInt8](data)
        guard d.count >= 18, d[0] == 0x1f, d[1] == 0x8b, d[2] == 8 else { return nil }
        let flags = d[3]
        var i = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard d.count >= i + 2 else { return nil }
            i += 2 + (Int(d[i]) | Int(d[i + 1]) << 8)
        }
        if flags & 0x08 != 0 { i = (d[i...].firstIndex(of: 0) ?? d.count) + 1 } // FNAME
        if flags & 0x10 != 0 { i = (d[i...].firstIndex(of: 0) ?? d.count) + 1 } // FCOMMENT
        if flags & 0x02 != 0 { i += 2 } // FHCRC
        guard i < d.count - 8, let (out, _) = inflate(data[(data.startIndex + i)...]) else { return nil }
        let n = d.count
        let isize = UInt32(d[n - 4]) | UInt32(d[n - 3]) << 8 | UInt32(d[n - 2]) << 16 | UInt32(d[n - 1]) << 24
        guard isize == UInt32(truncatingIfNeeded: out.count) else { return nil }
        return out
    }

    /// Raw DEFLATE via the Compression framework's streaming API, returning
    /// the output and the number of input bytes consumed.
    private static func inflate(_ input: Data.SubSequence) -> (Data, Int)? {
        let src = Data(input)
        let dstCap = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        var out = Data()
        return src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Data, Int)? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = dstCap
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: dstCap - stream.dst_size)
                switch status {
                case COMPRESSION_STATUS_END: return (out, src.count - stream.src_size)
                case COMPRESSION_STATUS_OK: continue
                default: return nil
                }
            }
        }
    }
}
