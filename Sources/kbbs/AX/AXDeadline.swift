import Foundation

/// A wall clock every Accessibility traversal in the process obeys, and a record of
/// whether it ever cut one short.
///
/// A node budget bounds how many elements a search visits. It says nothing about what
/// each one costs, and that gap is not academic: measured against 카카오페이, a fully
/// budgeted search spent 86 seconds, three thousand nodes at several Accessibility
/// queries apiece and five to ten milliseconds a query.
///
/// Threading a deadline through every signature would mean editing the retained scraper
/// in dozens of places. This is set once around an operation instead and every traversal
/// beneath it stops when the time is up, including traversals in files kbbs did not
/// write.
///
/// The flag is the point. A search that stops early returns what it had reached, and a
/// short list is indistinguishable from an exhausted one — which is how a room with no
/// composer of its own ends up resolved to whatever the search did manage to find. So a
/// traversal that gives up says so, and the caller of `within` is told, and an operation
/// whose search was cut short must be treated as failed rather than answered.
///
/// A plain static is enough because the project holds every Accessibility call on one
/// serial queue. `within` saves and restores around its body: a nested deadline takes
/// the tighter of the two and can never extend an outer one, and a truncation inside a
/// nested scope is reported to both.
enum AXDeadline {
    nonisolated(unsafe) private static var current: Date?
    nonisolated(unsafe) private static var truncated = false

    struct Outcome<T> {
        let value: T
        /// True when any traversal under this scope stopped because time ran out.
        let truncated: Bool
    }

    /// True only when a deadline is set and has passed; no deadline means no limit.
    static var passed: Bool {
        guard let current else { return false }
        return Date() >= current
    }

    /// Called by a traversal that stopped early because the clock ran out — never
    /// because it hit its node budget or found what it wanted.
    static func noteTruncation() {
        truncated = true
    }

    static func within<T>(_ seconds: TimeInterval, _ body: () throws -> T) rethrows -> Outcome<T> {
        let inheritedDeadline = current
        let inheritedTruncation = truncated
        let mine = Date().addingTimeInterval(seconds)
        current = inheritedDeadline.map { min($0, mine) } ?? mine
        truncated = false
        defer {
            current = inheritedDeadline
            truncated = inheritedTruncation || truncated
        }
        let value = try body()
        return Outcome(value: value, truncated: truncated)
    }
}
