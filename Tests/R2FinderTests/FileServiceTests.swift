// FileServiceTests.swift
// Ports of the file_ops.zig and zig_check_collision unit tests.

import XCTest
@testable import R2FinderServices

final class FileServiceTests: XCTestCase {
    var base = ""

    override func setUpWithError() throws {
        base = try makeScratchDir("fileservice")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    func testCreateDirectoryCreatesNewDirectory() {
        let path = base + "/mkdir_test"
        XCTAssertNil(FileService.createDirectory(path: path))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testCreateDirectoryFailsOnExistingPath() {
        let path = base + "/mkdir_dup"
        XCTAssertNil(FileService.createDirectory(path: path))
        XCTAssertNotNil(FileService.createDirectory(path: path))
    }

    func testRenameRenamesFile() throws {
        let src = base + "/rename_src.txt"
        let dst = base + "/rename_dst.txt"
        try write("x", to: src)

        XCTAssertNil(FileService.rename(src: src, dst: dst))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src))
    }

    func testDeleteFilesRemovesFile() throws {
        let path = base + "/del_me.txt"
        try write("x", to: path)

        XCTAssertNil(FileService.deleteFiles(paths: [path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testDeleteFilesIgnoresMissingPaths() {
        // rm -rf semantics: deleting something already gone is not an error
        XCTAssertNil(FileService.deleteFiles(paths: [base + "/never_existed"]))
    }

    func testDeleteFilesRemovesDirectoryRecursively() throws {
        let dir = base + "/del_dir"
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try write("x", to: dir + "/sub/file.txt")

        XCTAssertNil(FileService.deleteFiles(paths: [dir]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    func testCheckCollisionDetectsNameClash() throws {
        let srcDir = base + "/coll_src"
        let dstDir = base + "/coll_dst"
        try FileManager.default.createDirectory(atPath: srcDir, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: false)
        try write("a", to: srcDir + "/dup.txt")
        try write("b", to: dstDir + "/dup.txt")

        XCTAssertTrue(FileService.checkCollision(sources: [srcDir + "/dup.txt"], dstDir: dstDir))
        XCTAssertFalse(FileService.checkCollision(sources: [srcDir + "/other.txt"], dstDir: dstDir))
    }
}
