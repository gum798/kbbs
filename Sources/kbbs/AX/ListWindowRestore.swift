import ApplicationServices
import Foundation

/// Bringing a minimized chat list back, and waiting for KakaoTalk to redraw it.
///
/// A window restored from the Dock reports its frame immediately and its CONTENT some
/// time later: a scan run straight after the restore came back with one row out of sixty,
/// and every row identity check then failed. So the scan is repeated until it stops
/// growing or the deadline passes.
enum ListWindowRestore {
    /// Bring the list back and hand over the one row asked for.
    ///
    /// The open path needs a single row, so it does not pay for the other fifty-nine:
    /// titles are read only until the match turns up. Nothing is returned until the list
    /// has visibly redrawn, which is what the row count is for — a restore in progress
    /// reports one row, and answering "that room is not in the list" from that is how an
    /// open fails on a list that was about to be fine.
    static func rowAfterRestoring(
        titled title: String,
        listWindow: UIElement,
        scanner: ChatListScanner,
        limit: Int,
        log: (String) -> Void = { _ in }
    ) -> UIElement? {
        let deadline = Date().addingTimeInterval(restore(listWindow, log: log) ? 4.0 : 1.0)
        repeat {
            let (rowCount, row) = scanner.findRow(titled: title, in: listWindow, limit: limit)
            if let row {
                log("행 확보 (\(rowCount)행 중)")
                return row
            }
            if rowCount > 2 {
                log("\(rowCount)행을 읽었지만 그 방은 없음")
                return nil
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline

        log("복원 후에도 목록이 안 읽힘")
        return nil
    }

    /// Un-minimize if it was minimized, and say whether it was — the wait afterwards is
    /// only long when KakaoTalk has to redraw the whole list from nothing.
    static func restore(_ listWindow: UIElement, log: (String) -> Void = { _ in }) -> Bool {
        let wasMinimized = (listWindow.attributeOptional(kAXMinimizedAttribute) ?? false) as Bool
        if wasMinimized {
            try? listWindow.setAttribute(kAXMinimizedAttribute, value: false as CFBoolean)
            log("목록 창 복원")
        }
        return wasMinimized
    }

    static func rowsAfterRestoring(
        listWindow: UIElement,
        scanner: ChatListScanner,
        limit: Int,
        log: (String) -> Void = { _ in }
    ) -> [ChatRowHandle] {
        let wasMinimized = (listWindow.attributeOptional(kAXMinimizedAttribute) ?? false) as Bool
        if wasMinimized {
            try? listWindow.setAttribute(kAXMinimizedAttribute, value: false as CFBoolean)
            log("목록 창 복원")
        }

        var best: [ChatRowHandle] = []
        let deadline = Date().addingTimeInterval(wasMinimized ? 4.0 : 1.0)
        repeat {
            let found = scanner.scanRows(in: listWindow, limit: limit)
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
