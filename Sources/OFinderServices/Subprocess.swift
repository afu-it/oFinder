// Subprocess.swift
// Small blocking wrapper around Process shared by TransferService and
// ArchiveService: streams stdout line-by-line (splitting on both \n and \r,
// since rsync and 7zz rewrite their progress line with \r), and drains
// stderr concurrently so the pipe never fills and deadlocks the child.

import Foundation

// @unchecked Sendable: `stderrData` and the launch/cancel flags are
// NSLock-guarded (the readability handler runs on a Dispatch thread, and
// cancel() comes from the main thread); everything else is only touched from
// the single thread that calls run().
final class Subprocess: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let stderrLock = NSLock()
    private var stderrData = Data()
    private static let stderrCap = 8192

    private let stateLock = NSLock()
    private var launched = false
    private var cancelled = false

    /// Grace period before a child that ignored SIGTERM is killed outright.
    private static let killAfter: TimeInterval = 5

    init(executablePath: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    /// Exit code after run() returns; 255 if the child died on a signal or
    /// was cancelled before it ever launched. Reading the termination status
    /// of an unlaunched Process raises, hence the guard.
    var exitCode: Int32 {
        stateLock.lock()
        let didLaunch = launched
        stateLock.unlock()
        guard didLaunch else { return 255 }
        return process.terminationReason == .exit ? process.terminationStatus : 255
    }

    /// Stop the child: SIGTERM first, SIGKILL if it is still alive after the
    /// grace period — rsync blocked on an unresponsive mount never gets to
    /// handle the polite signal. Safe before launch (the launch is refused)
    /// and after exit (nothing to signal).
    func cancel() {
        stateLock.lock()
        cancelled = true
        let didLaunch = launched
        stateLock.unlock()

        guard didLaunch, process.isRunning else { return }
        process.terminate()

        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killAfter) { [weak self] in
            guard let self, self.process.isRunning else { return }
            // Descendants first, and collected before anything dies: rsync
            // forks, the children inherit our stdout pipe, and killing only
            // the parent leaves them holding it open — run() would then never
            // see EOF while the orphans carried on deleting source files.
            for descendant in Self.descendants(of: pid) { kill(descendant, SIGKILL) }
            kill(pid, SIGKILL)
        }
    }

    /// Every process below `pid` in the kernel's process table.
    ///
    /// Foundation's `Process` cannot place a child in its own process group,
    /// so there is no group to signal — the tree has to be walked by hand.
    /// Signalling this app's own group instead would kill oFinder.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride

        // The size query is a snapshot: one process launching before the
        // fetch makes the kernel refuse the buffer as too small. Over-allocate
        // and retry rather than return empty — an empty answer here means the
        // forks survive, which is the case this whole path exists for. The
        // length passed back must describe the buffer we actually allocated,
        // not the kernel's estimate, or it licenses a write past the end.
        for _ in 0..<4 {
            var estimate = 0
            guard sysctl(&name, 4, nil, &estimate, nil, 0) == 0, estimate > 0 else { return [] }

            let capacity = estimate / stride + 16
            var table = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var length = capacity * stride
            guard sysctl(&name, 4, &table, &length, nil, 0) == 0 else { continue }

            return tree(under: pid, in: table.prefix(length / stride))
        }
        return []
    }

    /// Breadth-first walk of the parent links. `seen` starts holding the root
    /// so the caller's own pid can never come back as its own descendant.
    private static func tree(under pid: pid_t, in table: ArraySlice<kinfo_proc>) -> [pid_t] {
        var found: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var frontier = [pid]
        while let parent = frontier.popLast() {
            for proc in table where proc.kp_eproc.e_ppid == parent {
                let child = proc.kp_proc.p_pid
                guard seen.insert(child).inserted else { continue }
                found.append(child)
                frontier.append(child)
            }
        }
        return found
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
    /// nil otherwise — including the cancelled-before-launch case, which is
    /// not a failure to report but an outcome the caller asked for.
    func run(onLine: (String) -> Void) -> String? {
        stateLock.lock()
        let alreadyCancelled = cancelled
        stateLock.unlock()
        if alreadyCancelled { return nil }

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

        // A cancel that landed while the child was being spawned saw
        // launched == false and signalled nothing. Catch it here.
        stateLock.lock()
        launched = true
        let cancelledDuringLaunch = cancelled
        stateLock.unlock()
        if cancelledDuringLaunch, process.isRunning { process.terminate() }

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
