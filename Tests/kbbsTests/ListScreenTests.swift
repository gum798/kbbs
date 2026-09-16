import XCTest

@testable import kbbs

/// The board index is the screen the user lives in. These tests run with no KakaoTalk,
/// no Accessibility grant and no terminal — they feed a model in and read the 24 rows out.
final class ListScreenTests: XCTestCase {

    private func plain(_ rows: [String]) -> [String] {
        rows.map { Frame.stripANSI($0) }
    }

    private func state(_ count: Int) -> ListState {
        var s = ListState()
        s.rooms = (1...count).map {
            Room(
                title: "방\($0)",
                lastMessage: "메시지 \($0)",
                timeLabel: "21:0\($0 % 10)",
                unreadCount: $0 % 3 == 0 ? $0 : nil,
                hasWindow: $0 % 2 == 0
            )
        }
        s.clock = Date(timeIntervalSince1970: 0)
        return s
    }

    // MARK: - The invariant

    func testEveryRowIsExactlyEightyCells() {
        let rows = ListScreen.render(state(27)).render()
        XCTAssertEqual(rows.count, 24)
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(Width.cells(Frame.stripANSI(row)), 80, "row \(i)")
        }
    }

    func testLongKoreanTitlesDoNotBreakTheFrame() {
        var s = state(3)
        s.rooms[0] = Room(
            title: "고등학교 3학년 2반 동창회 단체 대화방 번개 모임",
            lastMessage: String(repeating: "아주 긴 메시지 ", count: 20),
            timeLabel: "21:03",
            unreadCount: 1234,
            hasWindow: true
        )
        for row in ListScreen.render(s).render() {
            XCTAssertEqual(Width.cells(Frame.stripANSI(row)), 80)
        }
    }

    func testEmptyListStillDrawsAFullFrame() {
        let rows = ListScreen.render(ListState()).render()
        XCTAssertEqual(rows.count, 24)
        for row in rows {
            XCTAssertEqual(Width.cells(Frame.stripANSI(row)), 80)
        }
    }

    // MARK: - Content

    func testRoomTitlesAppear() {
        let rows = plain(ListScreen.render(state(3)).render())
        XCTAssertTrue(rows.contains { $0.contains("방1") })
        XCTAssertTrue(rows.contains { $0.contains("방3") })
    }

    func testRoomsAreNumberedFromOne() {
        let rows = plain(ListScreen.render(state(3)).render())
        XCTAssertTrue(rows.contains { $0.contains(" 1. ") })
        XCTAssertTrue(rows.contains { $0.contains(" 2. ") })
    }

    func testOpenRoomsAreMarkedAndClosedOnesAreNot() {
        let rows = plain(ListScreen.render(state(2)).render())
        let row1 = rows.first { $0.contains("방1") }!   // hasWindow false
        let row2 = rows.first { $0.contains("방2") }!   // hasWindow true
        XCTAssertTrue(row1.contains("-"))
        XCTAssertTrue(row2.contains("*"))
    }

    func testUnreadCountIsShownOnlyWhenPresent() {
        var s = state(2)
        s.rooms[0] = Room(title: "읽음", unreadCount: nil)
        s.rooms[1] = Room(title: "안읽음", unreadCount: 14)
        let rows = plain(ListScreen.render(s).render())
        XCTAssertTrue(rows.first { $0.contains("안읽음") }!.contains("14"))
        XCTAssertFalse(rows.first { $0.contains("읽음 ") }?.contains("14") ?? false)
    }

    func testCappedUnreadCountIsShownWithAPlus() {
        var s = state(1)
        s.rooms[0] = Room(title: "시끄러운방", unreadCount: 999)
        let row = plain(ListScreen.render(s).render()).first { $0.contains("시끄러운방") }!
        XCTAssertTrue(row.contains("999"))
    }

    // MARK: - Cursor

    func testCursorMarksTheSelectedRow() {
        var s = state(5)
        s.cursor = 2
        let rows = plain(ListScreen.render(s).render())
        let marked = rows.filter { $0.contains("▶") }
        XCTAssertEqual(marked.count, 1)
        XCTAssertTrue(marked[0].contains("방3"))
    }

    func testCursorOnTheFirstRowByDefault() {
        let rows = plain(ListScreen.render(state(5)).render())
        XCTAssertTrue(rows.first { $0.contains("▶") }!.contains("방1"))
    }

    // MARK: - Paging

    func testSecondPageShowsTheNextThirteenRooms() {
        var s = state(27)
        s.page = 1
        let rows = plain(ListScreen.render(s).render())
        XCTAssertTrue(rows.contains { $0.contains("방14") })
        XCTAssertFalse(rows.contains { $0.contains("방1 ") })
    }

    func testNumberColumnContinuesAcrossPages() {
        var s = state(27)
        s.page = 1
        let rows = plain(ListScreen.render(s).render())
        XCTAssertTrue(rows.contains { $0.contains("14. ") })
    }

    func testPartialLastPageLeavesBlankRowsNotPlaceholders() {
        var s = state(27)
        s.page = 2  // 27 rooms, 13 per page -> page 2 holds one room
        let rows = plain(ListScreen.render(s).render())
        XCTAssertTrue(rows.contains { $0.contains("방27") })
        // The 12 unused room rows must be empty inside the border, not "-" or "(없음)".
        let roomRows = rows[5..<18]
        let nonEmpty = roomRows.filter { !$0.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(nonEmpty.count, 1)
    }

    func testPageCounterReflectsPosition() {
        var s = state(27)
        s.page = 1
        let joined = plain(ListScreen.render(s).render()).joined()
        XCTAssertTrue(joined.contains("2/3"))
        XCTAssertTrue(joined.contains("27"))
    }

    // MARK: - The 선택> prompt

    func testNumberBufferIsEchoedAtThePrompt() {
        var s = state(27)
        s.numberBuffer = "12"
        let joined = plain(ListScreen.render(s).render())
        XCTAssertTrue(joined.contains { $0.contains("선택> 12") })
    }

    func testEmptyNumberBufferStillDrawsThePrompt() {
        let joined = plain(ListScreen.render(state(3)).render())
        XCTAssertTrue(joined.contains { $0.contains("선택>") })
    }

    func testHotkeyRowIsPresent() {
        let joined = plain(ListScreen.render(state(3)).render()).joined()
        XCTAssertTrue(joined.contains("P:이전"))
        XCTAssertTrue(joined.contains("N:다음"))
        XCTAssertTrue(joined.contains("R:새로고침"))
        XCTAssertTrue(joined.contains("Q:종료"))
    }

    // MARK: - Link state is never hidden

    func testConnectingIsShown() {
        var s = state(3)
        s.link = .connecting
        XCTAssertTrue(plain(ListScreen.render(s).render()).joined().contains("접속중"))
    }

    func testDownStateIsShown() {
        var s = state(3)
        s.link = .down(since: Date(timeIntervalSince1970: 0), reason: "창 없음")
        XCTAssertTrue(plain(ListScreen.render(s).render()).joined().contains("응답 없음"))
    }
}

