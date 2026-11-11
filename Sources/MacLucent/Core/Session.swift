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
        var kind: String              // the app's AppRegistry id
        var state: JSONValue?         // the app's `sessionState`
        var floatFrame: [Double]?     // x, y, width, height (workspace coordinates)
        // Format before apps saved their own state (read-only, for older session files).
        var directory: String?
        var tabs: [String]?
        var activeTab: Int?

        /// `state`, or the equivalent built from the old per-app fields.
        var resolvedState: JSONValue {
            if let state { return state }
            var o: [String: JSONValue] = [:]
            if let directory { o["directory"] = .string(directory) }
            if let tabs { o["tabs"] = .array(tabs.map { .string($0) }) }
            if let activeTab { o["activeTab"] = .number(Double(activeTab)) }
            return .object(o)
        }
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

    /// Only windows launched from the registry, whose app agrees to be saved, are saved.
    private func windowState(_ w: TileWindow) -> SessionFile.WindowState? {
        guard let id = w.appID, AppRegistry.app(id) != nil, let state = w.app.sessionState else { return nil }
        var s = SessionFile.WindowState(kind: id, state: state)
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
                guard let d = AppRegistry.app(ws_.kind), let app = d.restoreApp(self, ws_.resolvedState) else { continue }
                let tile = adoptRestoredTile(app, appID: d.id, in: ws)
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
}
