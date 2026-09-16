import Foundation

/// Everything kbbs writes, in one place.
///
/// Deliberately separate from kmsg's `~/.kmsg/`. The two products share a scraper but
/// not a process model: kbbs runs for hours holding state in memory, kmsg runs for
/// seconds. Pointing them at the same files means whichever writes last wins and the
/// other's work is silently lost.
enum Paths {
    static let directory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".kbbs", isDirectory: true)

    /// Where stdout and stderr go for the whole session. The scraper prints to both, and
    /// a stray line lands in the middle of a frame and shears it.
    static var log: URL { directory.appendingPathComponent("kbbs.log") }

    /// A message that was posted but never seen again in the transcript. Written once so
    /// it survives a crash, never resent automatically.
    static var lastUnconfirmed: URL { directory.appendingPathComponent("last-unconfirmed.txt") }

    /// Creates the directory at 0700 if it is missing. Safe to call repeatedly.
    @discardableResult
    static func ensureDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }
}
