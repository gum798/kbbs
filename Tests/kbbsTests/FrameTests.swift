import XCTest

@testable import kbbs

/// A frame is a fixed grid: exactly 24 rows of exactly 80 cells, always, whatever is
/// written into it. Every guarantee the HiTEL layout depends on is enforced here rather
/// than trusted to each screen composer.
final class FrameTests: XCTestCase {

    private func cells(_ s: String) -> Int {
        Width.cells(Frame.stripANSI(s))
    }

    // MARK: - Shape

    func testBlankFrameIsExactlyTwentyFourRows() {
        XCTAssertEqual(Frame().render().count, 24)
    }

    func testEveryBlankRowIsExactlyEightyCells() {
        for row in Frame().render() {
            XCTAssertEqual(cells(row), 80)
        }
    }

    func testCustomSizeIsHonoured() {
        let f = Frame(width: 40, height: 3)
        let rows = f.render()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(cells(rows[0]), 40)
    }

    // MARK: - Writing

    func testShortTextIsPaddedToFullWidth() {
        var f = Frame()
        f.set(0, "안녕")
        XCTAssertEqual(cells(f.render()[0]), 80)
        XCTAssertTrue(f.render()[0].hasPrefix("안녕"))
    }

    func testOverlongTextIsTruncatedToExactlyEightyCells() {
        var f = Frame()
        f.set(0, String(repeating: "김", count: 60))  // 120 cells of Hangul
        XCTAssertEqual(cells(f.render()[0]), 80)
    }

    func testTruncationNeverSplitsAWideGlyph() {
        var f = Frame(width: 5, height: 1)
        f.set(0, "김민수")  // 6 cells into 5
        XCTAssertEqual(f.render()[0], "김민 ")
    }

    func testWritingOutsideTheFrameIsIgnored() {
        var f = Frame(width: 10, height: 2)
        f.set(5, "nope")
        f.set(-1, "nope")
        XCTAssertEqual(f.render().count, 2)
        XCTAssertEqual(f.render()[0].trimmingCharacters(in: .whitespaces), "")
    }

    func testLaterWriteReplacesEarlierOne() {
        var f = Frame()
        f.set(3, "first")
        f.set(3, "second")
        XCTAssertTrue(f.render()[3].hasPrefix("second"))
        XCTAssertFalse(f.render()[3].contains("first"))
    }

    // MARK: - ANSI escapes are colour, not content

    func testSGRSequencesDoNotConsumeCells() {
        var f = Frame()
        f.set(0, "\u{1B}[7m안녕\u{1B}[0m")
        // Two Hangul syllables = 4 cells, so 76 spaces of padding, not 76 minus the
        // length of the escape sequences.
        XCTAssertEqual(cells(f.render()[0]), 80)
        XCTAssertTrue(f.render()[0].contains("\u{1B}[7m"))
    }

    func testStripANSIRemovesOnlyTheEscapes() {
        XCTAssertEqual(Frame.stripANSI("\u{1B}[7m안녕\u{1B}[0m"), "안녕")
        XCTAssertEqual(Frame.stripANSI("plain"), "plain")
        XCTAssertEqual(Frame.stripANSI("\u{1B}[38;5;226mA\u{1B}[m"), "A")
    }

    func testTruncationCountsCellsNotEscapeBytes() {
        var f = Frame(width: 4, height: 1)
        f.set(0, "\u{1B}[7m가나다\u{1B}[0m")  // 6 cells into 4
        XCTAssertEqual(cells(f.render()[0]), 4)
    }

    // MARK: - Composing a bordered row, the thing every screen does

    func testBorderedRowIsExactlyEightyCells() {
        let row = Frame.bordered(" 김민수", left: "║", right: "║", width: 80)
        XCTAssertEqual(cells(row), 80)
        XCTAssertTrue(row.hasPrefix("║"))
        XCTAssertTrue(row.hasSuffix("║"))
    }

    func testBorderedRowTruncatesContentToFit() {
        let row = Frame.bordered(String(repeating: "가", count: 60), left: "║", right: "║", width: 80)
        XCTAssertEqual(cells(row), 80)
        XCTAssertTrue(row.hasSuffix("║"))
    }

    func testRuleFillsBetweenCorners() {
        let rule = Frame.rule(left: "╔", fill: "═", right: "╗", width: 80)
        XCTAssertEqual(cells(rule), 80)
        XCTAssertTrue(rule.hasPrefix("╔"))
        XCTAssertTrue(rule.hasSuffix("╗"))
        XCTAssertEqual(rule.filter { $0 == "═" }.count, 78)
    }

    func testRuleCanCarryACentredTitle() {
        let rule = Frame.rule(left: "╔", fill: "═", right: "╗", width: 40, title: " 접 속 ")
        XCTAssertEqual(cells(rule), 40)
        XCTAssertTrue(rule.contains("접 속"))
    }

    // MARK: - The invariant the whole UI rests on

    func testEveryRowOfAFullyPopulatedFrameIsEightyCells() {
        var f = Frame()
        f.set(0, Frame.rule(left: "╔", fill: "═", right: "╗", width: 80))
        f.set(1, Frame.bordered("  K B B S   카카오톡 통신", left: "║", right: "║", width: 80))
        f.set(2, Frame.rule(left: "╠", fill: "═", right: "╣", width: 80))
        f.set(3, Frame.bordered(" ▶ 1. * 김민수  내일 몇 시에 봐요?  ㅋㅋㅋ 漢 ！", left: "║", right: "║", width: 80))
        f.set(23, Frame.rule(left: "╚", fill: "═", right: "╝", width: 80))
        for (i, row) in f.render().enumerated() {
            XCTAssertEqual(cells(row), 80, "row \(i) is not 80 cells")
        }
    }
}
