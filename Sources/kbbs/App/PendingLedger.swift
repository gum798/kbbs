import Foundation

/// Messages kbbs pressed send on, held until the transcript shows them.
///
/// The press returns nothing trustworthy (see `Sender`), so a send is only ever confirmed
/// by reading it back. One that never comes back becomes [미확인] rather than
/// disappearing — a false [미확인] costs doubt, a false ✓ costs a message.
struct PendingLedger {
    enum State: Equatable {
        case sending
        case unconfirmed
    }

    struct Entry: Equatable {
        let body: String
        let sentAt: Date
        /// Copies of this text already in the transcript when it was sent. Confirmation
        /// means seeing MORE than this, so an old identical message cannot confirm a new
        /// one.
        let baselineCount: Int
        var state: State
    }

    /// A guess. Nobody has measured KakaoTalk's slowest render.
    static let confirmationWindow: TimeInterval = 9

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func add(body: String, transcript: [TranscriptMessage], now: Date = Date()) {
        entries.append(
            Entry(
                body: body,
                sentAt: now,
                baselineCount: Self.count(of: body, in: transcript),
                state: .sending
            )
        )
    }

    /// Counts rather than matches one-for-one, so two sends of the same text need two
    /// new copies back.
    mutating func reconcile(against transcript: [TranscriptMessage], now: Date = Date()) {
        var remaining: [Entry] = []
        var confirmedByBody: [String: Int] = [:]

        for entry in entries {
            let key = Self.normalise(entry.body)
            let seen = Self.count(of: entry.body, in: transcript)
            let alreadyCredited = confirmedByBody[key] ?? 0
            if seen > entry.baselineCount + alreadyCredited {
                confirmedByBody[key] = alreadyCredited + 1
                continue
            }
            var entry = entry
            if now.timeIntervalSince(entry.sentAt) >= Self.confirmationWindow {
                entry.state = .unconfirmed
            }
            remaining.append(entry)
        }
        entries = remaining
    }

    /// Undo an entry whose send was refused before the press.
    mutating func dropLast(body: String) {
        if let index = entries.lastIndex(where: { $0.body == body }) {
            entries.remove(at: index)
        }
    }

    private static func count(of body: String, in transcript: [TranscriptMessage]) -> Int {
        let needle = normalise(body)
        return transcript.reduce(0) { $0 + (normalise($1.body) == needle ? 1 : 0) }
    }

    /// KakaoTalk trims what it is given.
    private static func normalise(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
