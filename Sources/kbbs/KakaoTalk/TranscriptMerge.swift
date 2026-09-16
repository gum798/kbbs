import Foundation

/// Joining the reader's two sources of messages without losing any.
///
/// The row parser walks the transcript rows. When it comes up short — KakaoTalk renders
/// some bubbles in shapes it does not recognise — a fallback sweeps the whole subtree and
/// finds text the rows missed, along with copies of everything the rows already had.
///
/// The old code ran a fingerprint dedup over the joined list, and the fingerprint is
/// author + minute + body. Two identical messages sent in the same minute therefore
/// became one. In Korean chat that is not an edge case: ㅋㅋ followed by ㅋㅋ is ordinary,
/// and the reader was quietly eating half of it.
enum TranscriptMerge {

    /// The row-parsed messages, plus whatever the fallback found that they did not.
    ///
    /// The rows are authoritative for how many of a repeated message there are — they
    /// come from counting bubbles. The fallback is a text sweep and cannot count, so its
    /// copies are matched against the row block and dropped; nothing is ever removed from
    /// within the rows themselves.
    static func merge(rowMessages: [TranscriptMessage], fallback: [TranscriptMessage]) -> [TranscriptMessage] {
        guard !fallback.isEmpty else { return inScreenOrder(rowMessages) }

        var remaining: [String: Int] = [:]
        for message in rowMessages {
            remaining[bodyFingerprint(message), default: 0] += 1
        }

        var extras: [TranscriptMessage] = []
        for message in fallback {
            let key = bodyFingerprint(message)
            if let count = remaining[key], count > 0 {
                remaining[key] = count - 1        // this one is a copy of a row message
                continue
            }
            extras.append(message)
        }

        return inScreenOrder(rowMessages + extras)
    }

    /// In the order KakaoTalk drew them, top to bottom.
    ///
    /// NOT by time. A message from an earlier day carries a later time of day, so a clock
    /// sort puts yesterday's 15:13 underneath today's 15:01. Position is the order; the
    /// timestamp is only a label.
    ///
    /// A message whose position could not be read inherits the one before it, so it stays
    /// beside what it was found next to.
    static func inScreenOrder(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        var carried = -Double.greatestFiniteMagnitude
        let keyed = messages.map { message -> (TranscriptMessage, Double) in
            if let key = message.orderKey {
                carried = key
            }
            return (message, carried)
        }
        return keyed
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.1 == rhs.element.1 { return lhs.offset < rhs.offset }
                return lhs.element.1 < rhs.element.1
            }
            .map(\.element.0)
    }

    /// Identity for "is this the same message" — author, minute and body.
    ///
    /// Named for what it is. It answers whether two readings describe the same text, and
    /// it cannot answer whether two messages are the same message, which is why it is no
    /// longer used to remove anything from an authoritative list.
    static func bodyFingerprint(_ message: TranscriptMessage) -> String {
        "\(message.author ?? "")\u{1F}\(message.timeRaw ?? "")\u{1F}\(message.body)"
    }
}

/// How a message should be attributed on screen.
enum TranscriptAttribution {

    enum Label: Equatable {
        case named(String)      // someone else, by name
        case me                 // mine, and the reader is confident
        case probablyMe         // mine by fallback, from a bubble whose side did not read
        case unknown            // someone else, unnamed
    }

    /// The label, and — importantly — whether it is a guess.
    ///
    /// KakaoTalk does not name the sender of your own messages, so the reader infers the
    /// side from bubble geometry. When that read fails it returns the same thing it
    /// returns for a confident "mine", which meant an unclear bubble was drawn as fact.
    /// `probablyMe` is the case that used to be invisible.
    static func label(for message: TranscriptMessage) -> Label {
        if let author = message.author, !author.isEmpty {
            return .named(author)
        }
        guard message.authorSource == "default-me" else { return .unknown }
        return message.side == "right" ? .me : .probablyMe
    }

    /// What the room screen prints in the author column.
    static func marker(for message: TranscriptMessage) -> String {
        switch label(for: message) {
        case .named(let name): return name
        case .me: return "나"
        case .probablyMe: return "나?"
        case .unknown: return "?"
        }
    }
}
