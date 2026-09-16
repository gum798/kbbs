import Darwin
import Foundation

/// The run loop: one thread, one screen, a 100ms heartbeat.
///
/// Every iteration is the same five steps — wait for input up to 100ms, decode what
/// arrived, service the signal flags, expire whatever has timed out, and repaint if the
/// frame changed. The 100ms is what makes the clock tick while nothing is being typed,
/// and it is the whole reason the screen can look alive during work it cannot cancel.
///
/// In M2 the refresh still runs inline on this thread, so R blocks the loop for as long
/// as KakaoTalk takes — about 8.6 seconds for 60 rooms. That is M3's problem, and until
/// then the screen tells the truth about it rather than pretending otherwise.
struct Loop {
    /// How long a lone Esc waits to find out whether it was an arrow key.
    private static let escapeGrace: TimeInterval = 0.025
    /// How long the 선택> buffer survives without another digit. It never auto-commits.
    private static let bufferIdle: TimeInterval = 3.0
    /// How long a note stays on the hotkey row.
    private static let noteLife: TimeInterval = 2.5

    private var state = ListState()
    private var decoder = KeyDecoder()
    private var lastFrame: [String] = []

    private var escapePendingSince: Date?
    private var bufferTouchedAt: Date?
    private var noteSetAt: Date?

    /// Called when the user asks for a rescan. Returning nil means the scan failed.
    private let refresh: () -> [Room]?

    init(rooms: [Room], link: LinkState, refresh: @escaping () -> [Room]?) {
        self.refresh = refresh
        state.rooms = rooms
        state.link = link
    }

    mutating func run() {
        while true {
            let bytes = RawMode.read(timeoutMilliseconds: 100)

            if RawMode.quitRequested() { return }

            if !bytes.isEmpty {
                for key in decoder.feed(bytes) {
                    if handle(key) == .quit { return }
                }
                // feed() may have left an Esc pending, or resolved one into an arrow.
                escapePendingSince = decoder.hasPendingEscape ? Date() : nil
            } else if let since = escapePendingSince,
                      Date().timeIntervalSince(since) >= Self.escapeGrace {
                escapePendingSince = nil
                for key in decoder.flushPendingEscape() {
                    if handle(key) == .quit { return }
                }
            }

            if RawMode.takeResize() {
                lastFrame = []                      // the old frame is the wrong size
            }

            expireTimers()
            state.clock = Date()
            paint()
        }
    }

    // MARK: - Keys

    private enum Outcome { case carryOn, quit }

    private mutating func handle(_ key: Key) -> Outcome {
        switch key {
        case .char("q"), .char("Q"):
            return .quit
        case .control("c"):
            return .quit

        case .up, .char("k"):
            state.moveUp()
        case .down, .char("j"):
            state.moveDown()

        case .pageUp, .char("p"), .char("P"):
            state.pageBack()
        case .pageDown, .char("n"), .char("N"):
            state.pageForward()

        case .home:
            state.page = 0
            state.cursor = 0
            state.clearNumberBuffer()
        case .end:
            state.page = state.pageCount - 1
            state.cursor = max(0, state.roomsOnPage - 1)
            state.clearNumberBuffer()

        case .char("r"), .char("R"):
            rescan()

        case .control("l"):
            lastFrame = []                          // force a full repaint

        case .backspace:
            state.popDigit()
            bufferTouchedAt = state.numberBuffer.isEmpty ? nil : Date()

        case .escape:
            state.clearNumberBuffer()
            bufferTouchedAt = nil

        case .enter:
            open()

        case .char(let c) where c.isNumber:
            state.appendDigit(c)
            bufferTouchedAt = Date()

        default:
            break
        }
        return .carryOn
    }

    private mutating func open() {
        guard let index = state.selectedRoomIndex else {
            say("그런 방은 없습니다")
            state.clearNumberBuffer()
            bufferTouchedAt = nil
            return
        }
        let room = state.rooms[index]
        state.clearNumberBuffer()
        bufferTouchedAt = nil
        // M4 builds the conversation screen. Saying so is better than a dead key.
        say("\(index + 1)번 「\(room.title)」 — 대화 화면은 아직 없습니다")
    }

    private mutating func rescan() {
        say("읽는 중… 카카오톡이 응답할 때까지 화면이 멈춥니다")
        paint()                                     // show it BEFORE the blocking call
        if let rooms = refresh() {
            state.rooms = rooms
            state.page = min(state.page, state.pageCount - 1)
            state.cursor = min(state.cursor, max(0, state.roomsOnPage - 1))
            state.link = .live(lastRefresh: Date())
            say("\(rooms.count)개 읽음")
        } else {
            state.link = .down(since: Date(), reason: "읽기 실패")
            say("읽지 못했습니다")
        }
    }

    private mutating func say(_ note: String) {
        state.note = note
        noteSetAt = Date()
    }

    private mutating func expireTimers() {
        let now = Date()
        if let touched = bufferTouchedAt, now.timeIntervalSince(touched) >= Self.bufferIdle {
            state.clearNumberBuffer()
            bufferTouchedAt = nil
        }
        if let set = noteSetAt, now.timeIntervalSince(set) >= Self.noteLife {
            state.note = nil
            noteSetAt = nil
        }
    }

    // MARK: - Painting

    /// One write(2) of at most 24 lines, positioned with `ESC[H` and cleared per line
    /// with `ESC[K`. No `ESC[2J` anywhere: clearing the whole screen is what makes a
    /// terminal flicker.
    private mutating func paint() {
        let size = RawMode.size()
        let rows = size.isBigEnough ? ListScreen.render(state).render() : tooSmall(size)
        guard rows != lastFrame else { return }
        lastFrame = rows

        var out = "\u{1B}[H"
        for (index, row) in rows.enumerated() {
            out += row + "\u{1B}[K"
            if index < rows.count - 1 { out += "\r\n" }
        }
        TTYOut.write(out)
    }

    private func tooSmall(_ size: RawMode.Size) -> [String] {
        let message = "화면을 80x24 이상으로 키워 주십시오"
        let detail = "지금 \(size.columns)x\(size.rows)"
        var rows = [String](repeating: "", count: max(1, size.rows))
        let middle = rows.count / 2
        rows[middle] = center(message, in: size.columns)
        if rows.count > middle + 2 {
            rows[middle + 2] = center(detail, in: size.columns)
        }
        return rows
    }

    private func center(_ text: String, in columns: Int) -> String {
        let fitted = Width.truncate(text, to: columns)
        let pad = max(0, (columns - Width.cells(fitted)) / 2)
        return String(repeating: " ", count: pad) + fitted
    }
}
