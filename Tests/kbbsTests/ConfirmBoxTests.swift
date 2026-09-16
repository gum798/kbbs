import XCTest

@testable import kbbs

/// The gate opens because the user pressed Enter on the list. If Enter also confirms it,
/// the key that raised the warning can carry straight through it — a double tap, or a key
/// that was still held down.
final class ConfirmBoxTests: XCTestCase {

    private let opened = Date(timeIntervalSince1970: 100)

    func testAnEnterArrivingWithTheBoxIsIgnored() {
        let box = ConfirmBox(title: "어머니", stage: .asking, openedAt: opened)
        XCTAssertFalse(box.acceptsEnter(at: opened))
        XCTAssertFalse(box.acceptsEnter(at: opened.addingTimeInterval(0.1)))
    }

    func testADeliberateEnterIsAccepted() {
        let box = ConfirmBox(title: "어머니", stage: .asking, openedAt: opened)
        XCTAssertTrue(box.acceptsEnter(at: opened.addingTimeInterval(0.5)))
        XCTAssertTrue(box.acceptsEnter(at: opened.addingTimeInterval(30)))
    }

    /// Only the question takes Enter. Once it is working, or has failed, Enter means
    /// nothing and must not restart anything.
    func testOnlyTheQuestionTakesEnter() {
        let working = ConfirmBox(title: "어머니", stage: .opening(step: 1), openedAt: opened)
        XCTAssertFalse(working.acceptsEnter(at: opened.addingTimeInterval(30)))

        let failed = ConfirmBox(title: "어머니", stage: .failed(reason: "실패"), openedAt: opened)
        XCTAssertFalse(failed.acceptsEnter(at: opened.addingTimeInterval(30)))
    }
}
