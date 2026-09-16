import Darwin
import Foundation

/// The terminal, and everything that must not reach it.
///
/// `ttyFD` is a dup of stdout taken before anything writes a byte. The renderer writes
/// only there. Both fd 1 and fd 2 are then pointed at `~/.kbbs/kbbs.log`, so a `print()`
/// nobody knew about, a Swift runtime warning, or the AX tracer cannot land in the
/// middle of a frame and shear it.
///
/// This is a mechanism, not a convention: it does not matter whether every print site in
/// the tree was found, because after `redirect()` there is nowhere for one to go.
enum TTYOut {
    /// The real terminal. Valid for the life of the process once `capture()` has run.
    nonisolated(unsafe) private(set) static var ttyFD: Int32 = STDOUT_FILENO

    nonisolated(unsafe) private static var logFD: Int32 = -1

    /// Dup stdout before anything else happens. Safe to call twice.
    static func capture() {
        guard ttyFD == STDOUT_FILENO else { return }
        let duplicate = dup(STDOUT_FILENO)
        if duplicate >= 0 {
            ttyFD = duplicate
        }
    }

    /// Point fd 1 and fd 2 at the log file. Does nothing if the log cannot be opened —
    /// a frame sheared by a stray line is better than refusing to start.
    static func redirect() {
        guard logFD < 0 else { return }
        Paths.ensureDirectory()
        let fd = open(Paths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        logFD = fd
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
    }

    /// Hand stdout and stderr back to the terminal. Called on the way out so anything
    /// printed after the alternate screen is gone is visible again.
    static func restore() {
        guard logFD >= 0 else { return }
        dup2(ttyFD, STDOUT_FILENO)
        dup2(ttyFD, STDERR_FILENO)
        close(logFD)
        logFD = -1
    }

    /// Write to the terminal, looping over partial writes and retrying EINTR.
    ///
    /// A signal arriving mid-frame is ordinary here — SIGWINCH fires while the user is
    /// still dragging the window edge — and a short write that went unnoticed would tear
    /// the frame in a way that looks like a layout bug.
    @discardableResult
    static func write(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(ttyFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            return false
        }
        return true
    }

    static func log(_ message: String) {
        guard logFD >= 0 else { return }
        let line = Array((message + "\n").utf8)
        _ = line.withUnsafeBytes { Darwin.write(logFD, $0.baseAddress!, $0.count) }
    }
}
