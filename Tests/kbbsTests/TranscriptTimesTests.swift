import XCTest

@testable import kbbs

/// KakaoTalk stamps the LAST message of a consecutive run, not the first. So a message
/// with no stamp of its own belongs to the time printed BELOW it, and filling downward —
/// which is what the reader used to do — dated it from a run that had already ended.
final class TranscriptTimesTests: XCTestCase {

    func testAMessageTakesTheStampBelowIt() {
        XCTAssertEqual(
            TranscriptTimes.fill([nil, nil, "16:03", nil, "16:09"]),
            ["16:03", "16:03", "16:03", "16:09", "16:09"]
        )
    }

    /// Read top to bottom, a message can never be earlier than the one above it.
    func testTimesNeverGoBackwards() {
        let filled = TranscriptTimes.fill(["16:07", nil, "16:03", nil, "16:19"]).compactMap { $0 }
        XCTAssertEqual(filled, ["16:07", "16:03", "16:03", "16:19", "16:19"])
    }

    /// Nothing below to inherit from: the last stamp seen above is the best available.
    func testTrailingMessagesKeepTheLastStamp() {
        XCTAssertEqual(
            TranscriptTimes.fill(["16:03", nil, nil]),
            ["16:03", "16:03", "16:03"]
        )
    }

    func testWithNoStampsAtAllNothingIsInvented() {
        XCTAssertEqual(TranscriptTimes.fill([nil, nil]), [nil, nil])
    }

    func testAnEmptyTranscript() {
        XCTAssertEqual(TranscriptTimes.fill([]), [])
    }

    func testEveryMessageStampedIsLeftAlone() {
        XCTAssertEqual(
            TranscriptTimes.fill(["16:01", "16:02", "16:03"]),
            ["16:01", "16:02", "16:03"]
        )
    }
}
