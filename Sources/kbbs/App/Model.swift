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

    /// Where these rooms came from. The status row says so when it is not the chat list,
    /// because otherwise empty columns read as a scraper that half-worked.
    var source: ListSource = .chatList

    /// Set while the user is being asked whether to let kbbs open a room's window.
    var confirm: ConfirmBox?

    /// Something the screen has to say back — a room number nobody has, a refusal while
    /// the scan is busy. The run loop clears it after a moment; the model only holds it.
    var note: String?

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

    /// How many of this page's thirteen slots hold a room. Less than a full page only
    /// on the last one.
    var roomsOnPage: Int { visibleRooms.count }

    /// The room Enter would open, as an index into `rooms`, or nil if there is none.
    ///
    /// A typed number wins over the cursor and is absolute across pages — room 16 is
    /// typed as '16' from anywhere. A number nobody has is nil rather than clamped: the
    /// caller says '그런 방은 없습니다' rather than opening a room the user did not ask
    /// for.
    var selectedRoomIndex: Int? {
        if !numberBuffer.isEmpty {
            guard let number = Int(numberBuffer), (1...rooms.count).contains(number) else {
                return nil
            }
            return number - 1
        }
        let index = page * ListState.rowsPerPage + cursor
        return index < rooms.count ? index : nil
    }

    // MARK: - Moving

    /// Down one row, turning the page at the bottom and wrapping at the end of the list.
    ///
    /// Wrapping is what keeps the cursor off the blank slots of a partial last page:
    /// there is no position it can reach that is not a room.
    mutating func moveDown() {
        clearNumberBuffer()
        guard !rooms.isEmpty else { return }
        if cursor + 1 < roomsOnPage {
            cursor += 1
        } else {
            page = (page + 1) % pageCount
            cursor = 0
        }
    }

    mutating func moveUp() {
        clearNumberBuffer()
        guard !rooms.isEmpty else { return }
        if cursor > 0 {
            cursor -= 1
        } else {
            page = (page + pageCount - 1) % pageCount
            cursor = max(0, roomsOnPage - 1)
        }
    }

    mutating func pageForward() {
        clearNumberBuffer()
        guard !rooms.isEmpty else { return }
        page = (page + 1) % pageCount
        cursor = 0
    }

    mutating func pageBack() {
        clearNumberBuffer()
        guard !rooms.isEmpty else { return }
        page = (page + pageCount - 1) % pageCount
        cursor = 0
    }

    // MARK: - The 선택> buffer

    /// A digit, up to three. The cursor follows as a live preview when the room is on
    /// this page — and deliberately does NOT turn the page when it is not, because '1'
    /// on the way to '12' would otherwise throw the screen around twice per number.
    mutating func appendDigit(_ digit: Character) {
        guard digit.isNumber, numberBuffer.count < 3 else { return }
        numberBuffer.append(digit)
        previewBufferedRoom()
    }

    mutating func popDigit() {
        guard !numberBuffer.isEmpty else { return }
        numberBuffer.removeLast()
        previewBufferedRoom()
    }

    mutating func clearNumberBuffer() {
        numberBuffer.removeAll()
    }

    private mutating func previewBufferedRoom() {
        guard let index = selectedRoomIndex else { return }
        let target = index / ListState.rowsPerPage
        guard target == page else { return }
        cursor = index % ListState.rowsPerPage
    }
}

/// The consent gate for opening a room that has no KakaoTalk window.
struct ConfirmBox {
    enum Stage {
        case asking
        case opening(step: Int)
        case failed(reason: String)
    }

    let title: String
    var stage: Stage
}
