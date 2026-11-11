import AppKit
import SwiftTerm

/// Terminal view with a hook for incoming shell output (used by the latency probe).
final class LucentTerminalView: LocalProcessTerminalView {
    var onData: (() -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onData?()
    }
}

/// Debug aid: with `ML_LATENCY_LOG=1` (or `--bench-typing`), measures every key press in a terminal:
///  - deliver: hardware key event → app receives it
///  - echo:    app receives it → shell output arrives from the PTY
///  - drawn:   app receives it → the main run loop has drawn and committed that output
/// Lines go to ~/Library/Logs/mac-lucent/latency.log.
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
        let dir = NSHomeDirectory() + "/Library/Logs/mac-lucent"
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
