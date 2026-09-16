import CoreGraphics

/// Whether a chat-list row can safely be double-clicked, and where.
///
/// This is the only place in kbbs that produces coordinates for a hardware event. The
/// click lands wherever the numbers say — on another application, on a desktop icon, on
/// nothing — so every way the numbers can be wrong is refused here rather than explained
/// afterwards.
///
/// Pure on purpose. The caller passes the row's freshly re-read AX frame and the screen
/// rectangles already converted to the same top-left-origin space CGEvent uses.
enum RowClickGuard {
    /// The smallest row worth clicking. Anything thinner is KakaoTalk reporting a row it
    /// has scrolled out of view, whose centre is still a perfectly clickable coordinate
    /// somewhere it should not be clicked.
    private static let minimumSide: CGFloat = 4

    /// `window` is the list's own frame. A scrollable list gives frames to rows that have
    /// scrolled out of sight — real coordinates on a real display, below the window's
    /// bottom edge — and clicking one lands on the desktop or on whatever is behind it.
    static func clickPoint(rowFrame: CGRect?, visibleScreens: [CGRect], within window: CGRect? = nil) -> CGPoint? {
        guard let rowFrame,
              rowFrame.width >= minimumSide,
              rowFrame.height >= minimumSide,
              rowFrame.width.isFinite,
              rowFrame.height.isFinite
        else {
            return nil
        }

        let centre = CGPoint(x: rowFrame.midX, y: rowFrame.midY)
        // The centre is what gets clicked, so the centre is what has to be on a display.
        // A row half off the edge fails here rather than clicking the half that is left.
        guard visibleScreens.contains(where: { $0.contains(centre) }) else { return nil }
        if let window, !window.contains(centre) { return nil }
        return centre
    }
}
