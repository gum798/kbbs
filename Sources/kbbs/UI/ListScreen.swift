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
            f.set(row, bordered(roomLine(
                visible[slot],
                number: state.firstNumberOnPage + slot,
                selected: slot == state.cursor
            )))
        }

        f.set(18, Frame.rule(left: Theme.teeL, fill: Theme.h, right: Theme.teeR, width: width))
        f.set(rowStatus, bordered(statusLine(state)))
        f.set(20, Frame.rule(left: Theme.teeL, fill: Theme.h, right: Theme.teeR, width: width))
        f.set(rowHotkeys, bordered(hotkeyLine(state)))
        f.set(rowPrompt, bordered(promptLine(state)))
        f.set(23, Frame.rule(left: Theme.bl, fill: Theme.h, right: Theme.br, width: width))

        return f
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
        let left = "  전체 \(total)개 / \(lo)-\(hi) (\(state.page + 1)/\(state.pageCount) 쪽)"
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
