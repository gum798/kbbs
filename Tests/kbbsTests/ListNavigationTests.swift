import XCTest

@testable import kbbs

/// Moving around the board index. Pure model work — no terminal, no KakaoTalk.
///
/// 60 rooms at 13 a page is five pages with a partial last one of eight, which is the
/// shape that catches off-by-ones: the cursor must not be able to sit on an empty slot.
final class ListNavigationTests: XCTestCase {

    private func state(_ count: Int = 60) -> ListState {
        var s = ListState()
        s.rooms = (1...count).map { Room(title: "방\($0)") }
        return s
    }

    // MARK: - The cursor

    func testDownMovesOneRow() {
        var s = state()
        s.moveDown()
        XCTAssertEqual(s.cursor, 1)
        XCTAssertEqual(s.page, 0)
    }

    func testDownAtTheBottomOfAPageTurnsToTheNextAndLandsOnTheFirstRow() {
        var s = state()
        s.cursor = ListState.rowsPerPage - 1
        s.moveDown()
        XCTAssertEqual(s.page, 1)
        XCTAssertEqual(s.cursor, 0)
    }

    func testUpAtTheTopOfAPageTurnsBackAndLandsOnTheLastRow() {
        var s = state()
        s.page = 1
        s.cursor = 0
        s.moveUp()
        XCTAssertEqual(s.page, 0)
        XCTAssertEqual(s.cursor, ListState.rowsPerPage - 1)
    }

    func testDownPastTheLastRoomWrapsToTheFirst() {
        var s = state()
        s.page = 4
        s.cursor = 7                       // room 60, the last one on a partial page
        s.moveDown()
        XCTAssertEqual(s.page, 0)
        XCTAssertEqual(s.cursor, 0)
    }

    func testUpFromTheFirstRoomWrapsToTheLast() {
        var s = state()
        s.moveUp()
        XCTAssertEqual(s.page, 4)
        XCTAssertEqual(s.cursor, 7)
        XCTAssertEqual(s.selectedRoomIndex, 59)
    }

    /// The last page holds eight of thirteen slots. Down from the last real room wraps
    /// rather than walking into the blanks.
    func testTheCursorCannotSitOnAnEmptySlotOfAPartialPage() {
        var s = state()
        s.page = 4
        for _ in 0..<20 {
            s.moveDown()
            XCTAssertNotNil(s.selectedRoomIndex, "cursor left the rooms behind")
            XCTAssertLessThan(s.selectedRoomIndex!, 60)
        }
    }

    // MARK: - Paging

    func testNextPage() {
        var s = state()
        s.pageForward()
        XCTAssertEqual(s.page, 1)
        XCTAssertEqual(s.cursor, 0)
    }

    func testPagingWrapsAtBothEnds() {
        var s = state()
        s.page = 4
        s.pageForward()
        XCTAssertEqual(s.page, 0)
        s.pageBack()
        XCTAssertEqual(s.page, 4)
    }

    func testPagingClearsTheNumberBuffer() {
        var s = state()
        s.appendDigit("2")
        s.pageForward()
        XCTAssertEqual(s.numberBuffer, "")
    }

    // MARK: - The 선택> buffer

    func testDigitsAccumulate() {
        var s = state()
        s.appendDigit("1")
        s.appendDigit("2")
        XCTAssertEqual(s.numberBuffer, "12")
    }

    func testTheBufferStopsAtThreeDigits() {
        var s = state()
        for d in "12345" { s.appendDigit(d) }
        XCTAssertEqual(s.numberBuffer, "123")
    }

    func testBackspacePopsADigit() {
        var s = state()
        s.appendDigit("1")
        s.appendDigit("2")
        s.popDigit()
        XCTAssertEqual(s.numberBuffer, "1")
    }

    /// Typing a room number moves the cursor as a preview, so the screen always says
    /// what Enter is about to do.
    func testTypingARoomOnThisPageMovesTheCursorToIt() {
        var s = state()
        s.appendDigit("5")
        XCTAssertEqual(s.cursor, 4)
        XCTAssertEqual(s.selectedRoomIndex, 4)
    }

    /// Room 42 is on page 4. Typing '4' previews room 4, which is on this page, so the
    /// cursor goes there; the '2' that follows must NOT turn the page after it. The
    /// screen would otherwise throw itself around once per digit.
    func testTypingARoomOffThisPageDoesNotTurnThePage() {
        var s = state()
        s.cursor = 2
        s.appendDigit("4")
        XCTAssertEqual(s.cursor, 3, "'4' should preview room 4")
        s.appendDigit("2")
        XCTAssertEqual(s.page, 0)
        XCTAssertEqual(s.cursor, 3, "the cursor should stay on the last previewable room")
        XCTAssertEqual(s.selectedRoomIndex, 41, "but Enter still means room 42")
    }

    func testAnArrowClearsTheBuffer() {
        var s = state()
        s.appendDigit("7")
        s.moveDown()
        XCTAssertEqual(s.numberBuffer, "")
    }

    // MARK: - What Enter means

    func testWithAnEmptyBufferEnterTakesTheCursorRow() {
        var s = state()
        s.page = 2
        s.cursor = 3
        XCTAssertEqual(s.selectedRoomIndex, 2 * 13 + 3)
    }

    /// Numbers are absolute across pages: 16 is typed as '16' from any page.
    func testABufferedNumberBeatsTheCursorAndIsAbsolute() {
        var s = state()
        s.page = 3
        s.appendDigit("1")
        s.appendDigit("6")
        XCTAssertEqual(s.selectedRoomIndex, 15)
    }

    func testARoomNumberThatDoesNotExistSelectsNothing() {
        var s = state()
        s.appendDigit("9")
        s.appendDigit("9")
        s.appendDigit("9")
        XCTAssertNil(s.selectedRoomIndex)
    }

    func testRoomZeroIsNotARoom() {
        var s = state()
        s.appendDigit("0")
        XCTAssertNil(s.selectedRoomIndex)
    }

    func testAnEmptyListSelectsNothing() {
        var s = ListState()
        XCTAssertNil(s.selectedRoomIndex)
        s.moveDown()
        s.pageForward()
        XCTAssertEqual(s.page, 0)
        XCTAssertEqual(s.cursor, 0)
    }
}
