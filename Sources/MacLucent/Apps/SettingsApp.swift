import AppKit
import UniformTypeIdentifiers

/// Settings window: edits `Config.shared` live and saves to ~/.config/lucent/settings.json.
final class SettingsApp: NSObject, TileApp {
    let view: NSView
    var title: String { "Settings" }
    var symbolName: String { "gearshape" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private var items: [NSView] = []
    /// Push current config values back into the controls (after a reset).
    private var refreshers: [() -> Void] = []
    private var targets: [ActionTarget] = []
    private let columnWidth: CGFloat = 620
    private var c: Config { .shared }

    override init() {
        let root = FlippedView()
        view = root
        super.init()
        root.wantsLayer = true
        root.layer?.backgroundColor = Config.shared.mantle.cgColor
        root.appearance = Config.shared.appearance

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        root.addSubview(scroll)
        root.onLayout = { [weak self] in self?.layout() }
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)
    }

    // MARK: Building the form

    private func build() {
        header("Theme", "The same themes as Lucent for Hyprland")
        add(ThemeGridView())

        header("General", "Gaps, borders and focus")
        slider("Inner gaps", 0...30, step: 1, fmt: "%.0f px", get: { Double(self.c.gapsIn) }, set: { self.c.gapsIn = CGFloat($0) })
        slider("Outer gaps", 0...60, step: 1, fmt: "%.0f px", get: { Double(self.c.gapsOut) }, set: { self.c.gapsOut = CGFloat($0) })
        slider("Border size", 0...8, step: 1, fmt: "%.0f px", get: { Double(self.c.borderSize) }, set: { self.c.borderSize = CGFloat($0) })
        popup("Modifier key", options: ["Command (⌘)", "Option (⌥)"],
              get: { self.c.modifierKey == .option ? "Option (⌥)" : "Command (⌘)" },
              set: { self.c.modifierKey = $0.hasPrefix("Option") ? .option : .command })
        toggle("Restore windows on launch", note: "Workspaces, layouts, terminal folders and browser tabs",
               get: { self.c.restoreSession }, set: { self.c.restoreSession = $0 })
        toggle("Focus follows mouse", get: { self.c.focusFollowsMouse }, set: { self.c.focusFollowsMouse = $0 })
        toggle("Raise on hover", note: "Floating workspaces: hovered window comes to the front",
               get: { self.c.raiseOnHover }, set: { self.c.raiseOnHover = $0 })

        header("Workspaces", "Floating workspaces let windows overlap and be moved freely")
        workspaceModes()

        header("Decoration", "Window shape, shadow and transparency")
        slider("Rounding", 0...24, step: 1, fmt: "%.0f px", get: { Double(self.c.rounding) }, set: { self.c.rounding = CGFloat($0) })
        toggle("Drop shadow", get: { self.c.shadow }, set: { self.c.shadow = $0 })
        slider("Dim inactive windows", 0...0.6, step: 0.05, fmt: "%.0f%%", scale: 100,
               get: { Double(self.c.inactiveDim) }, set: { self.c.inactiveDim = CGFloat($0) })
        slider("Terminal opacity", 0.5...1, step: 0.01, fmt: "%.0f%%", scale: 100,
               get: { Double(self.c.terminalOpacity) }, set: { self.c.terminalOpacity = CGFloat($0) })
        toggle("Background blur", note: "Costs some redraw performance",
               get: { self.c.blur }, set: { self.c.blur = $0 })

        header("Colors", "Window borders")
        color("Active border (start)", get: { self.c.activeBorder.first! }, set: { self.c.activeBorder[0] = $0 })
        color("Active border (end)", get: { self.c.activeBorder.last! }, set: { self.c.activeBorder[self.c.activeBorder.count - 1] = $0 })
        color("Inactive border", get: { self.c.inactiveBorder }, set: { self.c.inactiveBorder = $0 })

        header("Animations", nil)
        toggle("Enable animations", get: { self.c.animationsEnabled }, set: { self.c.animationsEnabled = $0 })
        slider("Window speed", 0.05...0.6, step: 0.01, fmt: "%.0f ms", scale: 1000,
               get: { self.c.animationDuration }, set: { self.c.animationDuration = $0 })
        slider("Workspace speed", 0.1...0.8, step: 0.01, fmt: "%.0f ms", scale: 1000,
               get: { self.c.workspaceAnimationDuration }, set: { self.c.workspaceAnimationDuration = $0 })

        header("Terminal", nil)
        popup("Font", options: ["Automatic"] + Self.monospacedFamilies(),
              get: { self.c.terminalFontFamily ?? "Automatic" },
              set: { self.c.terminalFontFamily = $0 == "Automatic" ? nil : $0 })
        slider("Font size", 9...24, step: 1, fmt: "%.0f pt", get: { Double(self.c.terminalFontSize) }, set: { self.c.terminalFontSize = CGFloat($0) })

        header("Browser", nil)
        text("Home page", get: { self.c.homepage }, set: { self.c.homepage = $0 })
        text("Search URL", note: "%s is replaced by the query", get: { self.c.searchURL }, set: { self.c.searchURL = $0 })

        header("Wallpaper", nil)
        wallpaperRow()

        footer()
    }

