import AppKit
import Foundation

// MARK: - What crosses the boundary

/// A job for the worker. Values only: no live `UIElement` is ever named here, because a
/// live handle on the main thread is the data race this design exists to make impossible.
enum AXJob: Sendable {
    case scanList(limit: Int)
    case openRoom(title: String)
    /// `token` names a context the worker opened earlier and still holds.
    case readRoom(token: Int, title: String, limit: Int)
    /// The one job that posts a hardware event. Only ever queued after the user has said
    /// Y to the gate that spells out what it does.
    case openWindow(title: String)
    case send(token: Int, body: String)
    case closeWindow(title: String)
    case showWindow(title: String)
}

/// A finished job, reduced to things that are safe to hand to the main thread.
enum AXResult: Sendable {
    case list(rooms: [Room], source: ListSource, elapsed: TimeInterval)
    case opened(token: Int, title: String, matchedTitle: String, elapsed: TimeInterval)
    case read(token: Int, snapshot: TranscriptSnapshot, elapsed: TimeInterval)
    case noWindow(title: String, candidates: [String])
    /// A step of the window-opening ladder finished. `step` is how many are done.
    case openingStep(title: String, step: Int)
    case openFailed(title: String, reason: String)
    case sent(body: String, composerCleared: Bool)
    case sendRefused(body: String, reason: String)
    case closed(title: String, reason: String?)
    case shown(title: String)
    case failed(reason: String)
}

// MARK: - The mailbox

/// The only shared mutable state in the program, held for microseconds at a time.
///
/// The main loop already wakes every 100ms, so no self-pipe is needed: 100ms of extra
/// latency on a result that took four seconds is invisible.
final class Mailbox: @unchecked Sendable {
    private struct Stamped {
        let result: AXResult
        let generation: Int
        /// Survives a generation bump. A send has already happened by the time its result
        /// exists, so abandoning it would leave a message sent and nothing saying so.
        let sticky: Bool
    }

    private let lock = NSLock()
    private var items: [Stamped] = []

    func deliver(_ result: AXResult, generation: Int, sticky: Bool = false) {
        lock.lock()
        items.append(Stamped(result: result, generation: generation, sticky: sticky))
        lock.unlock()
    }

    /// Everything waiting, minus anything queued before the last time the user changed
    /// their mind.
    ///
    /// Accessibility calls cannot be cancelled — the scraper is synchronous and full of
    /// sleeps — so Esc, a page turn and a quit do not stop work, they abandon it. The job
    /// still runs to completion and still occupies the queue; its answer is simply thrown
    /// away on arrival, which is what stops the previous room's transcript from landing
    /// in this one.
    func drain(currentGeneration: Int) -> [AXResult] {
        lock.lock()
        let taken = items
        items.removeAll()
        lock.unlock()
        return taken.filter { $0.sticky || $0.generation == currentGeneration }.map(\.result)
    }
}

// MARK: - How late is late

/// How a blocked call is presented, by wall time.
///
/// Per-call blocking is already bounded by `AXUIElementSetMessagingTimeout`; it is the
/// hundreds of calls in one walk that add up, which is why these tiers are driven by how
/// long the whole job has been running rather than by any single call.
enum DelayTier: Sendable {
    case quiet
    case slow
    case stuck

    static func of(elapsed: TimeInterval) -> DelayTier {
        if elapsed >= 6 { return .stuck }
        if elapsed >= 2 { return .slow }
        return .quiet
    }

    func badge(elapsed: TimeInterval) -> String? {
        switch self {
        // Floored, not rounded: at 12.7 seconds the honest thing to print is 12, because
        // 13 seconds have not passed yet. A counter that overstates is a counter nobody
        // trusts the second they check it.
        case .quiet: return nil
        case .slow: return "[응답 느림 \(Int(elapsed))초]"
        case .stuck: return "[카카오톡 응답 없음 \(Int(elapsed))초]"
        }
    }

