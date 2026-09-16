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
    var pending: [PendingLedger.Entry] = []

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
    private static let transcriptRows = 3...18

    /// Lines of conversation the screen can hold. The reader is asked for messages in
    /// proportion to this and nothing more — reading sixty to draw twelve is where the
    /// seconds went.
    static var visibleLines: Int { transcriptRows.count }
    private static let rowComposer = 20
    private static let rowHotkeys = 22

    static func render(_ state: RoomState) -> Frame {
        var f = Frame(width: width, height: 24)

        f.set(0, Frame.rule(left: "╔", fill: "═", right: "╗", width: width))
        f.set(rowTitle, bordered(titleBar(state)))
        f.set(2, Frame.rule(left: "╠", fill: "═", right: "╣", width: width))

        let lines = transcriptLines(state)
        for (offset, row) in transcriptRows.enumerated() {
            f.set(row, bordered(offset < lines.count ? lines[offset] : ""))
        }

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

    private static func transcriptLines(_ state: RoomState) -> [String] {
        var lines: [String] = []
        for message in state.messages {
            lines.append(contentsOf: messageLines(message))
        }
        for entry in state.pending {
            lines.append(contentsOf: pendingLines(entry))
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

        return lines
    }

    /// Drawn below the transcript because it is not in the transcript yet — that is the
    /// whole point of the marker.
    private static func pendingLines(_ entry: PendingLedger.Entry) -> [String] {
        let marker = entry.state == .sending ? "[전송중]" : "[미확인]"
        let budget = Col.body - Width.cells(marker) - 1
        let wrapped = Width.wrap(entry.body, to: max(1, budget))
        return wrapped.enumerated().map { index, text in
            let isLast = index == wrapped.count - 1
            let content = isLast ? Width.pad(text, to: budget) + " " + marker : text
            return index == 0
                ? " " + Width.pad("", to: Col.time) + " " + Width.column("나", to: Col.author) + " " + bodyCell(content)
                : hang() + bodyCell(content)
        }
    }

    private static func head(_ message: TranscriptMessage) -> String {
        " " + Width.pad(ChatTextNormalizer.compactTime(message.timeRaw ?? ""), to: Col.time)
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

    private static let prompt = " 입력> "

    private static func composerLine(_ state: RoomState) -> String {
        prompt + Width.pad(visibleComposer(state), to: inner - Width.cells(prompt))
    }

    /// What fits of the composer, from the end, so the caret is always on screen.
    private static func visibleComposer(_ state: RoomState) -> String {
        let budget = inner - Width.cells(prompt) - 1
        guard Width.cells(state.composer) > budget else { return state.composer }
        return String(Width.truncate(String(state.composer.reversed()), to: budget).reversed())
    }

    /// The terminal's own cursor belongs here, because the input method draws what it is
    /// composing at the cursor — not at the caret this screen paints. Park it anywhere
    /// else and a half-typed Hangul syllable appears there instead.
    static let caretRow = rowComposer + 1

    static func caretColumn(_ state: RoomState) -> Int {
        1 + Width.cells(prompt) + Width.cells(visibleComposer(state)) + 1
    }

    /// The hotkeys, or — while there is something to say — the note in their place.
    ///
    /// A note here is transient and usually a failure, so it gets the whole row rather
    /// than the eleven cells left over beside the key list.
    private static func hotkeyLine(_ state: RoomState) -> String {
        let right = Theme.lineIndicator(state.clock) + " " + Theme.clock(state.clock) + "  "
        let left: String
        if let note = state.note, !note.isEmpty {
            left = "  " + Width.elide(note, to: inner - Width.cells(right) - 4)
        } else {
            left = "  Enter:전송  Esc:목록  R:새로고침  W:창닫기  Q:종료"
        }
        let gap = max(1, inner - Width.cells(left) - Width.cells(right))
        return left + String(repeating: " ", count: gap) + right
    }

}
