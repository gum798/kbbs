import Foundation

/// Lifted verbatim from kmsg's WatchCommand.swift:412-506.
///
/// Pure value type: no I/O, no AX, no clock. Feed it each poll's snapshot and it
/// returns only the newly appended messages, matched by longest-suffix overlap with
/// fuzzy equivalence (±60s timestamp slack; author compared only when both sides have
/// one). The author rule is load-bearing for kbbs: TranscriptReader leaves `author`
/// nil whenever its geometry guess fails, so an empty author must keep matching
/// anything or a flaky frame read re-emits the whole visible tail as new.
///
/// Deliberately NOT lifted: filterMessagesAfterWatchStart (WatchCommand.swift:336-343).
/// replaceBaseline plus a first consume() returning [] already suppresses history
/// replay, and the timestamp filter adds a same-minute blind spot while permanently
/// dropping any message whose time label AX did not expose.
struct WatchPollingState {
    private let includeSystemMessages: Bool
    private let maxFingerprintCount: Int
    private var previousMessages: [TranscriptMessage] = []

    init(includeSystemMessages: Bool = false, maxFingerprintCount: Int = 200) {
        self.includeSystemMessages = includeSystemMessages
        self.maxFingerprintCount = maxFingerprintCount
    }

    mutating func replaceBaseline(with snapshotMessages: [TranscriptMessage]) {
        previousMessages = recentMessages(from: snapshotMessages)
    }

    mutating func consume(snapshotMessages: [TranscriptMessage]) -> [TranscriptMessage] {
        let currentMessages = recentMessages(from: snapshotMessages)
        guard !previousMessages.isEmpty else {
            previousMessages = currentMessages
            return []
        }

        let overlap = findOverlap(previousMessages, currentMessages)
        let emitted = overlap.endIndex >= 0
            ? Array(currentMessages.dropFirst(overlap.endIndex + 1))
            : currentMessages

        previousMessages = currentMessages
        return emitted
    }

    private func recentMessages(from snapshotMessages: [TranscriptMessage]) -> [TranscriptMessage] {
        let filtered = snapshotMessages.filter { includeSystemMessages || !$0.isSystem }
        return Array(filtered.suffix(maxFingerprintCount))
    }

    private func findOverlap(_ previous: [TranscriptMessage], _ current: [TranscriptMessage]) -> (count: Int, endIndex: Int) {
        let maxCount = min(previous.count, current.count)
        guard maxCount > 0 else {
            return (0, -1)
        }

        for overlapCount in stride(from: maxCount, through: 1, by: -1) {
            let previousSuffix = Array(previous.suffix(overlapCount))
            let maxStartIndex = current.count - overlapCount
            for startIndex in 0...maxStartIndex {
                let currentSlice = Array(current[startIndex..<(startIndex + overlapCount)])
                let matches = zip(previousSuffix, currentSlice).allSatisfy { lhs, rhs in
                    messagesEquivalent(lhs, rhs)
                }
                if matches {
                    return (overlapCount, startIndex + overlapCount - 1)
                }
            }
        }

        return (0, -1)
    }

    private func findOverlapCount(_ previous: [TranscriptMessage], _ current: [TranscriptMessage]) -> Int {
        findOverlap(previous, current).count
    }

    private func messagesEquivalent(_ lhs: TranscriptMessage, _ rhs: TranscriptMessage) -> Bool {
        guard lhs.isSystem == rhs.isSystem else { return false }
        guard normalizeForDiff(lhs.body) == normalizeForDiff(rhs.body) else { return false }

        if let lhsTimestamp = lhs.logicalTimestamp, let rhsTimestamp = rhs.logicalTimestamp {
            let delta = abs(lhsTimestamp.timeIntervalSince(rhsTimestamp))
            if delta > 60 {
                return false
            }
        }

        let lhsAuthor = normalizedAuthor(lhs.author)
        let rhsAuthor = normalizedAuthor(rhs.author)
        if lhsAuthor.isEmpty || rhsAuthor.isEmpty {
            return true
        }

        return lhsAuthor == rhsAuthor
    }

    private func normalizedAuthor(_ author: String?) -> String {
        (author ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizeForDiff(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