    /// The line that goes under the badge when there is nothing to do but wait. It is
    /// the literal truth, which is the only thing worth saying at that point.
    var advice: String? {
        self == .stuck ? "취소할 수 없습니다. 기다리거나 Ctrl-C 로 종료하세요." : nil
    }
}

/// How long to wait after a read fails, by how many times it has failed in a row.
enum Backoff {
    private static let ladder: [TimeInterval] = [3, 5, 10, 15]

    static func interval(afterFailures failures: Int) -> TimeInterval? {
        guard failures > 0 else { return nil }
        return ladder[min(failures, ladder.count) - 1]
    }
}

// MARK: - The watchdog

/// What the worker is doing right now, for the main loop to animate against.
///
/// Written by the worker immediately before it blocks and cleared immediately after.
/// It is the only thing the main thread can learn about a call in flight.
final class Watchdog: @unchecked Sendable {
    struct Running {
        let label: String
        let startedAt: Date
        var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    }

    private let lock = NSLock()
    private var label: String?
    private var startedAt: Date?

    func began(label: String, at date: Date = Date()) {
        lock.lock()
        self.label = label
        self.startedAt = date
        lock.unlock()
    }

    func finished() {
        lock.lock()
        label = nil
        startedAt = nil
        lock.unlock()
    }

    func current() -> Running? {
        lock.lock()
        defer { lock.unlock() }
        guard let label, let startedAt else { return nil }
        return Running(label: label, startedAt: startedAt)
    }
}

// MARK: - The worker

