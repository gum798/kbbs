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
    /// With the IME in Korean the R key sends ㄱ, or ㄲ with Shift — the letter never
    /// arrives at all. Shift doubles a consonant and leaves a vowel alone, so each key has
    /// two spellings and both are here.
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
        if allowingHangul, case .char(let typed) = key, let latin = jamo[typed] {
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
