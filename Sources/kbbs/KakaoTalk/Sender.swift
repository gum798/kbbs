import ApplicationServices
import Foundation

/// Measured on KakaoTalk 26.x: `AXPress` on the 「전송」 button SENDS THE MESSAGE AND THEN
/// RETURNS A GENERIC FAILURE. Believing that return value already cost one duplicate
/// message in a real chat.
///
/// So the press is a one-way door. Nothing retries it, nothing falls back to another
/// mechanism, and nothing treats its error as "did not send".
struct Sender {
    /// Every one of these happens BEFORE the press, so none of them can have sent.
    enum Failure: Error, CustomStringConvertible {
        case composerNotEmpty(characters: Int)
        case injectionFailed(String)
        case injectionNotReflected(readBack: Int)
        case noSendButton
        case sendButtonDisabled
        case pressFailed(String)

        var description: String {
            switch self {
            case .composerNotEmpty(let count):
                return "입력창에 이미 \(count)자가 있습니다"
            case .injectionFailed(let reason):
                return "입력창에 쓰지 못했습니다: \(reason)"
            case .injectionNotReflected(let readBack):
                return "쓴 내용이 그대로 들어가지 않았습니다 (\(readBack)자)"
            case .noSendButton:
                return "전송 버튼을 찾지 못했습니다"
            case .sendButtonDisabled:
                return "전송 버튼이 활성화되지 않았습니다"
            case .pressFailed(let reason):
                return "전송 버튼을 누르지 못했습니다: \(reason)"
            }
        }
    }

    /// Neither case is delivery — `stillHoldingText` in particular means "cannot tell",
    /// not "did not send".
    enum Outcome {
        case composerCleared
        case stillHoldingText
    }

    private let runner: AXActionRunner

    init(trace: Bool = false) {
        self.runner = AXActionRunner(traceEnabled: trace)
    }

    @discardableResult
    func send(_ body: String, window: UIElement, context: MessageTranscriptContext) throws -> Outcome {
        let composer = context.inputElement

        let existing = composer.stringValue ?? ""
        guard existing.isEmpty else {
            throw Failure.composerNotEmpty(characters: existing.count)
        }

        guard let button = sendButton(in: window) else {
            throw Failure.noSendButton
        }

        do {
            try composer.setAttribute(kAXValueAttribute, value: body as CFString)
        } catch {
            throw Failure.injectionFailed("\(error)")
        }

        Thread.sleep(forTimeInterval: 0.15)

        // Exact, not contains: the user's own half-typed sentence can contain ours, and a
        // loose check would send their words ahead of it.
        let readBack = composer.stringValue ?? ""
        guard readBack == body else {
            clear(composer)
            throw Failure.injectionNotReflected(readBack: readBack.count)
        }
        // The last point at which aborting is still safe.
        guard button.isEnabled else {
            clear(composer)
            throw Failure.sendButtonDisabled
        }

        // Result discarded on purpose — see the note on this type.
        _ = try? button.press()

        // KakaoTalk empties its own composer when it accepts a send.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if (composer.stringValue ?? "").isEmpty { return .composerCleared }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Not cleared: it may have been sent anyway, and wiping it erases the evidence.
        return .stillHoldingText
    }

    private func clear(_ composer: UIElement) {
        _ = try? composer.setAttribute(kAXValueAttribute, value: "" as CFString)
    }

    /// Budgeted: an unbudgeted walk of a chat window does not finish. Measured.
    private func sendButton(in window: UIElement) -> UIElement? {
        window.findAll(
            where: { $0.role == kAXButtonRole && $0.title == "전송" },
            limit: 1,
            maxNodes: 2000
        ).first
    }
}
