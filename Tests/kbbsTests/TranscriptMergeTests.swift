import XCTest

@testable import kbbs

/// The reader has two ways of getting messages out of a chat window: parsing rows, and
/// a fallback that sweeps the whole subtree when row parsing comes up short. Both lists
/// then had every duplicate removed from them — which is wrong, because in a Korean chat
/// the same message twice in a row is not a duplicate, it is how people talk.
final class TranscriptMergeTests: XCTestCase {

    private func message(
        _ body: String,
        author: String? = nil,
        time: String? = "13:20",
        y: Double? = nil
    ) -> TranscriptMessage {
        TranscriptMessage(
            author: author,
            timeRaw: time,
            body: body,
            isSystem: false,
            logicalTimestamp: nil,
            orderKey: y
        )
    }

    // MARK: - Real repeats survive

    /// Someone sends ㅋㅋ, then sends ㅋㅋ again. Two messages, same minute, same author,
    /// identical text — and the old fingerprint dedup silently made it one.
    func testTheSameMessageTwiceIsTwoMessages() {
        let rows = [message("ㅋㅋ"), message("ㅋㅋ")]
        XCTAssertEqual(TranscriptMerge.merge(rowMessages: rows, fallback: []).count, 2)
    }

    func testAThirdIdenticalMessageIsAlsoKept() {
        let rows = [message("ㅇㅇ"), message("ㅇㅇ"), message("ㅇㅇ")]
        XCTAssertEqual(TranscriptMerge.merge(rowMessages: rows, fallback: []).count, 3)
    }

    func testOrderIsPreserved() {
        let rows = [message("먼저"), message("나중")]
        XCTAssertEqual(TranscriptMerge.merge(rowMessages: rows, fallback: []).map(\.body), ["먼저", "나중"])
    }

    // MARK: - The fallback only fills gaps

    /// The fallback sweeps the same subtree, so it re-finds what the row parser already
    /// has. Those copies go; anything it found that the rows did not, stays.
    func testAFallbackCopyOfARowMessageIsDropped() {
        let rows = [message("안녕하세요")]
        let fallback = [message("안녕하세요"), message("반갑습니다")]
        let merged = TranscriptMerge.merge(rowMessages: rows, fallback: fallback)
        XCTAssertEqual(merged.map(\.body), ["안녕하세요", "반갑습니다"])
    }

    /// Two real 'ㅋㅋ' in the rows, and the fallback also sees them. The count must not
    /// collapse — the rows are authoritative for how many there are.
    func testTheFallbackCannotCollapseARealRepeatInTheRows() {
        let rows = [message("ㅋㅋ"), message("ㅋㅋ")]
        let fallback = [message("ㅋㅋ")]
        XCTAssertEqual(TranscriptMerge.merge(rowMessages: rows, fallback: fallback).count, 2)
    }

    /// And a repeat the fallback found twice, that the rows never saw at all, is kept as
    /// the fallback reported it.
    func testARepeatOnlyTheFallbackSawIsKept() {
        let fallback = [message("ㅋㅋ"), message("ㅋㅋ")]
        XCTAssertEqual(TranscriptMerge.merge(rowMessages: [], fallback: fallback).count, 2)
    }

    func testWithNoFallbackTheRowsComeBackUntouched() {
        let rows = [message("하나"), message("둘"), message("셋")]
        XCTAssertEqual(TranscriptMerge.merge(rowMessages: rows, fallback: []).map(\.body), ["하나", "둘", "셋"])
    }

    func testMessagesDifferingOnlyByAuthorAreBothKept() {
        let rows = [message("네", author: "김민수"), message("네", author: "이수진")]
        XCTAssertEqual(TranscriptMerge.merge(rowMessages: rows, fallback: []).count, 2)
    }
    // MARK: - Order

    /// Order is where KakaoTalk drew it, top to bottom — NOT the clock. A message from an
    /// earlier day carries a later time of day and still belongs above, which is exactly
    /// what a time sort got wrong on a real transcript.
    func testMessagesComeOutInScreenOrder() {
        let merged = TranscriptMerge.merge(
            rowMessages: [
                message("아래", y: 900),
                message("위", y: 100),
                message("가운데", y: 500),
            ],
            fallback: []
        )
        XCTAssertEqual(merged.map(\.body), ["위", "가운데", "아래"])
    }

    func testMessagesAtTheSameHeightKeepTheOrderTheyWereRead() {
        let merged = TranscriptMerge.merge(
            rowMessages: [message("먼저", y: 100), message("나중", y: 100)],
            fallback: []
        )
        XCTAssertEqual(merged.map(\.body), ["먼저", "나중"])
    }

    /// A row whose position could not be read belongs next to what it was found beside,
    /// not flung to one end.
    func testARowWithNoPositionStaysWhereItWasFound() {
        let merged = TranscriptMerge.merge(
            rowMessages: [message("위", y: 100), message("위치 없음"), message("아래", y: 500)],
            fallback: []
        )
        XCTAssertEqual(merged.map(\.body), ["위", "위치 없음", "아래"])
    }

    /// The bug this was found by: the fallback sweep picks up a message the row parser
    /// missed, and appending it blindly put a message from an earlier day underneath
    /// today's conversation.
    func testAFallbackExtraGoesWhereItWasOnScreen() {
        let merged = TranscriptMerge.merge(
            rowMessages: [message("아래", y: 900)],
            fallback: [message("위", y: 100)]
        )
        XCTAssertEqual(merged.map(\.body), ["위", "아래"])
    }
}

/// Who sent a message, and how sure the reader is about it.
///
/// KakaoTalk's tree does not name the sender of your own messages — the reader infers
/// the side from bubble geometry, and when that reading is unclear the old code returned
/// the same thing it returns for a confident "mine". The screen could not tell the two
/// apart, so an uncertain guess was displayed as fact.
final class TranscriptAttributionTests: XCTestCase {

    private func message(author: String?, side: String, source: String) -> TranscriptMessage {
        TranscriptMessage(
            author: author,
            timeRaw: "13:20",
            body: "본문",
            isSystem: false,
            logicalTimestamp: nil,
            side: side,
            authorSource: source
        )
    }

    func testANamedSenderIsShownByName() {
        let m = message(author: "김민수", side: "left", source: "explicit")
        XCTAssertEqual(TranscriptAttribution.label(for: m), .named("김민수"))
    }

    func testAConfidentRightHandBubbleIsMe() {
        let m = message(author: nil, side: "right", source: "default-me")
        XCTAssertEqual(TranscriptAttribution.label(for: m), .me)
    }

    /// The case the whole field exists for: the geometry read came back unknown, so the
    /// reader fell back to "me" without knowing it. The screen says so.
    func testAnUnknownSideIsAGuessAndIsMarkedAsOne() {
        let m = message(author: nil, side: "unknown", source: "default-me")
        XCTAssertEqual(TranscriptAttribution.label(for: m), .probablyMe)
    }

    func testAnUnresolvedLeftBubbleIsSomebodyElseButUnnamed() {
        let m = message(author: nil, side: "left", source: "left-unresolved")
        XCTAssertEqual(TranscriptAttribution.label(for: m), .unknown)
    }

    /// The fields are debug detail, not part of the JSON contract the reader already has.
    func testTheNewFieldsDoNotChangeTheEncodedShape() throws {
        let m = message(author: "김민수", side: "left", source: "explicit")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertNil(json?["side"])
        XCTAssertNil(json?["authorSource"])
        XCTAssertNil(json?["author_source"])
    }

}
