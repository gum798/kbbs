import Foundation

/// The dial-up ritual, printed in cooked mode before the alternate screen exists.
///
/// It is not only decoration. Every check that can fail before kbbs takes over the
/// terminal fails *here*, where an error is an ordinary line of text the user can read
/// and scroll back to — rather than inside a full-screen frame that a stray `print()`
/// from the scraper would shear in half. It doubles as the smoke test: if the ladder
/// gets to the end, the AX stack works.
struct BootLadder {
    /// Left column width so the dot leaders line up.
    private static let leader = 60

    private let out: (String) -> Void

    init(out: @escaping (String) -> Void = { print($0) }) {
        self.out = out
    }

    func banner(version: String) {
        out("KBBS  카카오톡 통신 단말기  v\(version)   (c) 1994  \(NSUserName())")
        out("")
        out("ATZ")
        out("OK")
        out("ATDT 01410")
        out("CONNECT 9600/ARQ/V32BIS/LAPM/V42BIS")
        out("")
        let title = Frame.rule(left: "╔", fill: "═", right: "╗", width: 54, title: " 접  속 ")
        out("  " + title)
        out("  " + Frame.bordered("           K B B S  ·  카카오톡 통신 서비스", left: "║", right: "║", width: 54))
        out("  " + Frame.bordered("              하이텔 호환 모드   80 x 24", left: "║", right: "║", width: 54))
        out("  " + Frame.rule(left: "╚", fill: "═", right: "╝", width: 54))
        out("")
    }

    /// ` 카카오톡 실행 ................................... 확인  PID 1421`
    func step(_ label: String, _ result: String, detail: String? = nil) {
        let labelCells = Width.cells(label)
        let dots = max(3, BootLadder.leader - labelCells - 1)
        var line = " " + label + " " + String(repeating: ".", count: dots) + " " + result
        if let detail { line += "  " + detail }
        out(line)
    }

    func note(_ text: String) {
        out(" ※ " + text)
    }

    func blank() { out("") }

    func connected() {
        out("")
        out(" 접속되었습니다.")
        out("")
    }

    func failed(_ reason: String) {
        out("")
        out(" NO CARRIER — " + reason)
        out("")
    }
}
