import XCTest

@testable import kbbs

/// Regression tests for a real failure seen against live KakaoTalk.
///
/// With KakaoTalk running but every window closed, the AX tree holds only menu bars —
/// and `findWindow(title:)` matched the APPLICATION element, whose title is also
/// "카카오톡". kbbs then reported "대화목록 창 … 확인" and immediately read zero rooms,
/// which reads as a kbbs bug when it is really "you have no KakaoTalk window open".
final class WindowCheckTests: XCTestCase {

    func testARealWindowIsAccepted() {
        XCTAssertNil(Kbbs.windowFailureReason(role: "AXWindow", title: "카카오톡"))
    }

    func testTheApplicationElementIsRejected() {
        let reason = Kbbs.windowFailureReason(role: "AXApplication", title: "카카오톡")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("창"))
    }

    func testAnElementWithNoRoleIsRejected() {
        XCTAssertNotNil(Kbbs.windowFailureReason(role: nil, title: nil))
    }

    func testASheetOrDrawerIsRejected() {
        // Anything that is not AXWindow cannot be the chat list.
        XCTAssertNotNil(Kbbs.windowFailureReason(role: "AXSheet", title: "카카오톡"))
    }

    func testTheReasonNamesWhatWasActuallyFound() {
        let reason = Kbbs.windowFailureReason(role: "AXApplication", title: "카카오톡")
        XCTAssertTrue(reason!.contains("AXApplication"))
    }
}
