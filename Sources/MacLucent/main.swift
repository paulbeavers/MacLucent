import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
    // Used by scripts/build-app.sh to produce the .icns.
    MainActor.assumeIsolated { AppIcon.writePNG(to: args[i + 1], size: 1024) }
    exit(0)
}

// Lucent restores its own session (Session.swift). macOS's window restoration only gets in the way:
// after a crash it blocks the next launch with a modal "reopen windows?" prompt.
UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
