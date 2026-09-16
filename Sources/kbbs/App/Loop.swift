import Darwin
import Foundation

/// The run loop: one thread, one screen at a time, a 100ms heartbeat.
///
/// This thread owns the model and the rendering and NOTHING else. It makes no
/// Accessibility call — not one, not even to count windows. Work goes to the worker's
/// serial queue and comes back as values through the mailbox, which is why a four-second
/// transcript read no longer stops the clock, the ●○○ indicator or the cursor keys.
///
/// Each iteration: wait up to 100ms for input, decode it, service the signal flags,
/// expire timers, drain the mailbox, queue at most one job, and repaint if the frame
/// changed. The 100ms timeout is the heartbeat and the only sleep on this thread.
struct Loop {
    private static let escapeGrace: TimeInterval = 0.025
    private static let bufferIdle: TimeInterval = 3.0
    private static let noteLife: TimeInterval = 2.5
    /// How often an open conversation is re-read, now that a read no longer blocks the
    /// screen. Measured cost is 3-9s, so this is a floor rather than a promise.
    private static let roomPoll: TimeInterval = 3.0
    /// How often the chat list is re-scanned while it is the screen you are looking at.
    private static let listPoll: TimeInterval = 15.0
    private static let windowWatch: TimeInterval = 1.0

    private enum Screen { case list, room, waiting, confirm }

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
    private var nextListPoll: Date?
    private var nextWindowWatch: Date?

    /// Bumped whenever the user changes their mind. Results stamped with anything older
    /// are read off the mailbox and dropped — abandonment, not cancellation, because an
    /// Accessibility call in flight cannot be stopped.
    private var generation = 1
    /// Touched only by this thread. At most one job is outstanding at a time, which is
    /// what keeps the queue from filling with reads nobody is waiting for any more.
    private var axBusy = false
    private var roomToken: Int?
    private var ledger = PendingLedger()
    private var readFailures = 0

    private let worker: AXWorker?
    private let readLimit: Int
    private let demoRescan: (() -> [Room])?

    init(
        rooms: [Room],
        link: LinkState,
        worker: AXWorker?,
        readLimit: Int = 60,
        source: ListSource = .chatList,
        demoRescan: (() -> [Room])? = nil
    ) {
        self.worker = worker
        self.readLimit = readLimit
        self.demoRescan = demoRescan
        list.rooms = rooms
        list.link = link
        list.source = source
        nextListPoll = Date().addingTimeInterval(Self.listPoll)
    }

