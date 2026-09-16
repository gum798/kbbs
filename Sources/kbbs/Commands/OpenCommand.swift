import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

/// The window-opening path on its own, with every step reported.
///
/// The terminal shows the same four steps inside a box; this is where they can be read
/// without one, which is what a failure that only happens on a real chat list needs.
struct OpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "대화방 창을 연다 (카카오톡이 잠깐 앞으로 나온다)"
    )

    @Argument(help: "열 대화방 이름")
    var room: String

    @Flag(name: .long, help: "누르지 않고, 어디까지 되는지만 본다")
    var dryRun = false

    @Flag(name: .long, help: "접근성 호출을 표준오류로 남긴다")
    var trace = false

    func run() throws {
        guard AccessibilityPermission.isGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
        let kakao = try KakaoTalkApp()
        let runner = AXActionRunner(traceEnabled: trace)

        if let existing = kakao.windows.first(where: { $0.role == kAXWindowRole && $0.title == room }) {
            print("이미 열려 있습니다 (최소화 \(existing.attributeOptional(kAXMinimizedAttribute) ?? false))")
            return
        }

        guard let listWindow = kakao.chatListWindow, listWindow.role == kAXWindowRole else {
            print("대화목록 창이 없습니다. 목록 창이 있어야 행을 누를 수 있습니다.")
            throw ExitCode.failure
        }

        let items = ChatListScanner().scan(in: listWindow, limit: 60, trace: nil)
        print("목록 스캔      \(items.count)개")
        guard let row = items.first(where: { $0.discovery.title == room })?.element else {
            print("「\(room)」 행이 목록에 없습니다.")
            print("보이는 이름: " + items.prefix(8).map { "「\($0.discovery.title)」" }.joined(separator: " ") + " …")
            throw ExitCode.failure
        }

        let frame = row.frame
        print("행 프레임      \(frame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "읽지 못함")")
        let screens = Self.screensInEventSpace()
        print("화면           " + screens.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" }.joined(separator: " "))

        guard RowClickGuard.clickPoint(rowFrame: frame, visibleScreens: screens) != nil else {
            print("좌표 거부      행이 화면 밖이거나 크기가 없습니다")
            throw ExitCode.failure
        }

        if dryRun {
            print("")
            print("dry-run — 누르지 않았습니다.")
            return
        }

        let terminal = SystemFocusProbe.frontmostPID()
        defer { if let terminal { SystemFocusProbe.activate(pid: terminal) } }

        kakao.activateForSend()
        let front = KakaoTalkApp.runningApplication.map {
            SystemFocusProbe.waitForFrontmost(pid: $0.processIdentifier, timeout: 1.5)
        } ?? false
        print("전면 전환      \(front ? "확인" : "실패")")
        guard front else { throw ExitCode.failure }

        // Bringing the app forward brings ALL its windows, and a chat window sitting over
        // the list takes the click instead. The list has to be the top one.
        try? listWindow.performAction(kAXRaiseAction)
        Thread.sleep(forTimeInterval: 0.2)
        print("목록 창 올림   \(listWindow.frame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "프레임 없음")")

        guard AXWorker.row(row, stillShows: room) else {
            print("행 확인       그 행은 이제 다른 방입니다 (목록이 바뀌었습니다)")
            throw ExitCode.failure
        }
        if let listFrame = listWindow.frame,
           RowClickGuard.clickPoint(rowFrame: row.frame, visibleScreens: [listFrame]) == nil {
            let ok = RowScroller.bringIntoView(row: row, listWindow: listWindow, runner: runner) { print("  \($0)") }
            print("스크롤         \(ok ? "창 안으로 들어옴" : "실패")")
        }
        let fresh = row.frame
        print("행 프레임 재확인 \(fresh.map { "y=\(Int($0.minY))" } ?? "없음")")
        guard let point = RowClickGuard.clickPoint(rowFrame: fresh, visibleScreens: screens, within: listWindow.frame) else {
            print("좌표 거부      행이 목록 창 밖입니다 (창 \(listWindow.frame.map { "y \(Int($0.minY))~\(Int($0.maxY))" } ?? "?"), 행 y \(fresh.map { Int($0.midY) } ?? -1))")
            throw ExitCode.failure
        }
        print("누를 좌표      (\(Int(point.x)), \(Int(point.y)))")

        runner.mouseDoubleClick(at: point, label: "open row")
        print("두 번 누름     완료")

        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if kakao.windows.contains(where: { $0.role == kAXWindowRole && $0.title == room }) {
                print("창 대기        열렸습니다")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("창 대기        2.5초 안에 열리지 않았습니다")
        print("지금 열린 창: " + kakao.windows.compactMap { $0.title }.map { "「\($0)」" }.joined(separator: " "))
        throw ExitCode.failure
    }

    /// NSScreen is bottom-left origin; AX frames and CGEvent are top-left.
    static func screensInEventSpace() -> [CGRect] {
        let main = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: main - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
    }
}
