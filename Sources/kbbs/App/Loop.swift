import Darwin
import Foundation

/// The run loop: one thread, one screen at a time, a 100ms heartbeat.
///
/// Every iteration is the same five steps — wait for input up to 100ms, decode what
/// arrived, service the signal flags, expire whatever has timed out, and repaint if the
/// frame changed. The 100ms is what makes the clock tick while nothing is being typed,
/// and it is the whole reason the screen can look alive during work it cannot cancel.
///
/// In M4 the Accessibility calls still run inline on this thread, so a scan or a read
/// blocks the loop for as long as KakaoTalk takes. That is M3's problem to move onto a
/// worker; until then the screen says so before it goes away rather than appearing to
/// hang.
struct Loop {
    private static let escapeGrace: TimeInterval = 0.025
    private static let bufferIdle: TimeInterval = 3.0
    private static let noteLife: TimeInterval = 2.5
    /// The floor for re-reading an open conversation. The actual interval is derived
    /// from how long the last read took — see `nextPollDelay`.
    private static let roomPoll: TimeInterval = 3.0
    /// How often the waiting screen checks whether you have opened the room yourself.
    private static let windowWatch: TimeInterval = 1.0

    private enum Screen {
        case list
        case room
        /// The room has no KakaoTalk window, so kbbs waits for one rather than
        /// conjuring it: see `WaitingState`.
        case waiting
    }

    /// What the screen shows while it waits for a window it will not open itself.
    private struct WaitingState {
        let title: String
        var since: Date
    }

    private var screen: Screen = .list
    private var list = ListState()
    private var roomState: RoomState?
    private var waiting: WaitingState?

    private var decoder = KeyDecoder()
    private var lastFrame: [String] = []

    private var escapePendingSince: Date?
    private var bufferTouchedAt: Date?
    private var noteSetAt: Date?
    private var nextRoomPoll: Date?
    private var nextWindowWatch: Date?

    private var opened: RoomReader.Opened?
    /// How long the last transcript read took. The poll cadence follows it.
    private var lastReadSeconds: TimeInterval?

    /// Measured, not assumed: a warm read of a real room costs 3-9 seconds, so a fixed
    /// 3s cadence would mean reading continuously and — while the calls are still inline
    /// on this thread — a screen that is frozen more often than it is alive. Three times
    /// the last read leaves the loop responsive for twice as long as it is blocked.
    private var nextPollDelay: TimeInterval {
        guard let last = lastReadSeconds else { return Self.roomPoll }
        return max(Self.roomPoll, last * 3)
    }

    private let refresh: () -> [Room]?
    private let reader: RoomReader?
    private let readLimit: Int

    init(
        rooms: [Room],
        link: LinkState,
        reader: RoomReader?,
        readLimit: Int = 60,
        refresh: @escaping () -> [Room]?
    ) {
        self.refresh = refresh
        self.reader = reader
        self.readLimit = readLimit
        list.rooms = rooms
        list.link = link
    }

    /// Start already inside a conversation, as `--room` does.
    mutating func enter(room: RoomState, opened: RoomReader.Opened) {
        self.roomState = room
        self.opened = opened
        self.screen = .room
        self.nextRoomPoll = Date().addingTimeInterval(Self.roomPoll)
    }

    mutating func run() {
        while true {
            let bytes = RawMode.read(timeoutMilliseconds: 100)
            if RawMode.quitRequested() { return }

            if !bytes.isEmpty {
                for key in decoder.feed(bytes) where handle(key) == .quit { return }
                escapePendingSince = decoder.hasPendingEscape ? Date() : nil
            } else if let since = escapePendingSince,
                      Date().timeIntervalSince(since) >= Self.escapeGrace {
                escapePendingSince = nil
                for key in decoder.flushPendingEscape() where handle(key) == .quit { return }
            }

            if RawMode.takeResize() { lastFrame = [] }

            expireTimers()
            serviceRoomPoll()
            serviceWindowWatch()
            tickClocks()
            paint()
        }
    }

    // MARK: - Keys

    private enum Outcome { case carryOn, quit }

    private mutating func handle(_ key: Key) -> Outcome {
        switch screen {
        case .list: return handleList(key)
        case .room: return handleRoom(key)
        case .waiting: return handleWaiting(key)
        }
    }

