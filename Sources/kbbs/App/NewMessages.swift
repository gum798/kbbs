import Foundation

/// How many of the messages on screen arrived while the user was looking at them.
///
/// Counted rather than timestamped: KakaoTalk's stamps are minute-resolution and a
/// message from an earlier day carries a later time, so they cannot order anything, let
/// alone say what is recent.
enum NewMessages {
    static func count(previous: [TranscriptMessage], current: [TranscriptMessage], carried: Int) -> Int {
        guard !previous.isEmpty else { return 0 }

        let arrived: Int
        if current.count > previous.count {
            arrived = current.count - previous.count
        } else if current.last?.body != previous.last?.body || current.last?.timeRaw != previous.last?.timeRaw {
            // The count held but the tail moved: an arrival pushed an old message off.
            arrived = 1
        } else {
            arrived = 0
        }
        return min(current.count, carried + arrived)
    }
}
