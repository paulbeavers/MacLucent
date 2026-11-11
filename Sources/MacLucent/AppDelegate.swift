import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var desktop: DesktopView!
    private(set) var manager: WindowManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.shared.load()
        NSApp.applicationIconImage = AppIcon.image(size: 512)
        NSApp.mainMenu = buildMenu()

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let args = CommandLine.arguments
        // Default: macOS native full screen, so mac-lucent gets its own Space (a page in Mission
        // Control / ⌃↑, swipeable like any full-screen app). `--borderless` instead covers the
        // current Space with a borderless window (menu bar and Dock auto-hidden); `--windowed`
        // opens a normal window.
        let covering = args.contains("--borderless")
        let nativeFullScreen = !covering && !args.contains("--windowed")
        window = MainWindow(contentRect: covering ? screen.frame : screen.visibleFrame,
                            styleMask: covering ? [.borderless, .miniaturizable]
                                                : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        window.title = "mac-lucent"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = Config.shared.crust
        window.appearance = NSAppearance(named: .darkAqua)
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)
        window.delegate = self

        desktop = DesktopView(frame: window.contentLayoutRect)
        window.contentView = desktop
        manager = WindowManager(desktop: desktop)
        desktop.onOverlayDismissed = { [weak self] in self?.manager.overlayDismissed() }

        window.setFrame(covering ? screen.frame : screen.visibleFrame, display: true)
        if covering {
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let s = self.window.screen ?? NSScreen.main else { return }
                    self.window.setFrame(s.frame, display: true)
                }
            }
        }
        if ProcessInfo.processInfo.environment["ML_BACKGROUND"] != nil {
            window.orderBack(nil) // test runs: don't take keyboard focus from the user
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if nativeFullScreen {
            window.toggleFullScreen(nil)
        }
        manager.launch("terminal")
        runDebugArguments()
    }

    /// Developer aids: `--open terminal,browser` opens extra windows, `--snapshot <png>` renders
    /// the desktop to a file after a short delay and quits.
    private func runDebugArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            for id in args[i + 1].split(separator: ",") { manager.launch(String(id)) }
        }
        if let i = args.firstIndex(of: "--type"), i + 1 < args.count {
            let text = args[i + 1].replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                for w in self?.manager.allWindows ?? [] { (w.app as? TerminalApp)?.terminal.send(txt: text) }
            }
        }
        if let i = args.firstIndex(of: "--workspace"), i + 1 < args.count, let n = Int(args[i + 1]) {
            manager.switchTo(n)
        }
        if args.contains("--bench-typing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self else { return }
                TypingBenchmark.run(window: self.window)
            }
        }
        if args.contains("--launcher") { manager.showLauncher() }
        if args.contains("--help-overlay") { desktop.showOverlay(HelpOverlay()) }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let layer = self.desktop.layer else { return }
                self.desktop.display()
                let scale = self.window.backingScaleFactor
                let size = self.desktop.bounds.size
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let terminals = manager.allWindows.filter { $0.app is TerminalApp }.count
        guard terminals > 0, !CommandLine.arguments.contains("--no-confirm-quit") else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit mac-lucent?"
        alert.informativeText = "\(terminals) terminal\(terminals == 1 ? "" : "s") will be closed."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.allWindows.forEach { $0.app.shutdown() }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { desktop.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { desktop.needsLayout = true }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About mac-lucent", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings), ","))
        appMenu.addItem(item("Stats", #selector(openStats), "i"))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide mac-lucent", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit mac-lucent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "mac-lucent"))

        let file = NSMenu(title: "File")
        file.addItem(item("New Terminal", #selector(newTerminal), "\r"))
        file.addItem(item("New Browser", #selector(newBrowser), "b"))
        file.addItem(item("Launcher…", #selector(showLauncher), "d"))
        main.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let win = NSMenu(title: "Window")
        let fs = win.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(.separator())
        win.addItem(item("Keybindings", #selector(showHelp), "/"))
        main.addItem(submenu(win, title: "Window"))
        NSApp.windowsMenu = win
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func newTerminal() { manager.launch("terminal") }
    @objc private func newBrowser() { manager.launch("browser") }
    @objc private func showLauncher() { manager.showLauncher() }
    @objc private func openSettings() { manager.launch("settings") }
    @objc private func openStats() { manager.launch("stats") }
    @objc private func showHelp() { desktop.showOverlay(HelpOverlay()) }
}

/// Borderless windows can't become key by default; ours must, to receive keyboard input.
final class MainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Programmatic app icon: three gradient-bordered tiles on a dark squircle.
@MainActor
enum AppIcon {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width
            let inset = s * 0.1
            let body = rect.insetBy(dx: inset, dy: inset)
            let bg = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
            NSGradient(colors: [NSColor(hex: 0x1E1E2E), NSColor(hex: 0x11111B)])?.draw(in: bg, angle: 90)

            let pad = s * 0.075, gap = s * 0.035
            let inner = body.insetBy(dx: pad, dy: pad)
            let leftW = (inner.width - gap) * 0.55
            let rightW = inner.width - gap - leftW
            let halfH = (inner.height - gap) / 2
            let tiles = [
                CGRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height),
                CGRect(x: inner.minX + leftW + gap, y: inner.minY, width: rightW, height: halfH),
                CGRect(x: inner.minX + leftW + gap, y: inner.minY + halfH + gap, width: rightW, height: halfH),
            ]
            let border = NSGradient(colors: [NSColor(hex: 0x33CCFF), NSColor(hex: 0x00FF99)])!
            for (i, t) in tiles.enumerated() {
                let r = s * 0.045
                let outer = NSBezierPath(roundedRect: t, xRadius: r, yRadius: r)
                if i == 0 {
                    border.draw(in: outer, angle: -45)
                } else {
                    NSColor(hex: 0x595959, alpha: 0.8).setFill()
                    outer.fill()
                }
                let bw = s * 0.012
                NSColor(hex: 0x181825).setFill()
                NSBezierPath(roundedRect: t.insetBy(dx: bw, dy: bw), xRadius: r - bw, yRadius: r - bw).fill()
            }
            // prompt glyph in the main tile
            let glyph = NSAttributedString(string: "❯_", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: s * 0.11, weight: .bold),
                .foregroundColor: NSColor(hex: 0xA6E3A1),
            ])
            glyph.draw(at: CGPoint(x: tiles[0].minX + s * 0.04, y: tiles[0].minY + s * 0.04))
            return true
        }
    }

    static func writePNG(to path: String, size: CGFloat) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image(size: size).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
