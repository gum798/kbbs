import XCTest
@testable import kbbs

final class MessageNavigationTests: XCTestCase {
    private final class Worker: AXWorking {
        var jobs: [AXJob] = []
        var results: [AXResult] = []
        func running() -> Watchdog.Running? { nil }
        func collect(generation: Int) -> [AXResult] {
            defer { results.removeAll() }
            return results
        }
        func submit(_ job: AXJob, generation: Int) { jobs.append(job) }
        func release(token: Int) {}
    }

    private func message(_ body: String) -> TranscriptMessage {
        TranscriptMessage(author: "친구", timeRaw: "12:00", body: body,
                          isSystem: false, logicalTimestamp: nil)
    }

    private func loop(count: Int = 25, worker: Worker? = nil) -> Loop {
        var loop = Loop(rooms: [], link: .connecting, worker: worker)
        var room = RoomState(title: "테스트방")
        room.messages = (0..<count).map { message("메시지\($0 + 1)") }
        loop.enter(room: room, token: 1)
        return loop
    }

    private func rows(_ loop: Loop) -> [String] {
        guard let room = loop.roomState else { return [] }
        return RoomScreen.render(room).render()
    }

    private func selectedRows(_ loop: Loop) -> [String] {
        rows(loop).filter { $0.contains(Theme.reverse) }
    }

    func testUpSelectsNewestThenRevealsOldHistoryAndStopsAtFirst() {
        var loop = loop()
        _ = loop.handle(.up)
        XCTAssertTrue(selectedRows(loop).contains { $0.contains("메시지25") })
        for _ in 0..<30 { _ = loop.handle(.up) }
        XCTAssertTrue(selectedRows(loop).contains { $0.contains("메시지1 ") })
        _ = loop.handle(.down)
        XCTAssertTrue(selectedRows(loop).contains { $0.contains("메시지2 ") })
    }

    func testDownPastLastClearsSelectionAndStaysClear() {
        var loop = loop(count: 2)
        _ = loop.handle(.up)
        _ = loop.handle(.up)
        _ = loop.handle(.down)
        XCTAssertTrue(selectedRows(loop).contains { $0.contains("메시지2 ") })
        _ = loop.handle(.down)
        XCTAssertTrue(selectedRows(loop).isEmpty)
        _ = loop.handle(.down)
        XCTAssertTrue(selectedRows(loop).isEmpty)
        XCTAssertEqual(loop.screen, .room)
    }

    func testEmptyRoomAndDownWithoutSelectionDoNothing() {
        var empty = loop(count: 0)
        _ = empty.handle(.up)
        _ = empty.handle(.down)
        XCTAssertTrue(selectedRows(empty).isEmpty)
        var populated = loop()
        _ = populated.handle(.down)
        XCTAssertTrue(selectedRows(populated).isEmpty)
    }

    func testEscapeClearsSelectionBeforeLeavingAndPreservesDraft() {
        var loop = loop()
        for character in "초안" { _ = loop.handle(.char(character)) }
        _ = loop.handle(.up)
        _ = loop.handle(.escape)
        XCTAssertEqual(loop.screen, .room)
        XCTAssertEqual(loop.roomState?.composer, "초안")
        XCTAssertTrue(selectedRows(loop).isEmpty)
        _ = loop.handle(.escape)
        XCTAssertEqual(loop.screen, .list)
    }

    func testIncomingReadKeepsSelectionStableUntilDownPastLast() {
        let worker = Worker()
        var loop = loop(count: 1, worker: worker)
        _ = loop.handle(.up)
        worker.results = [.read(token: 1, snapshot: TranscriptSnapshot(chat: "테스트방",
            fetchedAt: Date(), messages: [message("새 메시지")]), elapsed: 0)]
        loop.tick()
        XCTAssertTrue(selectedRows(loop).contains { $0.contains("메시지1 ") })
        XCTAssertFalse(rows(loop).contains { $0.contains("새 메시지") })
        _ = loop.handle(.down)
        XCTAssertTrue(selectedRows(loop).isEmpty)
        XCTAssertTrue(rows(loop).contains { $0.contains("새 메시지") })
    }

    func testBrowsingAndEnterWithoutDraftNeverSubmitAXJobs() {
        let worker = Worker()
        var loop = loop(worker: worker)
        _ = loop.handle(.up)
        _ = loop.handle(.up)
        _ = loop.handle(.enter)
        _ = loop.handle(.down)
        XCTAssertTrue(worker.jobs.isEmpty)
        XCTAssertFalse(rows(loop).contains { $0.contains("답장") })
    }

    func testSelectedMessageDoesNotChangeOrdinaryDraftSend() {
        let worker = Worker()
        var loop = loop(worker: worker)
        _ = loop.handle(.up)
        for character in "초안" { _ = loop.handle(.char(character)) }
        _ = loop.handle(.enter)
        XCTAssertEqual(worker.jobs.count, 1)
        guard let job = worker.jobs.first, case .send(let token, let body) = job else {
            return XCTFail("ordinary send must remain ordinary")
        }
        XCTAssertEqual(token, 1)
        XCTAssertEqual(body, "초안")
    }

    func testSelectedLongKoreanMessageKeepsFrameAndShowsItsBeginning() {
        var loop = loop(count: 0)
        var room = RoomState(title: "테스트방")
        room.messages = [message("첫머리 " + String(repeating: "한글😀", count: 300))]
        loop.enter(room: room, token: 1)
        _ = loop.handle(.up)
        XCTAssertTrue(selectedRows(loop).contains { $0.contains("첫머리") })
        XCTAssertEqual(rows(loop).count, 24)
        XCTAssertTrue(rows(loop).allSatisfy { Width.cells(Frame.stripANSI($0)) == 80 })
    }
}
