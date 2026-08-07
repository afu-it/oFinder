// TransferHandle.swift
// Cancellation handle for a running transfer or archive job.
//
// The caller needs something to cancel the moment it starts a job, but the
// child process is spawned later, on a background thread. So the handle
// exists first and the process is attached when it appears — and a cancel
// that arrives in that gap is remembered, then applied on attach. Without
// that, cancelling early would look like it worked and change nothing.

import Foundation

// @unchecked Sendable: both fields are NSLock-guarded; cancel() is called
// from the main thread while attach() runs on the job's own thread.
public final class TransferHandle: @unchecked Sendable {

    private let lock = NSLock()
    private var child: Subprocess?
    private var cancelled = false

    public init() {}

    /// True once cancel() has been called, whether or not a child was running
    /// at the time. Services read this to report a cancellation rather than a
    /// failure.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Stop the job. Idempotent, and safe before the child exists.
    public func cancel() {
        lock.lock()
        cancelled = true
        let running = child
        lock.unlock()
        running?.cancel()
    }

    /// Hand the newly spawned child to the handle.
    func attach(_ child: Subprocess) {
        lock.lock()
        self.child = child
        let cancelledFirst = cancelled
        lock.unlock()
        if cancelledFirst { child.cancel() }
    }
}
