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
        XCTAssertEqual(Hotkey.command(for: .char("S")), .showWindow)
    }

    func testLowercaseLettersAreNotHotkeys() {
        for letter in "qrpnkjws" {
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
    // MARK: - Korean keyboard

    /// With the IME in Korean, the R key produces ㄱ (or ㄲ with Shift). The list screen
    /// has no text to type, so it reads the jamo as the key that made it.
    func testKoreanJamoWorkAsHotkeysOnTheList() {
        XCTAssertEqual(Hotkey.command(for: .char("ㅃ"), allowingHangul: true), .quit)
        XCTAssertEqual(Hotkey.command(for: .char("ㄲ"), allowingHangul: true), .refresh)
        XCTAssertEqual(Hotkey.command(for: .char("ㅖ"), allowingHangul: true), .pagePrevious)
        XCTAssertEqual(Hotkey.command(for: .char("ㅜ"), allowingHangul: true), .pageNext)
        XCTAssertEqual(Hotkey.command(for: .char("ㅉ"), allowingHangul: true), .closeWindow)
        XCTAssertEqual(Hotkey.command(for: .char("ㄴ"), allowingHangul: true), .showWindow)
    }

    /// Shift doubles a consonant but leaves a vowel alone, so both spellings of each key
    /// have to be understood.
    func testBothTheShiftedAndUnshiftedJamoAreUnderstood() {
        XCTAssertEqual(Hotkey.command(for: .char("ㅂ"), allowingHangul: true), .quit)
        XCTAssertEqual(Hotkey.command(for: .char("ㄱ"), allowingHangul: true), .refresh)
        XCTAssertEqual(Hotkey.command(for: .char("ㅔ"), allowingHangul: true), .pagePrevious)
        XCTAssertEqual(Hotkey.command(for: .char("ㅈ"), allowingHangul: true), .closeWindow)
    }

    func testCursorJamoMoveTheCursor() {
        XCTAssertEqual(Hotkey.command(for: .char("ㅏ"), allowingHangul: true), .cursorUp)
        XCTAssertEqual(Hotkey.command(for: .char("ㅓ"), allowingHangul: true), .cursorDown)
        XCTAssertEqual(Hotkey.command(for: .char("K"), allowingHangul: true), .cursorUp)
        XCTAssertEqual(Hotkey.command(for: .char("J"), allowingHangul: true), .cursorDown)
    }

    /// The conversation screen must not do this: ㄱ there is the first letter of a word.
    func testAJamoIsJustTextInTheComposer() {
        XCTAssertNil(Hotkey.command(for: .char("ㄲ")))
        XCTAssertNil(Hotkey.command(for: .char("ㅃ")))
        XCTAssertNil(Hotkey.command(for: .char("ㄴ"), composerEmpty: true))
    }

    /// A whole syllable is never a hotkey — it is something the user typed on purpose.
    func testACompleteSyllableIsNotAHotkey() {
        XCTAssertNil(Hotkey.command(for: .char("가"), allowingHangul: true))
        XCTAssertNil(Hotkey.command(for: .char("나"), allowingHangul: true))
    }


    // MARK: - The keys a Korean IME cannot swallow

    /// Measured with `kbbs keys`: ㅉ does arrive, as E3 85 89 — but only once the
    /// syllable is finished, which for a lone consonant means when the next key is
    /// pressed. Pressing it once looks like nothing happened. A control byte is never
    /// composed, so these fire when they are pressed.
    func testControlLetterIsTheLetter() {
        XCTAssertEqual(Hotkey.command(for: .control("w")), .closeWindow)
        XCTAssertEqual(Hotkey.command(for: .control("r")), .refresh)
        XCTAssertEqual(Hotkey.command(for: .control("n")), .pageNext)
        XCTAssertEqual(Hotkey.command(for: .control("p")), .pagePrevious)
        XCTAssertEqual(Hotkey.command(for: .control("s")), .showWindow)
        XCTAssertEqual(Hotkey.command(for: .control("q")), .quit)
    }

    /// It needs no Hangul flag: these work on the conversation screen too, which is why
    /// they are worth having — W there is unreachable with a Korean IME as well.
    func testControlLetterWorksWithoutTheHangulFlag() {
        XCTAssertEqual(Hotkey.command(for: .control("w"), allowingHangul: false), .closeWindow)
    }

    /// But not over a composer with something in it. Ctrl-W is a word-delete everywhere
    /// else; closing a window out from under a half-typed message is not a trade the
    /// user asked for.
    func testControlLetterDoesNotFireOverTypedText() {
        XCTAssertNil(Hotkey.command(for: .control("w"), composerEmpty: false))
    }

    /// The two that were already spoken for keep their meanings.
    func testTheReservedControlKeysAreUnchanged() {
        XCTAssertEqual(Hotkey.command(for: .control("c"), composerEmpty: false), .quit)
        XCTAssertEqual(Hotkey.command(for: .control("l")), .repaint)
    }
}
