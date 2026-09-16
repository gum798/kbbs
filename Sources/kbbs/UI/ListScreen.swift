import Foundation

/// The board index — the screen kbbs opens on and returns to.
///
/// Pure: a `ListState` in, 24 rows out. No AX, no clock of its own, no terminal. That is
/// what makes it testable without KakaoTalk running.
enum ListScreen {

    static let width = 80
    /// Cells between the two `║` borders.
    static let inner = width - 2

    /// Fixed columns. They sum to `inner`; `columnsSumToInnerWidth` in the tests holds
    /// that true, because a miscount here is what makes the right border walk.
    private enum Col {
        static let lead = 1
        static let cursor = 1
        static let gap1 = 1
        static let num = 2
        static let dot = 2      // ". "
        static let mark = 1     // * or -
        static let gap2 = 1
        static let title = 18
        static let gap3 = 1
        static let preview = 38
        static let gap4 = 1
        static let time = 5
        static let gap5 = 1
        static let unread = 4   // "999+"
        static let trail = 1

        static let total = lead + cursor + gap1 + num + dot + mark + gap2
            + title + gap3 + preview + gap4 + time + gap5 + unread + trail
    }

    // MARK: - Rows

    private static let rowTitle = 1
    private static let rowHeader = 3
    private static let rowFirstRoom = 5
    private static let rowStatus = 19
    private static let rowHotkeys = 21
    private static let rowPrompt = 22

    static func render(_ state: ListState) -> Frame {
        var f = Frame(width: width, height: 24)

        f.set(0, Frame.rule(left: Theme.tl, fill: Theme.h, right: Theme.tr, width: width))
        f.set(rowTitle, bordered(titleBar(state)))
        f.set(2, Frame.rule(left: Theme.teeL, fill: Theme.h, right: Theme.teeR, width: width))
        f.set(rowHeader, bordered(columnHeader()))
        f.set(4, Frame.rule(left: Theme.teeL, fill: Theme.h, right: Theme.teeR, width: width))

        let visible = Array(state.visibleRooms)
        for slot in 0..<ListState.rowsPerPage {
            let row = rowFirstRoom + slot
            guard slot < visible.count else {
                // An unused slot on a partial last page is blank, not a placeholder.
                f.set(row, bordered(""))
                continue
            }
            let selected = slot == state.cursor
            let line = roomLine(visible[slot], number: state.firstNumberOnPage + slot, selected: selected)
            // Reverse the content, not the frame. The bar has to stop at the ║ or the box
            // reads as broken open on whichever line the cursor is on.
            f.set(row, bordered(selected ? Theme.reversed(Width.pad(line, to: inner)) : line))
        }

        if let confirm = state.confirm {
            stamp(confirm, into: &f)
        }

        f.set(18, Frame.rule(left: Theme.teeL, fill: Theme.h, right: Theme.teeR, width: width))
        f.set(rowStatus, bordered(statusLine(state)))
        f.set(20, Frame.rule(left: Theme.teeL, fill: Theme.h, right: Theme.teeR, width: width))
        f.set(rowHotkeys, bordered(hotkeyLine(state)))
        f.set(rowPrompt, bordered(promptLine(state)))
        f.set(23, Frame.rule(left: Theme.bl, fill: Theme.h, right: Theme.br, width: width))

        return f
    }

    // MARK: - The consent gate

    /// The four steps of an open, in the order they happen. Naming them is what makes a
    /// click that never lands legible: the ladder stops on the step that failed.
    private static let openSteps = ["전면 전환", "행 좌표 확인", "두 번 누르기", "창 대기"]

    /// Stamps the gate over the middle of the list, leaving the rows above it visible so
    /// the user keeps their place.
    private static func stamp(_ confirm: ConfirmBox, into f: inout Frame) {
        let body: [String]
        let heading: String

        switch confirm.stage {
        case .asking:
            heading = "[주의] 「\(Width.elide(confirm.title, to: 24))」 방은 카카오톡에 열린 창이 없습니다."
            body = [
                "",
                "창을 열려면 카카오톡이 앞으로 나와서, 목록의 해당 줄을 자동으로",
                "두 번 누릅니다. 그동안 마우스와 키보드를 건드리지 마세요.",
                "카카오톡 채팅 목록 창이 가려져 있으면 실패합니다.",
                "실패해도 메시지는 보내지 않습니다.",
                "",
                "  Y = 카카오톡에서 창 열기          N / Esc = 취소하고 목록으로",
            ]
        case .opening(let step):
            heading = "창 여는 중 — 「\(Width.elide(confirm.title, to: 24))」"
            body = [""] + openSteps.enumerated().map { index, name in
                let mark = index < step ? "완료" : (index == step ? "…" : "")
                return "  " + Width.pad(name, to: 18) + mark
            } + ["", "  마우스와 키보드를 건드리지 마세요."]
        case .failed(let reason):
            heading = "[실패] 창을 열지 못했습니다 — \(Width.elide(reason, to: 30))"
            body = [
                "",
                "카카오톡에서 이 방을 직접 여신 뒤 R 을 누르세요.",
                "메시지는 보내지 않았습니다.",
                "",
                "  R = 목록 새로고침                 Esc = 닫기",
            ]
        }

        let inner = width - 4
        let lines = [heading] + body
        // The box ends on the last list row (17); row 18 is the separator and stamping
        // over it eats the box's own bottom border.
        let top = max(rowFirstRoom, 17 - (lines.count + 1))
        f.set(top, bordered(" " + Frame.rule(left: "┌", fill: "─", right: "┐", width: inner)))
        for (offset, line) in lines.enumerated() {
            f.set(top + 1 + offset, bordered(" " + Frame.bordered(" " + line, left: "│", right: "│", width: inner)))
        }
        f.set(top + 1 + lines.count, bordered(" " + Frame.rule(left: "└", fill: "─", right: "┘", width: inner)))
    }

