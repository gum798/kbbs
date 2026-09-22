import AppKit
import Foundation

/// Represents the KakaoTalk application and provides access to its UI elements
public final class KakaoTalkApp: Sendable {
    public static let bundleIdentifier = "com.kakao.KakaoTalkMac"

    private let app: UIElement

    /// Binds to KakaoTalk as it already is. There is no auto-launch parameter because
    /// there is no auto-launch: starting KakaoTalk brings it to the front, and nothing
    /// short of a deliberate send is allowed to do that.
    public init() throws {
        guard let runningApp = Self.runningApplication else {
            throw KakaoTalkError.appNotRunning
        }

        self.app = UIElement.application(pid: runningApp.processIdentifier)
    }

    // MARK: - App State

    /// Get the running KakaoTalk application
    public static var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    /// Brings KakaoTalk to the front. The ONLY caller may be the send path.
    ///
    /// The last step of a send is a global HID Return that lands on whatever is frontmost
    /// at that instant, so KakaoTalk has to be frontmost first. Every other operation —
    /// every read, every poll, every scan — runs against the app where it sits. A read
    /// that fronts KakaoTalk is indistinguishable from a send, both to the user watching
    /// their screen and to the keystroke that follows.
    public func activateForSend() {
        guard let app = Self.runningApplication else { return }

        // Unhide the app first if it's hidden
        if app.isHidden {
            app.unhide()
        }

        // Use activateIgnoringOtherApps to reliably bring to foreground
        app.activate(options: [.activateIgnoringOtherApps])
    }

    // MARK: - Windows

    /// Get all KakaoTalk windows
    public var windows: [UIElement] {
        app.windows
    }

    /// Get the main window (friends list)
    public var mainWindow: UIElement? {
        app.mainWindow
    }

    /// Get the focused window
    public var focusedWindow: UIElement? {
        app.focusedWindow
    }

    // MARK: - Window Discovery

    /// Find a window by its title
    public func findWindow(title: String) -> UIElement? {
        windows.first { $0.title == title }
    }

    /// Find a window containing the given title substring
    public func findWindow(titleContaining substring: String) -> UIElement? {
        windows.first { $0.title?.contains(substring) == true }
    }

    /// Get the chat list window
    public var chatListWindow: UIElement? {
        // KakaoTalk 26.x: the chat list window is titled "카카오톡"
        // and contains navigation buttons with id "chatrooms" / "friends"
        if let w = findWindow(titleContaining: "채팅") { return w }
        if let w = findWindow(title: "카카오톡") { return w }
        // Fallback: find the window containing the chatrooms navigation button
        for window in windows {
            if !window.findAll(where: { $0.identifier == "chatrooms" }, limit: 1, maxNodes: 220).isEmpty {
                return window
            }
        }
        return nil
    }

    // MARK: - UI Navigation

    /// Get the application element for direct traversal
    public var applicationElement: UIElement {
        app
    }
}

// MARK: - Errors

public enum KakaoTalkError: Error, CustomStringConvertible {
    case appNotRunning
    case windowNotFound(String)
    case elementNotFound(String)
    case actionFailed(String)
    case permissionDenied

    public var description: String {
        switch self {
        case .appNotRunning:
            return "KakaoTalk is not running. Please launch KakaoTalk first."
        case .windowNotFound(let name):
            return "Window not found: \(name)"
        case .elementNotFound(let description):
            return "UI element not found: \(description)"
        case .actionFailed(let action):
            return "Action failed: \(action)"
        case .permissionDenied:
            return "Accessibility permission denied. Please grant permission in System Settings."
        }
    }
}
