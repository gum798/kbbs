import XCTest

@testable import kbbs

/// The screen for every way reading can stop. Without it a long-running terminal shows
/// an empty conversation forever and the user has no way to tell a quiet chat from a
/// dead one.
final class BlockedScreenTests: XCTestCase {

    private func plain(_ rows: [String]) -> [String] { rows.map { Frame.stripANSI($0) } }

    private func state(_ reason: String = "읽기 실패") -> BlockedState {
        BlockedState(
            reason: reason,
            since: Date(timeIntervalSince1970: 0),
            lastGoodRead: Date(timeIntervalSince1970: 0),
            retryIn: 8,
            clock: Date(timeIntervalSince1970: 40)
        )
    }

    func testEveryRowIsExactlyEightyCells() {
        let rows = plain(BlockedScreen.render(state()).render())
        XCTAssertEqual(rows.count, 24)
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(Width.cells(row), 80, "row \(i): \(row)")
        }
    }

    /// 80 cells is not enough on its own — a row nobody filled in is 80 spaces and passes
    /// the width check while leaving a hole in the side of the box.
    func testEveryRowIsInsideTheBox() {
        for (i, row) in plain(BlockedScreen.render(state()).render()).enumerated() {
            XCTAssertTrue(row.hasPrefix("║") || row.hasPrefix("╔") || row.hasPrefix("╠") || row.hasPrefix("╚"), "row \(i): \(row)")
            XCTAssertTrue(row.hasSuffix("║") || row.hasSuffix("╗") || row.hasSuffix("╣") || row.hasSuffix("╝"), "row \(i): \(row)")
        }
    }

    func testItSaysItIsCutOff() {
        let rows = plain(BlockedScreen.render(state()).render())
        XCTAssertTrue(rows.contains { $0.contains("통") && $0.contains("두") && $0.contains("절") })
    }

    /// The causes it cannot tell apart, named — picking one and being wrong is worse.
    func testItNamesTheCausesItCannotDistinguish() {
        let text = plain(BlockedScreen.render(state()).render()).joined(separator: "\n")
        XCTAssertTrue(text.contains("잠금"))
        XCTAssertTrue(text.contains("최소화"))
        XCTAssertTrue(text.contains("종료"))
        XCTAssertTrue(text.contains("권한"))
    }

    /// The one promise that has to survive any trimming: kbbs does not try the passcode.
    func testItPromisesNotToTypeThePasscode() {
        XCTAssertTrue(plain(BlockedScreen.render(state()).render()).joined().contains("암호"))
    }

    func testItShowsHowLongItHasBeenCutOffAndWhenItRetries() {
        let text = plain(BlockedScreen.render(state()).render()).joined(separator: "\n")
        XCTAssertTrue(text.contains("40초"), text)
        XCTAssertTrue(text.contains("8초"), text)
    }

    func testItOffersRetryAndTheWayBack() {
        let text = plain(BlockedScreen.render(state()).render()).joined(separator: "\n")
        XCTAssertTrue(text.contains("R:"))
        XCTAssertTrue(text.contains("Esc:"))
        XCTAssertTrue(text.contains("Q:"))
    }

    /// A revoked grant is the one cause that retrying cannot fix, so it does not pretend
    /// a countdown will help.
    func testARevokedPermissionOffersNoCountdown() {
        var s = state()
        s.permissionLost = true
        let text = plain(BlockedScreen.render(s).render()).joined(separator: "\n")
        XCTAssertTrue(text.contains("시스템 설정"), text)
        XCTAssertFalse(text.contains("자동 재시도"), text)
    }

    func testALongReasonKeepsTheFrame() {
        var s = state(String(repeating: "아주 긴 이유 ", count: 12))
        s.permissionLost = false
        for (i, row) in plain(BlockedScreen.render(s).render()).enumerated() {
            XCTAssertEqual(Width.cells(row), 80, "row \(i)")
        }
    }
    func testPrintForEyeballing() {
        guard ProcessInfo.processInfo.environment["KBBS_EYEBALL"] != nil else { return }
        for row in plain(BlockedScreen.render(state("전사를 읽지 못했습니다")).render()) { print(row) }
    }

}
