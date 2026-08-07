// ArchiveServiceTests.swift
// Port of the archive.zig round-trip test, using the bundled bin/7zz.

import XCTest
@testable import OFinderServices

final class ArchiveServiceTests: XCTestCase {
    var base = ""

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sevenzzPath),
                          "bin/7zz not found — run from a full checkout")
        base = try makeScratchDir("archive")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    func testCompressAndUncompressRoundTrip() throws {
        let srcFile = base + "/hello.txt"
        let archive = base + "/hello.7z"
        try write("hello 7z world\n", to: srcFile)

        // 1) Compress
        let compressed = Completion()
        ArchiveService.compress(sevenzzPath: sevenzzPath, sources: [srcFile],
                                archivePath: archive,
                                onProgress: { _, _, _, _, _ in },
                                onDone: compressed.handler)
        XCTAssertTrue(compressed.wait())
        XCTAssertTrue(compressed.success, compressed.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive))

        // 2) Delete the original so uncompress must recreate it
        try FileManager.default.removeItem(atPath: srcFile)

        // 3) Uncompress
        let uncompressed = Completion()
        ArchiveService.uncompress(sevenzzPath: sevenzzPath, archivePath: archive,
                                  dstDir: base,
                                  onProgress: { _, _, _, _, _ in },
                                  onDone: uncompressed.handler)
        XCTAssertTrue(uncompressed.wait())
        XCTAssertTrue(uncompressed.success, uncompressed.message ?? "")

        XCTAssertEqual(try String(contentsOfFile: srcFile, encoding: .utf8), "hello 7z world\n")
    }

    func testCompressSplitProducesVolumes() throws {
        // ~3 MB of incompressible-ish data, split into 1 MB volumes with -mx0
        let srcFile = base + "/big.bin"
        var data = Data(count: 3 * 1024 * 1024)
        data.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8((i &* 2654435761) & 0xFF) }
        }
        try data.write(to: URL(fileURLWithPath: srcFile))
        let archive = base + "/big.7z"

        let done = Completion()
        ArchiveService.compress(sevenzzPath: sevenzzPath, sources: [srcFile],
                                archivePath: archive,
                                volumeSizeMB: 1, storeOnly: true,
                                onProgress: { _, _, _, _, _ in },
                                onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive + ".001"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive + ".002"))
    }

    // Broadened-format support (the context menu now offers "Descomprimir"
    // for everything 7zz can extract): a .tgz made by system tar extracts one
    // layer per pass — the first pass yields the inner .tar.
    func testUncompressTgzYieldsInnerTar() throws {
        let srcFile = base + "/hello.txt"
        try write("hello tgz\n", to: srcFile)

        let tgz = base + "/bundle.tgz"
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tgz, "-C", base, "hello.txt"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let outDir = base + "/out"
        let done = Completion()
        ArchiveService.uncompress(sevenzzPath: sevenzzPath, archivePath: tgz,
                                  dstDir: outDir,
                                  onProgress: { _, _, _, _, _ in },
                                  onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        // gzip layer removed → inner tar ("bundle" per 7zz naming)
        let contents = try FileManager.default.contentsOfDirectory(atPath: outDir)
        XCTAssertEqual(contents.count, 1)
        XCTAssertTrue(contents[0] == "bundle" || contents[0].hasSuffix(".tar"),
                      "unexpected extraction result: \(contents)")
    }

    func testFailedUncompressReportsError() {
        let done = Completion()
        ArchiveService.uncompress(sevenzzPath: sevenzzPath,
                                  archivePath: base + "/not_an_archive.7z",
                                  dstDir: base,
                                  onProgress: { _, _, _, _, _ in },
                                  onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertFalse(done.success)
        XCTAssertNotNil(done.message)
    }
}
