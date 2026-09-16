import XCTest

@testable import kbbs

/// Opening a room with no window ends in a double-click at screen coordinates, because
/// KakaoTalk's chat rows ignore both AXPress and Return. That is the only hardware event
/// kbbs ever posts, and it lands wherever the coordinates say — so the coordinates are
/// checked before anything is posted, not after.
final class RowClickGuardTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testARowOnScreenGivesItsCentre() {
        let row = CGRect(x: 100, y: 200, width: 300, height: 60)
        XCTAssertEqual(RowClickGuard.clickPoint(rowFrame: row, visibleScreens: [screen]), CGPoint(x: 250, y: 230))
    }

    // MARK: - Inside the list window, not merely on the display

    /// A scrollable list gives frames to rows that have scrolled out of sight: they are
    /// real coordinates, on a real display, below the bottom edge of the window. Clicking
    /// one lands on the desktop, or on whatever app is behind it.
    func testARowBelowTheWindowIsRefused() {
        let list = CGRect(x: 2115, y: 667, width: 400, height: 640)
        let scrolledOff = CGRect(x: 2193, y: 1280, width: 305, height: 74)
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: scrolledOff, visibleScreens: [CGRect(x: 0, y: 0, width: 2560, height: 1440)], within: list))
    }

    func testARowInsideTheWindowIsAccepted() {
        let list = CGRect(x: 2115, y: 667, width: 400, height: 640)
        let visible = CGRect(x: 2193, y: 1058, width: 305, height: 74)
        XCTAssertEqual(
            RowClickGuard.clickPoint(rowFrame: visible, visibleScreens: [CGRect(x: 0, y: 0, width: 2560, height: 1440)], within: list),
            CGPoint(x: 2345.5, y: 1095)
        )
    }

    func testARowStraddlingTheBottomEdgeIsRefused() {
        let list = CGRect(x: 0, y: 0, width: 400, height: 640)
        let half = CGRect(x: 10, y: 610, width: 300, height: 74)
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: half, visibleScreens: [screen], within: list))
    }

    func testWithNoWindowFrameTheScreenCheckStillApplies() {
        let row = CGRect(x: 100, y: 200, width: 300, height: 60)
        XCTAssertNotNil(RowClickGuard.clickPoint(rowFrame: row, visibleScreens: [screen], within: nil))
    }

    /// A row the scanner never got a frame for. Clicking the origin would land on
    /// whatever is at the top-left of the main display.
    func testNoFrameMeansNoClick() {
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: nil, visibleScreens: [screen]))
    }

    /// KakaoTalk reports a zero-sized frame for rows it has scrolled out of view. Its
    /// centre is a real coordinate and would be clicked happily.
    func testAZeroSizedRowIsRefused() {
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: .zero, visibleScreens: [screen]))
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: CGRect(x: 40, y: 40, width: 0, height: 20), visibleScreens: [screen]))
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: CGRect(x: 40, y: 40, width: 300, height: 0), visibleScreens: [screen]))
    }

    func testARowSmallerThanACursorIsRefused() {
        let sliver = CGRect(x: 100, y: 100, width: 300, height: 1)
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: sliver, visibleScreens: [screen]))
    }

    /// A window dragged mostly off the desktop, or one on a display that has been
    /// unplugged since the scan.
    func testARowOffEveryScreenIsRefused() {
        let offscreen = CGRect(x: 4000, y: 3000, width: 300, height: 60)
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: offscreen, visibleScreens: [screen]))
    }

    func testNegativeCoordinatesOffScreenAreRefused() {
        let above = CGRect(x: 100, y: -400, width: 300, height: 60)
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: above, visibleScreens: [screen]))
    }

    /// A second display sitting to the left of the main one has negative x, which is
    /// perfectly legal and must not be mistaken for off-screen.
    func testARowOnASecondDisplayIsFine() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let row = CGRect(x: -1800, y: 300, width: 300, height: 60)
        XCTAssertEqual(RowClickGuard.clickPoint(rowFrame: row, visibleScreens: [screen, left]), CGPoint(x: -1650, y: 330))
    }

    /// Half on, half off: the centre decides, because the centre is what gets clicked.
    func testARowWhoseCentreIsOffScreenIsRefused() {
        let straddling = CGRect(x: 1400, y: 300, width: 400, height: 60)
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: straddling, visibleScreens: [screen]))
    }

    func testWithNoScreensAtAllNothingIsClickable() {
        let row = CGRect(x: 100, y: 200, width: 300, height: 60)
        XCTAssertNil(RowClickGuard.clickPoint(rowFrame: row, visibleScreens: []))
    }
}
