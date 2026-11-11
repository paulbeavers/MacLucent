import Foundation

/// Works around SwiftTerm 1.10.1 escape-sequence handling bugs by rewriting PTY output before
/// it reaches the terminal emulator.
///
/// SwiftTerm 1.10.1 treats every `CSI … u` as "restore cursor" (SCORC), ignoring the private
/// prefix. Programs that probe or use the kitty keyboard protocol — `CSI ? u` (query),
/// `CSI > flags u` (push), `CSI < u` (pop), `CSI = flags ; mode u` (set), e.g. Claude Code and
/// other modern TUIs — therefore make the cursor jump to a stale saved position, and their
/// next relative redraw lands in the wrong place. We don't implement that protocol, so those
/// sequences are dropped; without a reply, programs fall back to legacy key encoding.
struct TerminalOutputFilter {
    /// Bytes of a possibly-incomplete escape sequence held back from the previous chunk.
    private var pending: [UInt8] = []
    private static let maxPending = 64

    private static let esc: UInt8 = 0x1B
    private static let lbracket: UInt8 = 0x5B // [

    mutating func filter(_ input: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        // Fast path: nothing held back and no ESC in this chunk.
        if pending.isEmpty && !input.contains(Self.esc) { return input }

        let bytes = pending + input
        pending.removeAll(keepingCapacity: true)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            guard b == Self.esc else { out.append(b); i += 1; continue }
            switch Self.scanKittyKeyboardSequence(bytes, from: i) {
            case .match(let end):
                i = end // drop it
            case .incomplete:
                if n - i <= Self.maxPending {
                    pending.append(contentsOf: bytes[i...])
                    return out[...]
                }
                out.append(b); i += 1
            case .noMatch:
                out.append(b); i += 1
            }
        }
        return out[...]
    }

    private enum Scan { case match(end: Int), incomplete, noMatch }

    /// Recognizes `ESC [ (?|>|<|=) [0-9;:]* u` starting at `start`.
    private static func scanKittyKeyboardSequence(_ b: [UInt8], from start: Int) -> Scan {
        var i = start + 1
        guard i < b.count else { return .incomplete }
        guard b[i] == lbracket else { return .noMatch }
        i += 1
        guard i < b.count else { return .incomplete }
        switch b[i] {
        case UInt8(ascii: "?"), UInt8(ascii: ">"), UInt8(ascii: "<"), UInt8(ascii: "="): break
        default: return .noMatch
        }
        i += 1
        while i < b.count {
            let c = b[i]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: ";") || c == UInt8(ascii: ":") { i += 1; continue }
            return c == UInt8(ascii: "u") ? .match(end: i + 1) : .noMatch
        }
        return .incomplete
    }
}
