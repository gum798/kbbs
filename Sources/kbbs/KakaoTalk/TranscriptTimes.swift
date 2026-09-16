import Foundation

/// Fills in the timestamps KakaoTalk does not print.
///
/// It stamps the LAST message of a consecutive run by one sender, so a message without
/// one belongs to the time printed below it — not above. Filling downward dated messages
/// from a run that had already finished, which put times on screen that ran backwards.
enum TranscriptTimes {
    static func fill(_ explicit: [String?]) -> [String?] {
        var filled = explicit
        var carried: String?
        for index in filled.indices.reversed() {
            if let stamp = filled[index] {
                carried = stamp
            } else {
                filled[index] = carried
            }
        }
        // Anything past the last stamp has nothing below it; the stamp above is all there
        // is.
        carried = nil
        for index in filled.indices {
            if let stamp = filled[index] {
                carried = stamp
            } else {
                filled[index] = carried
            }
        }
        return filled
    }
}
