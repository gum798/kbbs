import ArgumentParser
import Foundation

private func invokedCommandName() -> String {
    let executable = CommandLine.arguments.first ?? "kbbs"
    let name = URL(fileURLWithPath: executable).lastPathComponent
    return name.isEmpty ? "kbbs" : name
}

@main
struct Kbbs: ParsableCommand {
    private static let commandName = invokedCommandName()

    static let configuration = CommandConfiguration(
        commandName: commandName,
        abstract: "카카오톡을 하이텔 방식 터미널로 쓴다",
        discussion: """
            \(commandName) 는 macOS 손쉬운 사용 API 로 카카오톡을 읽고 씁니다.

            시작하기 전에:
            1. 카카오톡이 실행되어 있고 로그인되어 있어야 합니다
               (\(commandName) 는 잠금 암호를 대신 입력하지 않습니다)
            2. 이 바이너리에 손쉬운 사용 권한이 있어야 합니다
               (시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용)

            인자 없이 실행하면 대화방 목록을 그립니다.

            예:
              \(commandName)
              \(commandName) --demo
              \(commandName) inspect --depth 5
            """,
        version: BuildVersion.current,
        subcommands: [
            InspectCommand.self,
        ]
    )

    @Option(name: .long, help: "읽어올 대화방 최대 개수")
    var limit: Int = 60

    @Flag(name: .long, help: "카카오톡 없이 예시 데이터로 화면만 그린다")
    var demo = false

    @Flag(name: .long, help: "접근성 트리를 어떻게 훑었는지 표준오류로 남긴다")
    var trace = false

