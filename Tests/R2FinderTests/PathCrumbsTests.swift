// PathCrumbsTests.swift

import XCTest
@testable import R2FinderServices

final class PathCrumbsTests: XCTestCase {

    private func titles(_ path: String) -> [String] {
        PathCrumbs.split(path: path, rootVolumeName: "Macintosh HD").map(\.title)
    }

    private func paths(_ path: String) -> [String] {
        PathCrumbs.split(path: path, rootVolumeName: "Macintosh HD").map(\.path)
    }

    func testRootIsTheVolumeName() {
        XCTAssertEqual(titles("/"), ["Macintosh HD"])
        XCTAssertEqual(paths("/"), ["/"])
    }

    func testOrdinaryPath() {
        XCTAssertEqual(titles("/Users/afwazan/Desktop"),
                       ["Macintosh HD", "Users", "afwazan", "Desktop"])
        XCTAssertEqual(paths("/Users/afwazan/Desktop"),
                       ["/", "/Users", "/Users/afwazan", "/Users/afwazan/Desktop"])
    }

    func testTrailingAndRepeatedSeparatorsAreIgnored() {
        XCTAssertEqual(titles("/Users/afwazan/"), ["Macintosh HD", "Users", "afwazan"])
        XCTAssertEqual(titles("//Users//afwazan"), ["Macintosh HD", "Users", "afwazan"])
    }

    func testMountedVolumeLeadsWithTheVolume() {
        // "Volumes" is not a place anyone navigates through, so it does not
        // appear as a crumb of its own.
        XCTAssertEqual(titles("/Volumes/Shuffle/Photos"), ["Shuffle", "Photos"])
        XCTAssertEqual(paths("/Volumes/Shuffle/Photos"),
                       ["/Volumes/Shuffle", "/Volumes/Shuffle/Photos"])
    }

    func testVolumesDirectoryItselfIsStillADirectory() {
        // With nothing after it there is no volume to lead with, so it is just
        // a folder on the boot disk.
        XCTAssertEqual(titles("/Volumes"), ["Macintosh HD", "Volumes"])
    }

    func testNamesContainingSpaces() {
        XCTAssertEqual(titles("/Users/afwazan/My Files").last, "My Files")
        XCTAssertEqual(paths("/Users/afwazan/My Files").last, "/Users/afwazan/My Files")
    }
}
