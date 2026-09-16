import ApplicationServices
import CoreGraphics
import Foundation

/// Scrolls a chat-list row into the window.
///
/// KakaoTalk advertises `AXScrollDownByPage` on its list and answers "Attribute
/// unsupported" when asked to perform it, so the only thing that moves that list is a
/// wheel event. A row below the window still HAS a frame — out on the desktop — which is
/// why every room past the visible handful was clicking on nothing at all.
enum RowScroller {
    static func bringIntoView(
        row: UIElement,
        listWindow: UIElement,
        runner: AXActionRunner,
        log: (String) -> Void = { _ in }
    ) -> Bool {
        guard let windowFrame = listWindow.frame else { return false }
        let target = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

        for attempt in 0..<12 {
            guard let rowFrame = row.frame else { return false }
            let centre = rowFrame.midY
            if centre >= windowFrame.minY, centre <= windowFrame.maxY { return true }

            // Three lines a step: enough to make progress, small enough to stop on the row
            // rather than past it.
            let lines = centre > windowFrame.maxY ? -3 : 3
            log("스크롤 \(attempt + 1) 행 y=\(Int(centre)) 창 \(Int(windowFrame.minY))~\(Int(windowFrame.maxY))")
            runner.scrollWheel(at: target, lines: lines, label: "list")
            Thread.sleep(forTimeInterval: 0.12)
        }
        return false
    }
}
