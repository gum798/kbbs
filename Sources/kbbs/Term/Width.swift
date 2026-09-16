import Foundation

/// How many terminal cells a string occupies.
///
/// Everything kbbs draws is a fixed 80-cell grid made of box characters. One cell of
/// error and the right border walks, so this is load-bearing rather than cosmetic —
/// and because the content is Korean, the wide case is the common case.
///
/// The table is deliberately partial. It covers the blocks that actually appear in a
/// Korean chat client (Hangul in all three of its encodings, CJK, fullwidth forms,
/// emoji) plus the East Asian Ambiguous glyphs this UI draws itself. It is not a
/// complete implementation of UAX #11 and does not try to be.
///
/// Ambiguous width is a property of the terminal, not of the text: the same glyph is
/// one cell in most terminals and two in a CJK-configured one. `ambiguousIsWide`
/// carries what the boot probe measured; until it reports, narrow is assumed.
struct Width {

    /// Set from the DSR-CPR boot probe, or from KBBS_AMBIGUOUS_WIDE.
    var ambiguousIsWide = false

    init(ambiguousIsWide: Bool = false) {
        self.ambiguousIsWide = ambiguousIsWide
    }

    // MARK: - Measuring

    func width(of text: String) -> Int {
        text.reduce(0) { $0 + width(ofCluster: $1) }
    }

    /// A grapheme cluster occupies as many cells as its first visible scalar. Summing
    /// scalars would be wrong for emoji ZWJ sequences, where several wide scalars join
    /// into one glyph; taking the first non-zero-width one gives 1 for "e" + combining
    /// acute and 2 for a joined emoji family.
    private func width(ofCluster cluster: Character) -> Int {
        // U+FE0F asks for the emoji rendering of a character that is otherwise text —
        // "\u{2764}\u{FE0F}" is drawn two cells wide where "\u{2764}" alone is one.
        if cluster.unicodeScalars.contains(where: { $0.value == 0xFE0F }) {
            return 2
        }

        for scalar in cluster.unicodeScalars {
            let w = width(ofScalar: scalar)
            if w != 0 { return w }
        }
        return 0
    }

    private func width(ofScalar scalar: Unicode.Scalar) -> Int {
        switch scalar.properties.generalCategory {
        case .control, .format, .nonspacingMark, .enclosingMark, .surrogate, .unassigned:
            return 0
        default:
            break
        }

        let v = scalar.value
        if Width.contains(Width.wideRanges, v) { return 2 }
        if Width.contains(Width.ambiguousRanges, v) { return ambiguousIsWide ? 2 : 1 }
        return 1
    }

    // MARK: - Fitting text into a fixed field

    /// The longest prefix of `text` that fits in `limit` cells.
    ///
    /// Never splits a grapheme cluster, and never emits half of a wide glyph — so a
    /// 5-cell budget holding 6 cells of Hangul yields 4 cells and one spare column,
    /// which `pad` fills.
    func truncate(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        var used = 0
        var out = String()
        out.reserveCapacity(text.count)
        for cluster in text {
            let w = width(ofCluster: cluster)
            if used + w > limit { break }
            used += w
            out.append(cluster)
        }
        return out
    }

    /// Exactly `limit` cells: truncated if too long, space-filled if too short.
    func pad(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        let fitted = truncate(text, to: limit)
        return fitted + String(repeating: " ", count: limit - width(of: fitted))
    }

    /// Like `truncate`, but marks the cut with `…` so a shortened room name reads as
    /// shortened rather than as a different room. "고등학교 3학년 2반 동창회" cut to
    /// "고등학교 3학년 2반" is a plausible name for a different group.
    func elide(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        if width(of: text) <= limit { return text }
        let marker = "…"
        let markerCells = width(of: marker)
        guard limit > markerCells else { return marker }
        return truncate(text, to: limit - markerCells) + marker
    }

    // MARK: - Convenience for the default (narrow-ambiguous) terminal

    private static let narrow = Width()

    static func cells(_ text: String) -> Int { narrow.width(of: text) }
    static func truncate(_ text: String, to limit: Int) -> String { narrow.truncate(text, to: limit) }
    static func pad(_ text: String, to limit: Int) -> String { narrow.pad(text, to: limit) }
    static func elide(_ text: String, to limit: Int) -> String { narrow.elide(text, to: limit) }

    /// Elide, then pad to exactly `limit` cells. The common case for a table column.
    static func column(_ text: String, to limit: Int) -> String {
        narrow.pad(narrow.elide(text, to: limit), to: limit)
    }

    // MARK: - Control characters

