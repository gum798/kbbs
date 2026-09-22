import XCTest

@testable import kbbs

final class ConnectionRecoveryTests: XCTestCase {
    private final class Worker: AXWorking {
        var results: [AXResult] = []
        var jobs: [AXJob] = []

        func running() -> Watchdog.Running? { nil }
        func collect(generation: Int) -> [AXResult] {
            defer { results.removeAll() }
            return results
        }
        func submit(_ job: AXJob, generation: Int) { jobs.append(job) }
        func release(token: Int) {}
    }

    private func makeLoop(_ worker: Worker, permission: Bool = true) -> Loop {
        Loop(rooms: [Room(title: "테스트방")], link: .connecting, worker: worker,
             readLimit: 60, permissionGranted: { permission })
    }

    private func disconnect(_ loop: inout Loop, worker: Worker) {
        for _ in 0..<3 {
            worker.results = [.failed(reason: "잠금 중 창을 읽지 못함")]
            loop.tick()
        }
        XCTAssertEqual(loop.screen, .blocked)
        worker.jobs.removeAll()
    }

    func testListDisconnectionAutomaticallyRetriesWithoutARoomToken() {
        let worker = Worker()
        var loop = makeLoop(worker)
        disconnect(&loop, worker: worker)

        loop.tick(now: Date().addingTimeInterval(30))

        XCTAssertEqual(worker.jobs.count, 1)
        guard let job = worker.jobs.first, case .scanList(let limit) = job else {
            return XCTFail("a disconnected list must rescan without a room token")
        }
        XCTAssertEqual(limit, 60)
    }

    func testManualRetryWorksForADisconnectedList() {
        let worker = Worker()
        var loop = makeLoop(worker)
        disconnect(&loop, worker: worker)

        _ = loop.handle(.control("r"))
        _ = loop.handle(.control("r"))

        XCTAssertEqual(worker.jobs.count, 1, "a busy retry must not queue another scan")
        guard let job = worker.jobs.first, case .scanList = job else {
            return XCTFail("R must retry the list")
        }
    }

    func testRecoveredListLeavesBlockedScreenAndResetsFailureCount() {
        let worker = Worker()
        var loop = makeLoop(worker)
        disconnect(&loop, worker: worker)
        worker.results = [.list(rooms: [Room(title: "복구된 방")], source: .chatList, elapsed: 0.1)]
        loop.tick()

        XCTAssertEqual(loop.screen, .list)
        XCTAssertNil(loop.blocked)
        XCTAssertEqual(loop.list.rooms.map(\.title), ["복구된 방"])

        worker.results = [.failed(reason: "일시 실패")]
        loop.tick()
        XCTAssertEqual(loop.screen, .list, "one failure after recovery is not three failures")
    }

    func testSuccessfulListScanBreaksASequenceOfFailures() {
        let worker = Worker()
        var loop = makeLoop(worker)
        for _ in 0..<3 {
            worker.results = [.failed(reason: "일시 실패")]
            loop.tick()
            worker.results = [.list(rooms: [Room(title: "테스트방")], source: .chatList, elapsed: 0)]
            loop.tick()
        }
        XCTAssertEqual(loop.screen, .list)
        XCTAssertNil(loop.blocked)
    }

    func testRoomRecoveryKeepsTheDraftAndReadsTheSameToken() {
        let worker = Worker()
        var loop = makeLoop(worker)
        var room = RoomState(title: "테스트방")
        room.composer = "아직 보내지 않은 글"
        loop.enter(room: room, token: 7)
        disconnect(&loop, worker: worker)

        loop.tick(now: Date().addingTimeInterval(30))
        guard let job = worker.jobs.first, case .readRoom(let token, let title, _) = job else {
            return XCTFail("a disconnected room must retry its read")
        }
        XCTAssertEqual(token, 7)
        XCTAssertEqual(title, "테스트방")
        worker.results = [.read(token: 7, snapshot: TranscriptSnapshot(
            chat: title, fetchedAt: Date(), messages: []), elapsed: 0)]
        loop.tick()
        XCTAssertEqual(loop.screen, .room)
        XCTAssertNil(loop.blocked)
        XCTAssertEqual(loop.roomState?.composer, "아직 보내지 않은 글")
    }

    func testRetryCountdownActuallyDecreases() {
        let worker = Worker()
        var loop = makeLoop(worker)
        disconnect(&loop, worker: worker)
        let before = loop.blocked!.retryIn
        loop.tick(now: Date().addingTimeInterval(4))
        XCTAssertLessThan(loop.blocked!.retryIn, before - 3)
    }

    func testRevokedPermissionDoesNotScheduleRoomRetries() {
        let worker = Worker()
        var loop = makeLoop(worker, permission: false)
        loop.enter(room: RoomState(title: "테스트방"), token: 7)
        disconnect(&loop, worker: worker)
        loop.tick(now: Date().addingTimeInterval(30))
        _ = loop.handle(.control("r"))
        XCTAssertTrue(worker.jobs.isEmpty)
    }
}
