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

    /// `composerEmpty` is false only on a screen with something typed into it, where a
    /// letter command would cost the user their text. Ctrl-C ignores it.
    static func command(for key: Key, composerEmpty: Bool = true) -> Hotkey? {
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

        switch key {
        case .char("Q"): return .quit
        case .char("R"): return .refresh
        case .char("P"): return .pagePrevious
        case .char("N"): return .pageNext
        case .char("W"): return .closeWindow
        case .char("S"): return .showWindow
        default: return nil
        }
    }
}
