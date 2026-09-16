import XCTest

@testable import kbbs

/// The whole product is a fixed 80-cell grid drawn with box characters. If a string's
/// display width is computed wrong by even one cell, the right border walks and every
/// frame below it is ragged. Korean text is the common case here, not the edge case.
final class WidthTests: XCTestCase {

    // MARK: - The two cases that matter most

    func testHangulSyllableIsTwoCells() {
        XCTAssertEqual(Width.cells("가"), 2)
    }

    func testAsciiIsOneCell() {
        XCTAssertEqual(Width.cells("a"), 1)
    }

    func testMixedKoreanAndAscii() {
        // 김민수 = 6, space = 1, "ok" = 2
        XCTAssertEqual(Width.cells("김민수 ok"), 9)
    }

    func testEmptyStringIsZero() {
        XCTAssertEqual(Width.cells(""), 0)
    }

    // MARK: - Hangul that is not a precomposed syllable

    func testCompatibilityJamoIsTwoCells() {
        // "ㅋㅋㅋ" is U+314B x3 from the Hangul Compatibility Jamo block, not syllables.
        // It is the single most common thing in Korean chat and it is NOT in the
        // AC00-D7A3 syllable range, so a table that only covers syllables gets it wrong.
        XCTAssertEqual(Width.cells("ㅋㅋㅋ"), 6)
    }

    func testConjoiningJamoIsTwoCells() {
        // U+1100 HANGUL CHOSEONG KIYEOK — the leading-jamo block used by decomposed
        // Hangul, which macOS filesystems and some IMEs produce.
        XCTAssertEqual(Width.cells("\u{1100}"), 2)
    }

    // MARK: - Other wide text that appears in Korean chat

    func testCJKIdeographIsTwoCells() {
        XCTAssertEqual(Width.cells("漢"), 2)
    }

    func testFullwidthPunctuationIsTwoCells() {
        // U+FF01 FULLWIDTH EXCLAMATION MARK
        XCTAssertEqual(Width.cells("！"), 2)
    }

    func testIdeographicSpaceIsTwoCells() {
        XCTAssertEqual(Width.cells("\u{3000}"), 2)
    }

    // MARK: - Zero-width and combining

    func testCombiningMarkIsZeroCells() {
        // "e" + U+0301 COMBINING ACUTE ACCENT is one grapheme cluster, one cell.
        XCTAssertEqual(Width.cells("e\u{0301}"), 1)
    }

    func testZeroWidthJoinerIsZeroCells() {
        XCTAssertEqual(Width.cells("\u{200D}"), 0)
    }

    // MARK: - Control characters never advance the cursor

    func testControlCharactersAreZeroCells() {
        XCTAssertEqual(Width.cells("\u{0007}"), 0)
        XCTAssertEqual(Width.cells("\n"), 0)
    }

    // MARK: - Ambiguous width is configurable, because the terminal decides

    func testAmbiguousDefaultsToNarrow() {
        // U+25B6 BLACK RIGHT-POINTING TRIANGLE — the list cursor. East Asian Ambiguous.
        // Most terminals render it in one cell; CJK-configured ones use two. The boot
        // probe measures the truth; until it reports, we assume narrow.
        XCTAssertEqual(Width.cells("▶"), 1)
    }

    func testAmbiguousHonoursWideSetting() {
        var w = Width()
        w.ambiguousIsWide = true
        XCTAssertEqual(w.width(of: "▶"), 2)
        XCTAssertEqual(w.width(of: "●"), 2)
    }

    func testAmbiguousSettingDoesNotAffectUnambiguousText() {
        var w = Width()
        w.ambiguousIsWide = true
        XCTAssertEqual(w.width(of: "가"), 2)
        XCTAssertEqual(w.width(of: "a"), 1)
    }

    // MARK: - Box drawing must stay narrow or every frame breaks

    func testBoxDrawingIsOneCellByDefault() {
        // These are Ambiguous too, which is exactly why the probe exists: if the
        // terminal renders them wide, an 80-cell frame drawn with them is 160 cells.
        for glyph in ["╔", "═", "╗", "║", "╚", "╝", "╠", "╣", "─", "│", "┌", "┐", "└", "┘"] {
            XCTAssertEqual(Width.cells(glyph), 1, "expected \(glyph) to measure 1 cell")
        }
    }