    /// Whether this grapheme is nothing but control characters.
    ///
    /// Note `\r\n` is ONE Character in Swift, which is why this asks about the cluster
    /// rather than a single scalar. C1 and the Unicode line/paragraph separators count:
    /// a terminal acts on those too.
    static func isControl(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty && character.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || v == 0x2028 || v == 0x2029
        }
    }

    /// The text as one line: every run of control characters becomes a single space, and
    /// the result is trimmed.
    ///
    /// KakaoTalk chat previews carry real newlines — "[모빙]\n고객님 안녕하세요!" is one
    /// preview, not two. Dropping the character would read as "[모빙]고객님"; keeping it
    /// breaks the row in half. A space is what the user sees in KakaoTalk's own list.
    static func oneLine(_ text: String) -> String {
        var out = String()
        var pendingSpace = false
        for character in text {
            if isControl(character) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Tables

    /// The tables are binary-searched, so their order is load-bearing. Sorting them here
    /// rather than by hand means a range added in the wrong place cannot quietly break
    /// the width of every character above it.
    private static func sorted(_ ranges: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func contains(_ ranges: [ClosedRange<UInt32>], _ v: UInt32) -> Bool {
        var lo = 0
        var hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if v < ranges[mid].lowerBound { hi = mid - 1 }
            else if v > ranges[mid].upperBound { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    /// East Asian Wide and Fullwidth. Always two cells, in every terminal.
    private static let wideRanges: [ClosedRange<UInt32>] = sorted([
        0x1100...0x115F,    // Hangul Jamo, conjoining leading — decomposed Hangul
        // Emoji_Presentation=Yes below U+1F300. Missed entirely until a room named
        // "윤지원\u{2728}" drew its row one cell too wide.
        0x231A...0x231B, 0x23E9...0x23EC, 0x23F0...0x23F0, 0x23F3...0x23F3,
        0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F,
        0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE,
        0x26C4...0x26C5, 0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA,
        0x26F2...0x26F3, 0x26F5...0x26F5, 0x26FA...0x26FA, 0x26FD...0x26FD,
        0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728, 0x274C...0x274C,
        0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
        0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50,
        0x2B55...0x2B55,
        0x2E80...0x303E,    // CJK radicals, Kangxi, CJK symbols — includes U+3000 ideographic space
        0x3041...0x33FF,    // Kana, Bopomofo, Hangul Compatibility Jamo (ㅋㅋㅋ lives at 3130-318F)
        0x3400...0x4DBF,    // CJK Extension A
        0x4E00...0x9FFF,    // CJK Unified Ideographs
        0xA000...0xA4CF,    // Yi
        0xA960...0xA97F,    // Hangul Jamo Extended-A
        0xAC00...0xD7A3,    // Hangul Syllables — the ordinary case
        0xD7B0...0xD7FF,    // Hangul Jamo Extended-B
        0xF900...0xFAFF,    // CJK Compatibility Ideographs
        0xFE10...0xFE19,    // Vertical forms
        0xFE30...0xFE6F,    // CJK compatibility forms, small form variants
        0xFF00...0xFF60,    // Fullwidth ASCII forms
        0xFFE0...0xFFE6,    // Fullwidth signs
        0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E,
        0x1F191...0x1F19A, 0x1F200...0x1F2FF,
        0x1F300...0x1F64F,  // Emoji: symbols, pictographs, emoticons
        0x1F680...0x1F6FF,  // Emoji: transport
        0x1F900...0x1F9FF,  // Emoji: supplemental
        0x1FA70...0x1FAFF,  // Emoji: extended-A
        0x20000...0x2FFFD,  // CJK Extension B and beyond
        0x30000...0x3FFFD,
    ])

    /// East Asian Ambiguous: one cell in a Western terminal, two in a CJK-configured
    /// one. This list is scoped to what kbbs itself draws — the frame, the cursor, the
    /// line indicator, the separators in the status rows — because those are the glyphs
    /// whose misjudgement breaks the layout. The boot probe measures them for real.
    private static let ambiguousRanges: [ClosedRange<UInt32>] = sorted([
        0x00A1...0x00A1, 0x00A4...0x00A4, 0x00A7...0x00A8,
        0x00AA...0x00AA, 0x00AD...0x00AE, 0x00B0...0x00B4,
        0x00B6...0x00BA, 0x00BC...0x00BF,   // includes U+00B7 · used in the status rows
        0x2018...0x2019, 0x201C...0x201D,
        0x2020...0x2022, 0x2024...0x2027,   // includes U+2026 … used for elided room names
        0x2030...0x2030, 0x2032...0x2033, 0x2035...0x2035,
        0x203B...0x203B,                    // ※ used for the boot-screen warnings
        0x203E...0x203E,
        0x2190...0x21FF,                    // arrows — ↑ marks a guessed sender
        0x2460...0x24FF,                    // enclosed alphanumerics
        0x2500...0x259F,                    // box drawing and block elements — the frame itself
        0x25A0...0x25FF,                    // geometric shapes — ▶ cursor, ●○ line indicator
        0x2605...0x2606, 0x2609...0x2609,
        0x260E...0x260F, 0x2614...0x2615,
        0x261C...0x261C, 0x261E...0x261E,
        0x2640...0x2640, 0x2642...0x2642,
        0x2660...0x266F,
    ])
}
