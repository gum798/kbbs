import ArgumentParser
import Foundation

/// One message into one room, from the command line.
///
/// The same path the terminal uses, exposed on its own so a send can be made — and
/// diagnosed — without the full screen. `--dry-run` resolves everything and reports what
/// it would do without writing to the composer or pressing anything.
struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "대화방에 메시지를 보낸다 (창이 열려 있어야 한다)"
    )

    @Argument(help: "창이 열려 있는 대화방 이름")
    var room: String

    @Argument(help: "보낼 내용")
    var body: String

    @Flag(name: .long, help: "실제로 보내지 않고, 어디까지 되는지만 확인한다")
    var dryRun = false

    @Flag(name: .long, help: "누르기 전에 카카오톡을 앞으로 가져온다 (끝나면 터미널로 돌려준다)")
    var front = false

    @Flag(name: .long, help: "접근성 호출을 표준오류로 남긴다")
    var trace = false

    func run() throws {
        guard AccessibilityPermission.isGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("빈 메시지는 보내지 않습니다.")
            throw ExitCode.failure
        }

        let kakao = try KakaoTalkApp()
        let reader = RoomReader(kakao: kakao, trace: trace)
        let opened: RoomReader.Opened
        do {
            opened = try reader.open(title: room)
        } catch RoomReader.OpenFailure.noWindow(let candidates) {
            print("「\(room)」 창이 열려 있지 않습니다.")
            print("지금 열린 창: " + candidates.map { "「\($0)」" }.joined(separator: " "))
            throw ExitCode.failure
        } catch {
            print("「\(room)」 의 입력창을 찾지 못했습니다.")
            throw ExitCode.failure
        }

        print("대화방  「\(opened.matchedTitle)」")
        print("내용    \"\(body)\"")

        if dryRun {
            let composer = opened.context.inputElement
            let existing = composer.stringValue ?? ""
            print("입력창  role=\(composer.role ?? "?") 비어있음=\(existing.isEmpty)")
            print("")
            print("dry-run — 아무것도 쓰지 않았고 아무것도 누르지 않았습니다.")
            return
        }

        // Only for finding out whether AXPress needs the app in front. If it does, that
        // is a fact about the design, not a flag anyone should have to remember.
        var terminal: pid_t?
        if front {
            terminal = SystemFocusProbe.frontmostPID()
            kakao.activateForSend()
            let arrived = KakaoTalkApp.runningApplication.map {
                SystemFocusProbe.waitForFrontmost(pid: $0.processIdentifier, timeout: 1.5)
            } ?? false
            print("전면 전환  \(arrived ? "확인" : "실패")")
        }
        defer {
            if let terminal { SystemFocusProbe.activate(pid: terminal) }
        }

        let outcome: Sender.Outcome
        do {
            outcome = try Sender(trace: trace).send(body, window: opened.window, context: opened.context)
        } catch {
            print("")
            print("보내지 않았습니다: \(error)")
            throw ExitCode.failure
        }

        switch outcome {
        case .composerCleared:
            print("보냈습니다.")
        case .stillHoldingText:
            print("눌렀지만 입력창에 글자가 남아 있습니다. 다시 보내지 말고 카카오톡에서 확인하세요.")
        }
    }
}
