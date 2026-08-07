// TransferHandleTests.swift

import XCTest
@testable import OFinderServices

final class TransferHandleTests: XCTestCase {

    func testAFreshHandleIsNotCancelled() {
        XCTAssertFalse(TransferHandle().isCancelled)
    }

    func testCancellingBeforeTheChildExistsStillCounts() {
        // The window between "job started" and "process spawned". A cancel
        // here used to vanish, leaving rsync running unattended.
        let handle = TransferHandle()
        handle.cancel()
        XCTAssertTrue(handle.isCancelled)
    }

    func testACancelThatArrivedFirstIsAppliedOnAttach() {
        let handle = TransferHandle()
        handle.cancel()

        // /bin/sleep would outlive the test if the pre-attach cancel were
        // dropped; run() returning without launching is the proof it was not.
        let child = Subprocess(executablePath: "/bin/sleep", arguments: ["30"])
        handle.attach(child)

        let started = Date()
        let spawnError = child.run { _ in }

        XCTAssertNil(spawnError, "a cancelled job is an outcome, not a spawn failure")
        XCTAssertEqual(child.exitCode, 255)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancellingARunningChildStopsIt() {
        let handle = TransferHandle()
        let child = Subprocess(executablePath: "/bin/sleep", arguments: ["30"])
        handle.attach(child)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { handle.cancel() }

        let started = Date()
        _ = child.run { _ in }

        XCTAssertTrue(handle.isCancelled)
        XCTAssertEqual(child.exitCode, 255, "killed by a signal, not a clean exit")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAChildThatIgnoresSIGTERMIsKilledAlongWithItsForks() {
        // rsync forks, and the forks inherit the stdout pipe. Killing only
        // the parent leaves them holding it open, so run() never sees EOF —
        // and for a move they carry on deleting source files.
        let marker = "ofinder-cancel-probe-\(ProcessInfo.processInfo.processIdentifier)"
        let handle = TransferHandle()
        let child = Subprocess(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; /bin/sleep 40 & echo \(marker); wait"])
        handle.attach(child)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { handle.cancel() }

        let started = Date()
        var started_ = false
        _ = child.run { if $0.contains(marker) { started_ = true } }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(started_, "the tree really ran before being cancelled")
        XCTAssertGreaterThan(elapsed, 4, "SIGTERM was ignored, so SIGKILL is what ended it")
        XCTAssertLessThan(elapsed, 20, "run() returned once the tree was gone")
        XCTAssertTrue(runningProcesses().filter { $0.contains("/bin/sleep 40") }.isEmpty,
                      "no orphaned fork left behind")
    }

    private func runningProcesses() -> [String] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ao", "command="]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return [] }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        ps.waitUntilExit()
        return text.split(separator: "\n").map(String.init)
    }

    func testCancellingTwiceIsHarmless() {
        let handle = TransferHandle()
        handle.cancel()
        handle.cancel()
        XCTAssertTrue(handle.isCancelled)
    }
}
