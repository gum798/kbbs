import XCTest

@testable import kbbs

/// The probe itself needs a terminal, but the part that can be wrong quietly — reading
/// the terminal's answer back — is a pure function over bytes.
final class WidthProbeTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testAPlainCursorReport() {
        XCTAssertEqual(WidthProbe.parseColumn(bytes("\u{1B}[1;3R")), 3)
    }

    func testATwoDigitColumn() {
        XCTAssertEqual(WidthProbe.parseColumn(bytes("\u{1B}[24;80R")), 80)
    }

    /// The report can arrive behind whatever else the terminal felt like sending.
    func testARepordPrecededByNoise() {
        XCTAssertEqual(WidthProbe.parseColumn(bytes("junk\u{1B}[1;2R")), 2)
    }

    func testAnIncompleteReportIsNotAnAnswerYet() {
        XCTAssertNil(WidthProbe.parseColumn(bytes("\u{1B}[1;3")))
        XCTAssertNil(WidthProbe.parseColumn(bytes("\u{1B}[")))
        XCTAssertNil(WidthProbe.parseColumn([]))
    }

    func testSomethingThatIsNotAReportAtAll() {
        XCTAssertNil(WidthProbe.parseColumn(bytes("hello")))
        XCTAssertNil(WidthProbe.parseColumn(bytes("\u{1B}[1R")))
    }

    /// A key pressed during the probe arrives on the same descriptor. The report is the
    /// last one in the buffer, not the first thing that looks like an escape.
    func testTheLastReportWins() {
        XCTAssertEqual(WidthProbe.parseColumn(bytes("\u{1B}[1;2R\u{1B}[1;5R")), 5)
    }
}