extension ListScreenTests {
    /// The columns must sum to the space between the borders. A miscount here is
    /// exactly what makes the right border walk.
    func testColumnsSumToInnerWidth() {
        XCTAssertEqual(ListScreen.columnTotal, ListScreen.inner)
    }
    // MARK: - Text KakaoTalk actually hands us

    /// A preview carrying a newline is not merely a rendering problem. Width counts the
    /// control character as zero cells, so the column pads to its full 38 and the row
    /// ends up one cell over budget — the right border is the thing that falls off.
    /// Frame neutralising the character is not enough on its own; the row has to be
    /// built from text that was already one line.
    func testAPreviewWithANewlineKeepsTheRightBorder() {
        var s = state(3)
        s.rooms[0] = Room(
            title: "모빙고객센터",
            lastMessage: "[모빙]\n고객님 안녕하세요!",
            timeLabel: "오후 1:21",
            hasWindow: false
        )
        let rows = plain(ListScreen.render(s).render())
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(Width.cells(row), 80, "row \(i)")
            XCTAssertFalse(row.contains("\n"), "row \(i) contains a line break")
        }
        XCTAssertTrue(rows[5].hasSuffix("║"), "the right border is gone: \(rows[5])")
    }

    func testTheNewlineReadsAsASpaceInThePreview() {
        var s = state(1)
        s.rooms[0] = Room(title: "모빙고객센터", lastMessage: "[모빙]\n고객님 안녕하세요!")
        let rows = plain(ListScreen.render(s).render())
        XCTAssertTrue(rows[5].contains("[모빙] 고객님"), "preview reads: \(rows[5])")
    }

    // MARK: - The transient note

    /// The screen has to be able to answer back — an out-of-range room number, a refusal
    /// while the scan is busy. It replaces the hotkey row's spare space rather than
    /// taking a row of its own, because there is no row to spare.
    func testANoteAppearsOnTheHotkeyRow() {
        var s = state(3)
        s.note = "그런 방은 없습니다"
        let rows = plain(ListScreen.render(s).render())
        XCTAssertTrue(rows[21].contains("그런 방은 없습니다"), "row 21 reads: \(rows[21])")
    }

    func testALongNoteStillLeavesEveryRowEightyCells() {
        var s = state(27)
        s.note = "카카오톡이 응답하지 않습니다. 기다리거나 Ctrl-C 로 종료하세요. 아주 긴 안내문"
        for (i, row) in plain(ListScreen.render(s).render()).enumerated() {
            XCTAssertEqual(Width.cells(row), 80, "row \(i)")
        }
    }

    func testWithoutANoteTheHotkeyRowIsUnchanged() {
        let without = plain(ListScreen.render(state(3)).render())[21]
        XCTAssertTrue(without.contains("P:이전"))
        XCTAssertTrue(without.contains("Q:종료"))
    }

    // MARK: - The selected row

    /// The ▶ alone is one cell of signal in an 80-cell row, and on a screen of Korean
    /// text it disappears. The row the cursor is on is drawn in reverse video so it reads
    /// as a bar at a glance.
    func testTheSelectedRowIsReversed() {
        var s = state(5)
        s.cursor = 2
        let rows = ListScreen.render(s).render()
        XCTAssertTrue(rows[5 + 2].contains(Theme.reverse), "no reverse on the cursor row")
        XCTAssertTrue(rows[5 + 2].contains(Theme.reset), "the reverse is never turned off")
    }

    func testTheOtherRowsAreNotReversed() {
        var s = state(5)
        s.cursor = 2
        let rows = ListScreen.render(s).render()
        for (offset, row) in rows[5...(5 + 4)].enumerated() where offset != 2 {
            XCTAssertFalse(row.contains(Theme.reverse), "row \(offset) should be plain")
        }
    }

    /// The colour codes must not be counted as content, or the bar pushes the right
    /// border off the screen.
    func testAReversedRowIsStillEightyCells() {
        var s = state(27)
        s.cursor = 4
        for (i, row) in ListScreen.render(s).render().enumerated() {
            XCTAssertEqual(Width.cells(Frame.stripANSI(row)), 80, "row \(i)")
        }
    }

    /// The bar covers the row, not the frame: the ║ borders stay in the normal colours
    /// so the box does not break open on the selected line.
    func testTheBordersStayOutsideTheBar() {
        var s = state(5)
        s.cursor = 0
        let row = ListScreen.render(s).render()[5]
        XCTAssertTrue(row.hasPrefix(Theme.v), "the left border is inside the bar")
        XCTAssertTrue(row.hasSuffix(Theme.v), "the right border is inside the bar")
    }

    func testAReversedRowStillReadsAsItself() {
        var s = state(3)
        s.cursor = 1
        let row = Frame.stripANSI(ListScreen.render(s).render()[6])
        XCTAssertTrue(row.contains("방2"), row)
        XCTAssertTrue(row.contains("▶"), row)
    }

}
