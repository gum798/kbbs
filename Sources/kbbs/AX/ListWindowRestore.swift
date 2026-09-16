import ApplicationServices
import Foundation

/// Bringing a minimized chat list back, and waiting for KakaoTalk to redraw it.
///
/// A window restored from the Dock reports its frame immediately and its CONTENT some
/// time later: a scan run straight after the restore came back with one row out of sixty,
/// and every row identity check then failed. So the scan is repeated until it stops
/// growing or the deadline passes.
enum ListWindowRestore {
    static func rowsAfterRestoring(
        listWindow: UIElement,
        scanner: ChatListScanner,
        limit: Int,
        log: (String) -> Void = { _ in }
    ) -> [ChatListSnapshotItem] {
        let wasMinimized = (listWindow.attributeOptional(kAXMinimizedAttribute) ?? false) as Bool
        if wasMinimized {
            try? listWindow.setAttribute(kAXMinimizedAttribute, value: false as CFBoolean)
            log("목록 창 복원")
        }

        var best: [ChatListSnapshotItem] = []
        let deadline = Date().addingTimeInterval(wasMinimized ? 4.0 : 1.0)
        repeat {
            let found = scanner.scan(in: listWindow, limit: limit, trace: nil)
            if found.count > best.count { best = found }
            // Two rows is the smallest list worth believing; a restore in progress reports
            // one, and a real account with one chat does not need this path at all.
            if best.count > 2 { return best }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline

        log("복원 후에도 \(best.count)개만 읽힘")
        return best
    }
}