    // MARK: Row builders

    private func header(_ title: String, _ subtitle: String?) {
        let v = RowView()
        let t = label(title, size: 15, weight: .semibold, color: c.text)
        v.addSubview(t)
        if let subtitle {
            let s = label(subtitle, size: 11.5, weight: .regular, color: c.overlay0)
            v.addSubview(s)
            s.frame.origin = CGPoint(x: 0, y: 44)
        }
        t.frame.origin = CGPoint(x: 0, y: 24)
        v.frame.size.height = subtitle == nil ? 52 : 66
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = c.surface0.cgColor
        v.addSubview(line)
        v.onLayout = { [weak v] in
            guard let v else { return }
            line.frame = CGRect(x: 0, y: v.bounds.height - 1, width: v.bounds.width, height: 1)
        }
        add(v)
    }

    /// A label on the left, `control` on the right.
    private func row(_ title: String, note: String? = nil, control: NSView, controlWidth: CGFloat, trailing: NSView? = nil) {
        let v = RowView()
        let l = label(title, size: 13, weight: .regular, color: c.subtext)
        v.addSubview(l)
        var n: NSTextField?
        if let note {
            let nl = label(note, size: 11, weight: .regular, color: c.overlay0)
            v.addSubview(nl)
            n = nl
        }
        v.addSubview(control)
        if let trailing { v.addSubview(trailing) }
        v.frame.size.height = note == nil ? 38 : 48
        v.onLayout = { [weak v] in
            guard let v else { return }
            let h = v.bounds.height
            l.frame.origin = CGPoint(x: 0, y: note == nil ? (h - l.frame.height) / 2 : 8)
            n?.frame.origin = CGPoint(x: 0, y: 27)
            let tw: CGFloat = trailing == nil ? 0 : 64
            let cx = v.bounds.width - controlWidth - tw
            let ch = control.fittingSize.height > 0 ? min(control.fittingSize.height, 28) : 22
            control.frame = CGRect(x: cx, y: (h - ch) / 2, width: controlWidth, height: ch)
            if let trailing {
                trailing.frame = CGRect(x: v.bounds.width - tw + 8, y: (h - trailing.frame.height) / 2,
                                        width: tw - 8, height: trailing.frame.height)
            }
        }
        add(v)
    }

