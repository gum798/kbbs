import Darwin
import Foundation

/// Asks the terminal how wide its ambiguous glyphs actually are.
///
/// East Asian Ambiguous width is a property of the terminal, not of the text: `▶`, `●`
/// and the box-drawing characters kbbs builds every frame from are one cell in most
/// terminals and two in a CJK-configured one. Guessing wrong does not misplace one
/// glyph, it walks the right border of all 24 rows.
///
/// So do not guess. Print the glyph at a known column, ask for the cursor position with
/// DSR (`ESC[6n`), and subtract. The terminal answers its own question.
///
/// Runs once, inside the alternate screen, before the first frame — the one moment when
/// nothing else is writing to the terminal and nobody is typing.
enum WidthProbe {

    enum Result {
        case measured(wide: Bool)
        case forced(wide: Bool)     // KBBS_AMBIGUOUS_WIDE said so
        case unanswered             // the terminal did not reply; narrow is assumed

        var isWide: Bool {
            switch self {
            case .measured(let wide), .forced(let wide): return wide
            case .unanswered: return false
            }
        }

        var describedInKorean: String {
            switch self {
            case .measured(let wide): return wide ? "넓게 2칸  측정함" : "좁게 1칸  측정함"
            case .forced(let wide): return wide ? "넓게 2칸  KBBS_AMBIGUOUS_WIDE" : "좁게 1칸  KBBS_AMBIGUOUS_WIDE"
            case .unanswered: return "좁게 1칸  터미널이 답하지 않음"
            }
        }
    }

    /// The glyphs kbbs actually draws whose width is ambiguous. If any of them comes back
    /// two cells wide the whole class is treated as wide, because a frame mixing the two
    /// assumptions is worse than a frame consistently wrong.
    private static let samples: [String] = ["▶", "●", "─", "│", "═", "║", "…", "·"]

    static func run() -> Result {
        if let forced = ProcessInfo.processInfo.environment["KBBS_AMBIGUOUS_WIDE"] {
            return .forced(wide: forced == "1" || forced.lowercased() == "true")
        }

        var answered = false
        var wide = false

        for sample in samples {
            guard let width = measure(sample) else { continue }
            answered = true
            if width >= 2 {
                wide = true
                break
            }
        }

        // Leave nothing behind: the scratch row is cleared and the cursor parked.
        TTYOut.write("\u{1B}[1;1H\u{1B}[2K\u{1B}[H")
        return answered ? .measured(wide: wide) : .unanswered
    }

    /// Cells the terminal used to draw `sample`, or nil if it did not answer in time.
    private static func measure(_ sample: String) -> Int? {
        drainPendingInput()
        TTYOut.write("\u{1B}[1;1H\u{1B}[2K" + sample + "\u{1B}[6n")
        guard let column = readCursorColumn(timeoutMilliseconds: 150) else { return nil }
        // The report is 1-based and the cursor sits just past the glyph.
        return column - 1
    }

    /// Reads `ESC [ row ; col R`, ignoring anything else that arrives.
    ///
    /// Bytes that are not part of the report are dropped rather than pushed back: this
    /// runs before the key decoder exists, and a keystroke made during the boot ladder
    /// is not a keystroke the user expects to have counted.
    private static func readCursorColumn(timeoutMilliseconds: Int32) -> Int? {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
        var response: [UInt8] = []

        while Date() < deadline {
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, 1, remaining) > 0 else { return nil }

            var buffer = [UInt8](repeating: 0, count: 64)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            guard count > 0 else { return nil }
            response.append(contentsOf: buffer[0..<count])

            if let column = parseColumn(response) { return column }
            if response.count > 256 { return nil }
        }
        return nil
    }

    /// The column out of `ESC [ row ; col R`, or nil if the buffer does not hold a whole
    /// report yet.
    ///
    /// Reads the LAST report in the buffer. A key pressed while the probe was waiting
    /// arrives on the same descriptor, and so does the previous sample's answer if the
    /// terminal was slow; the newest one is the one being asked about.
    static func parseColumn(_ bytes: [UInt8]) -> Int? {
        var search = bytes.endIndex
        while let escape = bytes[..<search].lastIndex(of: 0x1B) {
            search = escape
            guard escape + 2 < bytes.count, bytes[escape + 1] == 0x5B,
                  let end = bytes[escape...].firstIndex(of: 0x52)      // 'R'
            else {
                continue
            }
            let parts = bytes[(escape + 2)..<end].split(separator: 0x3B)   // ';'
            guard parts.count == 2, let column = Int(String(decoding: parts[1], as: UTF8.self)) else {
                continue
            }
            return column
        }
        return nil
    }

    /// Anything already waiting on stdin would otherwise be read as the report.
    private static func drainPendingInput() {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while poll(&fds, 1, 0) > 0 {
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count <= 0 { return }
        }
    }
}
