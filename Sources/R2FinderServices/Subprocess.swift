// Subprocess.swift
// Small blocking wrapper around Process shared by TransferService and
// ArchiveService: streams stdout line-by-line (splitting on both \n and \r,
// since rsync and 7zz rewrite their progress line with \r), and drains
// stderr concurrently so the pipe never fills and deadlocks the child.

import Foundation

// @unchecked Sendable: `stderrData` is NSLock-guarded (the readability
// handler runs on a Dispatch thread); everything else is only touched from
// the single thread that calls run().
final class Subprocess: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let stderrLock = NSLock()
    private var stderrData = Data()
    private static let stderrCap = 8192

    init(executablePath: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    /// Exit code after run() returns; 255 if the child died on a signal.
    var exitCode: Int32 {
        process.terminationReason == .exit ? process.terminationStatus : 255
    }

    /// Captured stderr (capped at 8 KB), whitespace-trimmed.
    var stderrText: String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return (String(data: stderrData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Launch the child and block until it exits, invoking `onLine` for every
    /// stdout line (\n- or \r-terminated). Returns a message on spawn failure,
    /// nil otherwise.
    func run(onLine: (String) -> Void) -> String? {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.stderrLock.lock()
            if self.stderrData.count < Self.stderrCap {
                self.stderrData.append(data.prefix(Self.stderrCap - self.stderrData.count))
            }
            self.stderrLock.unlock()
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return error.localizedDescription
        }

        // Read stdout on this thread, splitting lines on \n and \r.
        let stdout = stdoutPipe.fileHandleForReading
        var lineBuf = [UInt8]()
        while true {
            let chunk = stdout.availableData
            if chunk.isEmpty { break } // EOF
            for byte in chunk {
                if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    if !lineBuf.isEmpty {
                        if let line = String(bytes: lineBuf, encoding: .utf8) {
                            onLine(line)
                        }
                        lineBuf.removeAll(keepingCapacity: true)
                    }
                } else {
                    lineBuf.append(byte)
                }
            }
        }
        if !lineBuf.isEmpty, let line = String(bytes: lineBuf, encoding: .utf8) {
            onLine(line)
        }

        process.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return nil
    }
}
