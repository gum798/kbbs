import XCTest

@testable import kbbs

/// Pressing 전송 does not prove a message was sent. The button returns success for
/// having been pressed, which is a different claim. The only evidence that counts is
/// seeing the message come back out of KakaoTalk's own transcript on a later read.
///
/// So every send becomes a pending echo, drawn on screen as [전송중], and it stays that
/// way until the transcript shows it. If it never does it becomes [미확인] — which is
/// deliberately biased: a false [미확인] costs a moment of doubt, a false ✓ costs a
/// message the user believes they sent.
final class PendingLedgerTests: XCTestCase {

    private func message(_ body: String) -> TranscriptMessage {
        TranscriptMessage(author: nil, timeRaw: "21:01", body: body, isSystem: false, logicalTimestamp: nil)
    }

    func testAMessageThatComesBackIsConfirmed() {
        var ledger = PendingLedger()
        ledger.add(body: "안녕", transcript: [])
        ledger.reconcile(against: [message("안녕")], now: Date())
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func testAMessageThatHasNotComeBackIsStillPending() {
        var ledger = PendingLedger()
        ledger.add(body: "안녕", transcript: [])
        ledger.reconcile(against: [], now: Date())
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].state, .sending)
    }

    /// The transcript already held one "ㅋㅋ" before this send. Seeing that same one
    /// again is not evidence; a second one is.
    func testAnIdenticalMessageAlreadyInTheTranscriptIsNotEvidence() {
        var ledger = PendingLedger()
        let before = [message("ㅋㅋ")]
        ledger.add(body: "ㅋㅋ", transcript: before)
        ledger.reconcile(against: before, now: Date())
        XCTAssertEqual(ledger.entries.count, 1, "an old copy confirmed a new send")

        ledger.reconcile(against: [message("ㅋㅋ"), message("ㅋㅋ")], now: Date())
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func testTwoSendsOfTheSameTextNeedTwoMessagesBack() {
        var ledger = PendingLedger()
        ledger.add(body: "ㅇㅇ", transcript: [])
        ledger.add(body: "ㅇㅇ", transcript: [message("ㅇㅇ")])
        XCTAssertEqual(ledger.entries.count, 2)

        ledger.reconcile(against: [message("ㅇㅇ")], now: Date())
        XCTAssertEqual(ledger.entries.count, 1, "one message back should clear only one send")

        ledger.reconcile(against: [message("ㅇㅇ"), message("ㅇㅇ")], now: Date())
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    /// Nine seconds is a guess, and it is biased on purpose: it would rather say it
    /// cannot tell than tell the user something went out when it did not know.
    func testAMessageThatNeverComesBackBecomesUnconfirmed() {
        var ledger = PendingLedger()
        let sent = Date()
        ledger.add(body: "안녕", transcript: [], now: sent)
        ledger.reconcile(against: [], now: sent.addingTimeInterval(10))
        XCTAssertEqual(ledger.entries.first?.state, .unconfirmed)
    }

    func testAnUnconfirmedMessageIsStillConfirmedIfItTurnsUpLate() {
        var ledger = PendingLedger()
        let sent = Date()
        ledger.add(body: "안녕", transcript: [], now: sent)
        ledger.reconcile(against: [], now: sent.addingTimeInterval(10))
        XCTAssertEqual(ledger.entries.first?.state, .unconfirmed)

        ledger.reconcile(against: [message("안녕")], now: sent.addingTimeInterval(20))
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func testEntriesKeepTheOrderTheyWereSentIn() {
        var ledger = PendingLedger()
        ledger.add(body: "먼저", transcript: [])
        ledger.add(body: "나중", transcript: [])
        XCTAssertEqual(ledger.entries.map(\.body), ["먼저", "나중"])
    }

    /// Whitespace KakaoTalk trims on its way in must not make a sent message look lost.
    func testTrailingWhitespaceDoesNotPreventAMatch() {
        var ledger = PendingLedger()
        ledger.add(body: "안녕 ", transcript: [])
        ledger.reconcile(against: [message("안녕")], now: Date())
        XCTAssertTrue(ledger.entries.isEmpty)
    }
}
