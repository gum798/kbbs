import Darwin
import Foundation

// MARK: - Signal flags

/// Set by signal handlers, read by the run loop at the top of each iteration.
///
/// A handler may touch nothing else. `sig_atomic_t` assignment is the one thing the
/// standard promises is safe here, so the handlers do that and the loop does the work.
nonisolated(unsafe) var kbbsSignalQuit: sig_atomic_t = 0
nonisolated(unsafe) var kbbsSignalResize: sig_atomic_t = 0

/// The terminal as it was before kbbs touched it, plus the fd to put it back on.
///
/// File scope because the crash handler runs with no context and cannot be a closure:
/// it gets a C function pointer, which captures nothing.
nonisolated(unsafe) private var savedTermios = termios()
nonisolated(unsafe) private var savedTermiosValid = false
nonisolated(unsafe) private var restoreFD: Int32 = STDOUT_FILENO
nonisolated(unsafe) private var inRawMode = false

private let leaveSequence = "\u{1B}[?1049l\u{1B}[?25h\u{1B}[0m"

/// Put the terminal back using only what is legal in a signal handler.
///
/// `write` and `tcsetattr` are async-signal-safe; nothing else here is, which is why
/// this does not go through TTYOut or String.
private func emergencyRestore() {
    if savedTermiosValid {
        _ = tcsetattr(restoreFD, TCSAFLUSH, &savedTermios)
    }
    _ = leaveSequence.withCString { pointer in
        Darwin.write(restoreFD, pointer, strlen(pointer))
    }
}

private func handleQuitSignal(_ signal: Int32) {
    kbbsSignalQuit = 1
}

private func handleResizeSignal(_ signal: Int32) {
    kbbsSignalResize = 1
}

/// A crash inside a blocking Accessibility call must not leave the terminal in raw mode
/// with the alternate screen up — atexit does not run, and the user is left with an
/// invisible cursor in a shell that does not echo.
private func handleCrashSignal(_ signal: Int32) {
    emergencyRestore()
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

private func handleExit() {
    if inRawMode {
        emergencyRestore()
        inRawMode = false
    }
}

// MARK: - Raw mode

/// termios, the alternate screen, and the signal handlers that undo them.
enum RawMode {

    /// Rows and columns, as the terminal reports them right now.
    struct Size: Equatable {
        var columns: Int
        var rows: Int

        var isBigEnough: Bool { columns >= 80 && rows >= 24 }
    }

    static func size() -> Size {
        var window = winsize()
        guard ioctl(TTYOut.ttyFD, TIOCGWINSZ, &window) == 0, window.ws_col > 0 else {
            return Size(columns: 80, rows: 24)
        }
        return Size(columns: Int(window.ws_col), rows: Int(window.ws_row))
    }

    /// Raw mode plus the alternate screen. Idempotent.
    ///
    /// ISIG is deliberately LEFT ON: Ctrl-C should raise SIGINT, which the handler turns
    /// into a flag the loop services on its own terms. That path works even while an
    /// uncancellable Accessibility call has the worker blocked, because it depends on
    /// nothing but a saved termios and a saved fd.
    @discardableResult
    static func enter() -> Bool {
        guard !inRawMode else { return true }
        restoreFD = TTYOut.ttyFD

        guard isatty(restoreFD) == 1, tcgetattr(restoreFD, &savedTermios) == 0 else {
            return false
        }
        savedTermiosValid = true

        var raw = savedTermios
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~tcflag_t(OPOST)
        // VMIN 0 / VTIME 0: read never blocks. poll(2) decides when there is input.
        raw.c_cc.16 = 0
        raw.c_cc.17 = 0
        guard tcsetattr(restoreFD, TCSAFLUSH, &raw) == 0 else { return false }

        inRawMode = true
        TTYOut.write("\u{1B}[?1049h\u{1B}[?25l")
        return true
    }

    /// Ordinary exit: leave the alternate screen, show the cursor, put termios back.
    static func restore() {
        guard inRawMode else { return }
        TTYOut.write(leaveSequence)
        if savedTermiosValid {
            _ = tcsetattr(restoreFD, TCSAFLUSH, &savedTermios)
        }
        inRawMode = false
    }

    /// Handlers for everything that can end the process, plus the resize.
    ///
    /// The quit set only raises a flag: the loop finishes its iteration, flushes drafts
    /// and restores the terminal in order. The crash set cannot afford that — it puts the
    /// terminal back immediately and re-raises so the crash still reports as a crash.
    static func installSignalHandlers() {
        for quit in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            Darwin.signal(quit, handleQuitSignal)
        }
        Darwin.signal(SIGWINCH, handleResizeSignal)
        for crash in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE] {
            Darwin.signal(crash, handleCrashSignal)
        }
        // A pipe closing must not kill a program that owns a terminal's state.
        Darwin.signal(SIGPIPE, SIG_IGN)
        atexit(handleExit)
    }

    /// Whether a quit signal has arrived since the last check.
    static func quitRequested() -> Bool {
        kbbsSignalQuit != 0
    }

    /// Whether the window changed size since the last check, clearing the flag.
    static func takeResize() -> Bool {
        guard kbbsSignalResize != 0 else { return false }
        kbbsSignalResize = 0
        return true
    }

    /// Bytes waiting on stdin, or nothing if the timeout elapses first.
    ///
    /// The timeout is the heartbeat: it is what makes the clock tick and the line
    /// indicator animate while nothing is being typed.
    static func read(timeoutMilliseconds: Int32) -> [UInt8] {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&fds, 1, timeoutMilliseconds)
        guard ready > 0, fds.revents & Int16(POLLIN) != 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = buffer.withUnsafeMutableBytes { pointer in
            Darwin.read(STDIN_FILENO, pointer.baseAddress, pointer.count)
        }
        guard count > 0 else { return [] }
        return Array(buffer[0..<count])
    }
}
