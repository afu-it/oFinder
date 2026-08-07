// PathCrumbsTests.swift

import XCTest
@testable import OFinderServices

final class PathCrumbsTests: XCTestCase {

    private func titles(_ path: String) -> [String] {
        PathCrumbs.split(path: path).map(\.title)
    }

    private func paths(_ path: String) -> [String] {
        PathCrumbs.split(path: path).map(\.path)
    }

    func testRootStandsForItself() {
        XCTAssertEqual(titles("/"), ["/"])
        XCTAssertEqual(paths("/"), ["/"])
    }

    func testBootVolumeContributesNoCrumb() {
        // Its name is the same on every path and only takes up room.
        XCTAssertEqual(titles("/Users/afwazan/Desktop"), ["Users", "afwazan", "Desktop"])
        XCTAssertEqual(paths("/Users/afwazan/Desktop"),
                       ["/Users", "/Users/afwazan", "/Users/afwazan/Desktop"])
    }

    func testTrailingAndRepeatedSeparatorsAreIgnored() {
        XCTAssertEqual(titles("/Users/afwazan/"), ["Users", "afwazan"])
        XCTAssertEqual(titles("//Users//afwazan"), ["Users", "afwazan"])
    }

    func testMountedVolumeKeepsItsName() {
        // Here the volume carries real information, and "Volumes" is not a
        // folder anyone navigates through.
        XCTAssertEqual(titles("/Volumes/Shuffle/Photos"), ["Shuffle", "Photos"])
        XCTAssertEqual(paths("/Volumes/Shuffle/Photos"),
                       ["/Volumes/Shuffle", "/Volumes/Shuffle/Photos"])
    }

    func testVolumesDirectoryItselfIsStillADirectory() {
        // With nothing after it there is no volume to lead with.
        XCTAssertEqual(titles("/Volumes"), ["Volumes"])
        XCTAssertEqual(paths("/Volumes"), ["/Volumes"])
    }

    func testNamesContainingSpaces() {
        XCTAssertEqual(titles("/Users/afwazan/My Files").last, "My Files")
        XCTAssertEqual(paths("/Users/afwazan/My Files").last, "/Users/afwazan/My Files")
    }
}
