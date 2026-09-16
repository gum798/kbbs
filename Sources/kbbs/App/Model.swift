import Foundation

/// One row of the board index.
///
/// A plain value with no AX handle in it. The worker builds these from a scan and hands
/// them to the main thread; the renderer never touches a UIElement.
struct Room: Equatable {
    let title: String
    let lastMessage: String?
    let timeLabel: String?
    let unreadCount: Int?

    /// Whether KakaoTalk currently has a window open for this room, decided by matching
    /// window titles against row titles.
    ///
    /// It decides how expensive Enter is. A room with a window is a title lookup and a
    /// background-safe read, tens of milliseconds, nothing steals focus. A room without
    /// one has to be opened by driving KakaoTalk's own chat list, which activates the
    /// app and may post a hardware double-click — so it goes behind a confirmation.
    ///
    /// It is a guess, and a title collision routes to the wrong room. Korean chat lists
    /// routinely hold duplicate names.
    let hasWindow: Bool

    init(
        title: String,
        lastMessage: String? = nil,
        timeLabel: String? = nil,
        unreadCount: Int? = nil,
        hasWindow: Bool = false
    ) {
        // Flattened here rather than at render time: a control character measures zero
        // cells, so a column padded around one is a cell over budget and the row loses
        // its right border. The row has to be built from text that is already one line.
        self.title = Width.oneLine(title)
        self.lastMessage = lastMessage.map(Width.oneLine)
        self.timeLabel = timeLabel.map(Width.oneLine)
        self.unreadCount = unreadCount
        self.hasWindow = hasWindow
    }
}

/// How the worker's last attempt to read KakaoTalk went. Rendered into the status row
/// rather than hidden, because a poll that quietly stopped working looks exactly like a
/// chat where nobody is talking.
enum LinkState: Equatable {
    case connecting
    case live(lastRefresh: Date)
    case slow(since: Date)
    case down(since: Date, reason: String)
}

/// Everything the list screen draws. Mutated only on the main thread.
struct ListState {
    var rooms: [Room] = []
    var page = 0
    var cursor = 0
    /// Digits typed at the `선택>` prompt. The ▶ cursor mirrors them as they are typed.
    var numberBuffer = ""
    var link: LinkState = .connecting
    var clock = Date()

    static let rowsPerPage = 13

    var pageCount: Int { max(1, (rooms.count + ListState.rowsPerPage - 1) / ListState.rowsPerPage) }

    var visibleRooms: ArraySlice<Room> {
        let start = page * ListState.rowsPerPage
        guard start < rooms.count else { return [] }
        let end = min(start + ListState.rowsPerPage, rooms.count)
        return rooms[start..<end]
    }

    /// 1-based index of the first room on this page, as shown in the number column.
    var firstNumberOnPage: Int { page * ListState.rowsPerPage + 1 }
}
