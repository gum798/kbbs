import XCTest

@testable import kbbs

/// The wall clock the traversals read. It is a process-wide static, which is only safe
/// because it is always set and unset around a body — so that is what is tested here.
final class AXDeadlineTests: XCTestCase {

    func testNoDeadlineMeansNoLimit() {
        XCTAssertFalse(AXDeadline.passed)
    }

    func testADeadlineInThePastHasPassed() {
        AXDeadline.within(-1) {
            XCTAssertTrue(AXDeadline.passed)
        }
    }

    // MARK: - Saying that it gave up

    /// The whole point. A search that stops early returns what it had reached, and a
    /// short list reads exactly like an exhausted one — which is how a room with no
    /// composer of its own gets bound to another window's.
    func testATruncationIsReported() {
        let outcome = AXDeadline.within(60) { AXDeadline.noteTruncation() }
        XCTAssertTrue(outcome.truncated)
    }

    func testNoTruncationIsReportedWhenNothingGaveUp() {
        XCTAssertFalse(AXDeadline.within(60) {}.truncated)
    }

    /// A traversal cut short deep inside an operation has to reach the top of it.
    func testATruncationInsideANestedScopeReachesTheOuterOne() {
        let outer = AXDeadline.within(60) {
            let inner = AXDeadline.within(60) { AXDeadline.noteTruncation() }
            XCTAssertTrue(inner.truncated)
        }
        XCTAssertTrue(outer.truncated)
    }

    /// And must not leak past it, or the next operation inherits a failure it never had.
    func testATruncationDoesNotLeakIntoTheNextOperation() {
        XCTAssertTrue(AXDeadline.within(60) { AXDeadline.noteTruncation() }.truncated)
        XCTAssertFalse(AXDeadline.within(60) {}.truncated)
    }

    func testADeadlineAheadHasNot() {
        AXDeadline.within(60) {
            XCTAssertFalse(AXDeadline.passed)
        }
    }

    /// The static outlives the call, so a body that forgot to restore would bound every
    /// later traversal in the process at a time that has already gone.
    func testTheDeadlineIsGoneAfterTheBody() {
        AXDeadline.within(-1) {}
        XCTAssertFalse(AXDeadline.passed)
    }

    func testItIsRestoredEvenWhenTheBodyThrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(try AXDeadline.within(-1) { throw Boom() })
        XCTAssertFalse(AXDeadline.passed)
    }

    /// An inner deadline may only ever shorten. A read nested inside an open that is
    /// already out of time must not get itself a fresh minute.
    func testANestedDeadlineCannotExtendTheOuterOne() {
        AXDeadline.within(-1) {
            AXDeadline.within(60) {
                XCTAssertTrue(AXDeadline.passed)
            }
        }
    }

    func testANestedDeadlineMayShortenTheOuterOne() {
        AXDeadline.within(60) {
            AXDeadline.within(-1) {
                XCTAssertTrue(AXDeadline.passed)
            }
            XCTAssertFalse(AXDeadline.passed)
        }
    }

    func testTheOuterDeadlineComesBackAfterANestedOne() {
        AXDeadline.within(60) {
            AXDeadline.within(-1) {}
            XCTAssertFalse(AXDeadline.passed)
        }
        XCTAssertFalse(AXDeadline.passed)
    }

    func testAValueComesBackOutOfTheBody() {
        XCTAssertEqual(AXDeadline.within(60) { 7 }.value, 7)
    }
}
