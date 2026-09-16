import XCTest

@testable import kbbs

/// Which side of the pane a bubble sits on — the only thing that says whether a message
/// is yours, because KakaoTalk does not name you as the sender of your own.
///
/// Every number here is measured from a real conversation: the pane is 380 wide, a
/// left-aligned bubble always sits 60 from the left edge, and a right-aligned one always
/// sits 35 from the right.
final class MessageSideTests: XCTestCase {

    private let pane = CGRect(x: 1384, y: 0, width: 380, height: 400)

    private func bubble(left: CGFloat, right: CGFloat) -> CGRect {
        CGRect(x: pane.minX + left, y: 0, width: pane.width - left - right, height: 30)
    }

    func testTheirShortMessage() {
        XCTAssertEqual(MessageSideGuess.of(bubble: bubble(left: 60, right: 186), in: pane), .left)
    }

    func testTheirLongMessage() {
        XCTAssertEqual(MessageSideGuess.of(bubble: bubble(left: 60, right: 138), in: pane), .left)
    }

    func testMyShortMessage() {
        XCTAssertEqual(MessageSideGuess.of(bubble: bubble(left: 323, right: 35), in: pane), .right)
    }

    /// The bug this replaces. Measured at left=80 right=35 — plainly mine, the right
    /// inset is the same 35 as every other message of mine — but its centre lands at
    /// ratio 0.559 and the old test called anything at or below 0.56 theirs. A long
    /// message of the user's own was displayed under the other person's name.
    func testMyLongMessageIsStillMine() {
        XCTAssertEqual(MessageSideGuess.of(bubble: bubble(left: 80, right: 35), in: pane), .right)
        XCTAssertEqual(MessageSideGuess.of(bubble: bubble(left: 86, right: 35), in: pane), .right)
        XCTAssertEqual(MessageSideGuess.of(bubble: bubble(left: 88, right: 35), in: pane), .right)
    }

    /// Inset from both edges by a similar amount: a date divider or a system notice.
    /// Saying nothing is the honest answer and it is what puts 나? on screen.
    func testSomethingCentredIsUnknown() {
        XCTAssertEqual(MessageSideGuess.of(bubble: bubble(left: 126, right: 143), in: pane), .unknown)
    }

    func testAFullWidthBubbleIsUnknown() {
        XCTAssertEqual(MessageSideGuess.of(bubble: bubble(left: 0, right: 0), in: pane), .unknown)
    }

    func testNoFramesMeansUnknown() {
        XCTAssertEqual(MessageSideGuess.of(bubble: nil, in: pane), .unknown)
        XCTAssertEqual(MessageSideGuess.of(bubble: bubble(left: 60, right: 186), in: nil), .unknown)
    }
}
