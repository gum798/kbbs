import XCTest

@testable import kbbs

/// KakaoTalk's chat-list window can be closed while conversations stay open — closing it
/// does not quit the app, and it is the state a machine is often left in. kbbs used to
/// stop there. The open windows are a chat list of their own, so it falls back to them.
final class OpenWindowListTests: XCTestCase {

    func testEachOpenChatWindowBecomesARoom() {
        let rooms = RoomList.fromOpenWindows(titles: ["누나", "윤지원✨"], listWindowTitle: nil)
        XCTAssertEqual(rooms.map(\.title), ["누나", "윤지원✨"])
    }

    /// Every one of them has a window by definition, which is what makes this list worth
    /// showing: entering any of them is the cheap, silent path.
    func testTheyAllHaveWindows() {
        let rooms = RoomList.fromOpenWindows(titles: ["누나"], listWindowTitle: nil)
        XCTAssertTrue(rooms.allSatisfy(\.hasWindow))
    }

    func testTheChatListWindowIsNotARoom() {
        let rooms = RoomList.fromOpenWindows(titles: ["카카오톡", "누나"], listWindowTitle: "카카오톡")
        XCTAssertEqual(rooms.map(\.title), ["누나"])
    }

    func testUntitledWindowsAreDropped() {
        let rooms = RoomList.fromOpenWindows(titles: ["", "누나"], listWindowTitle: nil)
        XCTAssertEqual(rooms.map(\.title), ["누나"])
    }

    func testTheSameTitleTwiceAppearsOnce() {
        let rooms = RoomList.fromOpenWindows(titles: ["누나", "누나"], listWindowTitle: nil)
        XCTAssertEqual(rooms.count, 1)
    }

    /// There is no preview, timestamp or unread count on a window — only the chat list
    /// carries those. The columns are left empty rather than filled with a guess.
    func testThereIsNoPreviewOrTimeToInvent() {
        let room = RoomList.fromOpenWindows(titles: ["누나"], listWindowTitle: nil)[0]
        XCTAssertNil(room.lastMessage)
        XCTAssertNil(room.timeLabel)
        XCTAssertNil(room.unreadCount)
    }

    func testNoWindowsMeansNoRooms() {
        XCTAssertTrue(RoomList.fromOpenWindows(titles: [], listWindowTitle: "카카오톡").isEmpty)
    }
}
