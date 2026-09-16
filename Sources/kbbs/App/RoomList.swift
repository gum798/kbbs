import Foundation

/// Where the board index came from.
enum ListSource {
    /// KakaoTalk's own chat list, with previews, timestamps and unread counts.
    case chatList
    /// Only the conversations that happen to have a window open. Closing the chat list
    /// window does not quit KakaoTalk, so this is an ordinary state to find the app in.
    case openWindowsOnly
}

enum RoomList {
    /// A board index built from the windows KakaoTalk has open.
    ///
    /// Everything except the name is missing here and is left empty rather than guessed:
    /// a window carries no preview, no timestamp and no unread count. What it does carry
    /// is the only expensive fact in the list — every one of these rooms can be entered
    /// with a background read and no takeover of the screen.
    static func fromOpenWindows(titles: [String], listWindowTitle: String?) -> [Room] {
        var seen = Set<String>()
        var rooms: [Room] = []
        for title in titles {
            guard !title.isEmpty, title != listWindowTitle, !seen.contains(title) else { continue }
            seen.insert(title)
            rooms.append(Room(title: title, hasWindow: true))
        }
        return rooms
    }
}
