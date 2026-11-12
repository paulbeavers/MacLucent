import Foundation

/// Works around SwiftTerm 1.10.1 escape-sequence handling bugs by rewriting PTY output before
/// it reaches the terminal emulator.
///
/// 1. SwiftTerm 1.10.1 treats every `CSI … u` as "restore cursor" (SCORC), ignoring the private
///    prefix. Programs that probe or use the kitty keyboard protocol — `CSI ? u` (query),
///    `CSI > flags u` (push), `CSI < u` (pop), `CSI = flags ; mode u` (set), e.g. Claude Code and
///    other modern TUIs — therefore make the cursor jump to a stale saved position, and their
///    next relative redraw lands in the wrong place. We don't implement that protocol, so those
///    sequences are dropped; without a reply, programs fall back to legacy key encoding.
///
/// 2. Window operations, `CSI Ps ; … t` (XTWINOPS), crash SwiftTerm 1.10.1 as built here: its
///    `windowCommand` hits "unexpected enum case" and traps — Neovim sends these at startup.
///    They never reach SwiftTerm: they're handed to `onWindowOp`, which answers the size queries
///    programs actually use; the rest (move/resize/iconify the window, title stack) are ignored,
///    as Lucent ignored them anyway.
struct TerminalOutputFilter {
    /// Called with the parameters of each `CSI … t` removed from the stream.
    var onWindowOp: (([Int]) -> Void)?

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
            switch Self.scan(bytes, from: i) {
            case .drop(let end):
                i = end
            case .windowOp(let end, let params):
                onWindowOp?(params)
                i = end
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

    private enum Scan { case drop(end: Int), windowOp(end: Int, params: [Int]), incomplete, noMatch }

    /// Recognizes, starting at `start`:
    /// - `ESC [ (?|>|<|=) [0-9;:]* u` → drop (kitty keyboard protocol)
    /// - `ESC [ [0-9;]* t`            → window operation
    private static func scan(_ b: [UInt8], from start: Int) -> Scan {
        var i = start + 1
        guard i < b.count else { return .incomplete }
        guard b[i] == lbracket else { return .noMatch }
        i += 1
        guard i < b.count else { return .incomplete }
        var prefix: UInt8?
        switch b[i] {
        case UInt8(ascii: "?"), UInt8(ascii: ">"), UInt8(ascii: "<"), UInt8(ascii: "="):
            prefix = b[i]
            i += 1
        default:
            break
        }
        let paramsStart = i
        while i < b.count {
            let c = b[i]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: ";") || c == UInt8(ascii: ":") { i += 1; continue }
            if c == UInt8(ascii: "u"), prefix != nil { return .drop(end: i + 1) }
            if c == UInt8(ascii: "t"), prefix == nil {
                let text = String(decoding: b[paramsStart..<i], as: UTF8.self)
                let params = text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                return .windowOp(end: i + 1, params: params)
            }
            return .noMatch
        }
        return .incomplete
    }
}
