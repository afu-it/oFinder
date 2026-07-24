// TransferServiceTests.swift
// Ports of the transfer.zig integration tests, using the bundled bin/rsync.

import XCTest
@testable import R2FinderServices

final class TransferServiceTests: XCTestCase {
    var base = ""
    var srcDir = ""
    var dstDir = ""

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: rsyncPath),
                          "bin/rsync not found — run from a full checkout")
        base = try makeScratchDir("transfer")
        srcDir = base + "/src"
        dstDir = base + "/dst"
        try FileManager.default.createDirectory(atPath: srcDir, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    func testCopyFilesCopiesFileToDestination() throws {
        try write("hello from rs_2finder\n", to: srcDir + "/hello.txt")

        let done = Completion()
        TransferService.copy(rsyncPath: rsyncPath, sources: [srcDir + "/hello.txt"],
                             dstDir: dstDir, overwrite: true,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir + "/hello.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcDir + "/hello.txt"),
                      "copy must keep the original")
    }

    func testCopyRespectsOverwriteFalse() throws {
        try write("original", to: dstDir + "/data.txt")
        try write("new", to: srcDir + "/data.txt")

        let done = Completion()
        // overwrite = false → rsync --ignore-existing
        TransferService.copy(rsyncPath: rsyncPath, sources: [srcDir + "/data.txt"],
                             dstDir: dstDir, overwrite: false,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertEqual(try String(contentsOfFile: dstDir + "/data.txt", encoding: .utf8), "original")
    }

    func testMoveFilesMovesAndRemovesSource() throws {
        try write("move me\n", to: srcDir + "/move_me.txt")

        let done = Completion()
        TransferService.move(rsyncPath: rsyncPath, sources: [srcDir + "/move_me.txt"],
                             dstDir: dstDir, overwrite: true,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir + "/move_me.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcDir + "/move_me.txt"))
    }

    func testFailedTransferReportsError() {
        let done = Completion()
        TransferService.copy(rsyncPath: rsyncPath, sources: [base + "/does_not_exist.txt"],
                             dstDir: dstDir, overwrite: true,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertFalse(done.success)
        XCTAssertNotNil(done.message)
    }
}
