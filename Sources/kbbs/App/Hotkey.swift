import Foundation

/// The letter commands, in one place.
///
/// Uppercase only. A lowercase letter is always text — otherwise a message cannot contain
/// the word "quit", and a `q` typed mid-sentence ends the program and takes the sentence
/// with it, which is a bug this program has already had once.
enum Hotkey: Equatable {
    case quit
    case refresh
    case pagePrevious
    case pageNext
    case repaint
    case closeWindow
    case showWindow
    case cursorUp
    case cursorDown

    /// The 2-set Korean layout, for the screens that have no text to type.
    ///
    /// With the IME in Korean the R key sends ㄱ, or ㄲ with Shift — the Latin letter
    /// never arrives. Shift doubles a consonant and leaves a vowel alone, so each key has
    /// two spellings and both are here.
    ///
    /// This is a courtesy, not a reliable path: the IME hands a jamo over only once the
    /// syllable it belongs to is finished, so a lone consonant sits in the input method
    /// until the NEXT key is pressed and then arrives late, behind it. The Ctrl aliases
    /// below are the ones that work at the moment they are pressed.
    private static let jamo: [Character: Character] = [
        "ㅂ": "Q", "ㅃ": "Q",
        "ㅈ": "W", "ㅉ": "W",
        "ㄱ": "R", "ㄲ": "R",
        "ㅔ": "P", "ㅖ": "P",
        "ㅜ": "N",
        "ㄴ": "S",
        "ㅏ": "K",
        "ㅓ": "J",
    ]

    /// `composerEmpty` is false only on a screen with something typed into it, where a
    /// letter command would cost the user their text. Ctrl-C ignores it.
    ///
    /// `allowingHangul` is for screens with nothing to type: there a jamo can only have
    /// come from a hotkey. The conversation screen must leave it false — ㄱ there is the
    /// first letter of a word.
    ///
    /// The Ctrl aliases need no such flag. They are already behind `composerEmpty`, and
    /// a control byte is never text.
    static func command(for key: Key, composerEmpty: Bool = true, allowingHangul: Bool = false) -> Hotkey? {
        switch key {
        case .control("c"):
            return .quit
        case .control("l"):
            return .repaint
        case .pageUp:
            return .pagePrevious
        case .pageDown:
            return .pageNext
        default:
            break
        }

        guard composerEmpty else { return nil }

        var key = key
        // Ctrl+letter is the letter — the only spelling of these commands a Korean IME
        // does not delay. Measured with `kbbs keys`: ㅉ does reach the program as E3 85
        // 89, but not when it is pressed; the IME holds it as an unfinished syllable and
        // releases it behind whatever key comes next. Pressing it once therefore looks
        // like nothing happened. A control byte is never composed.
        if case .control(let typed) = key, let letter = typed.uppercased().first {
            key = .char(letter)
        } else if allowingHangul, case .char(let typed) = key, let latin = jamo[typed] {
            key = .char(latin)
        }

        switch key {
        case .char("Q"): return .quit
        case .char("R"): return .refresh
        case .char("P"): return .pagePrevious
        case .char("N"): return .pageNext
        case .char("W"): return .closeWindow
        case .char("S"): return .showWindow
        case .char("K"): return .cursorUp
        case .char("J"): return .cursorDown
        default: return nil
        }
    }
}
