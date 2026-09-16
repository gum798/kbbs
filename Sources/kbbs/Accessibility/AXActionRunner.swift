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

    /// Post a left-button double-click at the given screen point.
    /// KakaoTalk's search/chat-list rows expose only AXShowDefaultUI/AXShowAlternateUI and
    /// ignore both AXPress and keyboard Enter, so a hardware-level double-click is the only
    /// reliable way to open them.
    func mouseDoubleClick(at point: CGPoint, label: String) {
        log("\(label): double-click at (\(Int(point.x)),\(Int(point.y)))")
        postMouseClicks(at: point, clickCount: 2)
    }

    /// Scroll a list under the pointer.
    ///
    /// KakaoTalk advertises AXScrollDownByPage on its chat list and answers "Attribute
    /// unsupported" when asked to perform it, so a wheel event is the only way to move
    /// that list. It goes to whatever is under the cursor, which is why the cursor is
    /// warped to the target first and put back afterwards.
    func scrollWheel(at point: CGPoint, lines: Int, label: String) {
        log("\(label): scroll \(lines) at (\(Int(point.x)),\(Int(point.y)))")
        let source = CGEventSource(stateID: .hidSystemState)
        let restorePoint = CGEvent(source: nil)?.location

        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)

        CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)

        if let restorePoint {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: restorePoint, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
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
}
