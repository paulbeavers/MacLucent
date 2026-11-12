import AppKit
import SwiftTerm

/// Terminal view that filters PTY output (see `TerminalOutputFilter`) and exposes an output hook.
final class LucentTerminalView: LocalProcessTerminalView {
    var onData: (() -> Void)?
    private var outputFilter = TerminalOutputFilter()
    /// Debug aid: `ML_PTY_LOG=<file>` records the raw shell output.
    static let ptyLog: FileHandle? = ProcessInfo.processInfo.environment["ML_PTY_LOG"].flatMap { p in
        FileManager.default.createFile(atPath: p, contents: nil); return FileHandle(forWritingAtPath: p) }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        Self.ptyLog?.write(Data(slice))
        if outputFilter.onWindowOp == nil {
            outputFilter.onWindowOp = { [weak self] params in
                MainActor.assumeIsolated { self?.answerWindowOp(params) }
            }
        }
        let filtered = outputFilter.filter(slice)
        if !filtered.isEmpty { super.dataReceived(slice: filtered) }
        onData?()
    }

    /// Answer XTWINOPS size queries ourselves (SwiftTerm 1.10.1 crashes on window operations —
    /// see TerminalOutputFilter). Everything else (move/resize/iconify, title stack) is ignored.
    private func answerWindowOp(_ p: [Int]) {
        let t = getTerminal()
        let scale = window?.backingScaleFactor ?? 2
        let cellW = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cellH = ceil(font.ascender - font.descender + font.leading)
        let cw = Int((cellW * scale).rounded()), ch = Int((cellH * scale).rounded())
        let esc = "\u{1B}["
        switch p.first ?? 0 {
        case 14: send(txt: "\(esc)4;\(ch * t.rows);\(cw * t.cols)t")        // text area, pixels
        case 15:
            let s = (window?.screen ?? NSScreen.main)?.frame.size ?? .zero
            send(txt: "\(esc)5;\(Int(s.height * scale));\(Int(s.width * scale))t") // screen, pixels
        case 16: send(txt: "\(esc)6;\(ch);\(cw)t")                          // cell size, pixels
        case 18: send(txt: "\(esc)8;\(t.rows);\(t.cols)t")                  // text area, characters
        case 19: send(txt: "\(esc)9;\(t.rows);\(t.cols)t")                  // screen, characters
        case 20: send(txt: "\u{1B}]L\u{1B}\\")                              // icon label (empty, by design)
        case 21: send(txt: "\u{1B}]l\u{1B}\\")                              // title (empty, by design)
        default: break
        }
    }
}

/// Debug aid: with `ML_LATENCY_LOG=1` (or `--bench-typing`), measures every key press in a terminal:
///  - deliver: hardware key event → app receives it
///  - echo:    app receives it → shell output arrives from the PTY
///  - drawn:   app receives it → the main run loop has drawn and committed that output
/// Lines go to ~/Library/Logs/Lucent/latency.log.
@MainActor
enum LatencyProbe {
    static var enabled = ProcessInfo.processInfo.environment["ML_LATENCY_LOG"] != nil
    private(set) static var samples: [(deliver: Double, echo: Double, drawn: Double)] = []

    private static var keyAt: Double = 0
    private static var deliver: Double = 0
    private static var chars = ""
    private static var echoAt: Double = 0
    private static var hooked = Set<ObjectIdentifier>()
    private static var observer: CFRunLoopObserver?
    private static let handle: FileHandle? = {
        let dir = NSHomeDirectory() + "/Library/Logs/Lucent"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/latency.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    static func keyReceived(_ e: NSEvent, terminal: LucentTerminalView?) {
        guard let terminal else { return }
        installObserver()
        if hooked.insert(ObjectIdentifier(terminal)).inserted {
            terminal.onData = {
                MainActor.assumeIsolated {
                    if keyAt > 0 && echoAt == 0 { echoAt = now }
                }
            }
        }
        flush(drawn: -1) // previous key never produced output
        keyAt = now
        deliver = (keyAt - e.timestamp) * 1000
        chars = (e.charactersIgnoringModifiers ?? "?").debugDescription
        echoAt = 0
    }

    /// Runs after Core Animation's commit in each run-loop pass: by then any output received
    /// earlier in the pass has been drawn and handed to the window server.
    private static func installObserver() {
        guard observer == nil else { return }
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000) { _, _ in
            MainActor.assumeIsolated {
                if keyAt > 0 && echoAt > 0 { flush(drawn: (now - keyAt) * 1000) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
    }

    private static func flush(drawn: Double) {
        guard keyAt > 0 else { return }
        let echo = echoAt > 0 ? (echoAt - keyAt) * 1000 : -1
        samples.append((deliver, echo, drawn))
        let line = String(format: "key=%@ deliver=%.1fms echo=%.1fms drawn=%.1fms\n", chars, deliver, echo, drawn)
        handle?.write(line.data(using: .utf8)!)
        keyAt = 0
        echoAt = 0
    }
}
