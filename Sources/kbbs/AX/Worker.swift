import Foundation

// MARK: - What crosses the boundary

/// A job for the worker. Values only: no live `UIElement` is ever named here, because a
/// live handle on the main thread is the data race this design exists to make impossible.
enum AXJob: Sendable {
    case scanList(limit: Int)
    case openRoom(title: String)
    /// `token` names a context the worker opened earlier and still holds.
    case readRoom(token: Int, title: String, limit: Int)
}

/// A finished job, reduced to things that are safe to hand to the main thread.
enum AXResult: Sendable {
    case list(rooms: [Room], elapsed: TimeInterval)
    case opened(token: Int, title: String, matchedTitle: String, elapsed: TimeInterval)
    case read(token: Int, snapshot: TranscriptSnapshot, elapsed: TimeInterval)
    case noWindow(title: String, candidates: [String])
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
    }

    private let lock = NSLock()
    private var items: [Stamped] = []

    func deliver(_ result: AXResult, generation: Int) {
        lock.lock()
        items.append(Stamped(result: result, generation: generation))
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
        return taken.filter { $0.generation == currentGeneration }.map(\.result)
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
    }

    /// What the worker is blocked on, if anything. Safe from the main thread.
    func running() -> Watchdog.Running? { watchdog.current() }

    /// Everything finished since the last call that still belongs to this generation.
    func collect(generation: Int) -> [AXResult] { mailbox.drain(currentGeneration: generation) }

    /// Queue one job. The caller stamps it with the generation it belongs to and is
    /// responsible for not queueing a second one while the first is outstanding.
    func submit(_ job: AXJob, generation: Int) {
        queue.async { [self] in
            watchdog.began(label: Self.label(for: job))
            let started = Date()
            let result = perform(job, started: started)
            watchdog.finished()
            mailbox.deliver(result, generation: generation)
        }
    }

    private static func label(for job: AXJob) -> String {
        switch job {
        case .scanList: return "대화방 목록 읽기"
        case .openRoom: return "대화방 열기"
        case .readRoom: return "대화 읽기"
        }
    }

    private func perform(_ job: AXJob, started: Date) -> AXResult {
        switch job {
        case .scanList(let limit):
            guard let listWindow else { return .failed(reason: "대화목록 창이 없습니다") }
            let found = scanner.scan(in: listWindow, limit: limit, trace: nil)
            guard !found.isEmpty else { return .failed(reason: "대화방을 하나도 읽지 못했습니다") }
            let open = Set(kakao.windows.compactMap { $0.title })
            let rooms = found.map { item in
                Room(
                    title: item.discovery.title,
                    lastMessage: item.discovery.lastMessage,
                    timeLabel: item.discovery.timeLabel,
                    unreadCount: item.discovery.unreadCount,
                    hasWindow: Kbbs.hasOpenWindow(item.discovery.title, among: open, listWindow: listWindow.title)
                )
            }
            return .list(rooms: rooms, elapsed: Date().timeIntervalSince(started))

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

    /// Forget a context the main thread has finished with. The handle dies here, on the
    /// queue that owns it.
    func release(token: Int) {
        queue.async { [self] in contexts[token] = nil }
    }
}
