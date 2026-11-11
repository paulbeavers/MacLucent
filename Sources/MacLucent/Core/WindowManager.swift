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
            ws.view.onLayoutChange = { [weak self, weak ws] in
                guard let self, let ws else { return }
                self.relayout(ws, animated: false)
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
                self.relayout(self.current, animated: true)
            }
        }
        updateBar()
    }

    // MARK: - Opening and closing

    func launch(_ id: String) {
        guard let d = AppRegistry.app(id) else { return }
        open(d.make(self))
    }

    func open(_ app: TileApp, on ws: Workspace? = nil) {
        let ws = ws ?? current
        let w = TileWindow(app: app)
        app.onTitleChange = { [weak self] in self?.updateBar() }
        app.onRequestClose = { [weak self, weak w] in
            guard let self, let w else { return }
            self.close(w)
        }
        desktop.layoutSubtreeIfNeeded()
        ws.view.frame = desktop.stage.bounds
        ws.tree.layout(in: ws.view.bounds) // fresh rects so dwindle picks the right split axis
        ws.fullscreen = nil
        ws.tree.insert(w, near: ws.focused)
        ws.view.addSubview(w)
        relayout(ws, animated: true, appearing: w)
        focus(w)
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
        if let w = current.focused { close(w) }
    }

    var allWindows: [TileWindow] { workspaces.flatMap { $0.windows } }

    func workspace(of w: TileWindow) -> Workspace? {
        workspaces.first { ws in ws.windows.contains { $0 === w } }
    }

    var focusedTerminalDirectory: String? {
        (current.focused?.app as? TerminalApp)?.currentDirectory
    }

    // MARK: - Focus

    func focus(_ w: TileWindow) {
        guard let ws = workspace(of: w) else { return }
        if ws !== current { switchTo(ws.index) }
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
        if let n = current.tree.neighbor(of: w, d) { focus(n) }
    }

    func swap(_ d: Direction) {
        guard let w = current.focused, current.fullscreen == nil,
              let n = current.tree.neighbor(of: w, d) else { return }
        current.tree.swap(w, n)
        relayout(current, animated: true)
    }

    func resize(_ d: Direction) {
        guard let w = current.focused else { return }
        current.tree.resize(w, direction: d)
        relayout(current, animated: true)
    }

    func toggleSplit() {
        guard let w = current.focused else { return }
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
            relayout(ws, animated: false)
        }
    }

    func relayout(_ ws: Workspace, animated: Bool, appearing: TileWindow? = nil) {
        let bounds = ws.view.bounds
        ws.tree.layout(in: bounds)
        let animate = animated && config.animationsEnabled && ws === current && !ws.view.isHidden
        let fullRect = bounds.insetBy(dx: config.gapsOut, dy: config.gapsOut)

        var targets: [(TileWindow, CGRect)] = []
        for w in ws.windows {
            guard var r = ws.tree.rect(for: w) else { continue }
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
        else { mode = "dwindle" }
        desktop.bar.update(workspaces: states,
                           title: app?.title ?? "",
                           symbol: app?.symbolName,
                           mode: "\(mode) · \(current.windows.count)")
        desktop.window?.title = app?.title ?? "mac-lucent"
    }

    // MARK: - Input

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e) ? nil : e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            self?.handleMouseDown(e)
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in
            guard let self, self.config.focusFollowsMouse else { return e }
            if let w = self.window(at: e), w !== self.current.focused, self.desktop.overlay == nil { self.focus(w) }
            return e
        } as Any)
    }

    private func window(at e: NSEvent) -> TileWindow? {
        guard e.window === desktop.window else { return nil }
        let p = current.view.convert(e.locationInWindow, from: nil)
        return current.windows.last { !$0.isHidden && $0.frame.contains(p) }
    }

    private func handleMouseDown(_ e: NSEvent) {
        if let overlay = desktop.overlay {
            let p = overlay.convert(e.locationInWindow, from: nil)
            if !overlay.panelFrame.contains(p) { desktop.dismissOverlay() }
            return
        }
        if let w = window(at: e), w !== current.focused {
            focus(w)
        }
    }

    private static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    private static let arrowKeys: [UInt16: Direction] = [123: .left, 124: .right, 125: .down, 126: .up]

    private func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = e.keyCode

        if desktop.overlay != nil {
            if flags == .command && (chars == "d" || chars == "/") || code == 53 {
                desktop.dismissOverlay()
                return true
            }
            return false
        }

        guard flags.contains(.command) else { return false }

        if flags == .command {
            switch (code, chars) {
            case (36, _), (76, _): launch("terminal"); return true
            case (_, "b"): launch("browser"); return true
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
        if flags == [.command, .shift] {
            if let n = Self.digitKeys[code] { moveFocused(to: n); return true }
            if let d = Self.arrowKeys[code] { swap(d); return true }
        }
        if flags == [.command, .control], let d = Self.arrowKeys[code] {
            resize(d); return true
        }
        if flags == [.command, .option], let d = Self.arrowKeys[code] {
            if d == .left { switchRelative(-1); return true }
            if d == .right { switchRelative(1); return true }
        }

        return current.focused?.app.handleKey(e) ?? false
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
