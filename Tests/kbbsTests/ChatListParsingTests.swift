import XCTest

@testable import kbbs

/// The badge and the timestamp are read out of nodes the scan already visits and
/// currently throws away. Parsing them is pure; finding them is not, and is verified
/// against the real app instead.
final class ChatListParsingTests: XCTestCase {

    func testNumericRoomTitlesAreNotDiscardedAsUnreadCounts() {
        for title in ["16", "18", "01", "09", "0"] {
            XCTAssertTrue(ChatTextNormalizer.isTitleText(title, identifier: "_NS:40"), title)
        }
    }

    func testMetadataCannotBecomeARoomTitle() {
        XCTAssertFalse(ChatTextNormalizer.isTitleText("2", identifier: "Count Label"))
        XCTAssertFalse(ChatTextNormalizer.isTitleText("오전 10:43", identifier: "_NS:69"))
        XCTAssertFalse(ChatTextNormalizer.isTitleText("16", identifier: nil))
        XCTAssertTrue(ChatTextNormalizer.isTitleText("테스트방", identifier: nil))
    }

    func testNumericRoomTitleIsNotAnUnreadBadgeWhenBadgeIsAbsent() {
        XCTAssertNil(ChatTextNormalizer.unreadCount(from: "16", identifier: "_NS:40"))
        XCTAssertEqual(ChatTextNormalizer.unreadCount(from: "2", identifier: "Count Label"), 2)
        XCTAssertEqual(ChatTextNormalizer.unreadCount(from: "3", identifier: nil), 3)
    }

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
    // MARK: - Time labels as KakaoTalk actually writes them

    /// KakaoTalk writes today's rooms as "오후 1:21", not "13:21". The parser only
    /// understood a bare H:MM, so every room from today came back with no timestamp and
    /// the 시각 column was blank for the whole top of the list, while 어제/N일 rows below
    /// it were filled in. Observed on a real chat list.
    func testAfternoonTimeIsATime() {
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("오후 1:21"))
    }

    func testMorningTimeIsATime() {
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("오전 11:05"))
    }

    func testTwentyFourHourTimeIsStillATime() {
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("13:37"))
    }

    func testYesterdayAndDayCountsAreStillTimes() {
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("어제"))
        XCTAssertTrue(ChatTextNormalizer.isTimeLikeValue("3일"))
    }

    func testAMeridiemWordOnItsOwnIsNotATime() {
        XCTAssertFalse(ChatTextNormalizer.isTimeLikeValue("오후"))
    }

    func testASentenceMentioningAnHourIsNotATime() {
        XCTAssertFalse(ChatTextNormalizer.isTimeLikeValue("오후에 봐요"))
    }

    // MARK: - Fitting a timestamp into five cells

    /// The 시각 column is 5 cells, which is what "21:03" and "어제" need. KakaoTalk hands
    /// over "오후 1:21" — nine cells — so the column showed the word 오후 and nothing
    /// else, on every room from today. The BBS form is 24-hour.
    func testAfternoonBecomesTwentyFourHour() {
        XCTAssertEqual(ChatTextNormalizer.compactTime("오후 1:21"), "13:21")
    }

    func testMorningKeepsItsHour() {
        XCTAssertEqual(ChatTextNormalizer.compactTime("오전 11:05"), "11:05")
    }

    func testNoonStaysTwelve() {
        XCTAssertEqual(ChatTextNormalizer.compactTime("오후 12:00"), "12:00")
    }

    func testMidnightIsZero() {
        XCTAssertEqual(ChatTextNormalizer.compactTime("오전 12:30"), "00:30")
    }

    func testAlreadyTwentyFourHourIsLeftAlone() {
        XCTAssertEqual(ChatTextNormalizer.compactTime("13:37"), "13:37")
    }

    func testADayLabelIsNotATime() {
        XCTAssertEqual(ChatTextNormalizer.compactTime("어제"), "어제")
        XCTAssertEqual(ChatTextNormalizer.compactTime("3일"), "3일")
    }

    func testEveryCompactedTimeFitsTheColumn() {
        for value in ["오후 1:21", "오전 11:05", "오후 12:00", "오전 12:30", "13:37", "어제", "3일"] {
            XCTAssertLessThanOrEqual(Width.cells(ChatTextNormalizer.compactTime(value)), 5, value)
        }
    }

}