    /// Start already inside a conversation, as `--room` does.
    mutating func enter(room: RoomState, token: Int) {
        roomState = room
        roomToken = token
        screen = .room
        nextRoomPoll = Date().addingTimeInterval(Self.roomPoll)
        nextListPoll = nil
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

            drainResults()
            expireTimers()
            serviceTimers()
            applyDelayTier()
            tickClocks()
            paint()
        }
    }

    // MARK: - Results

    private mutating func drainResults() {
        guard let worker else { return }
        for result in worker.collect(generation: generation) {
            // A progress report is not a finished job. Clearing the busy flag on one
            // would let a second job be queued while the click is still in flight.
            if case .openingStep = result {} else { axBusy = false }
            apply(result)
        }
    }

    private mutating func apply(_ result: AXResult) {
        switch result {
        case .list(let rooms, let source, let elapsed):
            list.rooms = rooms
            list.source = source
            list.page = min(list.page, list.pageCount - 1)
            list.cursor = min(list.cursor, max(0, list.roomsOnPage - 1))
            list.link = .live(lastRefresh: Date())
            say(String(format: "%d개 · %.1f초", rooms.count, elapsed) + (source == .chatList ? "" : " · 열린 창만"))
            nextListPoll = Date().addingTimeInterval(Self.listPoll)

        case .opened(let token, let title, let matched, let elapsed):
            roomToken = token
            var state = RoomState(title: title)
            state.matchedWindowTitle = matched
            state.link = .live(lastRefresh: Date())
            state.note = String(format: "열기 %.1f초 · 읽는 중…", elapsed)
            roomState = state
            waiting = nil
            list.confirm = nil
            screen = .room
            nextWindowWatch = nil
            nextListPoll = nil
            lastFrame = []
            submit(.readRoom(token: token, title: title, limit: readLimit))

        case .read(let token, let snapshot, let elapsed):
            guard roomToken == token, var room = roomState else { break }
            readFailures = 0
            room.messages = snapshot.messages
            ledger.reconcile(against: snapshot.messages)
            room.pending = ledger.entries
            room.link = .live(lastRefresh: Date())
            room.pollSeconds = Self.roomPoll
            room.note = String(format: "%d개 · 읽기 %.1f초", snapshot.count, elapsed)
            noteSetAt = Date()
            roomState = room
            nextRoomPoll = Date().addingTimeInterval(Self.roomPoll)

        case .noWindow(let title, _):
            // From the list this is a question, not a failure: the user decides whether
            // kbbs may take over the screen and the mouse to open it. From the waiting
            // screen it is just "not yet" and the watch keeps running.
            if screen == .waiting {
                nextWindowWatch = Date().addingTimeInterval(Self.windowWatch)
            } else {
                list.confirm = ConfirmBox(title: title, stage: .asking)
                screen = .confirm
                lastFrame = []
            }

        case .openingStep(_, let step):
            list.confirm?.stage = .opening(step: step)

        case .openFailed(let title, let reason):
            list.confirm = ConfirmBox(title: title, stage: .failed(reason: reason))
            screen = .confirm
            lastFrame = []

        case .sent(_, let cleared):
            roomState?.note = cleared ? "보냈습니다 — 전사에서 확인 중" : "눌렀지만 입력창에 남아 있습니다. 다시 보내지 마세요."
            noteSetAt = Date()
            nextRoomPoll = Date().addingTimeInterval(1.0)

        case .sendRefused(let body, let reason):
            // Every refusal happens before the press, so nothing was sent — the text is
            // handed back to the composer rather than lost.
            ledger.dropLast(body: body)
            if var room = roomState {
                room.pending = ledger.entries
                if room.composer.isEmpty { room.composer = body }
                room.note = "보내지 않았습니다: \(reason)"
                roomState = room
            }
            noteSetAt = Date()

        case .failed(let reason):
            readFailures += 1
            let wait = Backoff.interval(afterFailures: readFailures) ?? Self.roomPoll
            switch screen {
            case .room:
                roomState?.link = .down(since: Date(), reason: reason)
                roomState?.note = "\(reason) · \(Int(wait))초 뒤 다시"
                nextRoomPoll = Date().addingTimeInterval(wait)
            case .list, .confirm:
                list.link = .down(since: Date(), reason: reason)
                say(reason)
                nextListPoll = Date().addingTimeInterval(wait)
            case .waiting:
                nextWindowWatch = Date().addingTimeInterval(Self.windowWatch)
            }
            noteSetAt = Date()
        }
    }

    private mutating func submit(_ job: AXJob) {
        guard let worker, !axBusy else { return }
        axBusy = true
        worker.submit(job, generation: generation)
    }

    /// The user changed their mind. Anything in flight still runs to completion on the
    /// worker — it cannot be stopped — but its answer will be dropped on arrival.
    private mutating func abandonInFlight() {
        generation += 1
        axBusy = false
    }

    // MARK: - Keys

    private enum Outcome { case carryOn, quit }

    private mutating func handle(_ key: Key) -> Outcome {
        switch screen {
        case .list: return handleList(key)
        case .room: return handleRoom(key)
        case .waiting: return handleWaiting(key)
        case .confirm: return handleConfirm(key)
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

    /// Reading only. Typing fills the composer but Enter does not send: the send machine
    /// is M6, and a key that looks like it sent but did not is the worst lie this program
    /// could tell.
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
            if let token = roomToken {
                room.note = "읽는 중…"
                roomState = room
                submit(.readRoom(token: token, title: room.title, limit: readLimit))
            }
            return .carryOn
        case .backspace:
            if !room.composer.isEmpty { room.composer.removeLast() }
        case .enter:
            if !room.composer.isEmpty, let token = roomToken, !axBusy {
                let body = room.composer
                room.composer = ""
                ledger.add(body: body, transcript: room.messages)
                room.pending = ledger.entries
                roomState = room
                submit(.send(token: token, body: body))
                return .carryOn
            }
        case .char(let c):
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

    /// The gate. Enter is deliberately unbound: the user got here by pressing Enter on
    /// the list, and a second one must not roll straight through the warning.
    private mutating func handleConfirm(_ key: Key) -> Outcome {
        guard let confirm = list.confirm else {
            screen = .list
            return .carryOn
        }

        switch confirm.stage {
        case .asking:
            switch key {
            case .control("c"):
                return .quit
            case .char("y"), .char("Y"):
                list.confirm?.stage = .opening(step: 0)
                submit(.openWindow(title: confirm.title))
            case .char("n"), .char("N"), .escape:
                dismissConfirm()
            default:
                break
            }
        case .opening:
            // Keys are dead while KakaoTalk has the front and a click is in flight;
            // Ctrl-C still works because it arrives as a signal, not as a key.
            if case .control("c") = key { return .quit }
        case .failed:
            switch key {
            case .control("c"):
                return .quit
            case .char("r"), .char("R"):
                dismissConfirm()
                rescan()
            case .escape, .char("n"), .char("N"):
                dismissConfirm()
            default:
                break
            }
        }
        return .carryOn
    }

    private mutating func dismissConfirm() {
        list.confirm = nil
        screen = .list
        lastFrame = []
    }

    private mutating func handleWaiting(_ key: Key) -> Outcome {
        switch key {
        case .char("q"), .char("Q"), .control("c"):
            return .quit
        case .escape:
            waiting = nil
            screen = .list
            nextWindowWatch = nil
            nextListPoll = Date().addingTimeInterval(Self.listPoll)
            abandonInFlight()
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

        guard worker != nil else {
            say("예시 모드에서는 대화를 열 수 없습니다")
            return
        }
        guard !axBusy else {
            say("[대기중] 카카오톡을 읽고 있습니다")
            return
        }
        say("「\(room.title)」 여는 중…")
        submit(.openRoom(title: room.title))
    }

    private mutating func leaveRoom() {
        ledger = PendingLedger()
        if let token = roomToken { worker?.release(token: token) }
        roomToken = nil
        roomState = nil
        nextRoomPoll = nil
        nextListPoll = Date().addingTimeInterval(Self.listPoll)
        readFailures = 0
        screen = .list
        abandonInFlight()
        lastFrame = []
    }

    private mutating func rescan() {
        if let demoRescan {
            list.rooms = demoRescan()
            say("\(list.rooms.count)개 읽음")
            return
        }
        guard !axBusy else {
            say("[대기중] 이미 읽고 있습니다")
            return
        }
        say("읽는 중…")
        submit(.scanList(limit: readLimit))
    }

    // MARK: - Timers

    private mutating func serviceTimers() {
        let now = Date()

        if screen == .room, let due = nextRoomPoll, now >= due, !axBusy, let token = roomToken,
           let title = roomState?.title {
            submit(.readRoom(token: token, title: title, limit: readLimit))
            nextRoomPoll = now.addingTimeInterval(Self.roomPoll)
        }

        if screen == .list, let due = nextListPoll, now >= due, !axBusy, worker != nil {
            submit(.scanList(limit: readLimit))
            nextListPoll = now.addingTimeInterval(Self.listPoll)
        }

        if screen == .waiting, let waiting, let due = nextWindowWatch, now >= due, !axBusy {
            nextWindowWatch = now.addingTimeInterval(Self.windowWatch)
            submit(.openRoom(title: waiting.title))
        }
    }

    /// Say out loud that a call is taking a long time, and past six seconds say the one
    /// thing that is literally true about it.
    private mutating func applyDelayTier() {
        guard let running = worker?.running() else { return }
        let elapsed = running.elapsed
        let tier = DelayTier.of(elapsed: elapsed)
        guard let badge = tier.badge(elapsed: elapsed) else { return }

        var text = running.label + " " + badge
        if let advice = tier.advice { text += " — " + advice }
        let down = LinkState.down(since: running.startedAt, reason: "응답 없음")
        let slow = LinkState.slow(since: running.startedAt)

        switch screen {
        case .list, .confirm:
            list.note = text
            list.link = tier == .stuck ? down : slow
        case .room:
            roomState?.note = text
            roomState?.link = tier == .stuck ? down : slow
        case .waiting:
            break
        }
        noteSetAt = Date()
    }

    private mutating func say(_ note: String) {
        switch screen {
        case .list, .confirm: list.note = note
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

    // MARK: - Painting

    private mutating func paint() {
        let size = RawMode.size()
        let rows: [String]
        if !size.isBigEnough {
            rows = tooSmall(size)
        } else {
            switch screen {
            case .list, .confirm: rows = ListScreen.render(list).render()
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
