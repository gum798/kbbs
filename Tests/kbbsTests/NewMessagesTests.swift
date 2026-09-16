import XCTest

@testable import kbbs

/// Which of the messages on screen arrived while you were sitting there.
final class NewMessagesTests: XCTestCase {

    private func m(_ body: String) -> TranscriptMessage {
        TranscriptMessage(author: nil, timeRaw: "21:01", body: body, isSystem: false, logicalTimestamp: nil)
    }

    func testNothingIsNewOnTheFirstRead() {
        XCTAssertEqual(NewMessages.count(previous: [], current: [m("가"), m("나")], carried: 0), 0)
    }

    func testAnArrivalCounts() {
        let before = [m("가")]
        XCTAssertEqual(NewMessages.count(previous: before, current: before + [m("나")], carried: 0), 1)
    }

    func testArrivalsAccumulateWhileYouWatch() {
        let one = [m("가")]
        let two = one + [m("나")]
        XCTAssertEqual(NewMessages.count(previous: two, current: two + [m("다")], carried: 1), 2)
    }

    func testNothingChangedMeansNothingNew() {
        let same = [m("가"), m("나")]
        XCTAssertEqual(NewMessages.count(previous: same, current: same, carried: 2), 2)
    }

    /// The window holds a fixed number of messages, so an arrival can push an old one off
    /// the top and leave the count unchanged.
    func testAnArrivalThatPushedAnOldMessageOffStillCounts() {
        let before = [m("가"), m("나")]
        let after = [m("나"), m("다")]
        XCTAssertEqual(NewMessages.count(previous: before, current: after, carried: 0), 1)
    }

    func testTheCountNeverExceedsWhatIsOnScreen() {
        let two = [m("가"), m("나")]
        XCTAssertEqual(NewMessages.count(previous: two, current: two, carried: 99), 2)
    }
}
