import Foundation

struct BlockedState {
    var reason: String
    var since: Date
    var lastGoodRead: Date?
    var retryIn: TimeInterval
    var clock: Date
    /// The one cause retrying cannot fix.
    var permissionLost = false
}

enum BlockedScreen {
    private static let width = ListScreen.width
    private static let inner = ListScreen.inner

    /// Block letters, because at this size the screen has nothing else to do and a wall
    /// of text is not what a user glancing over sees.
    private static let banner = [
        "██  ██  ██████   ██████   ██████",
        "██ ██   ██   ██  ██   ██  ██",
        "████    ██████   ██████   ██████      통  신  두  절",
        "██ ██   ██   ██  ██   ██      ██",
        "██  ██  ██████   ██████   ██████",
    ]

    static func render(_ state: BlockedState) -> Frame {
        var f = Frame(width: width, height: 24)
        f.set(0, Frame.rule(left: Theme.tl, fill: Theme.h, right: Theme.tr, width: width))
        f.set(1, bordered("  K B B S   카카오톡 통신" + pad(Theme.stamp(state.clock) + "  ")))
        f.set(2, Frame.rule(left: Theme.teeL, fill: Theme.h, right: Theme.teeR, width: width))

        f.set(3, bordered(""))
        var row = 4
        for line in banner {
            f.set(row, bordered("        " + line))
            row += 1
        }
        f.set(row, bordered(""))
        row += 1

        for line in body(state) where row < 20 {
            f.set(row, bordered(Width.truncate(line, to: inner)))
            row += 1
        }
        while row < 20 {
            f.set(row, bordered(""))
            row += 1
        }

        f.set(20, Frame.rule(left: Theme.teeL, fill: Theme.h, right: Theme.teeR, width: width))
        f.set(21, bordered(statusLine(state)))
        f.set(22, bordered("  R:지금 재시도   Esc:목록으로   Q:종료"))
        f.set(23, Frame.rule(left: Theme.bl, fill: Theme.h, right: Theme.br, width: width))
        return f
    }

    private static func body(_ state: BlockedState) -> [String] {
        if state.permissionLost {
            return [
                "   손쉬운 사용 권한이 회수되었습니다.",
                "",
                "   시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용",
                "   에서 다시 허용한 뒤 실행하세요.",
            ]
        }

        let lastGood = state.lastGoodRead.map { "  (마지막 정상 수신 " + Theme.clock($0) + ")" } ?? ""
        return [
            "   카카오톡 창을 읽을 수 없습니다." + lastGood,
            "   " + Width.elide(state.reason, to: inner - 4),
            "",
            "   잠금 · 최소화 · 종료 · 권한 회수 중 하나입니다.",
            "   잠금 해제는 직접 해주세요 — kbbs 는 암호를 넣지 않습니다.",
        ]
    }

    private static func statusLine(_ state: BlockedState) -> String {
        let cutOff = Int(max(0, state.clock.timeIntervalSince(state.since)))
        let badge = "[두절 \(cutOff)초]  "
        let left = state.permissionLost
            ? "  " + Theme.lineIndicator(state.clock) + " 권한을 되돌린 뒤 다시 실행해 주세요"
            : "  " + Theme.lineIndicator(state.clock) + " 자동 재시도 · 다음 시도 \(Int(state.retryIn))초 후"
        let gap = max(1, inner - Width.cells(left) - Width.cells(badge))
        return left + String(repeating: " ", count: gap) + badge
    }

    private static func bordered(_ content: String) -> String {
        Frame.bordered(content, left: Theme.v, right: Theme.v, width: width)
    }

    private static func pad(_ right: String) -> String {
        let used = Width.cells("  K B B S   카카오톡 통신")
        return String(repeating: " ", count: max(1, inner - used - Width.cells(right))) + right
    }
}
