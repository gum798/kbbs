import ArgumentParser
import Foundation

struct CloseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "열려 있는 대화방 창을 닫는다"
    )

    @Argument(help: "닫을 대화방 이름")
    var room: String

    func run() throws {
        guard AccessibilityPermission.isGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
        let kakao = try KakaoTalkApp()
        do {
            try WindowCloser(kakao: kakao).close(title: room)
        } catch {
            print("닫지 못했습니다: \(error)")
            print("열린 창: " + kakao.windows.compactMap { $0.title }.map { "「\($0)」" }.joined(separator: " "))
            throw ExitCode.failure
        }
        print("「\(room)」 창을 닫았습니다.")
    }
}