    // MARK: - Line composition

    private static func bordered(_ content: String) -> String {
        Frame.bordered(content, left: Theme.v, right: Theme.v, width: width)
    }

    private static func titleBar(_ state: ListState) -> String {
        let left = "  K B B S   카카오톡 통신"
        let right = Theme.stamp(state.clock) + "  "
        return left + Width.pad("", to: max(0, inner - Width.cells(left) - Width.cells(right))) + right
    }

    private static func columnHeader() -> String {
        var s = " "
        s += Width.pad("번호", to: Col.cursor + Col.gap1 + Col.num + Col.dot)
        s += Width.pad("", to: Col.mark + Col.gap2)
        s += Width.pad("대화방", to: Col.title)
        s += " "
        s += Width.pad("마지막 대화", to: Col.preview)
        s += " "
        s += pad(left: "시각", to: Col.time)
        s += " "
        s += Width.pad("안읽", to: Col.unread)
        return s
    }

    private static func roomLine(_ room: Room, number: Int, selected: Bool) -> String {
        var s = " "
        s += selected ? Theme.cursor : " "
        s += " "
        s += pad(left: String(number), to: Col.num)
        s += ". "
        s += room.hasWindow ? Theme.windowOpen : Theme.windowClosed
        s += " "
        s += Width.column(room.title, to: Col.title)
        s += " "
        s += Width.column(room.lastMessage ?? "", to: Col.preview)
        s += " "
        s += pad(left: room.timeLabel ?? "", to: Col.time)
        s += " "
        s += pad(left: unreadText(room.unreadCount), to: Col.unread)
        return s
    }

    private static func unreadText(_ count: Int?) -> String {
        guard let count else { return "" }
        // The badge caps in KakaoTalk itself, so above the cap the true number is not
        // knowable and printing a bare 999 would claim precision we do not have.
        return count >= 999 ? "999+" : String(count)
    }

    private static func statusLine(_ state: ListState) -> String {
        let total = state.rooms.count
        let lo = total == 0 ? 0 : state.firstNumberOnPage
        let hi = total == 0 ? 0 : min(state.firstNumberOnPage + ListState.rowsPerPage - 1, total)
        let refreshed: String
        switch state.link {
        case .live(let at): refreshed = Theme.clock(at)
        default: refreshed = "--:--:--"
        }
        let origin = state.source == .openWindowsOnly ? " · 열린 창만" : ""
        let left = "  전체 \(total)개\(origin) / \(lo)-\(hi) (\(state.page + 1)/\(state.pageCount) 쪽)"
            + " / 갱신 \(refreshed) / *=창열림 -=창없음"
        let badge = badgeText(state.link) + "  "
        let fill = max(1, inner - Width.cells(left) - Width.cells(badge))
        return left + String(repeating: " ", count: fill) + badge
    }

    private static func badgeText(_ link: LinkState) -> String {
        switch link {
        case .connecting: return "[접속중]"
        case .live: return "[연결됨]"
        case .slow: return "[응답 느림]"
        case .down: return "[응답 없음]"
        }
    }

    /// The hotkeys, with any note filling the space after them.
    ///
    /// The note goes here rather than on a row of its own because there is no row to
    /// spare: 24 lines are all accounted for. A note longer than the gap is truncated
    /// rather than pushing the hotkeys off the left.
    private static func hotkeyLine(_ state: ListState) -> String {
        let keys = "  P:이전  N:다음  R:새로고침  Q:종료"
        guard let note = state.note, !note.isEmpty else { return keys }
        let spare = inner - Width.cells(keys) - 2
        guard spare > 2 else { return keys }
        return keys + "  " + Width.elide(note, to: spare)
    }

    private static func promptLine(_ state: ListState) -> String {
        let prompt = "선택> \(state.numberBuffer)_"
        let indent = max(0, 52 - 1)
        return String(repeating: " ", count: indent) + prompt
    }

    /// Right-aligns `text` in a `limit`-cell field, truncating from the left if needed.
    private static func pad(left text: String, to limit: Int) -> String {
        let fitted = Width.truncate(text, to: limit)
        let spare = limit - Width.cells(fitted)
        return String(repeating: " ", count: spare) + fitted
    }

    /// Exposed for the test that keeps the column arithmetic honest.
    static var columnTotal: Int { Col.total }
}
