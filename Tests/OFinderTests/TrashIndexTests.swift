// TrashIndexTests.swift

import XCTest
@testable import OFinderServices

final class TrashIndexTests: XCTestCase {

    // MARK: - Building a .DS_Store record by hand

    private func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private func utf16be(_ text: String) -> [UInt8] {
        Array(text.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
    }

    /// name, key, "ustr", value — the shape the scanner looks for.
    private func record(_ name: String, _ key: String, _ value: String) -> [UInt8] {
        be32(name.utf16.count) + utf16be(name)
            + Array(key.utf8) + Array("ustr".utf8)
            + be32(value.utf16.count) + utf16be(value)
    }

    private func store(_ records: [[UInt8]]) -> Data {
        Data(Array("Bud1".utf8) + [0, 0, 0, 0] + records.flatMap { $0 })
    }

    // MARK: - Tests

    func testStripsTheDataVolumeFirmlink() {
        // ptbL is recorded behind the firmlink that makes the Data volume
        // appear at the root, and without a leading slash.
        let data = store([
            record("notes.txt", "ptbL", "System/Volumes/Data/Users/afwazan/Documents/"),
            record("notes.txt", "ptbN", "notes.txt"),
        ])
        XCTAssertEqual(TrashIndex.origins(dsStore: data)["notes.txt"],
                       "/Users/afwazan/Documents/notes.txt")
    }

    func testRestoresTheOriginalNameNotTheTrashName() {
        // macOS renames on the way in when the Trash already holds that name;
        // ptbN is what it was called before.
        let data = store([
            record("report 2.pdf", "ptbL", "System/Volumes/Data/Users/afwazan/Downloads/"),
            record("report 2.pdf", "ptbN", "report.pdf"),
        ])
        XCTAssertEqual(TrashIndex.origins(dsStore: data)["report 2.pdf"],
                       "/Users/afwazan/Downloads/report.pdf")
    }

    func testPathsOutsideTheDataVolume() {
        let data = store([
            record("logo.png", "ptbL", "Volumes/Shuffle/Art/"),
            record("logo.png", "ptbN", "logo.png"),
        ])
        XCTAssertEqual(TrashIndex.origins(dsStore: data)["logo.png"],
                       "/Volumes/Shuffle/Art/logo.png")
    }

    func testOtherRecordTypesAreSkipped() {
        // A .DS_Store is mostly icon positions and window state; those records
        // must be stepped over without derailing the scan.
        let iloc = be32(4) + utf16be("junk") + Array("Iloc".utf8)
            + Array("blob".utf8) + be32(4) + [1, 2, 3, 4]
        let data = store([
            iloc,
            record("notes.txt", "ptbL", "System/Volumes/Data/Users/afwazan/Documents/"),
            record("notes.txt", "ptbN", "notes.txt"),
        ])
        let origins = TrashIndex.origins(dsStore: data)
        XCTAssertNil(origins["junk"])
        XCTAssertEqual(origins.count, 1)
    }

    func testGarbageProducesNothingRatherThanCrashing() {
        XCTAssertTrue(TrashIndex.origins(dsStore: Data([0xff, 0xff, 0xff, 0xff, 0x01])).isEmpty)
        XCTAssertTrue(TrashIndex.origins(dsStore: Data()).isEmpty)
    }
}