    private func slider(_ title: String, _ range: ClosedRange<Double>, step: Double, fmt: String, scale: Double = 1,
                        get: @escaping () -> Double, set: @escaping (Double) -> Void) {
        let s = NSSlider(value: get(), minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        s.isContinuous = true
        let value = label("", size: 12, weight: .medium, color: c.text, mono: true)
        value.alignment = .right
        let show = { value.stringValue = String(format: fmt, s.doubleValue * scale); value.sizeToFit() }
        show()
        bind(s) { [weak self] in
            let v = (s.doubleValue / step).rounded() * step
            set(v)
            show()
            self?.changed()
        }
        refreshers.append { s.doubleValue = get(); show() }
        row(title, control: s, controlWidth: 220, trailing: value)
    }

    private func toggle(_ title: String, note: String? = nil, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        let sw = NSSwitch()
        sw.state = get() ? .on : .off
        bind(sw) { [weak self] in set(sw.state == .on); self?.changed() }
        refreshers.append { sw.state = get() ? .on : .off }
        row(title, note: note, control: sw, controlWidth: 40)
    }

    private func color(_ title: String, get: @escaping () -> NSColor, set: @escaping (NSColor) -> Void) {
        let well = NSColorWell(frame: CGRect(x: 0, y: 0, width: 44, height: 24))
        if #available(macOS 13.0, *) { well.colorWellStyle = .minimal }
        well.color = get()
        bind(well) { [weak self] in
            NSColorPanel.shared.showsAlpha = true
            set(well.color)
            self?.changed()
        }
        refreshers.append { well.color = get() }
        row(title, control: well, controlWidth: 44)
    }

    private func popup(_ title: String, options: [String], get: @escaping () -> String, set: @escaping (String) -> Void) {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: options)
        let select = { if p.itemTitles.contains(get()) { p.selectItem(withTitle: get()) } else { p.selectItem(at: 0) } }
        select()
        bind(p) { [weak self] in set(p.titleOfSelectedItem ?? options[0]); self?.changed() }
        refreshers.append(select)
        row(title, control: p, controlWidth: 260)
    }

    private func text(_ title: String, note: String? = nil, get: @escaping () -> String, set: @escaping (String) -> Void) {
        let f = NSTextField(string: get())
        f.font = c.uiFont(12.5, weight: .regular)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        bind(f) { [weak self] in set(f.stringValue); self?.changed() }
        refreshers.append { f.stringValue = get() }
        row(title, note: note, control: f, controlWidth: 320)
    }

    private func workspaceModes() {
        let count = c.workspaceCount
        let seg = NSSegmentedControl(labels: (1...count).map(String.init), trackingMode: .selectAny, target: nil, action: nil)
        for i in 0..<count { seg.setWidth(26, forSegment: i) }
        let sync = { [weak self] in
            guard let self else { return }
            for i in 0..<count { seg.setSelected(self.c.floatingWorkspaces.contains(i + 1), forSegment: i) }
        }
        sync()
        bind(seg) { [weak self] in
            guard let self else { return }
            self.c.floatingWorkspaces = Set((0..<count).filter { seg.isSelected(forSegment: $0) }.map { $0 + 1 })
            self.changed()
        }
        refreshers.append(sync)
        row("Floating", note: "Selected workspaces float · \(c.shortcut("⌘⇧F")) toggles the current one",
            control: seg, controlWidth: CGFloat(count) * 27 + 6)
    }