    private mutating func handleList(_ key: Key) -> Outcome {
        switch key {
        case .char("q"), .char("Q"), .control("c"):
            return .quit
        case .up, .char("k"):
            list.moveUp()
        case .down, .char("j"):
            list.moveDown()
        case .pageUp, .char("p"), .char("P"):
            list.pageBack()
        case .pageDown, .char("n"), .char("N"):
            list.pageForward()
        case .home:
            list.page = 0
            list.cursor = 0
            list.clearNumberBuffer()
        case .end:
            list.page = list.pageCount - 1
            list.cursor = max(0, list.roomsOnPage - 1)
            list.clearNumberBuffer()
        case .char("r"), .char("R"):
            rescan()
        case .control("l"):
            lastFrame = []
        case .backspace:
            list.popDigit()
            bufferTouchedAt = list.numberBuffer.isEmpty ? nil : Date()
        case .escape:
            list.clearNumberBuffer()
            bufferTouchedAt = nil
        case .enter:
            openSelectedRoom()
        case .char(let c) where c.isNumber:
            list.appendDigit(c)
            bufferTouchedAt = Date()
        default:
            break
        }
        return .carryOn
    }

    /// Reading only. Typing goes into the composer but Enter does not send yet — the
    /// send machine is M6, and a key that looks like it sent but did not would be the
    /// worst possible lie for this program to tell.
    private mutating func handleRoom(_ key: Key) -> Outcome {
        guard var room = roomState else { return .carryOn }
        let composerEmpty = room.composer.isEmpty

        switch key {
        case .control("c"):
            return .quit
        case .char("q"), .char("Q") where composerEmpty:
            return .quit
        case .escape:
            leaveRoom()
            return .carryOn
        case .control("l"):
            lastFrame = []
        case .char("r"), .char("R") where composerEmpty:
            pollRoom(force: true)
            return .carryOn
        case .backspace:
            if !room.composer.isEmpty { room.composer.removeLast() }
        case .enter:
            if !room.composer.isEmpty {
                room.note = "전송은 아직 없습니다 (M6). 입력은 보관됩니다."
                noteSetAt = Date()
            }
        case .char(let c):
            // 300 codepoints is KakaoTalk's own ceiling; past it the keys stop counting.
            if room.composer.unicodeScalars.count < 300 {
                room.composer.append(c)
            } else {
                room.note = "300자까지"
                noteSetAt = Date()
            }
        default:
            break
        }
        roomState = room
        return .carryOn
    }

    private mutating func handleWaiting(_ key: Key) -> Outcome {
        switch key {
        case .char("q"), .char("Q"), .control("c"):
            return .quit
        case .escape:
            waiting = nil
            screen = .list
            nextWindowWatch = nil
            lastFrame = []
        case .control("l"):
            lastFrame = []
        default:
            break
        }
        return .carryOn
    }

    // MARK: - Rooms

    private mutating func openSelectedRoom() {
        guard let index = list.selectedRoomIndex else {
            say("그런 방은 없습니다")
            list.clearNumberBuffer()
            bufferTouchedAt = nil
            return
        }
        let room = list.rooms[index]
        list.clearNumberBuffer()
        bufferTouchedAt = nil

        guard let reader else {
            say("예시 모드에서는 대화를 열 수 없습니다")
            return
        }

        say("「\(room.title)」 여는 중…")
        paint()

        guard let opened = try? reader.open(title: room.title) else {
            // No window, or the context would not resolve. kbbs does not open one: that
            // brings KakaoTalk to the front, which is never a side effect of a read.
            waiting = WaitingState(title: room.title, since: Date())
            screen = .waiting
            nextWindowWatch = Date().addingTimeInterval(Self.windowWatch)
            lastFrame = []
            return
        }

        self.opened = opened
        var state = RoomState(title: room.title)
        state.matchedWindowTitle = opened.matchedTitle
        state.link = .live(lastRefresh: Date())
        roomState = state
        screen = .room
        lastFrame = []
        pollRoom(force: true)
    }

    private mutating func leaveRoom() {
        roomState = nil
        opened = nil
        nextRoomPoll = nil
        screen = .list
        lastFrame = []
    }

    private mutating func pollRoom(force: Bool) {
        guard let reader, let opened, var room = roomState else { return }
        if force { room.note = "읽는 중…" }
        roomState = room
        if force { paint() }

        guard let read = reader.read(opened, title: room.title, limit: readLimit) else {
            room.link = .down(since: Date(), reason: "읽기 실패")
            room.note = "읽지 못했습니다"
            noteSetAt = Date()
            roomState = room
            nextRoomPoll = Date().addingTimeInterval(nextPollDelay)
            return
        }

        room.messages = read.snapshot.messages
        room.link = .live(lastRefresh: Date())
        lastReadSeconds = read.elapsed
        room.pollSeconds = nextPollDelay
        room.note = String(format: "%d개 · 읽기 %.1f초 · 다음 %.0f초 뒤", read.snapshot.count, read.elapsed, nextPollDelay)
        noteSetAt = Date()
        roomState = room
        nextRoomPoll = Date().addingTimeInterval(nextPollDelay)
    }

