import ApplicationServices
import ArgumentParser
import Foundation

struct WindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "열려 있는 카카오톡 창을 열거한다"
    )

    @Option(name: .long, help: "지정한 초 동안 1초마다 다시 읽어 창의 생성/소멸을 감시한다")
    var watch: Int?

    func run() throws {
        guard AccessibilityPermission.isGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let kakao = try KakaoTalkApp()

        if let seconds = watch, seconds > 0 {
            watchWindows(kakao: kakao, seconds: seconds)
        } else {
            printWindows(kakao.windows)
        }
    }

    private func printWindows(_ windows: [UIElement]) {
        for (index, window) in windows.enumerated() {
            print(formatWindow(index: index, window: window))
        }
    }

    private func formatWindow(index: Int, window: UIElement) -> String {
        let role = window.role ?? "?"
        let title = window.title.map { "「\($0)」" } ?? "?"
        let isMinimized: Bool? = window.attributeOptional(kAXMinimizedAttribute)
        let minStr = isMinimized.map { String($0) } ?? "?"
        return "[\(index)] role=\(role) 제목=\(title) 최소화=\(minStr)"
    }

    /// 창 순서만 바뀌는 경우와 실제 창이 생기거나 사라진 경우를 구분하기 위해 AX 요소 일치 여부로 비교한다.
    private func haveWindowsChanged(from previous: [UIElement], to current: [UIElement]) -> Bool {
        if previous.count != current.count {
            return true
        }
        for prev in previous {
            if !current.contains(where: { CFEqual(prev.axElement, $0.axElement) }) {
                return true
            }
        }
        return false
    }

    private func watchWindows(kakao: KakaoTalkApp, seconds: Int) {
        var previous = kakao.windows
        var hasChanged = false

        for _ in 1...seconds {
            Thread.sleep(forTimeInterval: 1.0)
            let current = kakao.windows
            if haveWindowsChanged(from: previous, to: current) {
                hasChanged = true
                printWindows(current)
                previous = current
            }
        }

        if !hasChanged {
            printWindows(previous)
        }
    }
}
