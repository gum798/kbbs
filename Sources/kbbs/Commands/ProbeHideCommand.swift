import ApplicationServices
import ArgumentParser
import Foundation

/// Does AXHidden — the Accessibility spelling of ⌘H — put KakaoTalk away, and can kbbs
/// still read it afterwards?
///
/// The open path minimizes windows one at a time, verifying each and retrying, because
/// the comment in Worker says hiding the application "does not work". That was written
/// about `NSRunningApplication.hide()`. The application element's own AXHidden attribute
/// has never been tried, and hiding would put every window away in one write instead of
/// a retry ladder per window.
///
/// Reading is the part that decides it. kbbs polls the chat list and the transcript
/// continuously; a hidden app that stops answering would take the whole program with it.
/// So this hides, reads, and always unhides on the way out.
struct ProbeHideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe-hide",
        abstract: "앱 가리기(AXHidden)가 되는지, 가린 뒤에도 읽히는지 잰다 (끝나면 되돌린다)"
    )

    // Not an option: the root command already owns --room, and ArgumentParser gives it
    // to the root, leaving this one nil with no complaint.
    @Argument(help: "이 방의 입력창에 넣었다 지우기까지 해 본다 (보내지 않는다)")
    var room: String?

    func run() throws {
        guard AccessibilityPermission.isGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
        let kakao = try KakaoTalkApp()
        let app = kakao.applicationElement

        // Whatever happens below, KakaoTalk does not stay hidden because of this probe.
        defer { settle(app, to: false, label: "되돌리기") }

        print("시작           가려짐=\(read(app)) 창=\(kakao.windows.count)개")
        report("가리기 전", kakao: kakao)

        // The write reports success either way — every other settable attribute in this
        // app does — and the first read after it came back with the OLD value, so the
        // attribute settles asynchronously and a single read-back proves nothing. Poll.
        settle(app, to: true, label: "가리기")
        report("가린 뒤", kakao: kakao)
        Thread.sleep(forTimeInterval: 1.0)
        report("1초 뒤", kakao: kakao)
        print("지금 상태      가려짐=\(read(app))")
        if let room { probeComposer(room: room, kakao: kakao) }
    }

    /// Write the attribute and wait for the app to agree, reporting how long that took.
    private func settle(_ app: UIElement, to wanted: Bool, label: String) {
        let started = Date()
        try? app.setAttribute(kAXHiddenAttribute, value: wanted as CFBoolean)
        let deadline = started.addingTimeInterval(3)
        while Date() < deadline {
            if (app.attributeOptional(kAXHiddenAttribute) ?? !wanted) as Bool == wanted {
                print(String(format: "%@%.0fms 뒤 반영됨", pad(label), Date().timeIntervalSince(started) * 1000))
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        print("\(pad(label))3초 안에 반영 안 됨 (가려짐=\(read(app)))")
    }

    /// Does the composer of a hidden window still take a value, and does KakaoTalk still
    /// enable its own 전송 button for it?
    ///
    /// The two steps a send depends on, and nothing after them. Nothing is pressed and
    /// the composer is cleared again — the failure this is guarding against is a message
    /// leaving the machine, so the probe must not be able to cause one.
    private func probeComposer(room: String, kakao: KakaoTalkApp) {
        let runner = AXActionRunner(traceEnabled: false)
        guard let window = kakao.windows.first(where: { $0.role == kAXWindowRole && $0.title == room }) else {
            print("\(pad("입력창"))「\(room)」 창이 없습니다")
            return
        }
        // The state being measured is "app hidden, window NOT minimized" — that is what
        // hiding would replace the per-window minimize ladder with. Un-minimizing while
        // the app is hidden puts nothing on screen.
        let wasMinimized = (window.attributeOptional(kAXMinimizedAttribute) ?? false) as Bool
        if wasMinimized {
            try? window.setAttribute(kAXMinimizedAttribute, value: false as CFBoolean)
            Thread.sleep(forTimeInterval: 0.3)
            print("\(pad("창 펴기"))최소화=\((window.attributeOptional(kAXMinimizedAttribute) ?? false) as Bool)")
        }
        defer {
            if wasMinimized {
                try? window.setAttribute(kAXMinimizedAttribute, value: true as CFBoolean)
            }
        }
        let resolver = MessageContextResolver(kakao: kakao, runner: runner, interactionMode: .backgroundSafe)
        guard let context = AXDeadline.within(15, { resolver.resolve(in: window) }).value else {
            print("\(pad("입력창"))찾지 못했습니다")
            return
        }
        let composer = context.inputElement
        guard (composer.stringValue ?? "").isEmpty else {
            print("\(pad("입력창"))비어 있지 않습니다 — 건드리지 않습니다")
            return
        }
        let marker = "kbbs 가리기 확인"
        try? composer.setAttribute(kAXValueAttribute, value: marker as CFString)
        Thread.sleep(forTimeInterval: 0.15)
        let readBack = composer.stringValue ?? ""
        let button = window.findAll(
            where: { $0.role == kAXButtonRole && $0.title == "전송" },
            limit: 1,
            maxNodes: 200
        ).first
        var enabled = button?.isEnabled ?? false
        let deadline = Date().addingTimeInterval(0.6)
        while !enabled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            enabled = button?.isEnabled ?? false
        }
        print("\(pad("주입"))\(readBack == marker ? "반영됨" : "반영 안 됨 (\(readBack.count)자)")")
        print("\(pad("전송 버튼"))\(button == nil ? "없음" : (enabled ? "활성" : "비활성"))")
        try? composer.setAttribute(kAXValueAttribute, value: "" as CFString)
        print("\(pad("입력창 정리"))\((composer.stringValue ?? "").isEmpty ? "비움" : "남아 있음")")
    }

    private func read(_ app: UIElement) -> String {
        let hidden: Bool? = app.attributeOptional(kAXHiddenAttribute)
        return hidden.map(String.init) ?? "모름"
    }

    /// What the chat list answers in this state: how many rows, and whether the first one
    /// carries coordinates. Coordinates are the part the open path cannot do without.
    private func report(_ label: String, kakao: KakaoTalkApp) {
        guard let listWindow = kakao.chatListWindow, listWindow.role == kAXWindowRole else {
            print("\(pad(label))목록 창 없음")
            return
        }
        let started = Date()
        let rows = ChatListScanner().scanRows(in: listWindow, limit: 60)
        let elapsed = Date().timeIntervalSince(started)
        let frame = rows.first?.element.frame
        print(
            String(
                format: "%@%d행 %.0fms  첫 행=%@ 좌표=%@",
                pad(label),
                rows.count,
                elapsed * 1000,
                rows.first?.title ?? "없음",
                frame.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "없음"
            )
        )
    }

    private func pad(_ label: String) -> String { Width.pad(label, to: 15) }
}
