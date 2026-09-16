import ApplicationServices
import Foundation

/// Closing a KakaoTalk window.
///
/// Unlike sending, this is verifiable: the window is either gone from the application's
/// window list afterwards or it is not, so there is no need to believe anything the press
/// returns. kmsg did this by posting a global ⌘W; the window's own close button takes an
/// AXPress and goes nowhere near the keyboard.
struct WindowCloser {
    enum Failure: Error, CustomStringConvertible {
        case noWindow
        case noCloseButton
        case stillOpen

        var description: String {
            switch self {
            case .noWindow: return "그 이름의 창이 없습니다"
            case .noCloseButton: return "닫기 버튼을 찾지 못했습니다"
            case .stillOpen: return "눌렀지만 창이 닫히지 않았습니다"
            }
        }
    }

    private let kakao: KakaoTalkApp

    init(kakao: KakaoTalkApp) {
        self.kakao = kakao
    }

    func close(title: String) throws {
        guard let window = kakao.windows.first(where: { $0.role == kAXWindowRole && $0.title == title }) else {
            throw Failure.noWindow
        }
        guard let button: UIElement = window.attributeOptional(kAXCloseButtonAttribute).map(UIElement.init) else {
            throw Failure.noCloseButton
        }

        _ = try? button.press()

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if !kakao.windows.contains(where: { $0.role == kAXWindowRole && $0.title == title }) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Failure.stillOpen
    }
}
