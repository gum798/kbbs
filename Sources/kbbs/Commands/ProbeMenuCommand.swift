import ApplicationServices
import ArgumentParser
import Foundation

/// Does a chat-list row's context menu work, and does it offer a way to open the room?
///
/// If it does, opening a room needs no click, no raise and no activation — KakaoTalk
/// would never come forward at all. Nothing here presses a menu item; it opens the menu,
/// reads the item labels, and closes it again.
struct ProbeMenuCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe-menu",
        abstract: "대화방 행의 우클릭 메뉴를 열어 항목만 읽는다 (누르지 않는다)"
    )

    @Argument(help: "확인할 대화방 이름")
    var room: String

    func run() throws {
        guard AccessibilityPermission.isGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
        let kakao = try KakaoTalkApp()
        guard let listWindow = kakao.chatListWindow, listWindow.role == kAXWindowRole else {
            print("대화목록 창이 없습니다.")
            throw ExitCode.failure
        }

        let items = ChatListScanner().scan(in: listWindow, limit: 60, trace: nil)
        guard let row = items.first(where: { $0.discovery.title == room })?.element else {
            print("「\(room)」 행이 목록에 없습니다.")
            throw ExitCode.failure
        }

        let actions = (try? row.actionNames()) ?? []
        print("행 액션        \(actions.isEmpty ? "(없음)" : actions.joined(separator: "|"))")
        guard actions.contains("AXShowMenu") else {
            print("AXShowMenu 를 광고하지 않습니다.")
            return
        }

        let before = menuCount(in: kakao)
        do {
            try row.performAction("AXShowMenu")
        } catch {
            print("AXShowMenu 실패: \(error)")
            print("→ 이 경로는 쓸 수 없습니다. 지금처럼 더블클릭으로 엽니다.")
            return
        }
        Thread.sleep(forTimeInterval: 0.6)

        let menus = menus(in: kakao)
        print("열린 메뉴      \(menus.count)개 (전 \(before)개)")
        guard let menu = menus.last else {
            print("→ 액션은 성공했다지만 메뉴가 없습니다. 또 하나의 빈 약속입니다.")
            return
        }

        let entries = menu.findAll(role: kAXMenuItemRole, limit: 20, maxNodes: 200)
        print("항목           " + entries.compactMap { $0.title }.map { "「\($0)」" }.joined(separator: " "))
        print("항목 액션      " + entries.prefix(3).map { (try? $0.actionNames())?.joined(separator: "|") ?? "-" }.joined(separator: " / "))

        // Close it again: a context menu left open blocks the app.
        try? menu.performAction(kAXCancelAction)
        Thread.sleep(forTimeInterval: 0.3)
        let after = menuCount(in: kakao)
        print("닫기           \(after <= before ? "확인" : "실패 — 카카오톡에서 아무 곳이나 클릭해 닫아 주세요")")
    }

    private func menus(in kakao: KakaoTalkApp) -> [UIElement] {
        kakao.applicationElement.findAll(role: kAXMenuRole, limit: 8, maxNodes: 400)
    }

    private func menuCount(in kakao: KakaoTalkApp) -> Int {
        menus(in: kakao).count
    }
}
