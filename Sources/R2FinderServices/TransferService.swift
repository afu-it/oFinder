// TransferService.swift
// Async file copy/move via rsync — port of transfer.zig.
//
// Threading model (unchanged from the Zig implementation):
//   • Each transfer runs on its own detached background thread.
//   • Callbacks are invoked on that thread; the UI layer must dispatch to
//     the main queue before touching UI.
//
// The rsync invocation is byte-identical to the old one:
//   rsync -a --info=progress2 --no-inc-recursive
//         [--ignore-existing] [--remove-source-files] <sources> <dst>/

import Foundation

public enum TransferService {
    // Handlers are invoked on background threads — callers that touch UI must
    // hop to the main actor themselves.
    public typealias ProgressHandler = @Sendable (_ progress: Double, _ bytes: UInt64,
                                                  _ total: UInt64, _ speed: Double,
                                                  _ etaSecs: Int64) -> Void
    public typealias CompletionHandler = @Sendable (_ success: Bool, _ errorMessage: String?) -> Void

    public static func copy(rsyncPath: String, sources: [String], dstDir: String,
                            overwrite: Bool,
                            onProgress: @escaping ProgressHandler,
                            onDone: @escaping CompletionHandler) {
        start(rsyncPath: rsyncPath, sources: sources, dstDir: dstDir,
              overwrite: overwrite, isMove: false, onProgress: onProgress, onDone: onDone)
    }

    public static func move(rsyncPath: String, sources: [String], dstDir: String,
                            overwrite: Bool,
                            onProgress: @escaping ProgressHandler,
                            onDone: @escaping CompletionHandler) {
        start(rsyncPath: rsyncPath, sources: sources, dstDir: dstDir,
              overwrite: overwrite, isMove: true, onProgress: onProgress, onDone: onDone)
    }

    private static func start(rsyncPath: String, sources: [String], dstDir: String,
                              overwrite: Bool, isMove: Bool,
                              onProgress: @escaping ProgressHandler,
                              onDone: @escaping CompletionHandler) {
        Thread.detachNewThread {
            run(rsyncPath: rsyncPath, sources: sources, dstDir: dstDir,
                overwrite: overwrite, isMove: isMove,
                onProgress: onProgress, onDone: onDone)
        }
    }

    private static func run(rsyncPath: String, sources: [String], dstDir: String,
                            overwrite: Bool, isMove: Bool,
                            onProgress: @escaping ProgressHandler,
                            onDone: CompletionHandler) {
        // Destination needs a trailing slash: rsync copies sources *into* the dir.
        let dst = dstDir.hasSuffix("/") ? dstDir : dstDir + "/"

        var args = ["-a", "--info=progress2", "--no-inc-recursive"]
        if !overwrite { args.append("--ignore-existing") }
        if isMove { args.append("--remove-source-files") } // atomic move
        args.append(contentsOf: sources)
        args.append(dst)

        let child = Subprocess(executablePath: rsyncPath, arguments: args)

        // After the data transfer hits 100%, rsync keeps running while the OS
        // flushes writes to disk. 500 ms after the final 100% line we send
        // progress > 1.0 so the UI can show "Sincronizando…" with an
        // indeterminate bar. The group guarantees the signal fires before
        // completion is reported (matching the old thread-join ordering).
        var sentComplete = false
        var syncSignal: DispatchGroup?

        let spawnError = child.run { line in
            guard let info = RsyncProgressParser.parse(line: line), !sentComplete else { return }
            if info.progress >= 1.0 {
                sentComplete = true
                // rsync's --info=progress2 doesn't emit a stable total byte
                // count per line, so pass 0 and let the UI display bytes+speed.
                onProgress(info.progress, info.bytes, 0, info.speed, 0)
                let group = DispatchGroup()
                group.enter()
                syncSignal = group
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    onProgress(1.5, 0, 0, 0, 0)
                    group.leave()
                }
            } else {
                // ETA from speed and remaining share of the (estimated) total.
                var eta: Int64 = 0
                if info.speed > 0, info.progress > 0, info.progress < 1.0 {
                    let totalEst = Double(info.bytes) / info.progress
                    eta = Int64((totalEst - Double(info.bytes)) / info.speed)
                }
                onProgress(info.progress, info.bytes, 0, info.speed, eta)
            }
        }

        if let spawnError {
            onDone(false, "Error: \(spawnError)")
            return
        }

        // Wait for the sync-phase signal before reporting completion.
        syncSignal?.wait()

        guard child.exitCode == 0 else {
            let se = child.stderrText
            onDone(false, se.isEmpty
                ? L10n.f("service.rsyncExit", "rsync exited with code %d", child.exitCode)
                : "rsync: \(se)")
            return
        }

        // For a move, --remove-source-files only removes files (not empty
        // dirs). Clean up leftover empty directories (rm -rf semantics:
        // errors ignored).
        if isMove {
            for src in sources {
                try? FileManager.default.removeItem(atPath: src)
            }
        }

        onDone(true, nil)
    }
}
