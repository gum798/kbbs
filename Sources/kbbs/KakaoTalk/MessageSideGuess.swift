import CoreGraphics

/// Which edge of the conversation pane a bubble is aligned to.
///
/// By the edges, not the centre. A long message fills most of the pane whichever side it
/// is on, so its centre lands near the middle either way — which is how a user's own
/// message came to be displayed under the other person's name.
enum MessageSideGuess {
    /// How far apart the two gaps must be before the difference means anything, as a
    /// fraction of the pane. Measured: mine sit 35 from the right and theirs 60 from the
    /// left, so a real difference is 45 of 380 — while a centred system notice differs by
    /// 17. Anything in between is `unknown`, and the screen says 나?.
    private static let margin: CGFloat = 0.08

    static func of(bubble: CGRect?, in pane: CGRect?) -> MessageSide {
        guard let bubble, let pane, pane.width > 1, bubble.width > 1 else { return .unknown }

        let leftGap = bubble.minX - pane.minX
        let rightGap = pane.maxX - bubble.maxX
        let threshold = pane.width * margin

        if leftGap + threshold < rightGap { return .left }
        if rightGap + threshold < leftGap { return .right }
        return .unknown
    }
}
