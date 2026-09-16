import Foundation

/// The HiTEL vocabulary: the glyphs and the few colours every screen draws from.
///
/// All box characters are East Asian Ambiguous, which is why `Width` carries a flag for
/// them and why the boot probe measures the terminal before the alternate screen fills
/// up. If they render wide, an 80-cell frame is 160 cells and nothing lines up.
enum Theme {
    // Double-line frame — the outer shell.
    static let tl = "╔", tr = "╗", bl = "╚", br = "╝"
    static let h = "═", v = "║"
    static let teeL = "╠", teeR = "╣"

    // Single-line frame — inner boxes drawn over a screen, like the open confirmation.
    static let stl = "┌", str = "┐", sbl = "└", sbr = "┘"
    static let sh = "─", sv = "│"

    static let cursor = "▶"
    static let windowOpen = "*"
    static let windowClosed = "-"

    // SGR. Deliberately few: a 1990s terminal had sixteen colours and used four.
    static let reset = "\u{1B}[0m"
    static let reverse = "\u{1B}[7m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"

    static func reversed(_ s: String) -> String { reverse + s + reset }
    static func dimmed(_ s: String) -> String { dim + s + reset }

    /// `1997-03-17 (월) 21:04` — retro format, real clock.
    ///
    /// The mockups carried a 1994 date as a period joke. The clock itself is not a joke:
    /// in a chat client the time a message arrived is information, so the format is
    /// period and the value is true.
    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let days = ["일", "월", "화", "수", "목", "금", "토"]
        let weekday = days[max(0, min(6, (c.weekday ?? 1) - 1))]
        return String(
            format: "%04d-%02d-%02d (%@) %02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, weekday, c.hour ?? 0, c.minute ?? 0
        )
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
