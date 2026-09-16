import Foundation

/// A fixed grid of terminal cells — 80 x 24 unless told otherwise.
///
/// Its one job is the invariant the whole HiTEL layout rests on: every row it emits is
/// exactly `width` cells, no matter what a screen composer wrote into it. Short rows are
/// padded, long rows are truncated on cell boundaries, and SGR colour sequences pass
/// through without being counted as content.
///
/// Screens write plain rows into a frame; only the flush turns it into bytes. Nothing
/// here knows about termios, the alternate screen, or KakaoTalk.
struct Frame {
    let width: Int
    let height: Int
    private var rows: [String]

    init(width: Int = 80, height: Int = 24) {
        self.width = width
        self.height = height
        self.rows = Array(repeating: "", count: height)
    }

    /// Writes one row, replacing whatever was there. Out-of-range indices are ignored so
    /// a composer that miscounts cannot crash the terminal into a broken state.
    mutating func set(_ row: Int, _ text: String) {
        guard row >= 0, row < height else { return }
        rows[row] = text
    }

    subscript(row: Int) -> String {
        get { row >= 0 && row < height ? rows[row] : "" }
        set { set(row, newValue) }
    }

    /// Exactly `height` strings of exactly `width` cells each.
    func render() -> [String] {
        rows.map { Frame.fit($0, to: width) }
    }

    // MARK: - Row composition

    /// `left` + content + `right`, totalling exactly `width` cells.
    static func bordered(_ content: String, left: String, right: String, width: Int) -> String {
        let inner = width - Width.cells(left) - Width.cells(right)
        guard inner > 0 else { return fit(left + right, to: width) }
        return left + fit(content, to: inner) + right
    }

    /// A horizontal rule — `╔══…══╗` — optionally with a title sitting in the middle.
    static func rule(left: String, fill: String, right: String, width: Int, title: String? = nil) -> String {
        let inner = width - Width.cells(left) - Width.cells(right)
        guard inner > 0 else { return fit(left + right, to: width) }

        let unit = max(1, Width.cells(fill))
        guard let title, Width.cells(title) <= inner else {
            return left + String(repeating: fill, count: inner / unit) + right
        }

        let titleCells = Width.cells(title)
        let leftFill = (inner - titleCells) / 2
        let rightFill = inner - titleCells - leftFill
        return left
            + String(repeating: fill, count: leftFill / unit)
            + title
            + String(repeating: fill, count: rightFill / unit)
            + right
    }

    // MARK: - ANSI-aware fitting

    /// Truncates or pads `text` to exactly `limit` cells, treating escape sequences as
    /// zero-width. A truncated row that had colour applied gets a reset appended, so the
    /// padding — and everything after it — is drawn plain.
    static func fit(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        let chars = Array(text)
        var out = String()
        out.reserveCapacity(chars.count + limit)
        var used = 0
        var sawEscape = false
        var truncated = false
        var i = 0

        while i < chars.count {
            if chars[i] == "\u{1B}" {
                sawEscape = true
                let end = escapeEnd(chars, from: i)
                out.append(contentsOf: chars[i..<end])
                i = end
                continue
            }
            // A control character measures zero cells but acts on the terminal: a newline
            // in a chat preview broke the row in two and every border below it walked.
            // Substituting a space keeps the accounting honest — it is one cell now.
            if Width.isControl(chars[i]) {
                if used + 1 > limit {
                    truncated = true
                    break
                }
                used += 1
                out.append(" ")
                i += 1
                continue
            }
            let w = Width.cells(String(chars[i]))
            if used + w > limit {
                truncated = true
                break
            }
            used += w
            out.append(chars[i])
            i += 1
        }

        if sawEscape && truncated {
            out += "\u{1B}[0m"
        }
        return out + String(repeating: " ", count: limit - used)
    }

    /// The text with every escape sequence removed. Used by tests and by anything that
    /// needs to reason about what is actually on screen.
    static func stripANSI(_ s: String) -> String {
        let chars = Array(s)
        var out = String()
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}" {
                i = escapeEnd(chars, from: i)
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Index just past the escape sequence starting at `start`.
    ///
    /// Handles CSI (`ESC [ … final`) and the two-character forms; anything unrecognised
    /// consumes just the ESC so a malformed sequence cannot swallow the rest of the row.
    private static func escapeEnd(_ chars: [Character], from start: Int) -> Int {
        var j = start + 1
        guard j < chars.count else { return j }
        if chars[j] == "[" {
            j += 1
            while j < chars.count, !("\u{40}"..."\u{7E}").contains(chars[j]) { j += 1 }
            return j < chars.count ? j + 1 : j
        }
        return j + 1
    }
}