    private mutating func serviceRoomPoll() {
        guard screen == .room, let due = nextRoomPoll, Date() >= due else { return }
        pollRoom(force: false)
    }

    /// The waiting screen's whole job: notice the moment the user opens the room in
    /// KakaoTalk themselves, and slide into it.
    private mutating func serviceWindowWatch() {
        guard screen == .waiting, let waiting, let reader,
              let due = nextWindowWatch, Date() >= due
        else {
            return
        }
        nextWindowWatch = Date().addingTimeInterval(Self.windowWatch)
        guard let opened = try? reader.open(title: waiting.title) else { return }

        self.opened = opened
        var state = RoomState(title: waiting.title)
        state.matchedWindowTitle = opened.matchedTitle
        state.link = .live(lastRefresh: Date())
        roomState = state
        self.waiting = nil
        screen = .room
        lastFrame = []
        pollRoom(force: true)
    }

    private mutating func rescan() {
        say("읽는 중… 카카오톡이 응답할 때까지 화면이 멈춥니다")
        paint()
        if let rooms = refresh() {
            list.rooms = rooms
            list.page = min(list.page, list.pageCount - 1)
            list.cursor = min(list.cursor, max(0, list.roomsOnPage - 1))
            list.link = .live(lastRefresh: Date())
            say("\(rooms.count)개 읽음")
        } else {
            list.link = .down(since: Date(), reason: "읽기 실패")
            say("읽지 못했습니다")
        }
    }

    // MARK: - Timers and painting

    private mutating func say(_ note: String) {
        switch screen {
        case .list: list.note = note
        case .room: roomState?.note = note
        case .waiting: break
        }
        noteSetAt = Date()
    }

    private mutating func expireTimers() {
        let now = Date()
        if let touched = bufferTouchedAt, now.timeIntervalSince(touched) >= Self.bufferIdle {
            list.clearNumberBuffer()
            bufferTouchedAt = nil
        }
        if let set = noteSetAt, now.timeIntervalSince(set) >= Self.noteLife {
            list.note = nil
            roomState?.note = nil
            noteSetAt = nil
        }
    }

    private mutating func tickClocks() {
        let now = Date()
        list.clock = now
        roomState?.clock = now
    }

    /// One write(2) of at most 24 lines, positioned with `ESC[H` and cleared per line
    /// with `ESC[K`. No `ESC[2J` anywhere: clearing the whole screen is what flickers.
    private mutating func paint() {
        let size = RawMode.size()
        let rows: [String]
        if !size.isBigEnough {
            rows = tooSmall(size)
        } else {
            switch screen {
            case .list: rows = ListScreen.render(list).render()
            case .room: rows = RoomScreen.render(roomState ?? RoomState(title: "")).render()
            case .waiting: rows = waitingFrame()
            }
        }
        guard rows != lastFrame else { return }
        lastFrame = rows

        var out = "\u{1B}[H"
        for (index, row) in rows.enumerated() {
            out += row + "\u{1B}[K"
            if index < rows.count - 1 { out += "\r\n" }
        }
        TTYOut.write(out)
    }

    private func waitingFrame() -> [String] {
        var f = Frame(width: 80, height: 24)
        let waited = waiting.map { Int(Date().timeIntervalSince($0.since)) } ?? 0
        let title = waiting?.title ?? ""
        let lines = [
            "",
            "  「\(Width.elide(title, to: 40))」 은(는) 카카오톡에 창이 열려 있지 않습니다.",
            "",
            "  kbbs 는 대신 열지 않습니다. 창을 여는 일은 카카오톡을 화면 앞으로",
            "  끌어내는 일이고, 읽기만 하는 동안에는 그러지 않습니다.",
            "",
            "  카카오톡에서 이 대화방을 직접 열어 주세요.",
            "  열리는 즉시 이 화면이 대화로 바뀝니다.",
            "",
            "  \(Theme.lineIndicator(Date())) 1초마다 확인 중 · \(waited)초 기다리는 중",
            "",
            "  Esc:목록으로  Q:종료",
        ]
        f.set(0, Frame.rule(left: "╔", fill: "═", right: "╗", width: 80))
        f.set(1, Frame.bordered("  창 없음", left: "║", right: "║", width: 80))
        f.set(2, Frame.rule(left: "╠", fill: "═", right: "╣", width: 80))
        for (offset, line) in lines.enumerated() where offset + 3 < 23 {
            f.set(offset + 3, Frame.bordered(line, left: "║", right: "║", width: 80))
        }
        for row in (lines.count + 3)..<23 {
            f.set(row, Frame.bordered("", left: "║", right: "║", width: 80))
        }
        f.set(23, Frame.rule(left: "╚", fill: "═", right: "╝", width: 80))
        return f.render()
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
