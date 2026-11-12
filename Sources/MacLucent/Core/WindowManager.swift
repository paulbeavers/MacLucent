import AppKit
import QuartzCore

/// The compositor: owns workspaces, tiles windows, routes keybindings and focus.
@MainActor
final class WindowManager {
    let desktop: DesktopView
    private(set) var workspaces: [Workspace] = []
    private(set) var current: Workspace
    private var monitors: [Any] = []
    private var closing = Set<ObjectIdentifier>()
    /// An in-progress ⌘-drag (move) or ⌘-right-drag (resize) of a floating window.
    private var mouseDrag: MouseDrag?

    private struct MouseDrag {
        let window: TileWindow
        let resizing: Bool
        let startPoint: CGPoint
        let startFrame: CGRect
        let downEvent: NSEvent
        var moved = false
    }

    private var config: Config { .shared }
    /// Hyprland's default "myBezier" (0.05, 0.9, 0.1, 1.05) – a slight overshoot.
    private let bezier = CAMediaTimingFunction(controlPoints: 0.05, 0.9, 0.1, 1.05)
    private let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    init(desktop: DesktopView) {
        self.desktop = desktop
        for i in 1...Config.shared.workspaceCount {
            workspaces.append(Workspace(index: i))
        }
        current = workspaces[0]
        for ws in workspaces {
            ws.view.isHidden = ws !== current
            ws.mode = Config.shared.floatingWorkspaces.contains(ws.index) ? .floating : .tiled
            ws.view.onLayoutChange = { [weak self, weak ws] in
                guard let self, let ws else { return }
                self.relayout(ws, animated: false)
            }
            ws.view.onFloatingEdgeDrag = { [weak self] w in
                guard let self, w !== self.current.focused else { return }
                self.focus(w)
            }
            desktop.stage.addSubview(ws.view)
        }
        desktop.onStageResize = { [weak self] in self?.stageDidResize() }
        desktop.bar.onWorkspaceClick = { [weak self] i in self?.switchTo(i) }
        installMonitors()
        NotificationCenter.default.addObserver(forName: .configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.desktop.needsLayout = true
                let modeChanged = self.syncModesFromConfig()
                self.relayout(self.current, animated: modeChanged)
                self.updateBar()
            }
        }
        updateBar()
    }

    // MARK: - Opening and closing

    func launch(_ id: String) {
        guard let d = AppRegistry.app(id) else { return }
        if let action = d.action {
            action(self)
            return
        }
        if d.singleInstance, let existing = allWindows.first(where: { $0.appID == id }) {
            focus(existing)
            return
        }
        guard let make = d.make else { return }
        open(make(self)).appID = id
    }

    /// A window for `app`, wired to the manager (title updates, self-close).
    private func makeTile(_ app: TileApp) -> TileWindow {
        let w = TileWindow(app: app)
        app.onTitleChange = { [weak self] in self?.updateBar() }
        app.onRequestClose = { [weak self, weak w] in
            guard let self, let w else { return }
            self.close(w)
        }
        return w
    }

    /// Session restore: add a tile to `ws` without inserting it into the tiling tree (the
    /// caller rebuilds the tree, then calls `finishRestore`).
    func adoptRestoredTile(_ app: TileApp, appID: String?, in ws: Workspace) -> TileWindow {
        let w = makeTile(app)
        w.appID = appID
        ws.view.addSubview(w)
        return w
    }

    /// Lay out every restored workspace and switch to the saved one.
    func finishRestore(currentWorkspace: Int) {
        desktop.layoutSubtreeIfNeeded()
        for ws in workspaces where !ws.isEmpty {
            ws.view.frame = desktop.stage.bounds
            relayout(ws, animated: false)
            for w in ws.windows { w.isActive = w === ws.focused }
        }
        if currentWorkspace != current.index, workspaces.contains(where: { $0.index == currentWorkspace }) {
            let animations = config.animationsEnabled
            config.animationsEnabled = false
            switchTo(currentWorkspace)
            config.animationsEnabled = animations
        } else if let f = current.focused ?? current.windows.first {
            focus(f)
        }
        updateBar()
    }

    @discardableResult
    func open(_ app: TileApp, on ws: Workspace? = nil) -> TileWindow {
        let ws = ws ?? current
        let w = makeTile(app)
        desktop.layoutSubtreeIfNeeded()
        ws.view.frame = desktop.stage.bounds
        ws.tree.layout(in: ws.view.bounds) // fresh rects so dwindle picks the right split axis
        ws.fullscreen = nil
        ws.tree.insert(w, near: ws.focused)
        ws.view.addSubview(w)
        if ws.mode == .floating { w.floatFrame = defaultFloatFrame(in: ws) }
        relayout(ws, animated: true, appearing: w)
        focus(w)
        return w
    }

    func close(_ w: TileWindow) {
        let id = ObjectIdentifier(w)
        guard !closing.contains(id), let ws = workspace(of: w) else { return }
        closing.insert(id)
        w.app.shutdown()
        ws.tree.remove(w)
        ws.forget(w)

        let finish = { [weak self] in
            w.removeFromSuperview()
            self?.closing.remove(id)
        }
        if config.animationsEnabled && ws === current {
            let f = w.frame
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = config.animationDuration * 0.7
                ctx.timingFunction = easeOut
                w.animator().alphaValue = 0
                w.animator().frame = f.insetBy(dx: f.width * 0.08, dy: f.height * 0.08)
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
        } else {
            finish()
        }

        relayout(ws, animated: true)
        if let next = ws.history.last ?? ws.windows.last {
            focus(next)
        } else {
            desktop.window?.makeFirstResponder(desktop)
            updateBar()
        }
    }

    func closeFocused() {
        guard let w = current.focused else { return }
        if w.app.requestClose() { return } // e.g. the browser closed a tab
        close(w)
    }

    var allWindows: [TileWindow] { workspaces.flatMap { $0.windows } }

    func workspace(of w: TileWindow) -> Workspace? {
        workspaces.first { ws in ws.windows.contains { $0 === w } }
    }

    var focusedTerminalDirectory: String? {
        (current.focused?.app as? TerminalApp)?.currentDirectory
    }

    // MARK: - Focus

    /// `raise: false` lets focus-follows-mouse focus without reshuffling floating windows
    /// (when "Raise on hover" is off).
    func focus(_ w: TileWindow, raise: Bool = true) {
        guard let ws = workspace(of: w) else { return }
        if ws !== current { switchTo(ws.index) }
        if raise, ws.mode == .floating, ws.fullscreen == nil, ws.view.subviews.last !== w {
            ws.view.addSubview(w, positioned: .above, relativeTo: nil) // raise
            ws.view.window?.invalidateCursorRects(for: ws.view)
        }
        for other in ws.windows { other.isActive = other === w }
        ws.noteFocused(w)
        w.app.focus()
        updateBar()
    }

    func focus(_ d: Direction) {
        guard let w = current.focused else {
            if let first = current.windows.first { focus(first) }
            return
        }
        if current.fullscreen != nil { return }
        if current.mode == .floating {
            let others = current.windows.filter { $0 !== w && !$0.isHidden }.map { ($0, $0.frame) }
            if let n = LayoutTree.nearest(from: w.frame, among: others, d, overlapping: true) { focus(n) }
            return
        }
        if let n = current.tree.neighbor(of: w, d) { focus(n) }
    }

    /// Tiled: swap with the neighbour. Floating: move the window.
    func swap(_ d: Direction) {
        guard let w = current.focused, current.fullscreen == nil else { return }
        if current.mode == .floating {
            nudgeFloating(w, move: d)
            return
        }
        guard let n = current.tree.neighbor(of: w, d) else { return }
        current.tree.swap(w, n)
        relayout(current, animated: true)
    }

    /// Tiled: move the split. Floating: grow/shrink the window from its right/bottom edge.
    func resize(_ d: Direction) {
        guard let w = current.focused else { return }
        if current.mode == .floating {
            nudgeFloating(w, resize: d)
            return
        }
        current.tree.resize(w, direction: d)
        relayout(current, animated: true)
    }

    private static let nudge: CGFloat = 40

    private func nudgeFloating(_ w: TileWindow, move d: Direction? = nil, resize r: Direction? = nil) {
        var f = w.floatFrame ?? w.frame
        let n = Self.nudge
        switch d {
        case .left?: f.origin.x -= n
        case .right?: f.origin.x += n
        case .up?: f.origin.y -= n
        case .down?: f.origin.y += n
        case nil: break
        }
        let min = TileWindow.minFloatingSize
        switch r {
        case .left?: f.size.width = max(min.width, f.width - n)
        case .right?: f.size.width += n
        case .up?: f.size.height = max(min.height, f.height - n)
        case .down?: f.size.height += n
        case nil: break
        }
        w.floatFrame = clampFloating(f, in: current.view.bounds)
        relayout(current, animated: true)
    }

    func toggleSplit() {
        guard let w = current.focused, current.mode == .tiled else { return }
        current.tree.toggleSplit(of: w)
        relayout(current, animated: true)
    }

    func toggleFullscreen() {
        guard let w = current.focused else { return }
        current.fullscreen = current.fullscreen === w ? nil : w
        relayout(current, animated: true)
        updateBar()
    }

    // MARK: - Workspaces

    func switchTo(_ index: Int) {
        guard let target = workspaces.first(where: { $0.index == index }), target !== current else { return }
        let old = current
        current = target
        let bounds = desktop.stage.bounds
        let dir: CGFloat = target.index > old.index ? 1 : -1

        target.view.frame = bounds
        relayout(target, animated: false)
        target.view.isHidden = false

        if config.animationsEnabled {
            target.view.frame = bounds.offsetBy(dx: dir * bounds.width, dy: 0)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = config.workspaceAnimationDuration
                ctx.timingFunction = easeOut
                old.view.animator().frame = bounds.offsetBy(dx: -dir * bounds.width, dy: 0)
                target.view.animator().frame = bounds
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if old !== self.current { old.view.isHidden = true }
                    old.view.frame = bounds
                }
            })
        } else {
            old.view.isHidden = true
        }

        if let f = target.focused ?? target.windows.first {
            focus(f)
        } else {
            desktop.window?.makeFirstResponder(desktop)
        }
        updateBar()
    }

    /// Switch the current workspace between tiled and floating (persisted in settings).
    func toggleFloating() {
        if config.floatingWorkspaces.contains(current.index) {
            config.floatingWorkspaces.remove(current.index)
        } else {
            config.floatingWorkspaces.insert(current.index)
        }
        config.save()
        config.notifyChanged() // syncModesFromConfig applies it, animated
    }

    /// Apply `Config.floatingWorkspaces`. Returns true if the current workspace changed mode.
    @discardableResult
    private func syncModesFromConfig() -> Bool {
        var currentChanged = false
        for ws in workspaces {
            let mode: LayoutMode = config.floatingWorkspaces.contains(ws.index) ? .floating : .tiled
            guard mode != ws.mode else { continue }
            if mode == .floating {
                // Windows that have never floated start where they are tiled now.
                ws.tree.layout(in: ws.view.bounds)
                for w in ws.windows where w.floatFrame == nil {
                    w.floatFrame = ws.tree.rect(for: w) ?? defaultFloatFrame(in: ws)
                }
            }
            ws.mode = mode
            if ws === current { currentChanged = true } else { relayout(ws, animated: false) }
        }
        return currentChanged
    }

    /// Mod+Tab: step through the workspaces that have windows (plus the current one), wrapping.
    func cycleWorkspaces(_ delta: Int) {
        let candidates = workspaces.filter { !$0.isEmpty || $0 === current }
        guard candidates.count > 1, let i = candidates.firstIndex(where: { $0 === current }) else { return }
        switchTo(candidates[(i + delta + candidates.count) % candidates.count].index)
    }

    func switchRelative(_ delta: Int) {
        let n = current.index + delta
        if n >= 1 && n <= workspaces.count { switchTo(n) }
    }

    func moveFocused(to index: Int) {
        guard let w = current.focused,
              let target = workspaces.first(where: { $0.index == index }), target !== current else { return }
        let src = current
        src.tree.remove(w)
        src.forget(w)
        w.removeFromSuperview()
        w.isActive = false
        target.fullscreen = nil
        target.tree.insert(w, near: target.focused)
        target.view.addSubview(w)
        target.noteFocused(w)
        target.view.frame = desktop.stage.bounds
        if target.mode == .floating, w.floatFrame == nil { w.floatFrame = defaultFloatFrame(in: target) }
        relayout(target, animated: false)
        relayout(src, animated: true)
        if let next = src.history.last ?? src.windows.last {
            focus(next)
        } else {
            desktop.window?.makeFirstResponder(desktop)
            updateBar()
        }
    }

    // MARK: - Layout

    private func stageDidResize() {
        for ws in workspaces {
            ws.view.frame = desktop.stage.bounds
            for w in ws.windows {
                if let f = w.floatFrame { w.floatFrame = clampFloating(f, in: ws.view.bounds) }
            }
            relayout(ws, animated: false)
        }
    }

    /// Centered, ~60% of the stage, cascading for each additional floating window.
    private func defaultFloatFrame(in ws: Workspace) -> CGRect {
        let b = ws.view.bounds
        let w = min(max(b.width * 0.55, 480), 1100, b.width - 2 * config.gapsOut)
        let h = min(max(b.height * 0.6, 320), 760, b.height - 2 * config.gapsOut)
        let n = CGFloat(ws.windows.filter { $0.floatFrame != nil }.count % 8)
        let f = CGRect(x: (b.width - w) / 2 - 84 + n * 28, y: (b.height - h) / 2 - 84 + n * 28, width: w, height: h)
        return clampFloating(f.integral, in: b)
    }

    /// Keep a floating window at least partly on screen and above its minimum size.
    private func clampFloating(_ f: CGRect, in b: CGRect) -> CGRect {
        var r = f
        r.size.width = max(TileWindow.minFloatingSize.width, min(r.width, b.width))
        r.size.height = max(TileWindow.minFloatingSize.height, min(r.height, b.height))
        let keep: CGFloat = 60
        r.origin.x = min(max(r.minX, b.minX - r.width + keep), b.maxX - keep)
        r.origin.y = min(max(r.minY, b.minY), b.maxY - keep) // never lose the top edge
        return r.integral
    }

    func relayout(_ ws: Workspace, animated: Bool, appearing: TileWindow? = nil) {
        let bounds = ws.view.bounds
        ws.tree.layout(in: bounds)
        let animate = animated && config.animationsEnabled && ws === current && !ws.view.isHidden
        let fullRect = bounds.insetBy(dx: config.gapsOut, dy: config.gapsOut)

        var targets: [(TileWindow, CGRect)] = []
        for w in ws.windows {
            guard var r = ws.tree.rect(for: w) else { continue }
            if ws.mode == .floating {
                if w.floatFrame == nil { w.floatFrame = r }
                r = w.floatFrame!
            }
            if let fs = ws.fullscreen {
                w.isHidden = w !== fs
                if w === fs {
                    r = fullRect
                    ws.view.addSubview(w, positioned: .above, relativeTo: nil)
                }
            } else {
                w.isHidden = false
            }
            targets.append((w, r))
        }

        if animate {
            if let a = appearing, let r = targets.first(where: { $0.0 === a })?.1 {
                a.frame = r.insetBy(dx: r.width * 0.1, dy: r.height * 0.1)
                a.alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = config.animationDuration
                ctx.timingFunction = bezier
                ctx.allowsImplicitAnimation = true
                for (w, r) in targets {
                    w.animator().frame = r
                    w.animator().alphaValue = 1
                }
            }, completionHandler: {
                MainActor.assumeIsolated {
                    for (w, r) in targets where w.superview != nil {
                        if w.frame != r { w.frame = r }
                        w.updateGeometry()
                    }
                }
            })
        } else {
            for (w, r) in targets {
                w.frame = r
                w.alphaValue = 1
            }
        }
        ws.view.updateHint()
        ws.view.window?.invalidateCursorRects(for: ws.view)
    }

    // MARK: - Bar

    func updateBar() {
        let states = workspaces.compactMap { ws -> BarView.WorkspaceState? in
            let visible = ws.index <= config.minVisibleWorkspaces || !ws.isEmpty || ws === current
            return visible ? .init(index: ws.index, occupied: !ws.isEmpty, active: ws === current) : nil
        }
        let app = current.focused?.app
        let mode: String
        if current.fullscreen != nil { mode = "fullscreen" }
        else if current.mode == .floating { mode = "floating" }
        else { mode = "dwindle" }
        desktop.bar.update(workspaces: states,
                           title: app?.title ?? "",
                           symbol: app?.symbolName,
                           mode: "\(mode) · \(current.windows.count)")
        desktop.window?.title = app?.title ?? "Lucent"
    }

    // MARK: - Input

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if LatencyProbe.enabled {
                LatencyProbe.keyReceived(e, terminal: (self.current.focused?.app as? TerminalApp)?.terminal)
            }
            return self.handleKey(e) ? nil : e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self else { return e }
            if self.beginFloatingDrag(e) { return nil }
            self.handleMouseDown(e)
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .rightMouseDragged]) { [weak self] e in
            guard let self, self.mouseDrag != nil else { return e }
            self.continueFloatingDrag(e)
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] e in
            guard let self, let drag = self.mouseDrag else { return e }
            self.mouseDrag = nil
            self.current.view.window?.invalidateCursorRects(for: self.current.view)
            if drag.moved { return nil }
            // A plain ⌘-click (no drag): deliver it after all, e.g. ⌘-click on a link.
            e.window?.sendEvent(drag.downEvent)
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in
            guard let self, self.config.focusFollowsMouse else { return e }
            if let w = self.window(at: e), w !== self.current.focused, self.desktop.overlay == nil,
               self.mouseDrag == nil { self.focus(w, raise: self.config.raiseOnHover) }
            return e
        } as Any)
    }

    private func window(at e: NSEvent) -> TileWindow? {
        guard e.window === desktop.window else { return nil }
        let p = current.view.convert(e.locationInWindow, from: nil)
        // Front-most first: floating windows can overlap.
        return current.view.subviews.reversed().lazy
            .compactMap { $0 as? TileWindow }
            .first { !$0.isHidden && $0.frame.contains(p) }
    }

    /// ⌘-drag moves and ⌘-right-drag resizes a window on a floating workspace (like Hyprland's
    /// Super+LMB / Super+RMB). Returns true if the event starts such a drag and should be swallowed.
    private func beginFloatingDrag(_ e: NSEvent) -> Bool {
        guard e.type == .leftMouseDown || e.type == .rightMouseDown,
              e.modifierFlags.intersection([.command, .shift, .option, .control]) == config.mod,
              desktop.overlay == nil, current.mode == .floating, current.fullscreen == nil,
              let w = window(at: e) else { return false }
        if w !== current.focused { focus(w) }
        mouseDrag = MouseDrag(window: w, resizing: e.type == .rightMouseDown,
                              startPoint: current.view.convert(e.locationInWindow, from: nil),
                              startFrame: w.floatFrame ?? w.frame, downEvent: e)
        return true
    }

    private func continueFloatingDrag(_ e: NSEvent) {
        guard var drag = mouseDrag else { return }
        let p = current.view.convert(e.locationInWindow, from: nil)
        let dx = p.x - drag.startPoint.x, dy = p.y - drag.startPoint.y
        if !drag.moved && abs(dx) + abs(dy) < 4 { return } // ignore jitter on a click
        drag.moved = true
        mouseDrag = drag
        var f = drag.startFrame
        if drag.resizing {
            f.size.width = max(TileWindow.minFloatingSize.width, f.width + dx)
            f.size.height = max(TileWindow.minFloatingSize.height, f.height + dy)
        } else {
            f.origin.x += dx
            f.origin.y += dy
        }
        f = clampFloating(f, in: current.view.bounds)
        drag.window.floatFrame = f
        drag.window.frame = f
    }

    private func handleMouseDown(_ e: NSEvent) {
        if let overlay = desktop.overlay {
            let p = overlay.convert(e.locationInWindow, from: nil)
            if !overlay.panelFrame.contains(p) { desktop.dismissOverlay() }
            return
        }
        if let w = window(at: e), w !== current.focused || current.view.subviews.last !== w {
            focus(w) // click focuses and raises
        }
    }

    private static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    private static let arrowKeys: [UInt16: Direction] = [123: .left, 124: .right, 125: .down, 126: .up]

    private func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = e.keyCode
        let mod = config.mod

        if desktop.overlay != nil {
            if flags == mod && (chars == "d" || chars == "/") || code == 53 {
                desktop.dismissOverlay()
                return true
            }
            return false
        }

        // Shortcuts without the Lucent modifier (e.g. ⌃Tab for browser tabs, or ⌘ shortcuts
        // when the modifier is ⌥) go straight to the focused app.
        guard flags.contains(mod) else { return current.focused?.app.handleKey(e) ?? false }

        if flags == mod {
            // App launch shortcuts come from the registry.
            if let app = AppRegistry.apps.first(where: { $0.shortcut?.matches(e) == true }) {
                launch(app.id)
                return true
            }
            switch (code, chars) {
            case (48, _): cycleWorkspaces(1); return true // Mod+Tab (⌘Tab belongs to macOS)
            case (_, "d"): showLauncher(); return true
            case (_, "w"): closeFocused(); return true
            case (_, "f"): toggleFullscreen(); return true
            case (_, "j"): toggleSplit(); return true
            case (_, "/"): desktop.showOverlay(HelpOverlay()); return true
            default: break
            }
            if let n = Self.digitKeys[code] { switchTo(n); return true }
            if let d = Self.arrowKeys[code] { focus(d); return true }
        }
        if flags == [mod, .shift] {
            if code == 48 { cycleWorkspaces(-1); return true }
            if chars == "f" { toggleFloating(); return true }
            if let n = Self.digitKeys[code] { moveFocused(to: n); return true }
            if let d = Self.arrowKeys[code] { swap(d); return true }
        }
        if flags == [mod, .control], let d = Self.arrowKeys[code] {
            resize(d); return true
        }
        if flags == [.command, .option], let d = Self.arrowKeys[code] {
            if d == .left { switchRelative(-1); return true }
            if d == .right { switchRelative(1); return true }
        }

        return current.focused?.app.handleKey(e) ?? false
    }

    func showThemePicker() {
        desktop.showOverlay(ThemePickerOverlay())
    }

    func showLauncher() {
        let launcher = LauncherOverlay(apps: AppRegistry.apps) { [weak self] d in
            self?.desktop.dismissOverlay()
            self?.launch(d.id)
        }
        desktop.showOverlay(launcher)
    }

    func overlayDismissed() {
        if let f = current.focused { f.app.focus() }
    }
}
