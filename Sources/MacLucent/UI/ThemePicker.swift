import AppKit

extension Config {
    /// Pick a theme: apply it fully (colours, borders, terminal), tell every view, save.
    func selectTheme(_ id: String, save shouldSave: Bool = true) {
        guard let t = ThemeLibrary.theme(id) else { return }
        applyTheme(t, fully: true)
        notifyChanged()
        if shouldSave { save() }
    }
}

/// A small preview of a theme, drawn in that theme's own colours.
final class ThemeSwatchView: NSView {
    var theme: LucentTheme? { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    var isHighlighted = false { didSet { needsDisplay = true } }
    var showsName = true
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = theme else { return }
        let p = t.palette
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let card = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        p.base.setFill()
        card.fill()
        // Focused-window look for the current theme, a quiet outline otherwise.
        if isCurrent {
            card.lineWidth = 2.5
            NSGradient(colors: [p.mauve, p.blue])?.draw(in: NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9), angle: 45)
            p.base.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 2.5, dy: 2.5), xRadius: 7, yRadius: 7).fill()
        } else {
            (isHighlighted ? p.overlay : p.surface0).setStroke()
            card.lineWidth = 1
            card.stroke()
        }
        var y: CGFloat = 10
        if showsName {
            let name = NSAttributedString(string: t.name, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: p.text])
            let mode = NSAttributedString(string: t.isLight ? "light" : "dark", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: p.overlay])
            let modeW = mode.size().width
            name.draw(with: CGRect(x: 12, y: y, width: bounds.width - 30 - modeW, height: 16),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            mode.draw(at: CGPoint(x: bounds.width - 12 - modeW, y: y + 2))
            y += 24
        } else {
            y = (bounds.height - 12) / 2
        }
        // Accent swatches, in Lucent's role order.
        let swatches = [p.mauve, p.blue, p.sapphire, p.teal, p.green, p.yellow, p.peach, p.red, p.pink]
        let d: CGFloat = 12, gap: CGFloat = 5
        var x: CGFloat = 12
        for c in swatches where x + d <= bounds.width - 10 {
            c.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: y, width: d, height: d)).fill()
            x += d + gap
        }
        // Text-on-surface sample, so contrast is visible at a glance.
        if showsName, x + 34 <= bounds.width - 10 {
            let sample = NSBezierPath(roundedRect: CGRect(x: bounds.width - 46, y: y - 2, width: 34, height: 16), xRadius: 4, yRadius: 4)
            p.surface0.setFill()
            sample.fill()
            NSAttributedString(string: "Aa", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                          .foregroundColor: p.text])
                .draw(at: CGPoint(x: bounds.width - 37, y: y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Settings → Theme: a grid of cards; clicking one switches theme immediately.
final class ThemeGridView: NSView {
    private var cards: [ThemeSwatchView] = []
    private let cardHeight: CGFloat = 62
    private let gap: CGFloat = 10

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for t in ThemeLibrary.all() {
            let card = ThemeSwatchView()
            card.theme = t
            card.isCurrent = t.id == Config.shared.themeID
            card.onClick = { Config.shared.selectTheme(t.id) }
            cards.append(card)
            addSubview(card)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func columns(for width: CGFloat) -> Int { max(1, Int((width + gap) / (190 + gap))) }

    func height(for width: CGFloat) -> CGFloat {
        let rows = (cards.count + columns(for: width) - 1) / columns(for: width)
        return CGFloat(rows) * (cardHeight + gap)
    }

    override func layout() {
        super.layout()
        let cols = columns(for: bounds.width)
        let w = (bounds.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, card) in cards.enumerated() {
            card.frame = CGRect(x: CGFloat(i % cols) * (w + gap), y: CGFloat(i / cols) * (cardHeight + gap),
                                width: w, height: cardHeight)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}

/// Launcher → Themes…: a quick, filterable list like Lucent's theme menu. Moving through it
/// previews each theme live; Enter keeps it, Esc (or clicking outside) restores the previous one.
final class ThemePickerOverlay: OverlayView, NSTextFieldDelegate {
    private let field = NSTextField()
    private var rows: [ThemeSwatchView] = []
    private var labels: [NSTextField] = []
    private var filtered: [LucentTheme] = []
    private var selected = 0
    private let original: SettingsFile
    private var committed = false
    private let rowHeight: CGFloat = 34
    private let visibleRows = 10

    override var panelSize: NSSize {
        NSSize(width: 520, height: 64 + CGFloat(min(visibleRows, max(1, filtered.count))) * rowHeight + 12)
    }

    override init(frame: NSRect) {
        original = Config.shared.snapshot()
        super.init(frame: frame)
        let c = Config.shared
        field.placeholderString = "Theme…"
        field.font = c.uiFont(16, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        panel.addSubview(field)
        filtered = ThemeLibrary.all()
        selected = filtered.firstIndex { $0.id == c.themeID } ?? 0
        rebuildRows()
        recolor()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didAppear() { window?.makeFirstResponder(field) }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        labels.forEach { $0.removeFromSuperview() }
        rows = []
        labels = []
        // Keep the selection inside the visible window of rows.
        let first = max(0, min(selected - visibleRows / 2, filtered.count - visibleRows))
        for (i, t) in filtered.enumerated().dropFirst(first).prefix(visibleRows) {
            let swatch = ThemeSwatchView()
            swatch.theme = t
            swatch.showsName = false
            swatch.isCurrent = i == selected
            swatch.onClick = { [weak self] in self?.choose(i, commit: true) }
            let label = NSTextField(labelWithString: t.name + (t.isLight ? "  ·  light" : ""))
            label.lineBreakMode = .byTruncatingTail
            panel.addSubview(swatch)
            panel.addSubview(label)
            rows.append(swatch)
            labels.append(label)
        }
        needsLayout = true
        recolor()
    }

    private func recolor() {
        let c = Config.shared
        panel.appearance = c.appearance
        panel.layer?.borderColor = c.accent.withAlphaComponent(0.7).cgColor
        field.textColor = c.text
        let first = max(0, min(selected - visibleRows / 2, filtered.count - visibleRows))
        for (k, label) in labels.enumerated() {
            let isSel = first + k == selected
            label.font = c.uiFont(13.5, weight: isSel ? .semibold : .regular)
            label.textColor = isSel ? c.text : c.subtext
        }
    }

    override func layoutPanel() {
        let w = panel.bounds.width, h = panel.bounds.height
        field.frame = CGRect(x: 18, y: h - 44, width: w - 36, height: 24)
        for (k, swatch) in rows.enumerated() {
            let y = h - 64 - CGFloat(k + 1) * rowHeight
            swatch.frame = CGRect(x: 10, y: y + 2, width: 178, height: rowHeight - 4)
            labels[k].frame = CGRect(x: 200, y: y + (rowHeight - 18) / 2, width: w - 214, height: 18)
        }
    }

    /// Preview (apply without saving) or commit a theme.
    private func choose(_ i: Int, commit: Bool) {
        guard filtered.indices.contains(i) else { return }
        selected = i
        Config.shared.selectTheme(filtered[i].id, save: false)
        rebuildRows()
        if commit {
            committed = true
            Config.shared.save()
            onDismiss?()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let q = field.stringValue.lowercased()
        filtered = ThemeLibrary.all().filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.id.contains(q) }
        selected = 0
        rebuildRows()
        // Resize the panel to the new number of rows.
        layout()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            if !filtered.isEmpty { choose((selected + 1) % filtered.count, commit: false) }
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            if !filtered.isEmpty { choose((selected - 1 + filtered.count) % filtered.count, commit: false) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            choose(selected, commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
            return true
        default:
            return false
        }
    }

    /// Closing without Enter puts back whatever was active before the picker opened.
    override func willDismiss() {
        guard !committed else { return }
        let c = Config.shared
        c.apply(original)
        c.notifyChanged()
    }
}
