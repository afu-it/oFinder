// ProgressParserTests.swift
// Fixture-based tests for the rsync/7zz progress parsers — these lines are
// captured from real `rsync --info=progress2` and `7zz -bsp1` output, so the
// parsers can be verified independently of any live transfer.

import XCTest
@testable import R2FinderServices

final class RsyncProgressParserTests: XCTestCase {

    func testIntermediateLineWithoutXfrSuffix() {
        let p = RsyncProgressParser.parse(line: "  104857600  50%  399.88MB/s    0:00:00")
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.progress, 0.5)
        XCTAssertEqual(p?.bytes, 104_857_600)
        XCTAssertEqual(p?.speed ?? 0, 399.88 * 1024 * 1024, accuracy: 1)
    }

    func testLineWithXfrSuffix() {
        let p = RsyncProgressParser.parse(line: "  3,111,124,992  99%  352.23MB/s    0:00:08 (xfr#10, to-chk=10/21)")
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.progress, 0.99)
        XCTAssertEqual(p?.bytes, 3_111_124_992)
        XCTAssertEqual(p?.speed ?? 0, 352.23 * 1024 * 1024, accuracy: 1)
    }

    func testHundredPercent() {
        let p = RsyncProgressParser.parse(line: "  1,234,567 100%    1.10GB/s    0:00:01 (xfr#1, to-chk=0/1)")
        XCTAssertEqual(p?.progress, 1.0)
        XCTAssertEqual(p?.bytes, 1_234_567)
        XCTAssertEqual(p?.speed ?? 0, 1.10 * 1024 * 1024 * 1024, accuracy: 1)
    }

    func testKilobytesPerSecond() {
        let p = RsyncProgressParser.parse(line: "     32,768   3%  128.00kB/s    0:01:40")
        XCTAssertEqual(p?.progress ?? 0, 0.03, accuracy: 0.0001)
        XCTAssertEqual(p?.speed ?? 0, 128 * 1024, accuracy: 0.5)
    }

    func testPlainBytesPerSecond() {
        let p = RsyncProgressParser.parse(line: "  512   1%  100.00B/s    0:00:00")
        XCTAssertEqual(p?.speed ?? 0, 100, accuracy: 0.5)
    }

    func testNonProgressLinesReturnNil() {
        XCTAssertNil(RsyncProgressParser.parse(line: "sending incremental file list"))
        XCTAssertNil(RsyncProgressParser.parse(line: "hello.txt"))
        XCTAssertNil(RsyncProgressParser.parse(line: ""))
        XCTAssertNil(RsyncProgressParser.parse(line: "created directory /tmp/x"))
    }
}

final class SevenZipProgressParserTests: XCTestCase {

    func testBarePercent() {
        XCTAssertEqual(SevenZipProgressParser.parsePercent(line: " 42%"), 42)
        XCTAssertEqual(SevenZipProgressParser.parsePercent(line: "100%"), 100)
    }

    func testPercentWithFileSuffix() {
        XCTAssertEqual(SevenZipProgressParser.parsePercent(line: " 37% 12 + folder/file.dat"), 37)
    }

    func testNonPercentLinesReturnNil() {
        XCTAssertNil(SevenZipProgressParser.parsePercent(line: "7-Zip (z) 24.09 (arm64)"))
        XCTAssertNil(SevenZipProgressParser.parsePercent(line: "Everything is Ok"))
        XCTAssertNil(SevenZipProgressParser.parsePercent(line: "%"))
        XCTAssertNil(SevenZipProgressParser.parsePercent(line: ""))
    }
}
