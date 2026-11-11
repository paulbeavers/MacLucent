import AppKit

/// Anything that can live inside a tiled window. Terminal and Browser implement this;
/// future apps (Settings, file browser, ...) just need to conform and register in `AppRegistry`.
@MainActor
protocol TileApp: AnyObject {
    /// The root view of the app. It will be resized to fill the window's content area.
    var view: NSView { get }
    var title: String { get }
    /// SF Symbol shown in the bar.
    var symbolName: String { get }
    /// Called by the app when its title changes.
    var onTitleChange: (() -> Void)? { get set }
    /// Called by the app when it wants its window closed (e.g. the shell exited).
    var onRequestClose: (() -> Void)? { get set }

    /// Make the app's main control first responder.
    func focus()
    /// Release resources (kill processes, stop loads). Called once, before removal.
    func shutdown()
    /// App-specific shortcuts. Return true if the event was handled.
    func handleKey(_ event: NSEvent) -> Bool
    /// Whether closing should be confirmed (e.g. a terminal running a foreground job).
    var hasUnsavedState: Bool { get }
}

extension TileApp {
    func handleKey(_ event: NSEvent) -> Bool { false }
    var hasUnsavedState: Bool { false }
}

/// Describes an app that can be launched from the launcher / keybindings.
@MainActor
struct AppDescriptor {
    let id: String
    let name: String
    let symbolName: String
    let shortcut: String
    let make: @MainActor (WindowManager) -> TileApp
}

@MainActor
enum AppRegistry {
    static var apps: [AppDescriptor] = [
        AppDescriptor(id: "terminal", name: "Terminal", symbolName: "terminal", shortcut: "⌘↩") { wm in
            TerminalApp(directory: wm.focusedTerminalDirectory)
        },
        AppDescriptor(id: "browser", name: "Browser", symbolName: "globe", shortcut: "⌘B") { wm in
            BrowserApp(manager: wm)
        },
    ]

    static func app(_ id: String) -> AppDescriptor? { apps.first { $0.id == id } }
}
