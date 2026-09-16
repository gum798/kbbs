import XCTest

@testable import kbbs

/// The decoder turns bytes off the tty into keys. It never reads the clock and never
/// reads a file descriptor, so every case here is exact: feed bytes, read keys out.
///
/// The cases that matter are the ones where a key arrives in pieces. A `read(2)` can
/// split a Hangul syllable down the middle or hand over an arrow key one byte at a time,
/// and a decoder that forgets between calls turns 가 into three pieces of garbage.
final class KeysTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: - Plain text

    func testAsciiArrivesAsItself() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed(bytes("a")), [.char("a")])
    }

    func testAWholeHangulSyllable() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed(bytes("가")), [.char("가")])
    }

    func testAHangulSyllableSplitAcrossThreeReads() {
        var d = KeyDecoder()
        let b = bytes("가")
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(d.feed([b[0]]), [])
        XCTAssertEqual(d.feed([b[1]]), [])
        XCTAssertEqual(d.feed([b[2]]), [.char("가")])
    }

    func testAFourByteEmojiSplitInHalf() {
        var d = KeyDecoder()
        let b = bytes("🙂")
        XCTAssertEqual(b.count, 4)
        XCTAssertEqual(d.feed(Array(b[0..<2])), [])
        XCTAssertEqual(d.feed(Array(b[2..<4])), [.char("🙂")])
    }

    func testAWholeWordPastedInOneRead() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed(bytes("안녕")), [.char("안"), .char("녕")])
    }

    // MARK: - Control keys

    func testCarriageReturnIsEnter() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x0D]), [.enter])
    }

    func testLineFeedIsAlsoEnter() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x0A]), [.enter])
    }

    func testDeleteIsBackspace() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x7F]), [.backspace])
    }

    func testBackspaceByteIsBackspace() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x08]), [.backspace])
    }

    func testTab() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x09]), [.tab])
    }

    func testControlC() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x03]), [.control("c")])
    }

    func testControlL() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x0C]), [.control("l")])
    }

    // MARK: - Arrows and navigation

    func testCSIArrows() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B, 0x5B, 0x41]), [.up])
        XCTAssertEqual(d.feed([0x1B, 0x5B, 0x42]), [.down])
        XCTAssertEqual(d.feed([0x1B, 0x5B, 0x43]), [.right])
        XCTAssertEqual(d.feed([0x1B, 0x5B, 0x44]), [.left])
    }

    /// Application cursor mode sends ESC O A rather than ESC [ A. tmux does this.
    func testSS3Arrows() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B, 0x4F, 0x41]), [.up])
        XCTAssertEqual(d.feed([0x1B, 0x4F, 0x42]), [.down])
    }

    func testAnArrowSplitOneByteAtATime() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])
        XCTAssertEqual(d.feed([0x5B]), [])
        XCTAssertEqual(d.feed([0x41]), [.up])
    }

    func testPageKeys() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed(Array("\u{1B}[5~".utf8)), [.pageUp])
        XCTAssertEqual(d.feed(Array("\u{1B}[6~".utf8)), [.pageDown])
    }

    func testHomeAndEndInBothSpellings() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed(Array("\u{1B}[H".utf8)), [.home])
        XCTAssertEqual(d.feed(Array("\u{1B}[F".utf8)), [.end])
        XCTAssertEqual(d.feed(Array("\u{1B}[1~".utf8)), [.home])
        XCTAssertEqual(d.feed(Array("\u{1B}[4~".utf8)), [.end])
    }

    /// A sequence the decoder does not know is consumed whole rather than spilling its
    /// bytes into the number buffer as digits.
    func testAnUnknownSequenceIsSwallowed() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed(Array("\u{1B}[200~".utf8)), [])
        XCTAssertEqual(d.feed(bytes("a")), [.char("a")])
    }

    // MARK: - The lone Escape

    /// Esc is both a key and the first byte of every arrow. The decoder cannot tell
    /// which until either more bytes arrive or enough time passes, so it holds the Esc
    /// and the loop decides — `feed` never guesses.
    func testALoneEscapeIsHeldUntilTheLoopGivesUpOnIt() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])
        XCTAssertEqual(d.flushPendingEscape(), [.escape])
    }

    func testFlushingWithNothingPendingYieldsNothing() {
        var d = KeyDecoder()
        XCTAssertEqual(d.flushPendingEscape(), [])
    }

    func testAnEscapeThatTurnedOutToBeAnArrowIsNotAlsoAnEscape() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])
        XCTAssertEqual(d.feed([0x5B, 0x41]), [.up])
        XCTAssertEqual(d.flushPendingEscape(), [])
    }

    func testEscapeFollowedByAnOrdinaryCharacterEmitsBoth() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])
        XCTAssertEqual(d.feed(bytes("a")), [.escape, .char("a")])
    }

    func testTwoEscapesInOneRead() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B, 0x1B]), [.escape])
        XCTAssertEqual(d.flushPendingEscape(), [.escape])
    }

    // MARK: - Malformed input

    func testAnInvalidByteIsDroppedWithoutEatingWhatFollows() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0xFF] + bytes("a")), [.char("a")])
    }

    func testATruncatedSyllableFollowedByAsciiDoesNotSwallowTheAscii() {
        var d = KeyDecoder()
        let b = bytes("가")
        XCTAssertEqual(d.feed([b[0], b[1]]), [])
        XCTAssertEqual(d.feed(bytes("a")), [.char("a")])
    }
    /// The loop has to know whether an Esc is being held, so it can start the clock on
    /// it. Asking the decoder is how it avoids keeping a second copy of that state.
    func testTheDecoderSaysWhenItIsHoldingAnEscape() {
        var d = KeyDecoder()
        XCTAssertFalse(d.hasPendingEscape)
        _ = d.feed([0x1B])
        XCTAssertTrue(d.hasPendingEscape)
        _ = d.feed([0x5B, 0x41])
        XCTAssertFalse(d.hasPendingEscape)
    }

    func testAnOrdinaryKeyLeavesNothingPending() {
        var d = KeyDecoder()
        _ = d.feed(bytes("a"))
        XCTAssertFalse(d.hasPendingEscape)
    }

}