    // MARK: - Truncation is what the width table is actually for

    func testTruncateLeavesShortStringsAlone() {
        XCTAssertEqual(Width.truncate("김민수", to: 10), "김민수")
    }

    func testTruncateCutsOnCellsNotCharacters() {
        // 6 cells of Hangul into a 4-cell budget: two syllables fit, the third does not.
        XCTAssertEqual(Width.truncate("김민수", to: 4), "김민")
    }

    func testTruncateNeverSplitsAWideGlyphInHalf() {
        // A 5-cell budget cannot hold 3 syllables (6 cells), and half a syllable is not
        // a thing, so the result is 4 cells and the caller pads the spare column.
        let out = Width.truncate("김민수", to: 5)
        XCTAssertEqual(out, "김민")
        XCTAssertLessThanOrEqual(Width.cells(out), 5)
    }

    func testTruncateToZeroIsEmpty() {
        XCTAssertEqual(Width.truncate("김민수", to: 0), "")
    }

    func testTruncateKeepsGraphemeClustersIntact() {
        let out = Width.truncate("e\u{0301}abc", to: 2)
        XCTAssertEqual(out, "e\u{0301}a")
    }

    // MARK: - Padding is the other half: every frame line must be exactly 80 cells

    func testPadFillsToExactCellCount() {
        XCTAssertEqual(Width.pad("김민수", to: 10), "김민수    ")
        XCTAssertEqual(Width.cells(Width.pad("김민수", to: 10)), 10)
    }

    func testPadTruncatesWhenTooLong() {
        XCTAssertEqual(Width.cells(Width.pad("김민수 개발팀 회의", to: 8)), 8)
    }

    func testPadAddsOneSpareColumnWhenAWideGlyphWouldNotFit() {
        // 5-cell field, 6-cell content: truncates to 4 cells then pads 1 space.
        let out = Width.pad("김민수", to: 5)
        XCTAssertEqual(out, "김민 ")
        XCTAssertEqual(Width.cells(out), 5)
    }
}

extension WidthTests {
    // MARK: - Eliding, so a cut name reads as cut rather than as a different name

    func testElideLeavesShortTextAlone() {
        XCTAssertEqual(Width.elide("김민수", to: 10), "김민수")
    }

    func testElideLeavesExactlyFittingTextAlone() {
        XCTAssertEqual(Width.elide("김민수", to: 6), "김민수")
    }

    func testElideMarksTruncatedText() {
        let out = Width.elide("고등학교 3학년 2반 동창회", to: 18)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertLessThanOrEqual(Width.cells(out), 18)
    }

    func testElideNeverExceedsTheLimit() {
        for limit in 1...30 {
            XCTAssertLessThanOrEqual(Width.cells(Width.elide("가나다라마바사아자차", to: limit)), limit)
        }
    }

    func testElideToZeroIsEmpty() {
        XCTAssertEqual(Width.elide("김민수", to: 0), "")
    }

    func testElideIntoASingleCellIsJustTheMarker() {
        XCTAssertEqual(Width.elide("김민수", to: 1), "…")
    }
    // MARK: - Emoji outside the astral planes (seen in a real chat list)

    /// A room named "윤지원✨" made its row 81 cells wide. U+2728 lives in Dingbats, not
    /// in the 1F300-1FAFF block the table covered, so it was counted as one cell while
    /// every terminal draws it as two — and the right border walked on that row alone.
    func testSparklesIsTwoCells() {
        XCTAssertEqual(Width.cells("\u{2728}"), 2)
    }

    func testANameEndingInAnEmojiMeasuresCorrectly() {
        XCTAssertEqual(Width.cells("윤지원\u{2728}"), 8)
    }

    func testWatchAndHourglassAreTwoCells() {
        XCTAssertEqual(Width.cells("\u{231A}"), 2)
        XCTAssertEqual(Width.cells("\u{231B}"), 2)
    }

    func testRedHeartWithEmojiPresentationIsTwoCells() {
        XCTAssertEqual(Width.cells("\u{2764}\u{FE0F}"), 2)
    }

    func testTheSameHeartWithTextPresentationStaysNarrow() {
        XCTAssertEqual(Width.cells("\u{2764}\u{FE0E}"), 1)
    }

}
