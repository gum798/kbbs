import XCTest

@testable import kbbs

/// The badge and the timestamp are read out of nodes the scan already visits and
/// currently throws away. Parsing them is pure; finding them is not, and is verified
/// against the real app instead.
final class ChatListParsingTests: XCTestCase {

    // MARK: - Unread badge

    func testPlainCountParses() {
        XCTAssertEqual(ChatTextNormalizer.unreadCount(from: "3"), 3)
        XCTAssertEqual(ChatTextNormalizer.unreadCount(from: "14"), 14)
    }

    func testCountWithThousandsSeparatorParses() {
        XCTAssertEqual(ChatTextNormalizer.unreadCount(from: "1,234"), 1234)
    }

    func testCappedCountParsesToItsFloor() {
        // KakaoTalk shows "999+" once a room passes the cap. The real number is unknown
        // and unknowable from the badge, so the floor is the honest reading.
        XCTAssertEqual(ChatTextNormalizer.unreadCount(from: "999+"), 999)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(ChatTextNormalizer.unreadCount(from: "  7 "), 7)
    }

    func testNonCountTextIsNotACount() {
        XCTAssertNil(ChatTextNormalizer.unreadCount(from: "어제"))
        XCTAssertNil(ChatTextNormalizer.unreadCount(from: "21:03"))
        XCTAssertNil(ChatTextNormalizer.unreadCount(from: "김민수"))
        XCTAssertNil(ChatTextNormalizer.unreadCount(from: ""))
        XCTAssertNil(ChatTextNormalizer.unreadCount(from: "+"))
    }

    func testZeroIsNotAnUnreadCount() {
        // A room with nothing unread has no badge; a literal "0" is something else.
        XCTAssertNil(ChatTextNormalizer.unreadCount(from: "0"))
    }

    // MARK: - Time label, using the filter that already exists

    func testClockTimesAreTimeLike() {
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("21:03"))
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("9:07"))
    }

    func testRelativeKoreanDatesAreTimeLike() {
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("어제"))
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("그저께"))
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("3일"))
    }

    func testOrdinaryMessagesAreNotTimeLike() {
        XCTAssertFalse(ChatTextNormalizer.isTimeLikeValue("내일 몇 시에 봐요?"))
        XCTAssertFalse(ChatTextNormalizer.isTimeLikeValue("ㅋㅋㅋ"))
    }
}
