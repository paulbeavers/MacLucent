import AppKit

/// Waybar-style top bar: workspaces on the left, focused window title in the middle,
/// layout mode and clock on the right.
final class BarView: NSView {
    struct WorkspaceState: Equatable {
        let index: Int
        let occupied: Bool
        let active: Bool
    }

    var onWorkspaceClick: ((Int) -> Void)?

    private let background = NSVisualEffectView()
    private let tint = NSView()
    private let logo = NSImageView()
    private var pills: [Int: WorkspacePill] = [:]
    private var states: [WorkspaceState] = []
    private let titleIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")
    private var timer: Timer?
    private let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM  HH:mm"
        return f
    }()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let c = Config.shared
        wantsLayer = true
        layer?.cornerRadius = c.rounding
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = c.surface1.withAlphaComponent(0.6).cgColor

        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.appearance = c.appearance
        if c.blur { addSubview(background) }
        tint.wantsLayer = true
        tint.layer?.backgroundColor = c.crust.withAlphaComponent(c.blur ? 0.55 : 0.85).cgColor
        addSubview(tint)

        logo.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)
        logo.symbolConfiguration = .init(pointSize: 13, weight: .bold)
        logo.contentTintColor = c.accent
        addSubview(logo)

        titleIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        titleIcon.contentTintColor = c.subtext
        addSubview(titleIcon)

        for l in [titleLabel, modeLabel, clockLabel] {
            l.lineBreakMode = .byTruncatingTail
            l.textColor = c.text
            addSubview(l)
        }
        titleLabel.font = c.uiFont(12, weight: .medium)
        titleLabel.alignment = .center
        modeLabel.font = c.monoUIFont(11, weight: .medium)
        modeLabel.textColor = c.overlay0
        clockLabel.font = c.monoUIFont(12, weight: .semibold)
        clockLabel.textColor = c.text

        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)
    }

    @objc private func configChanged() {
        let c = Config.shared
        layer?.cornerRadius = c.rounding
        if c.blur, background.superview == nil {
            addSubview(background, positioned: .below, relativeTo: nil)
        } else if !c.blur {
            background.removeFromSuperview()
        }
        tint.layer?.backgroundColor = c.crust.withAlphaComponent(c.blur ? 0.55 : 0.85).cgColor
        // Theme colours
        layer?.borderColor = c.surface1.withAlphaComponent(0.6).cgColor
        background.appearance = c.appearance
        logo.contentTintColor = c.accent
        titleIcon.contentTintColor = c.subtext
        titleLabel.textColor = c.text
        modeLabel.textColor = c.overlay0
        clockLabel.textColor = c.text
        for p in pills.values { p.refreshColors() }
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func tick() {
        clockLabel.stringValue = clockFormatter.string(from: Date())
        needsLayout = true
    }

    func update(workspaces: [WorkspaceState], title: String, symbol: String?, mode: String) {
        titleLabel.stringValue = title
        titleIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        modeLabel.stringValue = mode
        if workspaces != states {
            states = workspaces
            let wanted = Set(workspaces.map { $0.index })
            for (i, p) in pills where !wanted.contains(i) {
                p.removeFromSuperview()
                pills[i] = nil
            }
            for s in workspaces {
                let p = pills[s.index] ?? {
                    let p = WorkspacePill(index: s.index)
                    p.onClick = { [weak self] in self?.onWorkspaceClick?(s.index) }
                    addSubview(p)
                    pills[s.index] = p
                    return p
                }()
                p.state = s
            }
            layoutPills(animated: true)
        }
        needsLayout = true
    }

    private func layoutPills(animated: Bool) {
        var x: CGFloat = 34
        let h: CGFloat = 18
        let y = (bounds.height - h) / 2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated && Config.shared.animationsEnabled ? 0.25 : 0
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            for s in states {
                guard let p = pills[s.index] else { continue }
                let w: CGFloat = s.active ? 38 : 20
                let f = CGRect(x: x, y: y, width: w, height: h)
                if p.frame == .zero { p.frame = f } else { p.animator().frame = f }
                x += w + 5
            }
        }
    }

    var pillsMaxX: CGFloat {
        states.compactMap { pills[$0.index]?.frame.maxX }.max() ?? 34
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        tint.frame = bounds
        logo.frame = CGRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        layoutPills(animated: false)

        clockLabel.sizeToFit()
        let cw = clockLabel.frame.width
        clockLabel.frame = CGRect(x: bounds.width - cw - 14, y: (bounds.height - clockLabel.frame.height) / 2,
                                  width: cw, height: clockLabel.frame.height)
        modeLabel.sizeToFit()
        let mw = modeLabel.frame.width
        modeLabel.frame = CGRect(x: clockLabel.frame.minX - mw - 18, y: (bounds.height - modeLabel.frame.height) / 2,
                                 width: mw, height: modeLabel.frame.height)

        // Title is centered on the bar but must not overlap the side modules.
        titleLabel.sizeToFit()
        let leftLimit = pillsMaxX + 20
        let rightLimit = modeLabel.frame.minX - 20
        let iconW: CGFloat = titleIcon.image == nil ? 0 : 20
        let maxW = max(0, min(rightLimit - leftLimit - iconW, 2 * min(bounds.midX - leftLimit, rightLimit - bounds.midX) - iconW))
        let tw = min(titleLabel.frame.width, maxW)
        let total = tw + iconW
        let tx = bounds.midX - total / 2
        titleIcon.frame = CGRect(x: tx, y: (bounds.height - 14) / 2, width: 14, height: 14)
        titleLabel.frame = CGRect(x: tx + iconW, y: (bounds.height - titleLabel.frame.height) / 2,
                                  width: tw, height: titleLabel.frame.height)
    }
}

final class WorkspacePill: NSView {
    let index: Int
    var onClick: (() -> Void)?
    var state = BarView.WorkspaceState(index: 0, occupied: false, active: false) {
        didSet { needsDisplay = true; updateLabel() }
    }
    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        label.stringValue = "\(index)"
        label.font = Config.shared.monoUIFont(10.5, weight: .bold)
        label.alignment = .center
        addSubview(label)
        updateLabel()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let c = Config.shared
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if state.active {
            NSGradient(colors: c.activeBorder)?.draw(in: path, angle: 0)
        } else if hovering {
            c.surface1.setFill(); path.fill()
        } else if state.occupied {
            c.surface0.setFill(); path.fill()
        }
    }

    func refreshColors() {
        updateLabel()
        needsDisplay = true
    }

    private func updateLabel() {
        let c = Config.shared
        label.textColor = state.active ? c.crust : (state.occupied ? c.text : c.overlay0)
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        let h = label.frame.height
        label.frame = CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}
