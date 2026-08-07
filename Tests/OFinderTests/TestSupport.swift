// TestSupport.swift
// Shared helpers for the service tests.

import Foundation
import XCTest

/// Repo root, derived from this file's location
/// (Tests/OFinderTests/TestSupport.swift → three levels up).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// Bundled binaries used by the app (and by these tests).
let rsyncPath = repoRoot.appendingPathComponent("bin/rsync").path
let sevenzzPath = repoRoot.appendingPathComponent("bin/7zz").path

/// Create a unique scratch directory for one test; caller removes it.
func makeScratchDir(_ name: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("r2finder-tests-\(name)-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func write(_ content: String, to path: String) throws {
    try content.write(toFile: path, atomically: true, encoding: .utf8)
}

/// Block until an async service completion fires; returns (success, message).
/// @unchecked Sendable: the result fields are lock-guarded, and the semaphore
/// provides the happens-before edge between the service thread and the test.
final class Completion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _success = false
    private var _message: String?

    var success: Bool { lock.withLock { _success } }
    var message: String? { lock.withLock { _message } }

    func handler(_ ok: Bool, _ msg: String?) {
        lock.withLock {
            _success = ok
            _message = msg
        }
        semaphore.signal()
    }

    @discardableResult
    func wait(timeout: TimeInterval = 30) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}
