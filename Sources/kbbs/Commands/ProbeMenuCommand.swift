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

        print("행 액션        " + describe(row))

        // The row exposes nothing; the cell inside it is what advertises AXShowMenu.
        let cells = row.findAll(role: kAXCellRole, limit: 4, maxNodes: 40)
        for (index, cell) in cells.enumerated() {
            print("셀[\(index)] 액션   " + describe(cell))
        }

        guard let target = cells.first(where: { ((try? $0.actionNames()) ?? []).contains("AXShowMenu") }) ?? cells.first else {
            print("셀을 찾지 못했습니다.")
            return
        }

        // A context menu will not appear for an app that is not active, so give it the
        // same conditions the double-click path gets.
        let terminal = SystemFocusProbe.frontmostPID()
        defer { if let terminal { SystemFocusProbe.activate(pid: terminal) } }
        kakao.activateForSend()
        _ = KakaoTalkApp.runningApplication.map { SystemFocusProbe.waitForFrontmost(pid: $0.processIdentifier, timeout: 1.5) }
        try? listWindow.performAction(kAXRaiseAction)
        Thread.sleep(forTimeInterval: 0.3)
        print("전면 전환      최전면=\(SystemFocusProbe.frontmostPID().map(String.init) ?? "?") 카톡=\(KakaoTalkApp.runningApplication?.processIdentifier.description ?? "?")")

        let before = menuCount(in: kakao)
        do {
            try target.performAction("AXShowMenu")
        } catch {
            print("AXShowMenu 실패: \(error)")
            print("→ 이 경로는 쓸 수 없습니다. 지금처럼 더블클릭으로 엽니다.")
            return
        }
        Thread.sleep(forTimeInterval: 1.0)

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

    private func describe(_ element: UIElement) -> String {
        let actions = (try? element.actionNames()) ?? []
        return actions.isEmpty ? "(없음)" : actions.joined(separator: "|")
    }

    private func menus(in kakao: KakaoTalkApp) -> [UIElement] {
        kakao.applicationElement.findAll(role: kAXMenuRole, limit: 12, maxNodes: 1500)
    }

    private func menuCount(in kakao: KakaoTalkApp) -> Int {
        menus(in: kakao).count
    }
}
