// NavigationHistoryTests.swift

import XCTest
@testable import R2FinderServices

final class NavigationHistoryTests: XCTestCase {

    func testStartsWithNowhereToGo() {
        let history = NavigationHistory(startingAt: "/a")
        XCTAssertEqual(history.current, "/a")
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testBackAndForwardWalkTheStack() {
        var history = NavigationHistory(startingAt: "/a")
        history.push("/b")
        history.push("/c")

        XCTAssertEqual(history.goBack(), "/b")
        XCTAssertEqual(history.goBack(), "/a")
        XCTAssertEqual(history.goForward(), "/b")
        XCTAssertEqual(history.goForward(), "/c")
    }

    func testBackStopsAtTheStartWithoutMovingTheIndex() {
        var history = NavigationHistory(startingAt: "/a")
        history.push("/b")
        XCTAssertEqual(history.goBack(), "/a")
        XCTAssertNil(history.goBack())
        // The failed call must not have walked the index past the start.
        XCTAssertEqual(history.current, "/a")
        XCTAssertEqual(history.goForward(), "/b")
    }

    func testPushingFromTheMiddleDropsTheForwardBranch() {
        var history = NavigationHistory(startingAt: "/a")
        history.push("/b")
        history.push("/c")
        _ = history.goBack()          // now at /b, /c is ahead

        history.push("/x")
        XCTAssertEqual(history.current, "/x")
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(), "/b")
        // /c is gone: forward leads to /x, not back to the abandoned branch.
        XCTAssertEqual(history.goForward(), "/x")
    }

    func testPushingTheCurrentPathIsNotANavigation() {
        // A refresh re-pushes the same path. Recording it would fill the stack
        // with duplicates, and Back would appear to do nothing several times.
        var history = NavigationHistory(startingAt: "/a")
        history.push("/a")
        history.push("/a")
        XCTAssertFalse(history.canGoBack)

        history.push("/b")
        history.push("/b")
        XCTAssertEqual(history.goBack(), "/a")
    }

    func testEmptyHistory() {
        var history = NavigationHistory()
        XCTAssertNil(history.current)
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())

        history.push("/only")
        XCTAssertEqual(history.current, "/only")
        XCTAssertFalse(history.canGoBack)
    }
}
