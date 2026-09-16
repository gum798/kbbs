import XCTest

@testable import kbbs

/// The conversation panel. Same contract as the list: a model in, exactly 24 rows of
/// exactly 80 cells out, with no terminal and no KakaoTalk anywhere near it.
final class RoomScreenTests: XCTestCase {

    private func plain(_ rows: [String]) -> [String] { rows.map { Frame.stripANSI($0) } }

    private func message(
        _ body: String,
        author: String? = nil,
        time: String? = "21:01",
        side: String = "left",
        source: String = "explicit",
        images: Int = 0,
        links: Int = 0
    ) -> TranscriptMessage {
        TranscriptMessage(
            author: author,
            timeRaw: time,
            body: body,
            imageCount: images,
            linkCount: links,
            isSystem: false,
            logicalTimestamp: nil,
            side: side,
            authorSource: source
        )
    }

    private func state(_ messages: [TranscriptMessage], title: String = "김민수") -> RoomState {
        var s = RoomState(title: title)
        s.messages = messages
        s.clock = Date(timeIntervalSince1970: 0)
        return s
    }

    // MARK: - The invariant

    func testEveryRowIsExactlyEightyCells() {
        let rows = plain(RoomScreen.render(state([
            message("형 내일 시간 돼요?", author: "김민수"),
            message("응 괜찮아", side: "right", source: "default-me"),
        ])).render())
        XCTAssertEqual(rows.count, 24)
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(Width.cells(row), 80, "row \(i): \(row)")
        }
    }

    func testAnEmptyRoomStillFillsTheFrame() {
        for (i, row) in plain(RoomScreen.render(state([])).render()).enumerated() {
            XCTAssertEqual(Width.cells(row), 80, "row \(i)")
        }
    }

    func testAVeryLongKoreanMessageKeepsTheFrame() {
        let long = String(repeating: "가나다라마바사", count: 12)
        for (i, row) in plain(RoomScreen.render(state([message(long, author: "김민수")])).render()).enumerated() {
            XCTAssertEqual(Width.cells(row), 80, "row \(i)")
        }
    }

    func testTheRoomTitleIsOnScreen() {
        let rows = plain(RoomScreen.render(state([], title: "개발팀")).render())
        XCTAssertTrue(rows[1].contains("개발팀"), rows[1])
    }

    // MARK: - What the transcript says

    func testTheNewestMessageIsAtTheBottomOfTheTranscript() {
        let rows = plain(RoomScreen.render(state([
            message("먼저 온 말", author: "김민수"),
            message("나중에 온 말", author: "김민수"),
        ])).render())
        let first = rows.firstIndex { $0.contains("먼저 온 말") }
        let second = rows.firstIndex { $0.contains("나중에 온 말") }
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertLessThan(first!, second!)
    }

    /// More messages than fit means the oldest scroll off the top — there is no
    /// scrollback, so the newest must be the ones you can see.
    func testWhenThereIsTooMuchTheNewestSurvives() {
        let many = (1...40).map { message("메시지\($0)", author: "김민수") }
        let rows = plain(RoomScreen.render(state(many)).render())
        XCTAssertTrue(rows.contains { $0.contains("메시지40") }, "the newest message is missing")
        XCTAssertFalse(rows.contains { $0.contains("메시지1 ") }, "an old message should have scrolled off")
    }

    func testBothOfTwoIdenticalMessagesAreDrawn() {
        let rows = plain(RoomScreen.render(state([
            message("ㅋㅋ", author: "김민수", time: "21:02"),
            message("ㅋㅋ", author: "김민수", time: "21:02"),
        ])).render())
        XCTAssertEqual(rows.filter { $0.contains("ㅋㅋ") }.count, 2)
    }

    // MARK: - Who said it

    func testMyOwnMessageIsMarkedAsMine() {
        let rows = plain(RoomScreen.render(state([
            message("응 괜찮아", side: "right", source: "default-me"),
        ])).render())
        XCTAssertTrue(rows.contains { $0.contains("나") && $0.contains("응 괜찮아") })
    }

    /// The geometry read came back unknown and the reader fell back to "mine". The ? is
    /// the whole disclosure — it used to also spend a transcript row spelling it out.
    func testAGuessedSenderIsMarked() {
        let rows = plain(RoomScreen.render(state([
            message("넵", side: "unknown", source: "default-me"),
        ])).render())
        XCTAssertTrue(rows.contains { $0.contains("나?") }, "the guess is not marked")
        XCTAssertFalse(rows.contains { $0.contains("추정") }, "the explanation should be gone")
    }

    func testANamedSenderIsShownByName() {
        let rows = plain(RoomScreen.render(state([message("안녕", author: "김민수")])).render())
        XCTAssertTrue(rows.contains { $0.contains("김민수") && $0.contains("안녕") })
    }

    // MARK: - Attachments

    func testAPhotoIsMarked() {
        let rows = plain(RoomScreen.render(state([message("", author: "김민수", images: 1)])).render())
        XCTAssertTrue(rows.contains { $0.contains("[사진]") }, "\(rows)")
    }

    func testALinkIsMarked() {
        let rows = plain(RoomScreen.render(state([message("지도 보낼게요", author: "김민수", links: 1)])).render())
        XCTAssertTrue(rows.contains { $0.contains("[링크]") })
    }

    // MARK: - The bottom of the screen

    func testTheComposerShowsWhatHasBeenTyped() {
        var s = state([])
        s.composer = "알겠어요 그때 봬요"
        let rows = plain(RoomScreen.render(s).render())
        XCTAssertTrue(rows[20].contains("알겠어요 그때 봬요"), rows[20])
    }

    func testTheHotkeyRowNamesTheWayBack() {
        let rows = plain(RoomScreen.render(state([])).render())
        XCTAssertTrue(rows[22].contains("Esc:목록"), rows[22])
    }

    /// There is no status band any more, so a note that matters shares the hotkey row.
    func testANoteReachesTheHotkeyRow() {
        var s = state([])
        s.note = "입력창에 남아 있습니다"
        let rows = plain(RoomScreen.render(s).render())
        XCTAssertTrue(rows[22].contains("입력창에 남아 있습니다"), rows[22])
    }

    func testALongComposerKeepsTheFrame() {
        var s = state([])
        s.composer = String(repeating: "가", count: 120)
        for (i, row) in plain(RoomScreen.render(s).render()).enumerated() {
            XCTAssertEqual(Width.cells(row), 80, "row \(i)")
        }
    }
    func testAPendingMessageIsMarkedAsSending() {
        var s = state([])
        var ledger = PendingLedger()
        ledger.add(body: "보내는 중인 말", transcript: [])
        s.pending = ledger.entries
        let rows = plain(RoomScreen.render(s).render())
        XCTAssertTrue(rows.contains { $0.contains("보내는 중인 말") && $0.contains("[전송중]") }, "\(rows)")
    }

    func testAnUnconfirmedMessageSaysSo() {
        var s = state([])
        var ledger = PendingLedger()
        let sent = Date(timeIntervalSince1970: 0)
        ledger.add(body: "확인 안 된 말", transcript: [], now: sent)
        ledger.reconcile(against: [], now: sent.addingTimeInterval(20))
        s.pending = ledger.entries
        let rows = plain(RoomScreen.render(s).render())
        XCTAssertTrue(rows.contains { $0.contains("[미확인]") }, "\(rows)")
    }

    func testAPendingMessageKeepsTheFrame() {
        var s = state([message("앞선 말", author: "김민수")])
        var ledger = PendingLedger()
        ledger.add(body: String(repeating: "긴 메시지 ", count: 12), transcript: [])
        s.pending = ledger.entries
        for (i, row) in plain(RoomScreen.render(s).render()).enumerated() {
            XCTAssertEqual(Width.cells(row), 80, "row \(i)")
        }
    }

    /// KakaoTalk stamps transcript rows "오후 1:21" too, and the 시각 column is five
    /// cells. Without compacting, every row on the screen read just "오후".
    func testTheTimeColumnShowsAClockNotAMeridiem() {
        let rows = plain(RoomScreen.render(state([
            message("안녕", author: "김민수", time: "오후 1:21"),
        ])).render())
        XCTAssertTrue(rows.contains { $0.contains("13:21") }, "\(rows)")
        XCTAssertFalse(rows.contains { $0.contains("오후") }, "the meridiem is still there")
    }

    func testATwentyFourHourStampIsLeftAlone() {
        let rows = plain(RoomScreen.render(state([message("안녕", author: "김민수", time: "21:03")])).render())
        XCTAssertTrue(rows.contains { $0.contains("21:03") })
    }

    /// 80 cells is not enough on its own — a row nobody filled in is 80 spaces and passes
    /// the width check while leaving a hole in the side of the box.
    func testEveryRowIsInsideTheBox() {
        for (i, row) in plain(RoomScreen.render(state([message("안녕", author: "김민수")])).render()).enumerated() {
            XCTAssertTrue("║╔╠╚".contains(row.first ?? " "), "row \(i) has no left border: \(row)")
            XCTAssertTrue("║╗╣╝".contains(row.last ?? " "), "row \(i) has no right border: \(row)")
        }
    }


    // MARK: - Where the terminal cursor goes

    /// The IME draws what it is composing at the TERMINAL's cursor, not at the caret kbbs
    /// paints. With the cursor parked wherever the last write left it, a half-typed
    /// Hangul syllable appeared outside the frame entirely.
    func testTheCaretColumnOfAnEmptyComposer() {
        XCTAssertEqual(RoomScreen.caretColumn(state([])), 9)
    }

    func testTheCaretMovesPastWhatHasBeenTyped() {
        var s = state([])
        s.composer = "abc"
        XCTAssertEqual(RoomScreen.caretColumn(s), 12)
    }

    /// Two cells per Hangul syllable, or the cursor drifts left of the text it follows.
    func testTheCaretCountsHangulAsTwoCells() {
        var s = state([])
        s.composer = "안녕"
        XCTAssertEqual(RoomScreen.caretColumn(s), 13)
    }

    func testTheCaretStaysOnScreenForALongLine() {
        var s = state([])
        s.composer = String(repeating: "가", count: 200)
        let column = RoomScreen.caretColumn(s)
        XCTAssertGreaterThan(column, 1)
        XCTAssertLessThanOrEqual(column, 80)
    }

    /// The row the cursor belongs on, 1-based for the terminal.
    func testTheComposerRowIsWhereTheComposerIs() {
        XCTAssertEqual(RoomScreen.caretRow, 21)
    }

}
