import XCTest

@testable import kbbs

/// The ladder writes through an injected closure, which is what makes it testable and
/// what lets the run loop send it to the real terminal after the alternate screen is
/// gone.
final class BootLadderTests: XCTestCase {

    private func capture(_ body: (BootLadder) -> Void) -> [String] {
        var lines: [String] = []
        let ladder = BootLadder(out: { lines.append($0) })
        body(ladder)
        return lines
    }

    /// Printed into the scrollback on the way out, after termios is back. It is the
    /// signal that kbbs let go of the terminal cleanly rather than crashing out of it.
    func testHangingUpSaysSo() {
        let lines = capture { $0.hangUp() }
        XCTAssertTrue(lines.contains { $0.contains("NO CARRIER") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("접속을 종료") }, "\(lines)")
    }

    func testTheLadderStillReportsAFailureWithACause() {
        let lines = capture { $0.failed("카카오톡이 실행되어 있지 않습니다.") }
        XCTAssertTrue(lines.contains { $0.contains("카카오톡이 실행되어 있지 않습니다.") })
    }
}
