import Foundation

/// Opening a room and reading it, without touching anything.
///
/// The only file besides the retained scraper that talks to Accessibility. Everything it
/// does is read-only by construction: it resolves a window that KakaoTalk already has
/// open, resolves the transcript context once, and keeps it for the life of the room.
/// It cannot open a window, cannot activate KakaoTalk and cannot type.
struct RoomReader {
    struct Opened {
        let window: UIElement
        let context: MessageTranscriptContext
        /// The window title actually matched, which is not always the room title asked
        /// for — Korean chat lists hold duplicate names, so the screen shows this.
        let matchedTitle: String
        let elapsed: TimeInterval
    }

    struct Read {
        let snapshot: TranscriptSnapshot
        let elapsed: TimeInterval
    }

    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner

    init(kakao: KakaoTalkApp, trace: Bool = false) {
        self.kakao = kakao
        self.runner = AXActionRunner(traceEnabled: trace)
    }

    /// The window KakaoTalk already has open for this room, if there is one.
    ///
    /// Title match is all there is — a window carries no chat id. The role check is not
    /// ceremony: with every window closed, the only element titled "카카오톡" is the
    /// application, and matching on title alone reports a window that is not one.
    func window(titled title: String) -> UIElement? {
        kakao.windows.first { candidate in
            candidate.role == kAXWindowRole && candidate.title == title
        }
    }

    /// Resolve the transcript context for a room whose window is already open.
    ///
    /// Returns nil when the room has no window. It does NOT open one: opening is a
    /// separate, user-confirmed act, because it brings KakaoTalk to the front.
    enum OpenFailure: Error {
        /// KakaoTalk has no window with this title.
        case noWindow(candidates: [String])
        /// The window is there, but its input box and transcript would not resolve.
        case noContext(matchedTitle: String)
    }

    /// `within` bounds how long the resolve may spend before giving up. A room's own
    /// window answers in well under a second; a window that is not a room at all — the
    /// KakaoPay tab is a web view — has no composer to find, and the search for one ran
    /// for 86 seconds proving that before this existed.
    func open(title: String, within: TimeInterval? = nil) throws -> Opened {
        let started = Date()
        guard let window = window(titled: title) else {
            throw OpenFailure.noWindow(candidates: kakao.windows.compactMap { $0.title })
        }
        let resolver = MessageContextResolver(
            kakao: kakao,
            runner: runner,
            interactionMode: .backgroundSafe,
            deadline: within.map { started.addingTimeInterval($0) }
        )
        guard let context = resolver.resolve(in: window) else {
            throw OpenFailure.noContext(matchedTitle: window.title ?? title)
        }
        return Opened(
            window: window,
            context: context,
            matchedTitle: window.title ?? title,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// A warm read against a context resolved earlier. This is the one that runs every
    /// few seconds, so it is the one whose cost decides the poll interval.
    func read(_ opened: Opened, title: String, limit: Int) -> Read? {
        let started = Date()
        let reader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner, interactionMode: .backgroundSafe)
        do {
            let snapshot = try reader.readSnapshot(
                from: opened.context,
                chatWindow: opened.window,
                fallbackChatTitle: title,
                limit: limit
            )
            return Read(snapshot: snapshot, elapsed: Date().timeIntervalSince(started))
        } catch {
            return nil
        }
    }
}
