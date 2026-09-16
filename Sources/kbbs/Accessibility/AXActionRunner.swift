import ApplicationServices.HIServices
import Foundation

struct AXActionRunner {
    typealias TraceWriter = (String) -> Void

    private let traceEnabled: Bool
    private let traceWriter: TraceWriter

    init(traceEnabled: Bool) {
        self.traceEnabled = traceEnabled
        self.traceWriter = { message in
            guard let data = "[trace-ax] \(message)\n".data(using: .utf8) else { return }
            FileHandle.standardError.write(data)
        }
    }

    func log(_ message: @autoclosure () -> String) {
        guard traceEnabled else { return }
        traceWriter(message())
    }

    @discardableResult
    func waitUntil(
        label: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        evaluateAfterTimeout: Bool = true,
        condition: () -> Bool
    ) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() {
                log("\(label): ready")
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let elapsed = Date().timeIntervalSince(start)
        log("\(label): timeout after \(String(format: "%.2f", elapsed))s")
        return evaluateAfterTimeout ? condition() : false
    }

    @discardableResult
    func focusWithVerification(
        _ element: UIElement,
        label: String,
        attempts: Int = 3,
        retryDelay: TimeInterval = 0.08
    ) -> Bool {
        for attempt in 1...max(attempts, 1) {
            do {
                try element.focus()
            } catch {
                log("\(label): focus attempt \(attempt) failed (\(error))")
            }

            if element.isFocused || waitUntil(label: "\(label) focused", timeout: 0.25, condition: {
                element.isFocused
            }) {
                log("\(label): focused on attempt \(attempt)")
                return true
            }

            do {
                try element.press()
            } catch {
                log("\(label): press fallback \(attempt) failed (\(error))")
            }

            if element.isFocused || waitUntil(label: "\(label) focused", timeout: 0.25, condition: {
                element.isFocused
            }) {
                log("\(label): focused by press fallback on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): focus verification failed")
        return false
    }

    @discardableResult
    func setTextWithVerification(
        _ text: String,
        on element: UIElement,
        label: String,
        attempts: Int = 2,
        retryDelay: TimeInterval = 0.08
    ) -> Bool {
        for attempt in 1...max(attempts, 1) {
            do {
                try element.setAttribute(kAXValueAttribute, value: text as CFString)
            } catch {
                log("\(label): set AXValue attempt \(attempt) failed (\(error))")
                Thread.sleep(forTimeInterval: retryDelay)
                continue
            }

            let reflected = waitUntil(label: "\(label) AXValue reflected", timeout: 0.3, condition: {
                isInputReflected(expected: text, current: element.stringValue)
            })
            if reflected {
                log("\(label): set AXValue succeeded on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): set AXValue verification failed")
        return false
    }

    func pressEnterKey() {
        pressKey(code: 36)
    }

    private func pressKey(code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// Post a left-button double-click at the given screen point.
    /// KakaoTalk's search/chat-list rows expose only AXShowDefaultUI/AXShowAlternateUI and
    /// ignore both AXPress and keyboard Enter, so a hardware-level double-click is the only
    /// reliable way to open them.
    func mouseDoubleClick(at point: CGPoint, label: String) {
        log("\(label): double-click at (\(Int(point.x)),\(Int(point.y)))")
        postMouseClicks(at: point, clickCount: 2)
    }

    private func postMouseClicks(at point: CGPoint, clickCount: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let restorePoint = CGEvent(source: nil)?.location

        CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)

        for click in 1...max(clickCount, 1) {
            if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                up.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.04)
        }

        // Return the cursor so the click does not strand the user's pointer.
        if let restorePoint {
            CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: restorePoint,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
    }

    private func isInputReflected(expected: String, current: String?) -> Bool {
        guard let current else { return false }
        return current == expected || current.contains(expected)
    }

    private func didEnterEffect(before: String, after: String) -> Bool {
        let trimmedAfter = after.trimmingCharacters(in: .whitespacesAndNewlines)
        if !before.isEmpty && trimmedAfter.isEmpty {
            return true
        }
        return after != before
    }
}
