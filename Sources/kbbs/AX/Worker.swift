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
                let opened = try reader.open(title: title)
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
            if let window = kakao.windows.first(where: { $0.role == kAXWindowRole && $0.title == title }) {
                try? window.setAttribute(kAXMinimizedAttribute, value: false as CFBoolean)
            }
            return .closed(title: title, reason: nil)

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
        func log(_ line: String) { TTYOut.log("[open] \(line)") }
        log("요청 「\(title)」 보유행=\(rows.count) 목록창=\(listWindow == nil ? "없음" : "있음")")
        // The list reorders whenever a message arrives, and the table REUSES its row
        // views — so a handle kept from an earlier scan can now be showing a different
        // conversation entirely, and clicking it opens that one. Every open therefore
        // checks the row still says what it said, and re-scans when it does not.
        if rows[title] == nil || !Self.row(rows[title]!, stillShows: title) {
            log("행 재스캔 (없거나 낡음)")
            if let listWindow {
                let found = scanner.scan(in: listWindow, limit: 60, trace: nil)
                rows = Dictionary(found.map { ($0.discovery.title, $0.element) }, uniquingKeysWith: { first, _ in first })
                log("재스캔 결과 \(found.count)개")
            } else {
                log("목록 창이 없어 재스캔 불가")
            }
        }
        guard let row = rows[title] else {
            log("실패: 행 없음")
            return .openFailed(title: title, reason: "목록에서 그 행을 찾지 못했습니다")
        }
        guard Self.row(row, stillShows: title) else {
            log("실패: 행이 다른 방을 표시함")
            return .openFailed(title: title, reason: "목록이 바뀌었습니다. R 로 새로고침하세요")
        }

        let terminal = SystemFocusProbe.frontmostPID()
        // Put KakaoTalk back the way it was found: the list is raised only so the click
        // can land on it, and leaving it sitting over the user's screen afterwards is the
        // part they notice. Hiding the whole app does not work — NSRunningApplication.hide
        // on another process returns without hiding anything — so the list window is
        // minimized, which does.
        defer {
            if let listWindow {
                try? listWindow.setAttribute(kAXMinimizedAttribute, value: true as CFBoolean)
                log("목록 창 최소화")
            }
            if let terminal { SystemFocusProbe.activate(pid: terminal) }
        }

        // It may have been minimized by a previous open; raising a minimized window does
        // nothing, so it comes back first — and its rows are re-read once it has redrawn,
        // because the ones held from before point at where it used to be.
        if let listWindow {
            let found = ListWindowRestore.rowsAfterRestoring(
                listWindow: listWindow,
                scanner: scanner,
                limit: 60,
                log: log
            )
            if found.count > 2 {
                rows = Dictionary(found.map { ($0.discovery.title, $0.element) }, uniquingKeysWith: { first, _ in first })
                log("복원 후 재스캔 \(found.count)개")
            }
        }

        // 1. Front. KakaoTalk has to be frontmost for a click to reach it.
        mailbox.deliver(.openingStep(title: title, step: 1), generation: currentGeneration)
        kakao.activateForSend()
        let kakaoPID = KakaoTalkApp.runningApplication?.processIdentifier
        let front = kakaoPID.map { SystemFocusProbe.waitForFrontmost(pid: $0, timeout: 1.5) } ?? false
        // Not a gate. Being frontmost is a means, not the goal, and this check has failed
        // on a KakaoTalk that then opened the room perfectly well. What actually protects
        // the click is that its coordinates are inside KakaoTalk's own list window, which
        // is checked below, after the window is raised.
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
            if let opened = try? reader.open(title: title) {
                // Measured: a minimized window still reads, and still takes an injected
                // composer value with the 전송 button enabling. So the window kbbs had to
                // bring up gets put away again immediately instead of piling onto the
                // screen for the rest of the session.
                log("열림 확인 「\(opened.matchedTitle)」")
                try? opened.window.setAttribute(kAXMinimizedAttribute, value: true as CFBoolean)
                let token = nextToken
                nextToken += 1
                contexts[token] = opened
                return .opened(
                    token: token,
                    title: title,
                    matchedTitle: opened.matchedTitle,
                    elapsed: 0
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
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