    private func wallpaperRow() {
        let path = label("", size: 12, weight: .regular, color: c.text)
        path.lineBreakMode = .byTruncatingMiddle
        let show = { [weak self] in
            path.stringValue = self?.c.wallpaperPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Built-in gradient"
        }
        show()
        refreshers.append(show)

        let choose = NSButton(title: "Choose…", target: nil, action: nil)
        bind(choose) { [weak self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.canChooseDirectories = false
            if panel.runModal() == .OK, let url = panel.url {
                self?.c.wallpaperPath = url.path
                show()
                self?.changed()
            }
        }
        let clear = NSButton(title: "Use built-in", target: nil, action: nil)
        bind(clear) { [weak self] in
            self?.c.wallpaperPath = nil
            show()
            self?.changed()
        }
        let buttons = FlippedView()
        buttons.addSubview(choose)
        buttons.addSubview(clear)
        choose.sizeToFit()
        clear.sizeToFit()
        clear.frame.origin = .zero
        choose.frame.origin = CGPoint(x: clear.frame.maxX + 8, y: 0)
        buttons.frame.size = CGSize(width: choose.frame.maxX, height: max(choose.frame.height, 22))

        let v = RowView()
        v.addSubview(path)
        v.addSubview(buttons)
        v.frame.size.height = 44
        v.onLayout = { [weak v] in
            guard let v else { return }
            let h = v.bounds.height
            buttons.frame.origin = CGPoint(x: v.bounds.width - buttons.frame.width, y: (h - buttons.frame.height) / 2)
            path.frame = CGRect(x: 0, y: (h - 16) / 2, width: max(0, buttons.frame.minX - 16), height: 16)
        }
        add(v)
    }

    private func footer() {
        let v = RowView()
        let reset = NSButton(title: "Reset to defaults", target: nil, action: nil)
        bind(reset) { [weak self] in
            Config.shared.resetToDefaults()
            self?.refreshers.forEach { $0() }
        }
        reset.sizeToFit()
        let note = label("Saved automatically to " + (Config.settingsURL.path as NSString).abbreviatingWithTildeInPath,
                         size: 11, weight: .regular, color: c.overlay0)
        v.addSubview(reset)
        v.addSubview(note)
        v.frame.size.height = 90
        v.onLayout = { [weak v] in
            guard v != nil else { return }
            reset.frame.origin = CGPoint(x: 0, y: 32)
            note.frame.origin = CGPoint(x: reset.frame.maxX + 14, y: 32 + (reset.frame.height - note.frame.height) / 2)
        }
        add(v)
    }

    // MARK: Helpers

    private func add(_ v: NSView) {
        items.append(v)
        doc.addSubview(v)
    }

    private var applying = false

    private func changed() {
        applying = true
        c.notifyChanged()
        applying = false
        c.save()
    }

    private func bind(_ control: NSControl, _ action: @escaping () -> Void) {
        let t = ActionTarget(action)
        targets.append(t)
        control.target = t
        control.action = #selector(ActionTarget.fire)
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = mono ? c.monoUIFont(size, weight: weight) : c.uiFont(size, weight: weight)
        l.textColor = color
        l.sizeToFit()
        return l
    }

    static func monospacedFamilies() -> [String] {
        let fm = NSFontManager.shared
        var seen = Set<String>()
        for name in fm.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            if let fam = NSFont(name: name, size: 12)?.familyName, !fam.hasPrefix(".") { seen.insert(fam) }
        }
        return seen.sorted()
    }

    private func layout() {
        scroll.frame = view.bounds
        let width = max(320, min(columnWidth, view.bounds.width - 48))
        let x = (view.bounds.width - width) / 2
        var y: CGFloat = 8
        for v in items {
            let h = (v as? ThemeGridView)?.height(for: width) ?? v.frame.height
            v.frame = CGRect(x: x, y: y, width: width, height: h)
            v.needsLayout = true
            y += v.frame.height
        }
        doc.frame = CGRect(x: 0, y: 0, width: max(0, scroll.contentSize.width), height: y + 24)
    }

    /// Keep controls in sync when config changes elsewhere (reset, another window, a file load).
    private var builtTheme = Config.shared.themeID

    @objc private func configChanged() {
        if c.themeID != builtTheme {
            builtTheme = c.themeID
            // Rebuild after the current event: the change may come from one of our own controls.
            DispatchQueue.main.async { [weak self] in self?.rebuildForTheme() }
            return
        }
        guard !applying else { return }
        refreshers.forEach { $0() }
    }

    /// Recreate every row in the new theme's colours, keeping the scroll position.
    private func rebuildForTheme() {
        let offset = scroll.contentView.bounds.origin
        items.forEach { $0.removeFromSuperview() }
        items.removeAll()
        refreshers.removeAll()
        targets.removeAll()
        view.appearance = c.appearance
        view.layer?.backgroundColor = c.mantle.cgColor
        build()
        layout()
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: TileApp

    func focus() {
        view.window?.makeFirstResponder(scroll.documentView)
    }

    func shutdown() {
        targets.removeAll()
    }
}

/// Closure-backed target for NSControl actions.
final class ActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// Flipped row that lays out its children via a closure.
final class RowView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}
