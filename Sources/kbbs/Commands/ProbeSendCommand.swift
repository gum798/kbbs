import ApplicationServices
import ArgumentParser
import Foundation

/// Answers the one question the send design branches on, without sending anything.
///
/// KakaoTalk's chat window exposes a 「전송」 button with `AXPress` on it, sitting
/// disabled because the composer is empty. If putting text in through Accessibility
/// enables that button, the send path is: set the value, verify it, press the button —
/// no focus grab, no global Return, no keyboard lockout, and about 150 fewer lines than
/// the alternative. If it does NOT enable, KakaoTalk is driving that button off its own
/// text-change notification and the whole focus-gate machine is unavoidable.
///
/// Nothing here presses anything. There is no `AXPress` and no key event in this file,
/// so no sequence of failures can send a message. The worst case is text left sitting in
/// the composer, and it is cleared on every exit path.
struct ProbeSendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe-send",
        abstract: "전송 경로를 진단한다 — 입력창에 넣었다 지우기만 하고, 보내지 않는다"
    )

    @Argument(help: "창이 열려 있는 대화방 이름")
    var room: String

    @Flag(name: .long, help: "창을 최소화한 뒤에도 읽히는지 본다 (원래 상태로 되돌린다)")
    var minimized = false

    @Flag(name: .long, help: "위로 스크롤한 뒤에도 새 메시지가 보이는지 본다")
    var scrolled = false

    @Flag(name: .long, help: "접근성 호출을 표준오류로 남긴다")
    var trace = false

    private static let probeText = "kbbs 확인용 — 보내지 않습니다"

    func run() throws {
        guard AccessibilityPermission.isGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
        let kakao = try KakaoTalkApp()
        let runner = AXActionRunner(traceEnabled: trace)

        guard let window = kakao.windows.first(where: { $0.role == kAXWindowRole && $0.title == room }) else {
            print("「\(room)」 창이 열려 있지 않습니다.")
            print("지금 열린 창: " + kakao.windows.compactMap { $0.title }.map { "「\($0)」" }.joined(separator: " "))
            throw ExitCode.failure
        }

        let resolver = MessageContextResolver(kakao: kakao, runner: runner, interactionMode: .backgroundSafe)
        guard let context = resolver.resolve(in: window) else {
            print("입력창을 찾지 못했습니다.")
            throw ExitCode.failure
        }
        if scrolled {
            try probeScrolled(kakao: kakao, window: window, context: context, runner: runner)
            return
        }

        if minimized {
            try probeMinimized(kakao: kakao, window: window, runner: runner)
            return
        }

        let composer = context.inputElement

        // Never write over something the user is in the middle of typing.
        let existing = composer.stringValue ?? ""
        guard existing.isEmpty else {
            print("입력창에 이미 \(existing.count)자가 들어 있습니다. 건드리지 않고 중단합니다.")
            throw ExitCode.failure
        }

        let button = sendButton(in: window)
        let enabledBefore = button?.isEnabled
        print("입력창   role=\(composer.role ?? "?") actions=\(actions(of: composer))")
        print("전송버튼 \(button == nil ? "찾지 못함" : "찾음") actions=\(button.map(actions) ?? "-") 활성=\(describe(enabledBefore))")
        print("")

        // Cleared on every path out of here, including a thrown error.
        defer {
            _ = try? composer.setAttribute(kAXValueAttribute, value: "" as CFString)
            let left = composer.stringValue ?? ""
            print("")
            print(left.isEmpty ? "입력창 비움 확인." : "입력창에 \(left.count)자가 남았습니다 — 카카오톡에서 직접 지워 주세요.")
        }

        print("주입: \"\(Self.probeText)\"")
        do {
            try composer.setAttribute(kAXValueAttribute, value: Self.probeText as CFString)
        } catch {
            print("주입 실패: \(error)")
            throw ExitCode.failure
        }

        // Give KakaoTalk a moment to react to the value, the way it would to typing.
        Thread.sleep(forTimeInterval: 0.25)

        let readBack = composer.stringValue ?? ""
        let exact = readBack == Self.probeText
        let enabledAfter = button?.isEnabled

        print("되읽기: \(exact ? "정확히 일치" : "불일치 (\(readBack.count)자)")")
        print("전송버튼 활성: \(describe(enabledBefore)) → \(describe(enabledAfter))")
        print("")

        switch (exact, enabledBefore, enabledAfter) {
        case (true, false, true):
            print("A1 답: AX 주입만으로 「전송」 버튼이 켜집니다.")
            print("→ 전송은 AXPress 로 끝낼 수 있습니다. 전역 Return·포커스 게이트·자판 잠금 불필요.")
            print("→ 남은 질문은 하나: 백그라운드에서 AXPress 가 실제로 보내는가. 그건 진짜 전송이 필요합니다.")
        case (true, _, false):
            print("A1 답: 글자는 들어갔지만 「전송」 버튼이 꺼진 채입니다.")
            print("→ 카카오톡이 자기 입력 알림으로 버튼을 굴립니다. AX 주입은 그 알림을 일으키지 않습니다.")
            print("→ 전역 Return 과 포커스 게이트를 쓰는 설계(스펙 §5)로 가야 합니다.")
        case (false, _, _):
            print("A1 답: 주입 자체가 반영되지 않았습니다.")
            print("→ 전송 설계 이전에 입력 방법부터 다시 봐야 합니다.")
        default:
            print("A1 답: 판정 불가 — 버튼을 못 찾았거나 활성 상태를 못 읽었습니다.")
        }
    }

    /// Does a window that is not scrolled to the bottom still show new messages?
    private func probeScrolled(
        kakao: KakaoTalkApp,
        window: UIElement,
        context: MessageTranscriptContext,
        runner: AXActionRunner
    ) throws {
        let reader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner, interactionMode: .backgroundSafe)
        func read() -> [String] {
            ((try? reader.readSnapshot(from: context, chatWindow: window, fallbackChatTitle: room, limit: 20))?
                .messages.map(\.body)) ?? []
        }

        let before = read()
        print("스크롤 전   \(before.count)개")

        for _ in 0..<3 { try? context.transcriptRoot.performAction("AXScrollUpByPage") }
        Thread.sleep(forTimeInterval: 0.5)
        print("위로 스크롤 완료")

        let stamp = "kbbs 스크롤 확인 \(Int(Date().timeIntervalSince1970) % 10000)"
        try Sender(trace: trace).send(stamp, window: window, context: context)
        print("보냄        \"\(stamp)\"")
        Thread.sleep(forTimeInterval: 2.0)

        let after = read()
        let seen = after.contains { $0.contains(stamp) }
        print("스크롤 상태에서 읽기  \(after.count)개 · 방금 보낸 것 \(seen ? "보임" : "안 보임")")

        for _ in 0..<5 { try? context.transcriptRoot.performAction("AXScrollDownByPage") }
        Thread.sleep(forTimeInterval: 0.5)
        let recovered = read()
        let seenAfter = recovered.contains { $0.contains(stamp) }
        print("아래로 내린 뒤        \(recovered.count)개 · 방금 보낸 것 \(seenAfter ? "보임" : "안 보임")")
        print("")
        print(seen
            ? "스크롤 위치와 무관하게 보입니다."
            : (seenAfter
               ? "스크롤을 내려야 보입니다 — 읽기 전에 맨 아래로 내려야 합니다."
               : "내려도 안 보입니다. 원인이 스크롤이 아닙니다."))
    }

    /// Can a minimized window still be read? The design assumed not and built a whole
    /// consent gate around opening windows; nobody had checked.
    private func probeMinimized(kakao: KakaoTalkApp, window: UIElement, runner: AXActionRunner) throws {
        let reader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner, interactionMode: .backgroundSafe)
        let before = (try? reader.readSnapshot(from: window, fallbackChatTitle: room, limit: 10).count) ?? 0
        print("최소화 전  \(before)개 읽음")

        let wasMinimized: Bool = window.attributeOptional(kAXMinimizedAttribute) ?? false
        try window.setAttribute(kAXMinimizedAttribute, value: true as CFBoolean)
        Thread.sleep(forTimeInterval: 1.0)

        let after = (try? reader.readSnapshot(from: window, fallbackChatTitle: room, limit: 10).count) ?? 0
        print("최소화 후  \(after)개 읽음")
        print("최소화 후 제목  \(window.title.map { "「\($0)」" } ?? "없음")")
        print("최소화 후 창목록  " + kakao.windows.map { "「\($0.title ?? "-")」" }.joined(separator: " "))
        print("제목으로 다시 찾기  \(kakao.windows.contains { $0.role == kAXWindowRole && $0.title == room } ? "찾음" : "못 찾음")")

        // The case that matters most: does a message that ARRIVES while the window is
        // hidden ever reach the Accessibility tree? Reading old content proves nothing
        // about that, and a room kbbs opened is minimized for the rest of the session.
        let reader2 = KakaoTalkTranscriptReader(kakao: kakao, runner: runner, interactionMode: .backgroundSafe)
        if let context = MessageContextResolver(kakao: kakao, runner: runner, interactionMode: .backgroundSafe)
            .resolve(in: window), (context.inputElement.stringValue ?? "").isEmpty {
            let stamp = "kbbs 최소화 확인 \(Int(Date().timeIntervalSince1970) % 10000)"
            _ = try? Sender(trace: trace).send(stamp, window: window, context: context)
            Thread.sleep(forTimeInterval: 2.5)
            let arrived = ((try? reader2.readSnapshot(from: context, chatWindow: window, fallbackChatTitle: room, limit: 20))?
                .messages.map(\.body).contains { $0.contains(stamp) }) ?? false
            print("최소화 중 도착한 메시지  \(arrived ? "보임" : "안 보임")")
        }

        // Reading is only half of it: auto-minimising would break sending if the composer
        // stops accepting a value, or the button stops enabling, while hidden.
        let resolver = MessageContextResolver(kakao: kakao, runner: runner, interactionMode: .backgroundSafe)
        if let context = resolver.resolve(in: window) {
            let composer = context.inputElement
            let existing = composer.stringValue ?? ""
            if existing.isEmpty {
                try? composer.setAttribute(kAXValueAttribute, value: Self.probeText as CFString)
                Thread.sleep(forTimeInterval: 0.25)
                let reflected = (composer.stringValue ?? "") == Self.probeText
                let enabled = sendButton(in: window)?.isEnabled
                _ = try? composer.setAttribute(kAXValueAttribute, value: "" as CFString)
                print("최소화 상태 주입  \(reflected ? "반영됨" : "반영 안 됨") · 전송버튼 \(describe(enabled))")
            } else {
                print("최소화 상태 주입  건너뜀 (입력창에 글자가 있음)")
            }
        } else {
            print("최소화 상태 주입  입력창을 찾지 못함")
        }

        if !wasMinimized {
            try? window.setAttribute(kAXMinimizedAttribute, value: false as CFBoolean)
            print("원래대로 되돌렸습니다.")
        }
        print("")
        print(after > 0
            ? "A2 답: 최소화된 창도 읽힙니다. 창을 숨긴 채로 쓸 수 있습니다."
            : "A2 답: 최소화하면 읽히지 않습니다. 창이 보여야 합니다.")
    }

    /// The send button, by its label. Bounded: an unbudgeted walk of this tree does not
    /// finish, which is measured and recorded in the project's notes.
    private func sendButton(in window: UIElement) -> UIElement? {
        window.findAll(
            where: { $0.role == kAXButtonRole && $0.title == "전송" },
            limit: 1,
            maxNodes: 2000
        ).first
    }

    private func actions(of element: UIElement) -> String {
        let names = (try? element.actionNames()) ?? []
        return names.isEmpty ? "(없음)" : names.joined(separator: "|")
    }

    private func describe(_ enabled: Bool?) -> String {
        guard let enabled else { return "읽지 못함" }
        return enabled ? "켜짐" : "꺼짐"
    }
}
