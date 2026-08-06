// TransferGuardTests.swift

import XCTest
@testable import R2FinderServices

final class TransferGuardTests: XCTestCase {

    func testDropOntoItselfIsRejected() {
        XCTAssertEqual(TransferGuard.check(sources: ["/tmp/a/b"], dstDir: "/tmp/a/b",
                                           isMove: true),
                       .destinationIsSource(source: "/tmp/a/b"))
    }

    func testDropIntoOwnChildIsRejected() {
        // The case that empties a folder into a subfolder of itself.
        XCTAssertEqual(TransferGuard.check(sources: ["/tmp/a/b"], dstDir: "/tmp/a/b/c",
                                           isMove: true),
                       .destinationInsideSource(source: "/tmp/a/b"))
        XCTAssertEqual(TransferGuard.check(sources: ["/tmp/a/b"], dstDir: "/tmp/a/b/c/d",
                                           isMove: true),
                       .destinationInsideSource(source: "/tmp/a/b"))
    }

    func testSiblingSharingAPathPrefixIsAllowed() {
        // "/tmp/a/bc" starts with "/tmp/a/b" as a string but is not inside it.
        // A containment check written without the separator rejects this.
        XCTAssertNil(TransferGuard.check(sources: ["/tmp/a/b"], dstDir: "/tmp/a/bc",
                                         isMove: true))
    }

    func testRelativeSegmentsAreNormalisedBeforeComparing() {
        XCTAssertEqual(TransferGuard.check(sources: ["/tmp/a/b"],
                                           dstDir: "/tmp/a/x/../b", isMove: true),
                       .destinationIsSource(source: "/tmp/a/b"))
    }

    func testTrailingSlashOnSourceStillMatches() {
        XCTAssertEqual(TransferGuard.check(sources: ["/tmp/a/b/"], dstDir: "/tmp/a/b/c",
                                           isMove: true),
                       .destinationInsideSource(source: "/tmp/a/b/"))
    }

    func testMoveIntoCurrentParentIsANoOp() {
        XCTAssertEqual(TransferGuard.check(sources: ["/tmp/a/b"], dstDir: "/tmp/a",
                                           isMove: true),
                       .alreadyThere)
    }

    func testCopyIntoCurrentParentIsAllowed() {
        // Copying beside the original is a real operation; only the move is
        // a no-op worth blocking.
        XCTAssertNil(TransferGuard.check(sources: ["/tmp/a/b"], dstDir: "/tmp/a",
                                         isMove: false))
    }

    func testUnrelatedDestinationIsAllowed() {
        XCTAssertNil(TransferGuard.check(sources: ["/tmp/a/b"], dstDir: "/tmp/x",
                                         isMove: true))
    }

    func testOneBadSourceRejectsTheWholeTransfer() {
        XCTAssertEqual(TransferGuard.check(sources: ["/tmp/x", "/tmp/a/b"],
                                           dstDir: "/tmp/a/b/c", isMove: true),
                       .destinationInsideSource(source: "/tmp/a/b"))
    }
}