    func run() throws {
        Paths.ensureDirectory()
        let ladder = BootLadder()
        ladder.banner(version: BuildVersion.current)

        if demo {
            ladder.step("예시 모드", "확인", detail: "카카오톡을 읽지 않습니다")
            ladder.connected()
            draw(Kbbs.demoRooms, link: .live(lastRefresh: Date()))
            return
        }

        guard AccessibilityPermission.isGranted() else {
            ladder.step("손쉬운 사용 권한 (\(Kbbs.commandName))", "없음")
            ladder.failed("손쉬운 사용 권한이 필요합니다.")
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
        ladder.step("손쉬운 사용 권한 (\(Kbbs.commandName))", "확인")

        guard let running = KakaoTalkApp.runningApplication else {
            ladder.step("카카오톡 실행", "없음")
            ladder.failed("카카오톡이 실행되어 있지 않습니다. 먼저 실행하고 로그인하세요.")
            throw ExitCode.failure
        }
        ladder.step("카카오톡 실행", "확인", detail: "PID \(running.processIdentifier)")

        // autoLaunch: false — kbbs never starts KakaoTalk for you. Launching it would
        // bring it to the front, and nothing before a deliberate send is allowed to.
        let app = try KakaoTalkApp(autoLaunch: false)

        guard let listWindow = app.chatListWindow else {
            ladder.step("대화목록 창", "없음")
            ladder.failed("대화목록 창을 찾지 못했습니다. 카카오톡 창이 열려 있는지 확인하세요.")
            throw ExitCode.failure
        }
        if let reason = Kbbs.windowFailureReason(role: listWindow.role, title: listWindow.title) {
            ladder.step("대화목록 창", "없음")
            ladder.failed(reason)
            print("  Dock 의 카카오톡 아이콘을 눌러 창을 열고, 「채팅」 탭으로 이동한 뒤")
            print("  다시 실행하세요.")
            print("")
            throw ExitCode.failure
        }
        ladder.step("대화목록 창", "확인", detail: "「\(listWindow.title ?? "제목없음")」")

        let tracer: ((String) -> Void)? = trace
            ? { FileHandle.standardError.write(Data(("[trace] " + $0 + "\n").utf8)) }
            : nil
        tracer?("windows: " + app.windows.map { "「\($0.title ?? "-")」" }.joined(separator: " "))

        // Ambiguous-width glyphs are measured with a DSR-CPR probe, which needs raw
        // mode. Until that exists we assume narrow and say so rather than pretending.
        ladder.step("문자폭 (▶ ● ─ 등)", "좁게 1칸", detail: "측정 전 기본값")

        let started = Date()
        let scanner = ChatListScanner()
        let items = scanner.scan(in: listWindow, limit: limit, trace: tracer)
        let elapsed = Date().timeIntervalSince(started)

        guard !items.isEmpty else {
            ladder.step("대화방 목록 읽기", "0개", detail: String(format: "%.1f초", elapsed))
            // The scanner distinguishes "no container" from "container but no rows"
            // in its trace; without it we can only report the symptom, so say what to
            // check rather than pretending to know which happened.
            ladder.failed("대화방을 하나도 읽지 못했습니다.")
            print("")
            print(Kbbs.diagnoseEmptyList(in: listWindow, commandName: Kbbs.commandName))
            print("  어디서 끊겼는지 보려면:  \(Kbbs.commandName) --trace")
            print("")
            throw ExitCode.failure
        }
        ladder.step("대화방 목록 읽기", "\(items.count)개", detail: String(format: "%.1f초", elapsed))

        let openTitles = Set(app.windows.compactMap { $0.title })
        let rooms = items.map { item in
            Room(
                title: item.discovery.title,
                lastMessage: item.discovery.lastMessage,
                timeLabel: item.discovery.timeLabel,
                unreadCount: item.discovery.unreadCount,
                hasWindow: Kbbs.hasOpenWindow(item.discovery.title, among: openTitles, listWindow: listWindow.title)
            )
        }

        ladder.blank()
        ladder.note("잠금 화면은 건드리지 않습니다. 암호를 여러 번 틀리면 계정이 로그아웃됩니다.")
        ladder.connected()

        draw(rooms, link: .live(lastRefresh: Date()))
    }

    private func draw(_ rooms: [Room], link: LinkState) {
        var state = ListState()
        state.rooms = rooms
        state.link = link
        state.clock = Date()
        for row in ListScreen.render(state).render() {
            print(row)
        }
    }

    /// Whether KakaoTalk has a window open for this room.
    ///
    /// A title match, which is all we have: there is no chat id on a window. Korean chat
    /// lists routinely contain duplicate names, so this can point at the wrong room —
    /// the room title bar shows the matched window title so a mismatch is visible.
    static func hasOpenWindow(_ roomTitle: String, among windowTitles: Set<String>, listWindow: String?) -> Bool {
        guard !roomTitle.isEmpty, roomTitle != "(Unknown Chat)" else { return false }
        for title in windowTitles where title != listWindow {
            if title == roomTitle { return true }
        }
        return false
    }

    /// Why a resolved "chat list window" is not actually usable, or nil if it is.
    ///
    /// `findWindow(title:)` matches on title alone. When KakaoTalk is running with every
    /// window closed, the AX tree holds only menu bars and the element whose title is
    /// "카카오톡" is the APPLICATION, not a window — so the check passed, the scan then
    /// found nothing, and the two messages contradicted each other. Verified against the
    /// live app: role came back AXApplication.
    static func windowFailureReason(role: String?, title: String?) -> String? {
        guard let role else {
            return "창을 식별할 수 없습니다 (role 을 읽지 못했습니다)."
        }
        guard role == kAXWindowRole else {
            let name = title.map { "「\($0)」" } ?? "이름 없는 요소"
            return """
            열린 카카오톡 창이 없습니다.
              \(name) 를 찾았지만 이것은 창이 아니라 \(role) 입니다.
              카카오톡이 실행 중이지만 창이 모두 닫혀 있을 때 이렇게 보입니다.
            """
        }
        return nil
    }

    /// Why the scan came back empty, said precisely rather than guessed.
    ///
    /// KakaoTalk's main window carries one navigation button per tab, identified as
    /// `friends` / `chatrooms` / `more`. If those are present but the chat-list
    /// container is not, the window is simply on another tab — the most common cause,
    /// and one the user fixes in a second once told plainly.
    ///
    /// Read-only: nothing is clicked and nothing is brought to the front.
    ///
    /// Budgeted deliberately. `UIElement.findFirst(identifier:)` delegates to the
    /// unbounded `findFirst(where:)`, and on KakaoTalk's real tree that does not finish
    /// — an earlier version of this function ran for over seven minutes before being
    /// killed. Nav buttons live near the root, so a few thousand nodes is generous, and
    /// one traversal collects all three instead of three traversals collecting one each.
    static func diagnoseEmptyList(in window: UIElement, commandName: String) -> String {
        let labels = ["chatrooms": "채팅", "friends": "친구", "more": "더보기"]
        let hits = window.findAll(
            where: { labels.keys.contains($0.identifier ?? "") },
            limit: labels.count,
            maxNodes: 3000
        )

        guard !hits.isEmpty else {
            return """
              이 창에서는 탭 버튼(친구/채팅/더보기)조차 찾지 못했습니다.
              카카오톡이 로그인 화면이나 잠금 화면일 수 있습니다.
              카카오톡을 직접 확인해 주세요.
            """
        }

        let found = hits.compactMap { button -> String? in
            guard let id = button.identifier, let label = labels[id] else { return nil }
            let selected = (button.value as? Int).map { $0 != 0 }
                ?? (button.stringValue.map { $0 == "1" } ?? false)
            return label + (selected ? "(선택됨)" : "")
        }.sorted()

        return """
          탭 버튼은 보입니다: \(found.joined(separator: " / "))
          그런데 대화목록이 없습니다 — 카카오톡이 「채팅」 탭에 있지 않습니다.
          카카오톡 창에서 채팅 탭을 누른 뒤 다시 실행하세요.

          (\(commandName) 가 대신 눌러 주지는 않습니다. 그러려면 카카오톡을 앞으로
           끌어내야 하는데, 읽기만 하는 동안에는 그러지 않습니다.)
        """
    }

    static let demoRooms: [Room] = [
        Room(title: "김민수", lastMessage: "내일 몇 시에 봐요?", timeLabel: "21:03", unreadCount: 2, hasWindow: true),
        Room(title: "개발팀", lastMessage: "빌드 깨졌어요 확인 부탁드립니다", timeLabel: "20:58", unreadCount: 14, hasWindow: true),
        Room(title: "어머니", lastMessage: "밥은 먹었니", timeLabel: "20:31"),
        Room(title: "고등학교 3학년 2반 동창회", lastMessage: "[사진]", timeLabel: "20:12", unreadCount: 3),
        Room(title: "박지훈", lastMessage: "ㅋㅋㅋㅋㅋ", timeLabel: "19:44"),
        Room(title: "회사 공지방", lastMessage: "금요일 전사 워크샵 안내드립니다", timeLabel: "18:02"),
        Room(title: "Claude Code 스터디", lastMessage: "다음 주 발표 자료 공유드려요", timeLabel: "17:20", unreadCount: 1),
        Room(title: "이수진", lastMessage: "네 알겠습니다", timeLabel: "어제"),
        Room(title: "가족방", lastMessage: "이번 주말에 내려갈게요", timeLabel: "어제", unreadCount: 1234),
        Room(title: "최영호", lastMessage: "감사합니다!", timeLabel: "어제"),
        Room(title: "점심 메뉴 추천방", lastMessage: "오늘은 국밥", timeLabel: "3일"),
        Room(title: "정은지", lastMessage: "링크 보냈어요", timeLabel: "3일"),
        Room(title: "동아리 번개", lastMessage: "다들 시간 되시나요", timeLabel: "4일"),
    ]

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 1, arguments[0] == "-v" {
            print(BuildVersion.current)
            return
        }
        self.main(arguments)
    }
}
