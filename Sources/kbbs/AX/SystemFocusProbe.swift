import AppKit
import ApplicationServices
import Foundation

/// Which application is frontmost, asked of the window server rather than of AppKit.
///
/// `NSWorkspace.frontmostApplication` is KVO-backed and updates off the main run loop.
/// kbbs never pumps a run loop — it sits in `poll(2)` — so that property can be stale by
/// however long the process has been busy. The system-wide Accessibility element answers
/// from the window server every time it is asked.
enum SystemFocusProbe {

    /// The pid of the frontmost application, or nil if it cannot be read.
    static func frontmostPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focused) == .success,
              let element = focused
        else {
            return nil
        }

        var pid: pid_t = 0
        // swiftlint:disable:next force_cast
        guard AXUIElementGetPid(element as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }

    /// Bring an application forward by pid. Used to give the terminal back after kbbs has
    /// had to put KakaoTalk in front of it.
    @discardableResult
    static func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    /// Poll — rather than sleep — until `pid` is frontmost or the deadline passes.
    ///
    /// Activation is asynchronous and posting is not. A fixed sleep is a race; this is a
    /// check with a bound on it.
    @discardableResult
    static func waitForFrontmost(pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if frontmostPID() == pid { return true }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return frontmostPID() == pid
    }
}
