import XCTest

@testable import kbbs

/// The worker itself is a thread and a queue, but the parts that decide what the user
/// sees are plain values: which results still matter, how late is late, and how far to
/// back off. Those are tested here, without starting anything.
final class WorkerTests: XCTestCase {

    // MARK: - Generations

    /// Accessibility calls cannot be cancelled — the copied scraper is synchronous with
    /// dozens of sleeps in it. So Esc does not stop a read; it abandons the result. Every
    /// job carries the generation it was queued in, and anything from an older one is
    /// read off the mailbox and dropped.
    func testAResultFromTheCurrentGenerationIsDelivered() {
        let box = Mailbox()
        box.deliver(.failed(reason: "테스트"), generation: 7)
        XCTAssertEqual(box.drain(currentGeneration: 7).count, 1)
    }

    func testAResultFromAnOlderGenerationIsDropped() {
        let box = Mailbox()
        box.deliver(.failed(reason: "이전 방"), generation: 3)
        XCTAssertTrue(box.drain(currentGeneration: 4).isEmpty)
    }

    func testDrainingTakesEverythingOnce() {
        let box = Mailbox()
        box.deliver(.failed(reason: "하나"), generation: 1)
        box.deliver(.failed(reason: "둘"), generation: 1)
        XCTAssertEqual(box.drain(currentGeneration: 1).count, 2)
        XCTAssertTrue(box.drain(currentGeneration: 1).isEmpty)
    }

    func testStaleResultsDoNotBlockFreshOnes() {
        let box = Mailbox()
        box.deliver(.failed(reason: "낡음"), generation: 1)
        box.deliver(.failed(reason: "새것"), generation: 2)
        let delivered = box.drain(currentGeneration: 2)
        XCTAssertEqual(delivered.count, 1)
        if case .failed(let reason) = delivered[0] {
            XCTAssertEqual(reason, "새것")
        } else {
            XCTFail("wrong result delivered")
        }
    }

    // MARK: - How late is late

    /// Three tiers, all rendered from the main loop while the worker is blocked. Under
    /// two seconds nothing is said, because saying something would be noise.
    func testAQuickCallSaysNothing() {
        XCTAssertEqual(DelayTier.of(elapsed: 0.4), .quiet)
        XCTAssertEqual(DelayTier.of(elapsed: 1.9), .quiet)
    }

    func testASlowCallIsAnnounced() {
        XCTAssertEqual(DelayTier.of(elapsed: 2.0), .slow)
        XCTAssertEqual(DelayTier.of(elapsed: 5.9), .slow)
    }

    /// Past six seconds the screen stops implying this will finish soon and says the one
    /// thing that is literally true: it cannot be cancelled.
    func testAStuckCallIsAdmitted() {
        XCTAssertEqual(DelayTier.of(elapsed: 6.0), .stuck)
        XCTAssertEqual(DelayTier.of(elapsed: 40), .stuck)
    }

    func testTheBadgeTextMatchesTheTier() {
        XCTAssertNil(DelayTier.quiet.badge(elapsed: 1))
        XCTAssertEqual(DelayTier.slow.badge(elapsed: 3.2), "[응답 느림 3초]")
        XCTAssertEqual(DelayTier.stuck.badge(elapsed: 12.7), "[카카오톡 응답 없음 12초]")
    }

    // MARK: - Backing off

    func testTheFirstFailureWaitsThreeSeconds() {
        XCTAssertEqual(Backoff.interval(afterFailures: 1), 3)
    }

    func testRepeatedFailuresWaitLonger() {
        XCTAssertEqual(Backoff.interval(afterFailures: 2), 5)
        XCTAssertEqual(Backoff.interval(afterFailures: 3), 10)
        XCTAssertEqual(Backoff.interval(afterFailures: 4), 15)
    }

    func testTheLadderStopsAtFifteenSeconds() {
        XCTAssertEqual(Backoff.interval(afterFailures: 9), 15)
    }

    func testNoFailuresMeansNoBackoff() {
        XCTAssertNil(Backoff.interval(afterFailures: 0))
    }

    // MARK: - The watchdog

    /// The worker stamps what it is about to do before it blocks, and the main loop reads
    /// it to animate. Nothing else is shared.
    func testTheWatchdogReportsWhatIsRunning() {
        let watchdog = Watchdog()
        XCTAssertNil(watchdog.current())
        watchdog.began(label: "대화 읽기", at: Date(timeIntervalSince1970: 100))
        let running = watchdog.current()
        XCTAssertEqual(running?.label, "대화 읽기")
        watchdog.finished()
        XCTAssertNil(watchdog.current())
    }

    func testTheWatchdogMeasuresFromWhenTheJobStarted() {
        let watchdog = Watchdog()
        let started = Date().addingTimeInterval(-4)
        watchdog.began(label: "목록 훑기", at: started)
        let elapsed = watchdog.current()?.elapsed ?? 0
        XCTAssertGreaterThan(elapsed, 3.5)
        XCTAssertLessThan(elapsed, 5)
    }
}
