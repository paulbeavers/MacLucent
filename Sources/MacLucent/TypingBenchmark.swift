import AppKit

/// Debug aid (`--bench-typing`): sends synthetic keystrokes through NSApp.sendEvent into the
/// focused terminal and reports LatencyProbe statistics. `ML_BENCH_INTERVAL` sets the gap (s).
@MainActor
enum TypingBenchmark {
    static func run(window: NSWindow) {
        LatencyProbe.enabled = true
        let interval = Double(ProcessInfo.processInfo.environment["ML_BENCH_INTERVAL"] ?? "0.15") ?? 0.15
        var n = 0
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                n += 1
                guard n <= 40 else {
                    timer.invalidate()
                    func stats(_ a: [Double]) -> String {
                        let s = a.filter { $0 >= 0 }.sorted()
                        guard !s.isEmpty else { return "none" }
                        return String(format: "n=%d median=%.2fms p90=%.2fms max=%.2fms", s.count, s[s.count / 2], s[s.count * 9 / 10], s.last!)
                    }
                    let samples = LatencyProbe.samples
                    print("key -> echo :", stats(samples.map { $0.echo }))
                    print("key -> drawn:", stats(samples.map { $0.drawn }))
                    NSApp.terminate(nil)
                    return
                }
                let t = ProcessInfo.processInfo.systemUptime
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: t,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: "x", charactersIgnoringModifiers: "x",
                                              isARepeat: false, keyCode: 7)!
                    NSApp.sendEvent(ev)
                }
            }
        }
    }
}
