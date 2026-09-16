import Foundation

/// One keystroke, after the bytes have been put back together.
enum Key: Equatable {
    case char(Character)
    case up, down, left, right
    case home, end, pageUp, pageDown
    case enter, backspace, tab, escape
    case control(Character)
}

/// Bytes off the terminal, turned into keys.
///
/// Everything here is incremental, because a `read(2)` boundary falls wherever the
/// kernel puts it: a Hangul syllable is three bytes and an arrow key is three bytes, and
/// either can arrive one byte at a time. The decoder keeps what it could not finish and
/// picks it up on the next call.
///
/// It never reads the clock. Escape is the one byte whose meaning depends on time — it
/// is both a key and the start of every arrow — so the decoder holds it and the run loop
/// decides when enough time has passed, by calling `flushPendingEscape`. Putting the
/// timer in here would make the decoder untestable for the sake of one branch.
struct KeyDecoder {
    /// Bytes of a UTF-8 sequence that has not finished arriving.
    private var partial: [UInt8] = []
    /// Bytes of an escape sequence that has not finished arriving, including the ESC.
    private var escape: [UInt8] = []

    mutating func feed(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        for byte in bytes {
            if !escape.isEmpty {
                consumeEscapeByte(byte, into: &keys)
                continue
            }
            if byte == 0x1B {
                flushPartial()
                escape = [byte]
                continue
            }
            consumeTextByte(byte, into: &keys)
        }
        return keys
    }

    /// The Escape the decoder was holding, if the loop waited long enough to be sure no
    /// sequence is coming. Empty when there was nothing pending.
    mutating func flushPendingEscape() -> [Key] {
        guard escape == [0x1B] else { return [] }
        escape.removeAll()
        return [.escape]
    }

    // MARK: - Escape sequences

    private mutating func consumeEscapeByte(_ byte: UInt8, into keys: inout [Key]) {
        // ESC alone so far. What comes next says whether this was a key or a sequence.
        if escape.count == 1 {
            switch byte {
            case 0x5B, 0x4F:            // CSI "[" and SS3 "O"
                escape.append(byte)
            case 0x1B:                  // a second Esc: the first one was a key
                keys.append(.escape)
            default:                    // Esc then something ordinary: both are keys
                escape.removeAll()
                keys.append(.escape)
                consumeTextByte(byte, into: &keys)
            }
            return
        }

        escape.append(byte)

        // SS3 is one byte of payload; CSI runs until a byte in the final range.
        let isSS3 = escape[1] == 0x4F
        let isFinal = isSS3 || (0x40...0x7E).contains(byte)
        guard isFinal else {
            // A sequence that never terminates would grow without bound; nothing real
            // sends more than a handful of parameter bytes.
            if escape.count > 32 { escape.removeAll() }
            return
        }

        if let key = Self.key(forSequence: escape) {
            keys.append(key)
        }
        escape.removeAll()
    }

    /// The key a finished escape sequence means, or nil for one kbbs does not use —
    /// swallowed whole, so its parameter bytes never reach the number buffer as digits.
    private static func key(forSequence sequence: [UInt8]) -> Key? {
        guard sequence.count >= 3 else { return nil }
        let final = sequence[sequence.count - 1]
        let parameters = Array(sequence[2..<(sequence.count - 1)])

        switch final {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        case 0x7E:
            switch parameters {
            case [0x31], [0x37]: return .home        // 1~ and 7~
            case [0x34], [0x38]: return .end         // 4~ and 8~
            case [0x35]: return .pageUp              // 5~
            case [0x36]: return .pageDown            // 6~
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Text and control bytes

    private mutating func consumeTextByte(_ byte: UInt8, into keys: inout [Key]) {
        if partial.isEmpty, let key = Self.controlKey(for: byte) {
            keys.append(key)
            return
        }

        if partial.isEmpty {
            guard byte >= 0x20 else { return }          // an unmapped C0 byte is noise
            if byte < 0x80 {
                keys.append(.char(Character(UnicodeScalar(byte))))
                return
            }
            guard Self.sequenceLength(leading: byte) != nil else { return }
            partial = [byte]
            return
        }

        // Mid-sequence. Anything that is not a continuation byte means the sequence was
        // truncated; drop it and let this byte start over rather than swallowing it.
        guard byte & 0xC0 == 0x80 else {
            partial.removeAll()
            consumeTextByte(byte, into: &keys)
            return
        }

        partial.append(byte)
        guard let expected = Self.sequenceLength(leading: partial[0]), partial.count >= expected else {
            return
        }

        if let text = String(bytes: partial, encoding: .utf8), let character = text.first {
            keys.append(.char(character))
        }
        partial.removeAll()
    }

    private mutating func flushPartial() {
        partial.removeAll()
    }

    private static func controlKey(for byte: UInt8) -> Key? {
        switch byte {
        case 0x0D, 0x0A: return .enter
        case 0x7F, 0x08: return .backspace
        case 0x09: return .tab
        case 0x01...0x07, 0x0B...0x0C, 0x0E...0x1A:
            return .control(Character(UnicodeScalar(byte + 0x60)))
        default: return nil
        }
    }

    private static func sequenceLength(leading byte: UInt8) -> Int? {
        switch byte {
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }
}