/// One serial queue, created once, on which every AXUIElement call in the process runs.
///
/// The main thread never calls Accessibility — not one call, not even to count windows.
/// It submits jobs and reads values back. Live handles stay here, in `contexts`, keyed by
/// an integer the main thread passes around instead.
final class AXWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kbbs.ax")
    private let mailbox = Mailbox()
    private let watchdog = Watchdog()

    private let kakao: KakaoTalkApp
    private let reader: RoomReader
    /// Only the window-opening job uses this, and only for the double-click.
    private let runner: AXActionRunner
    private let scanner = ChatListScanner()
    /// nil when kbbs was started straight into one room, which needs no list.
    private let listWindow: UIElement?
    private let trace: Bool

    /// Worker-side only. The main thread sees an Int and nothing else.
    private var contexts: [Int: RoomReader.Opened] = [:]
    private var nextToken = 1

    init(kakao: KakaoTalkApp, listWindow: UIElement?, trace: Bool) {
        self.kakao = kakao
        self.listWindow = listWindow
        self.trace = trace
        self.reader = RoomReader(kakao: kakao, trace: trace)
        self.runner = AXActionRunner(traceEnabled: trace)
    }

    /// What the worker is blocked on, if anything. Safe from the main thread.
    func running() -> Watchdog.Running? { watchdog.current() }

    /// Everything finished since the last call that still belongs to this generation.
    func collect(generation: Int) -> [AXResult] { mailbox.drain(currentGeneration: generation) }

    /// Queue one job. The caller stamps it with the generation it belongs to and is
    /// responsible for not queueing a second one while the first is outstanding.
    /// The generation of the job currently running, so a job that reports progress can
    /// stamp its own messages. Worker-side only.
    private var currentGeneration = 0

    func submit(_ job: AXJob, generation: Int) {
        queue.async { [self] in
            currentGeneration = generation
            watchdog.began(label: Self.label(for: job))
            let started = Date()
            let result = perform(job, started: started)
            watchdog.finished()
            mailbox.deliver(result, generation: generation, sticky: Self.mustBeHeard(result))
        }
    }

    /// A result the user has to be told about whatever else they have done since.
    private static func mustBeHeard(_ result: AXResult) -> Bool {
        switch result {
        case .sent, .sendRefused: return true
        default: return false
        }
    }

    private static func label(for job: AXJob) -> String {
        switch job {
        case .scanList: return "대화방 목록 읽기"
        case .openRoom: return "대화방 열기"
        case .readRoom: return "대화 읽기"
        case .openWindow: return "창 열기"
        case .send: return "전송"
        case .closeWindow: return "창 닫기"
        case .showWindow: return "창 보이기"
        }
    }

    private func perform(_ job: AXJob, started: Date) -> AXResult {
        switch job {
        case .scanList(let limit):
            // The chat list window can be closed at any moment — closing it does not quit
            // KakaoTalk — so a refresh that assumed it was still there would empty the
            // board index the moment the user closed one window.
            let window = listWindow ?? kakao.chatListWindow.flatMap { candidate in
                candidate.role == kAXWindowRole ? candidate : nil
            }
            let found = window.map { scanner.scan(in: $0, limit: limit, trace: nil) } ?? []

            if !found.isEmpty, let window {
                rows = Dictionary(found.map { ($0.discovery.title, $0.element) }, uniquingKeysWith: { first, _ in first })
                let open = Set(kakao.windows.compactMap { $0.title })
                let rooms = found.map { item in
                    Room(
                        title: item.discovery.title,
                        lastMessage: item.discovery.lastMessage,
                        timeLabel: item.discovery.timeLabel,
                        unreadCount: item.discovery.unreadCount,
                        hasWindow: Kbbs.hasOpenWindow(item.discovery.title, among: open, listWindow: window.title)
                    )
                }
                return .list(rooms: rooms, source: .chatList, elapsed: Date().timeIntervalSince(started))
            }

            rows = [:]
            let fallback = RoomList.fromOpenWindows(
                titles: kakao.windows.compactMap { $0.role == kAXWindowRole ? $0.title : nil },
                listWindowTitle: window?.title ?? "카카오톡"
            )
            guard !fallback.isEmpty else { return .failed(reason: "카카오톡 창이 하나도 열려 있지 않습니다") }
            return .list(rooms: fallback, source: .openWindowsOnly, elapsed: Date().timeIntervalSince(started))

        case .openRoom(let title):
            do {
                let opened = try reader.open(title: title, within: 8)
                let token = nextToken
                nextToken += 1
                contexts[token] = opened
                return .opened(
                    token: token,
                    title: title,
                    matchedTitle: opened.matchedTitle,
                    elapsed: Date().timeIntervalSince(started)
                )
            } catch RoomReader.OpenFailure.noWindow(let candidates) {
                return .noWindow(title: title, candidates: candidates)
            } catch RoomReader.OpenFailure.timedOut(_, let seconds) {
                // Not the same as not finding them. Saying "찾지 못했습니다" for a search
                // that ran out of time tells the user a fact about their room that
                // nothing established.
                return .failed(reason: "「\(title)」 를 \(Int(seconds))초 안에 읽지 못했습니다")
            } catch {
                return .failed(reason: "「\(title)」 의 입력창과 대화 영역을 찾지 못했습니다")
            }

        case .readRoom(let token, let title, let limit):
            guard let opened = contexts[token] else {
                return .failed(reason: "대화방 연결이 끊겼습니다")
            }
            guard let read = reader.read(opened, title: title, limit: limit) else {
                // The context may have gone stale — the window was closed or reused.
                contexts[token] = nil
                return .failed(reason: "전사를 읽지 못했습니다")
            }
            return .read(token: token, snapshot: read.snapshot, elapsed: read.elapsed)

        case .openWindow(let title):
            return openWindow(titled: title)

        case .send(let token, let body):
            guard let opened = contexts[token] else {
                return .sendRefused(body: body, reason: "대화방 연결이 끊겼습니다")
            }
            do {
                let outcome = try Sender(trace: trace).send(body, window: opened.window, context: opened.context)
                return .sent(body: body, composerCleared: outcome == .composerCleared)
            } catch {
                return .sendRefused(body: body, reason: "\(error)")
            }

        case .showWindow(let title):
            guard let window = kakao.windows.first(where: { $0.role == kAXWindowRole && $0.title == title }) else {
                return .failed(reason: "「\(title)」 창이 없습니다")
            }
            try? window.setAttribute(kAXMinimizedAttribute, value: false as CFBoolean)
            return .shown(title: title)

        case .closeWindow(let title):
            do {
                try WindowCloser(kakao: kakao).close(title: title)
                return .closed(title: title, reason: nil)
            } catch {
                return .closed(title: title, reason: "\(error)")
            }
        }
    }

    /// Open a room's window by driving KakaoTalk's own chat list.
    ///
    /// The only hardware event kbbs posts. KakaoTalk's rows expose neither AXPress nor a
    /// Return that works — the comment recording that is in AXActionRunner — so a double
    /// click at screen coordinates is the only path that exists.
    ///
    /// Four steps, each reported so a click that never lands is visible as the step it
    /// stopped on. The terminal gets the front back at the end whatever happened.
    private func openWindow(titled title: String) -> AXResult {
        let openStarted = Date()
        func log(_ line: String) {
            TTYOut.log(String(format: "[open %5.0fms] ", Date().timeIntervalSince(openStarted) * 1000) + line)
        }
        log("요청 「\(title)」 보유행=\(rows.count) 목록창=\(listWindow == nil ? "없음" : "있음")")
        let terminal = SystemFocusProbe.frontmostPID()
        // Put KakaoTalk back the way it was found: the list is raised only so the click
        // can land on it, and leaving it sitting over the user's screen afterwards is the
        // part they notice. Hiding the whole app does not work — NSRunningApplication.hide
        // on another process returns without hiding anything — so the list window is
        // minimized, which does. The net only fires if step 4 did not already get there.
        var listPutAway = false
        defer {
            if let listWindow, !listPutAway {
                Self.putAway(listWindow, label: "목록 창", log: log)
            }
            if let terminal { SystemFocusProbe.activate(pid: terminal) }
        }

        // 0. Which row, asked while the list is still out of sight.
        //
        // A minimized window answers what its rows SAY but not where they ARE — a handle
        // bound there reports frame=nil, which is the bug 9d03b24 fixed by moving the
        // binding after the restore. Moving the whole scan after the restore was the
        // wrong lesson from that: only the frame has to wait. So the expensive question
        // is settled here, off-screen, and the frame is taken again below once the list
        // is up. If this comes back empty nothing is lost — the path below still runs.
        let presumed = listWindow.flatMap { window -> UIElement? in
            let (count, found) = scanner.findRow(titled: title, in: window, limit: 60)
            log("사전 스캔 \(count)행 \(found == nil ? "— 그 방 없음" : "— 행 확보")")
            return found
        }

        // 1. Front. KakaoTalk has to be frontmost for a click to reach it, and the list
        //    has to be out of the Dock before it can be raised.
        if let listWindow { _ = ListWindowRestore.restore(listWindow, log: log) }

        mailbox.deliver(.openingStep(title: title, step: 1), generation: currentGeneration)
        kakao.activateForSend()
        let kakaoPID = KakaoTalkApp.runningApplication?.processIdentifier
        // Not a gate. Being frontmost is a means, not the goal, and this check has failed
        // on a KakaoTalk that then opened the room perfectly well. What actually protects
        // the click is that its coordinates are inside KakaoTalk's own list window, which
        // is checked below, after the window is raised.
        //
        // What it really is, is the pause KakaoTalk needs before a click will land, and
        // waitForFrontmost spends the whole second either way — it just stops asking an
        // unanswerable question sixty times on the way through.
        let front = kakaoPID.map { SystemFocusProbe.waitForFrontmost(pid: $0, timeout: 1.0) } ?? false
        log("전면 전환 \(front ? "확인" : "안 됨") 최전면=\(SystemFocusProbe.frontmostPID().map(String.init) ?? "모름") 카톡=\(kakaoPID.map(String.init) ?? "?")")

        // 2. Raise the list, then take coordinates. Bringing the app forward brings ALL
        //    its windows, so a chat window sitting over the list takes the double-click
        //    instead — which is how an earlier version closed an unrelated chat rather
        //    than opening the one asked for. The frame is re-read after the raise, not
        //    trusted from the scan.
        mailbox.deliver(.openingStep(title: title, step: 2), generation: currentGeneration)
        if let listWindow {
            try? listWindow.performAction(kAXRaiseAction)
            Thread.sleep(forTimeInterval: 0.2)
        }
        // 2b. Bind the row, now that there is a frame to bind. The pre-scan's handle is
        //     kept if it still has a frame and still shows this room — the list reorders
        //     on every message, so that is not a formality. Otherwise the list is read
        //     again, which is what this used to do every single time.
        let row: UIElement
        // Which of the two checks turned the pre-scan handle down, because so far it is
        // always turned down and the answer decides whether the pre-scan is worth having.
        if let presumed, presumed.frame == nil {
            log("사전 스캔 행 버림 — 좌표 없음")
        } else if let presumed, !Self.row(presumed, stillShows: title) {
            log("사전 스캔 행 버림 — 다른 방을 표시")
        }
        if let presumed, presumed.frame != nil, Self.row(presumed, stillShows: title) {
            row = presumed
            log("사전 스캔 행 사용")
        } else if let listWindow, let fresh = ListWindowRestore.rowAfterRestoring(
            titled: title,
            listWindow: listWindow,
            scanner: scanner,
            limit: 60,
            log: log
        ), Self.row(fresh, stillShows: title) {
            row = fresh
            log("재스캔 행 사용")
        } else if let held = rows[title], held.frame != nil, Self.row(held, stillShows: title) {
            row = held
            log("보유 행 사용")
        } else {
            log("실패: 행 없음")
            return .openFailed(title: title, reason: "목록에서 그 방을 찾지 못했습니다")
        }

        // A row that has scrolled out of sight still has a frame — below the window, on
        // the desktop — so it has to be brought into view before its coordinates mean
        // anything. This is what made every room past the visible dozen unopenable.
        if let listWindow, let listFrame = listWindow.frame,
           RowClickGuard.clickPoint(rowFrame: row.frame, visibleScreens: [listFrame]) == nil {
            log("행이 창 밖 — 스크롤 시작")
            _ = RowScroller.bringIntoView(row: row, listWindow: listWindow, runner: runner, log: log)
        }
        guard let point = RowClickGuard.clickPoint(
            rowFrame: row.frame,
            visibleScreens: OpenCommand.screensInEventSpace(),
            within: listWindow?.frame
        ) else {
            log("실패: 좌표 거부 frame=\(row.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "없음") 창=\(listWindow?.frame.map { "\(Int($0.minY))~\(Int($0.maxY))" } ?? "없음")")
            return .openFailed(title: title, reason: "목록에서 그 줄이 보이지 않습니다")
        }
        log("누를 좌표 (\(Int(point.x)),\(Int(point.y)))")

        // 3. One double-click. Never retried: a second one lands somewhere unknown.
        mailbox.deliver(.openingStep(title: title, step: 3), generation: currentGeneration)
        runner.mouseDoubleClick(at: point, label: "open row")

        // 4. Wait for the window to actually appear, then resolve it like any other.
        mailbox.deliver(.openingStep(title: title, step: 4), generation: currentGeneration)
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            // The window first, which is one attribute per window, and only then the
            // full resolve. A resolve against a window that has not appeared yet walks
            // the app twice — once to miss, once to list what it saw instead — and this
            // loop used to do that twenty-five times before giving up.
            guard reader.window(titled: title) != nil else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            // The window exists, so the click landed. That is the proof needed to put
            // both windows away, and it comes before the resolve rather than after it —
            // the resolve is the slow half and neither window is needed for it. Measured:
            // a minimized window still reads, and still takes an injected composer value
            // with the 전송 button enabling.
            //
            // The chat window goes first, while KakaoTalk has not yet settled focus onto
            // the window it just made.
            if let chatWindow = reader.window(titled: title) {
                Self.putAway(chatWindow, label: "대화 창", log: log)
            }
            if let listWindow, !listPutAway {
                listPutAway = Self.putAway(listWindow, label: "목록 창", log: log)
            }
            // One resolve, not a loop of them. Looping repeated an expensive search that
            // had already failed for a reason, and the reason does not change in 50ms.
            // The pause first is for a window KakaoTalk has made but not yet filled.
            Thread.sleep(forTimeInterval: 0.3)
            do {
                let opened = try reader.open(title: title, within: 10)
                log("열림 확인 「\(opened.matchedTitle)」")
                Self.putAway(opened.window, label: "대화 창", log: log)
                let token = nextToken
                nextToken += 1
                contexts[token] = opened
                return .opened(
                    token: token,
                    title: title,
                    matchedTitle: opened.matchedTitle,
                    elapsed: 0
                )
            } catch RoomReader.OpenFailure.timedOut(_, let seconds) {
                log("실패: 창은 열렸으나 \(Int(seconds))초 안에 못 읽음")
                return .openFailed(title: title, reason: "창은 열렸지만 \(Int(seconds))초 안에 읽지 못했습니다")
            } catch {
                log("실패: 창은 열렸으나 대화 영역이 없음")
                return .openFailed(title: title, reason: "창은 열렸지만 대화 영역이 없습니다")
            }
        }
        log("실패: 2.5초 안에 창이 안 열림. 지금 창=" + kakao.windows.compactMap { $0.title }.joined(separator: "/"))
        return .openFailed(title: title, reason: "창이 열리지 않았습니다")
    }

    /// Rows from the last scan, by title, so an open does not have to hunt for a row the
    /// scanner already found. Worker-side only, like every other live handle.
    private var rows: [String: UIElement] = [:]

    /// Take over the row handles from the scan that ran during the boot ladder, before
    /// this worker existed. Without them the first window-open of a session has nothing
    /// to click and fails every time.
    func adoptRows(_ items: [ChatListSnapshotItem]) {
        queue.sync {
            rows = Dictionary(items.map { ($0.discovery.title, $0.element) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Take over a context that was resolved before the worker existed — the `--room`
    /// path opens one during the boot ladder so it can report what it cost.
    ///
    /// Synchronous on purpose: it happens once, before the loop starts, and the handle
    /// has to be on the queue that owns it before anything else touches it.
    func adopt(_ opened: RoomReader.Opened) -> Int {
        queue.sync {
            let token = nextToken
            nextToken += 1
            contexts[token] = opened
            return token
        }
    }

    /// Whether this row element still displays the conversation it was found for.
    ///
    /// Cheap on purpose — a handful of queries against one row, next to a full re-scan.
    /// Minimize a window, and check that it went.
    ///
    /// `AXMinimized` is settable, and setting it returns success whether or not anything
    /// happened — the same lie as the 전송 button and the scroll actions. On a window
    /// KakaoTalk has only just built the write lands on nothing, which is how a chat
    /// window opened by kbbs was left sitting on the user's screen while the list beside
    /// it, minimized by the identical call, went away.
    ///
    /// Returns as soon as the read-back agrees, so the common case costs one extra
    /// attribute read and nothing else.
    @discardableResult
    static func putAway(_ window: UIElement, label: String, log: (String) -> Void) -> Bool {
        for attempt in 1...3 {
            try? window.setAttribute(kAXMinimizedAttribute, value: true as CFBoolean)
            if (window.attributeOptional(kAXMinimizedAttribute) ?? false) as Bool {
                log("\(label) 최소화\(attempt > 1 ? " (\(attempt)번째)" : "")")
                return true
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        log("\(label) 최소화 실패 — 창이 그대로 남음")
        return false
    }

    static func row(_ row: UIElement, stillShows title: String) -> Bool {
        let texts = row.findAll(role: kAXStaticTextRole, limit: 6, maxNodes: 60)
        return texts.contains { ($0.stringValue ?? $0.title ?? "") == title }
    }

    /// Forget a context the main thread has finished with. The handle dies here, on the
    /// queue that owns it.
    func release(token: Int) {
        queue.async { [self] in contexts[token] = nil }
    }
}
