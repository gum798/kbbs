import ArgumentParser
import Darwin
import Foundation

/// Prints what the terminal actually sends, and what kbbs makes of it.
///
/// Terminals disagree about almost every key that is not a letter, and the disagreement
/// is invisible from the outside. Ctrl-C quits.
struct KeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "키를 누르면 터미널이 보낸 바이트와 해석 결과를 보여준다 (Ctrl-C 로 종료)"
    )

    func run() throws {
        TTYOut.capture()
        guard RawMode.enter() else {
            print("터미널을 제어할 수 없습니다.")
            throw ExitCode.failure
        }
        defer { RawMode.restore() }

        TTYOut.write("키를 눌러 보세요. Ctrl-C 로 종료.\r\n\r\n")
        var decoder = KeyDecoder()

        while true {
            let bytes = RawMode.read(timeoutMilliseconds: 100)
            if RawMode.quitRequested() { return }
            guard !bytes.isEmpty else {
                for key in decoder.flushPendingEscape() {
                    TTYOut.write("          → \(describe(key))\r\n")
                    if case .control("c") = key { return }
                }
                continue
            }

            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let printable = bytes.map { $0 >= 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : "·" }.joined()
            TTYOut.write("\(hex.padding(toLength: max(hex.count, 24), withPad: " ", startingAt: 0))\(printable)\r\n")

            for key in decoder.feed(bytes) {
                TTYOut.write("          → \(describe(key))\r\n")
                if case .control("c") = key { return }
            }
        }
    }

    private func describe(_ key: Key) -> String {
        switch key {
        case .char(let c): return "char(\(c))"
        case .enter: return "enter  ← 전송"
        case .lineBreak: return "lineBreak  ← 줄바꿈"
        case .escape: return "escape"
        case .backspace: return "backspace"
        case .tab: return "tab"
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageUp"
        case .pageDown: return "pageDown"
        case .control(let c): return "control(\(c))"
        }
    }
}
