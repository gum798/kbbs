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
