import Foundation

/// Everything the conversation panel draws. Mutated only on the main thread.
struct RoomState {
    let title: String
    var messages: [TranscriptMessage] = []
    var composer = ""
    var note: String?
    var link: LinkState = .connecting
    var clock = Date()
    /// Which window title the room was actually resolved to. Shown so a title collision
    /// — two contacts with the same name — is visible rather than silent.
    var matchedWindowTitle: String?
    /// How often this room is being re-read, in seconds. Derived from measurement, so
    /// the screen states it rather than claiming a cadence it is not keeping.
    var pollSeconds: TimeInterval?

    init(title: String) {
        self.title = title
    }
}

/// The conversation, as one fixed panel.
///
/// Pure: a `RoomState` in, 24 rows out. Same contract as `ListScreen`, and the same
/// reason — the layout is the thing most likely to be subtly wrong, and it is the thing
/// that can be tested without KakaoTalk running.
enum RoomScreen {

    static let width = ListScreen.width
    static let inner = ListScreen.inner

    private enum Col {
        static let lead = 1
        static let time = 5
        static let gap1 = 1
        static let author = 10
        static let gap2 = 1
        static let pipe = 1
        static let gap3 = 1
        static let body = 57
        static let trail = 1

        /// Where the body column starts — a continuation line hangs to here.
        static let indent = lead + time + gap1 + author + gap2
        static let total = indent + pipe + gap3 + body + trail
    }

    private static let rowTitle = 1
    private static let rowEndOfTape = 3
    private static let transcriptRows = 4...15
    private static let rowNotice = 17
    private static let rowComposer = 20
    private static let rowHotkeys = 22

    static func render(_ state: RoomState) -> Frame {
        var f = Frame(width: width, height: 24)

        f.set(0, Frame.rule(left: "╔", fill: "═", right: "╗", width: width))
        f.set(rowTitle, bordered(titleBar(state)))
        f.set(2, Frame.rule(left: "╠", fill: "═", right: "╣", width: width))

        f.set(rowEndOfTape, bordered(endOfTape()))
        let lines = transcriptLines(state)
        for (offset, row) in transcriptRows.enumerated() {
            f.set(row, bordered(offset < lines.count ? lines[offset] : ""))
        }

        f.set(16, Frame.rule(left: "╠", fill: "═", right: "╣", width: width))
        f.set(rowNotice, bordered(noticeLine(state)))
        f.set(18, bordered(""))
        f.set(19, Frame.rule(left: "╠", fill: "═", right: "╣", width: width))
        f.set(rowComposer, bordered(composerLine(state)))
        f.set(21, Frame.rule(left: "╠", fill: "═", right: "╣", width: width))
        f.set(rowHotkeys, bordered(hotkeyLine(state)))
        f.set(23, Frame.rule(left: "╚", fill: "═", right: "╝", width: width))
        return f
    }

    // MARK: - Rows

    private static func bordered(_ content: String) -> String {
        Frame.bordered(content, left: "║", right: "║", width: width)
    }

    private static func titleBar(_ state: RoomState) -> String {
        let left = "  [ " + Width.elide(state.title, to: 30) + " ]"
        let right = Theme.stamp(state.clock) + "  "
        let gap = max(1, inner - Width.cells(left) - Width.cells(right))
        return left + String(repeating: " ", count: gap) + right
    }

    /// Not a scroll position. KakaoTalk only exposes what it has rendered, so this is the
    /// literal edge of everything that can ever be read — permanent, not a warning.
    private static func endOfTape() -> String {
        let text = " 여기까지가 카카오톡에 남아 있는 전부입니다 "
        let fill = max(0, inner - Width.cells(text) - 2)
        let left = fill / 2
        return " " + String(repeating: "─", count: left) + text
            + String(repeating: "─", count: fill - left) + " "
    }

    /// The transcript as flat lines, newest last, clipped to what fits from the bottom.
    private static func transcriptLines(_ state: RoomState) -> [String] {
        var lines: [String] = []
        for message in state.messages {
            lines.append(contentsOf: messageLines(message))
        }
        let capacity = transcriptRows.count
        guard lines.count > capacity else { return lines }
        return Array(lines.suffix(capacity))
    }

    private static func messageLines(_ message: TranscriptMessage) -> [String] {
        let marker = attachmentMarker(message)
        let budget = marker.isEmpty ? Col.body : Col.body - Width.cells(marker) - 1
        let wrapped = Width.wrap(message.body, to: max(1, budget))

        var lines: [String] = []
        for (index, text) in wrapped.enumerated() {
            let isLast = index == wrapped.count - 1
            let content = isLast && !marker.isEmpty
                ? Width.pad(text, to: budget) + " " + marker
                : text
            lines.append(index == 0 ? head(message) + bodyCell(content) : hang() + bodyCell(content))
        }

        // The guess, spelled out on its own line directly under what it applies to.
        if TranscriptAttribution.label(for: message) == .probablyMe {
            lines.append(hang() + bodyCell("↑ 화면 위치로만 추정한 발신자입니다"))
        }
        return lines
    }

    private static func head(_ message: TranscriptMessage) -> String {
        " " + Width.pad(Width.truncate(message.timeRaw ?? "", to: Col.time), to: Col.time)
            + " " + Width.column(TranscriptAttribution.marker(for: message), to: Col.author)
            + " "
    }

    private static func hang() -> String {
        String(repeating: " ", count: Col.indent)
    }

    private static func bodyCell(_ text: String) -> String {
        "│ " + Width.column(text, to: Col.body) + " "
    }

    private static func attachmentMarker(_ message: TranscriptMessage) -> String {
        if message.imageCount > 0 { return "[사진]" }
        if message.attachmentCount > 0 { return "[파일]" }
        if message.linkCount > 0 { return "[링크]" }
        return ""
    }

    private static func noticeLine(_ state: RoomState) -> String {
        if let note = state.note, !note.isEmpty {
            return "  " + Width.elide(note, to: inner - 4)
        }
        let cadence = state.pollSeconds.map { String(format: "%.0f초주기", $0) } ?? "대기"
        var text = "  " + Theme.lineIndicator(state.clock) + " 회선감시 " + cadence
        if let matched = state.matchedWindowTitle {
            text += " · 창 「" + Width.elide(matched, to: 20) + "」"
        }
        return Width.truncate(text, to: inner)
    }

    private static func composerLine(_ state: RoomState) -> String {
        // The caret must stay visible, so a long line scrolls rather than wrapping.
        let budget = inner - 8
        let visible = Width.cells(state.composer) > budget
            ? String(Width.truncate(String(state.composer.reversed()), to: budget).reversed())
            : state.composer
        return " 입력> " + Width.pad(visible + "_", to: budget)
    }

    private static func hotkeyLine(_ state: RoomState) -> String {
        let keys = "  Enter:전송  Esc:목록  R:새로고침  Q:종료"
        let clock = Theme.clock(state.clock) + "  "
        let gap = max(1, inner - Width.cells(keys) - Width.cells(clock))
        return keys + String(repeating: " ", count: gap) + clock
    }
}
