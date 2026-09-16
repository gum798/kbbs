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
        ladder.step("대화목록 창", "확인", detail: "「\(listWindow.title ?? "제목없음")」")

        // Ambiguous-width glyphs are measured with a DSR-CPR probe, which needs raw
        // mode. Until that exists we assume narrow and say so rather than pretending.
        ladder.step("문자폭 (▶ ● ─ 등)", "좁게 1칸", detail: "측정 전 기본값")

        let started = Date()
        let scanner = ChatListScanner()
        let items = scanner.scan(in: listWindow, limit: limit)
        let elapsed = Date().timeIntervalSince(started)

        guard !items.isEmpty else {
            ladder.step("대화방 목록 읽기", "0개", detail: String(format: "%.1f초", elapsed))
            ladder.failed("대화방을 하나도 읽지 못했습니다. `\(Kbbs.commandName) inspect` 로 창 구조를 확인하세요.")
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
