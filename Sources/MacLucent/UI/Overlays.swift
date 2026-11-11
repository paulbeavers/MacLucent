import AppKit

/// Wofi/rofi-style app launcher.
final class LauncherOverlay: OverlayView, NSTextFieldDelegate {
    private let apps: [AppDescriptor]
    private let onLaunch: (AppDescriptor) -> Void
    private let field = NSTextField()
    private var rows: [LauncherRow] = []
    private var filtered: [AppDescriptor] = []
    private var selected = 0

    override var panelSize: NSSize {
        NSSize(width: 460, height: 64 + CGFloat(max(1, apps.count)) * 40 + 12)
    }

    init(apps: [AppDescriptor], onLaunch: @escaping (AppDescriptor) -> Void) {
        self.apps = apps
        self.onLaunch = onLaunch
        super.init(frame: .zero)
        let c = Config.shared
        field.placeholderString = "Run…"
        field.font = c.uiFont(16, weight: .regular)
        field.textColor = c.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        panel.addSubview(field)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didAppear() {
        window?.makeFirstResponder(field)
    }

    override func layoutPanel() {
        let w = panel.bounds.width
        let h = panel.bounds.height
        field.frame = CGRect(x: 18, y: h - 44, width: w - 36, height: 24)
        for (i, r) in rows.enumerated() {
            r.frame = CGRect(x: 8, y: h - 64 - CGFloat(i + 1) * 40, width: w - 16, height: 36)
        }
    }

    private func refresh() {
        let q = field.stringValue.lowercased()
        filtered = q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) || $0.id.contains(q) }
        selected = min(selected, max(0, filtered.count - 1))
        rows.forEach { $0.removeFromSuperview() }
        rows = filtered.enumerated().map { i, d in
            let r = LauncherRow(app: d)
            r.onClick = { [weak self] in self?.onLaunch(d) }
            r.isSelected = i == selected
            panel.addSubview(r)
            return r
        }
        needsLayout = true
    }

    func controlTextDidChange(_ obj: Notification) {
        selected = 0
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            move(1); return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if filtered.indices.contains(selected) { onLaunch(filtered[selected]) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?(); return true
        default:
            return false
        }
    }

    private func move(_ d: Int) {
        guard !filtered.isEmpty else { return }
        selected = (selected + d + filtered.count) % filtered.count
        for (i, r) in rows.enumerated() { r.isSelected = i == selected }
    }
}

final class LauncherRow: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateColors() } }
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    init(app: AppDescriptor) {
        super.init(frame: .zero)
        let c = Config.shared
        wantsLayer = true
        layer?.cornerRadius = 8
        icon.image = NSImage(systemSymbolName: app.symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        name.stringValue = app.name
        name.font = c.uiFont(14, weight: .medium)
        shortcut.stringValue = app.shortcut
        shortcut.font = c.monoUIFont(12, weight: .medium)
        shortcut.textColor = c.overlay0
        [icon, name, shortcut].forEach(addSubview)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 12, y: (bounds.height - 20) / 2, width: 20, height: 20)
        name.sizeToFit()
        name.frame.origin = CGPoint(x: 42, y: (bounds.height - name.frame.height) / 2)
        shortcut.sizeToFit()
        shortcut.frame.origin = CGPoint(x: bounds.width - shortcut.frame.width - 12, y: (bounds.height - shortcut.frame.height) / 2)
    }

    override func mouseUp(with event: NSEvent) { onClick?() }

    private func updateColors() {
        let c = Config.shared
        layer?.backgroundColor = isSelected ? c.accent.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        icon.contentTintColor = isSelected ? c.accent : c.subtext
        name.textColor = isSelected ? c.text : c.subtext
    }
}

/// Keybinding cheat sheet.
final class HelpOverlay: OverlayView {
    static let bindings: [(String, String)] = [
        ("⌘ ↩", "New terminal"),
        ("⌘ B", "New browser"),
        ("⌘ D", "App launcher"),
        ("⌘ ,", "Settings"),
        ("⌘ W", "Close window"),
        ("⌘ ←↑↓→", "Move focus"),
        ("⌘ ⇧ ←↑↓→", "Swap window (floating: move)"),
        ("⌘ ⌃ ←↑↓→", "Resize split (floating: resize)"),
        ("⌘ J", "Toggle split direction"),
        ("⌘ F", "Fullscreen window"),
        ("⌘ ⇧ F", "Toggle workspace floating / tiled"),
        ("⌘ drag", "Floating: move window (⌘ right-drag resizes)"),
        ("⌘ 1–9", "Switch workspace"),
        ("⌘ ⇧ 1–9", "Move window to workspace"),
        ("⌘ ⌥ ←/→", "Previous / next workspace"),
        ("⌘ + / ⌘ −", "Zoom terminal / page"),
        ("⌘ L", "Browser: focus address bar"),
        ("⌘ R  ⌘ [  ⌘ ]", "Browser: reload / back / forward"),
        ("right-click", "Browser: Inspect Element"),
        ("drag gaps", "Resize splits with the mouse"),
        ("⌘ Q", "Quit"),
    ]

    private let label = NSTextField(labelWithString: "")
    override var panelSize: NSSize { NSSize(width: 440, height: CGFloat(Self.bindings.count) * 22 + 70) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let c = Config.shared
        let s = NSMutableAttributedString(string: "Keybindings\n", attributes: [
            .font: c.uiFont(15, weight: .semibold), .foregroundColor: c.text])
        let tab = NSMutableParagraphStyle()
        tab.tabStops = [NSTextTab(textAlignment: .left, location: 150)]
        tab.lineSpacing = 5
        for (k, v) in Self.bindings {
            s.append(NSAttributedString(string: "\(k)\t", attributes: [
                .font: c.monoUIFont(12, weight: .semibold), .foregroundColor: c.accent, .paragraphStyle: tab]))
            s.append(NSAttributedString(string: "\(v)\n", attributes: [
                .font: c.uiFont(12.5, weight: .regular), .foregroundColor: c.subtext, .paragraphStyle: tab]))
        }
        label.attributedStringValue = s
        panel.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutPanel() {
        label.frame = panel.bounds.insetBy(dx: 24, dy: 18)
    }
}
