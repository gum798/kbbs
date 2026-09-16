import XCTest

@testable import kbbs

/// Hotkeys are uppercase. A lowercase letter is always text, which is the only rule that
/// makes a composer safe to type in — and the hotkey rows have always said "Q:종료", so
/// this is what the screen was already claiming.
final class HotkeyTests: XCTestCase {

    func testUppercaseLettersAreHotkeys() {
        XCTAssertEqual(Hotkey.command(for: .char("Q")), .quit)
        XCTAssertEqual(Hotkey.command(for: .char("R")), .refresh)
        XCTAssertEqual(Hotkey.command(for: .char("P")), .pagePrevious)
        XCTAssertEqual(Hotkey.command(for: .char("N")), .pageNext)
        XCTAssertEqual(Hotkey.command(for: .char("W")), .closeWindow)
    }

    func testLowercaseLettersAreNotHotkeys() {
        for letter in "qrpnkjw" {
            XCTAssertNil(Hotkey.command(for: .char(letter)), "\(letter) should be text")
        }
    }

    func testControlKeysStillWork() {
        XCTAssertEqual(Hotkey.command(for: .control("c")), .quit)
        XCTAssertEqual(Hotkey.command(for: .control("l")), .repaint)
    }

    func testPageKeysAreTheirOwnHotkeys() {
        XCTAssertEqual(Hotkey.command(for: .pageUp), .pagePrevious)
        XCTAssertEqual(Hotkey.command(for: .pageDown), .pageNext)
    }

    func testArrowsAndTextAreNotHotkeys() {
        XCTAssertNil(Hotkey.command(for: .up))
        XCTAssertNil(Hotkey.command(for: .enter))
        XCTAssertNil(Hotkey.command(for: .char("가")))
        XCTAssertNil(Hotkey.command(for: .char("1")))
    }

    /// Q quits from a conversation too, but only when there is nothing to lose. The guard
    /// lives with the hotkey rather than being repeated at each call site — repeating it
    /// is exactly how a lowercase q came to quit mid-sentence.
    func testQuitIsRefusedWhileSomethingIsBeingTyped() {
        XCTAssertNil(Hotkey.command(for: .char("Q"), composerEmpty: false))
        XCTAssertNil(Hotkey.command(for: .char("R"), composerEmpty: false))
    }

    /// Ctrl-C is the exception: it is the way out of anything, including a full composer.
    func testControlCAlwaysQuits() {
        XCTAssertEqual(Hotkey.command(for: .control("c"), composerEmpty: false), .quit)
    }
}
