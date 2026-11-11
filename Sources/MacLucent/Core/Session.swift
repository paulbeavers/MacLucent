import AppKit

/// Saved workspaces, layouts and window contents (~/.config/mac-lucent/session.json).
struct SessionFile: Codable {
    var version = 1
    var currentWorkspace: Int
    var workspaces: [WorkspaceState]

    struct WorkspaceState: Codable {
        var index: Int
        var windows: [WindowState]
        /// Tiling tree; leaves refer to `windows` by position.
        var layout: Node?
        /// Index into `windows` of the focused window.
        var focused: Int?
    }

    struct WindowState: Codable {
        var kind: String              // "terminal", "browser", "settings", "stats"
        var directory: String?        // terminal
        var tabs: [String]?           // browser
        var activeTab: Int?           // browser
        var floatFrame: [Double]?     // x, y, width, height (workspace coordinates)
    }

    indirect enum Node: Codable {
        case window(Int)
        case split(stacked: Bool, ratio: Double, first: Node, second: Node)
    }

    static var url: URL {
        // Test runs point this elsewhere so they never touch the real session.
        if let path = ProcessInfo.processInfo.environment["ML_SESSION_FILE"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/mac-lucent/session.json")
    }
}

extension WindowManager {
    /// Session handling is skipped for scripted test runs so they never touch the user's session.
    static var sessionEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        let args = CommandLine.arguments
        if env["ML_SESSION_FILE"] != nil { return Config.shared.restoreSession } // explicit test file
        return Config.shared.restoreSession && env["ML_BACKGROUND"] == nil && env["ML_NO_SESSION"] == nil
            && !args.contains("--snapshot") && !args.contains("--bench-typing")
    }

    // MARK: Saving

    func sessionSnapshot() -> SessionFile {
        var states: [SessionFile.WorkspaceState] = []
        for ws in workspaces where !ws.isEmpty {
            let windows = ws.windows
            let saved = windows.map(windowState)
            // Drop windows we can't recreate (e.g. future app types) from the layout.
            func node(_ n: LayoutNode?) -> SessionFile.Node? {
                guard let n else { return nil }
                if let w = n.window {
                    guard let i = windows.firstIndex(where: { $0 === w }), saved[i] != nil else { return nil }
                    return .window(i)
                }
                let a = node(n.first), b = node(n.second)
                switch (a, b) {
                case let (a?, b?): return .split(stacked: n.stacked, ratio: Double(n.ratio), first: a, second: b)
                case let (a?, nil): return a
                case let (nil, b?): return b
                default: return nil
                }
            }
            guard let layout = node(ws.tree.root) else { continue }
            states.append(.init(index: ws.index,
                                windows: saved.map { $0 ?? .init(kind: "none") },
                                layout: layout,
                                focused: ws.focused.flatMap { f in windows.firstIndex { $0 === f } }))
        }
        return SessionFile(currentWorkspace: current.index, workspaces: states)
    }

    private func windowState(_ w: TileWindow) -> SessionFile.WindowState? {
        var s: SessionFile.WindowState
        switch w.app {
        case let t as TerminalApp:
            s = .init(kind: "terminal", directory: t.currentDirectory)
        case let b as BrowserApp:
            let urls = b.tabs.map { $0.displayURL?.absoluteString ?? "" }
            s = .init(kind: "browser", tabs: urls, activeTab: b.activeIndex)
        case is SettingsApp:
            s = .init(kind: "settings")
        case is StatsApp:
            s = .init(kind: "stats")
        default:
            return nil
        }
        if let f = w.floatFrame { s.floatFrame = [f.minX, f.minY, f.width, f.height] }
        return s
    }

    func saveSession() {
        guard Self.sessionEnabled else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(sessionSnapshot()) else { return }
        try? FileManager.default.createDirectory(at: SessionFile.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: SessionFile.url, options: .atomic)
    }

    // MARK: Restoring

    /// Rebuild the saved session. Returns false if there was nothing to restore.
    @discardableResult
    func restoreSession() -> Bool {
        guard Self.sessionEnabled,
              let data = try? Data(contentsOf: SessionFile.url),
              let session = try? JSONDecoder().decode(SessionFile.self, from: data) else { return false }
        var restoredAny = false
        for state in session.workspaces {
            guard let ws = workspaces.first(where: { $0.index == state.index }), ws.isEmpty, let layout = state.layout else { continue }
            var tiles: [Int: TileWindow] = [:]
            for (i, ws_) in state.windows.enumerated() {
                guard let (app, id) = makeApp(ws_) else { continue }
                let tile = adoptRestoredTile(app, appID: id, in: ws)
                if let f = ws_.floatFrame, f.count == 4 { tile.floatFrame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3]) }
                tiles[i] = tile
            }
            func build(_ n: SessionFile.Node) -> LayoutNode? {
                switch n {
                case .window(let i):
                    return tiles[i].map { LayoutNode(window: $0) }
                case let .split(stacked, ratio, first, second):
                    let a = build(first), b = build(second)
                    guard let a, let b else { return a ?? b }
                    let node = LayoutNode()
                    node.stacked = stacked
                    node.ratio = CGFloat(min(0.9, max(0.1, ratio)))
                    node.first = a
                    node.second = b
                    a.parent = node
                    b.parent = node
                    return node
                }
            }
            guard let root = build(layout) else { continue }
            ws.tree.setRoot(root)
            let focused = state.focused.flatMap { tiles[$0] } ?? ws.windows.first
            if let focused { ws.noteFocused(focused) }
            restoredAny = true
        }
        guard restoredAny else { return false }
        finishRestore(currentWorkspace: session.currentWorkspace)
        return true
    }

    private func makeApp(_ s: SessionFile.WindowState) -> (TileApp, String)? {
        switch s.kind {
        case "terminal":
            return (TerminalApp(directory: s.directory), "terminal")
        case "browser":
            let urls = (s.tabs ?? []).filter { !$0.isEmpty }
            return (BrowserApp(manager: self, urls: urls, activeTab: s.activeTab ?? 0), "browser")
        case "settings":
            return (SettingsApp(), "settings")
        case "stats":
            return (StatsApp(manager: self), "stats")
        default:
            return nil
        }
    }
}
