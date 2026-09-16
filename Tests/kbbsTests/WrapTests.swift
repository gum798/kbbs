import XCTest

@testable import kbbs

/// Message bodies wrap into the 57-cell body column. Korean breaks anywhere — there are
/// no spaces to break on in a run of Hangul — while Latin prefers a space, because
/// breaking mid-word reads as a typo rather than as a wrap.
final class WrapTests: XCTestCase {

    private func widths(_ lines: [String]) -> [Int] { lines.map { Width.cells($0) } }

    func testTextThatFitsIsOneLine() {
        XCTAssertEqual(Width.wrap("안녕하세요", to: 20), ["안녕하세요"])
    }

    func testNoLineExceedsTheBudget() {
        let long = String(repeating: "가", count: 60)
        for width in widths(Width.wrap(long, to: 20)) {
            XCTAssertLessThanOrEqual(width, 20)
        }
    }

    func testAWideCellIsNeverSplitDownTheMiddle() {
        // 20 cells is 10 Hangul syllables exactly; 21 must not cut one in half.
        let lines = Width.wrap(String(repeating: "가", count: 11), to: 21)
        XCTAssertEqual(lines.first, String(repeating: "가", count: 10))
    }

    func testHangulBreaksWithoutNeedingASpace() {
        let lines = Width.wrap(String(repeating: "한", count: 30), to: 10)
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines.allSatisfy { Width.cells($0) == 10 })
    }

    func testLatinPrefersToBreakAtASpace() {
        let lines = Width.wrap("hello wonderful world", to: 12)
        XCTAssertEqual(lines[0], "hello")
        XCTAssertEqual(lines[1], "wonderful")
    }

    /// A Latin word longer than the whole column has nowhere to break, so it breaks
    /// anyway rather than overflowing.
    func testAnUnbreakableLatinWordIsCutRatherThanOverflowing() {
        let lines = Width.wrap("supercalifragilistic", to: 8)
        XCTAssertTrue(lines.allSatisfy { Width.cells($0) <= 8 })
        XCTAssertEqual(lines.joined(), "supercalifragilistic")
    }

    func testMixedKoreanAndLatinStaysInBudget() {
        let text = "내일 강남역 11번 출구 meeting at 11am 괜찮으세요?"
        for width in widths(Width.wrap(text, to: 15)) {
            XCTAssertLessThanOrEqual(width, 15)
        }
    }

    func testACombiningMarkStaysWithItsBase() {
        let lines = Width.wrap("e\u{0301}" + String(repeating: "a", count: 10), to: 5)
        XCTAssertTrue(lines[0].hasPrefix("e\u{0301}"), "the accent was orphaned: \(lines)")
    }

    func testAnEmptyBodyIsOneEmptyLine() {
        XCTAssertEqual(Width.wrap("", to: 10), [""])
    }

    func testLeadingSpacesOnAWrappedLineAreDropped() {
        let lines = Width.wrap("hello wonderful world", to: 12)
        XCTAssertFalse(lines.contains { $0.hasPrefix(" ") }, "\(lines)")
    }
}
