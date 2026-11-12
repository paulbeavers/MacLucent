import AppKit

/// Anything that can live inside a tiled window.
///
/// Adding an app = one file with a `TileApp` class + one `AppDescriptor` in `AppRegistry`.
/// The launcher, keyboard shortcut, help sheet, File menu, Stats counts and session restore
/// all come from the descriptor; no other framework code needs to change.
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
    /// ⌘W: return true if the app handled it itself (e.g. closed a browser tab) and the
    /// tile should stay open.
    func requestClose() -> Bool
    /// What to save for session restore (handed back to the descriptor's `restore`).
    /// Return nil to leave this window out of the session.
    var sessionState: JSONValue? { get }
}

extension TileApp {
    func handleKey(_ event: NSEvent) -> Bool { false }
    var hasUnsavedState: Bool { false }
    func requestClose() -> Bool { false }
    var sessionState: JSONValue? { .object([:]) } // restorable, no state needed
}

/// A shortcut key for launching an app; the modifier is Lucent's (⌘ or ⌥, see Settings).
struct AppShortcut {
    let character: String?
    let keyCodes: [UInt16]
    /// How it's shown, without the modifier, e.g. "B" or "↩".
    let label: String

    static func key(_ c: Character) -> AppShortcut {
        AppShortcut(character: String(c).lowercased(), keyCodes: [], label: String(c).uppercased())
    }
    static let returnKey = AppShortcut(character: nil, keyCodes: [36, 76], label: "↩")

    func matches(_ e: NSEvent) -> Bool {
        if keyCodes.contains(e.keyCode) { return true }
        guard let character else { return false }
        return e.charactersIgnoringModifiers?.lowercased() == character
    }

    /// For NSMenuItem.keyEquivalent.
    var keyEquivalent: String { character ?? (keyCodes.contains(36) ? "\r" : "") }
}

/// Describes an app that can be launched from the launcher / keybindings.
@MainActor
struct AppDescriptor {
    let id: String
    let name: String
    let symbolName: String
    /// Launch shortcut (with the Lucent modifier). Must not clash with the window-manager
    /// bindings: D W F J / Tab, digits and arrows.
    var shortcut: AppShortcut? = nil
    /// Only one window of this app may exist; launching again focuses it.
    var singleInstance = false
    /// Creates the app for a fresh launch. Nil for entries that only run `action`.
    var make: (@MainActor (WindowManager) -> TileApp)? = nil
    /// Recreates the app from its `sessionState`. Defaults to `make`.
    var restore: (@MainActor (WindowManager, JSONValue) -> TileApp)? = nil
    /// For launcher entries that don't create a tile directly.
    var action: (@MainActor (WindowManager) -> Void)? = nil

    /// The shortcut as displayed, e.g. "⌘B" (or "⌥B" with the Option modifier).
    var shortcutLabel: String { shortcut.map { Config.shared.modSymbol + $0.label } ?? "" }

    func restoreApp(_ wm: WindowManager, _ state: JSONValue) -> TileApp? {
        if let restore { return restore(wm, state) }
        return make?(wm)
    }
}

@MainActor
enum AppRegistry {
    static var apps: [AppDescriptor] = [
        AppDescriptor(id: "terminal", name: "Terminal", symbolName: "terminal", shortcut: .returnKey,
                      make: { wm in TerminalApp(directory: wm.focusedTerminalDirectory) },
                      restore: { _, s in TerminalApp(directory: s["directory"]?.string) }),
        AppDescriptor(id: "browser", name: "Browser", symbolName: "globe", shortcut: .key("B"),
                      make: { wm in BrowserApp(manager: wm) },
                      restore: { wm, s in
                          BrowserApp(manager: wm, urls: s["tabs"]?.array?.compactMap(\.string) ?? [],
                                     activeTab: s["activeTab"]?.int ?? 0)
                      }),
        AppDescriptor(id: "settings", name: "Settings", symbolName: "gearshape", shortcut: .key(","), singleInstance: true,
                      make: { _ in SettingsApp() }),
        AppDescriptor(id: "stats", name: "Stats", symbolName: "chart.xyaxis.line", shortcut: .key("I"), singleInstance: true,
                      make: { wm in StatsApp(manager: wm) }),
        AppDescriptor(id: "scratchpad", name: "Scratchpad", symbolName: "note.text", shortcut: .key("N"), singleInstance: true,
                      make: { _ in ScratchpadApp() },
                      restore: { _, s in ScratchpadApp(noteID: s["note"]?.string) }),
        AppDescriptor(id: "ports", name: "Ports", symbolName: "network", shortcut: .key("P"), singleInstance: true,
                      make: { wm in PortsApp(manager: wm) }),
        AppDescriptor(id: "machines", name: "Machines", symbolName: "server.rack", shortcut: .key("M"), singleInstance: true,
                      make: { wm in MachinesApp(manager: wm) }),
        AppDescriptor(id: "themes", name: "Themes…", symbolName: "paintpalette",
                      action: { wm in wm.showThemePicker() }),
    ]

    static func app(_ id: String?) -> AppDescriptor? { id.flatMap { id in apps.first { $0.id == id } } }
}

/// A small JSON value, used for apps' session state.
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var int: Int? { if case .number(let v) = self { return Int(v) }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
}
