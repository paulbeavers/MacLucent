import AppKit

/// Root view of the main window: wallpaper, workspace stage, bar and overlays.
final class DesktopView: NSView {
    let wallpaper = WallpaperView()
    let stage = NSView()
    let bar = BarView()
    private(set) var overlay: OverlayView?
    var onStageResize: (() -> Void)?
    var onOverlayDismissed: (() -> Void)?
    private var lastStageSize: NSSize = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {} // swallow keys on empty workspaces (no beep)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(wallpaper)
        stage.wantsLayer = true
        addSubview(stage)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let c = Config.shared
        let windowed = !(window?.styleMask.contains(.fullScreen) ?? true)
        let leftInset: CGFloat = windowed ? 72 : 0 // keep clear of the traffic lights
        wallpaper.frame = bounds
        bar.frame = CGRect(x: c.gapsOut + leftInset, y: c.barMargin,
                           width: bounds.width - c.gapsOut * 2 - leftInset, height: c.barHeight)
        let top = c.barMargin + c.barHeight
        stage.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        overlay?.frame = bounds
        if stage.frame.size != lastStageSize {
            lastStageSize = stage.frame.size
            onStageResize?()
        }
    }

    func showOverlay(_ o: OverlayView) {
        dismissOverlay(notify: false)
        overlay = o
        o.frame = bounds
        o.autoresizingMask = [.width, .height]
        o.onDismiss = { [weak self] in self?.dismissOverlay() }
        addSubview(o)
        o.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Config.shared.animationsEnabled ? 0.15 : 0
            o.animator().alphaValue = 1
        }
        o.didAppear()
    }

    func dismissOverlay(notify: Bool = true) {
        guard let o = overlay else { return }
        overlay = nil
        o.removeFromSuperview()
        if notify { onOverlayDismissed?() }
    }
}

/// Built-in wallpaper: deep gradient with soft colored glows. Uses an image if configured.
final class WallpaperView: NSView {
    private var image: NSImage? = Config.shared.wallpaperPath.flatMap { NSImage(contentsOfFile: $0) }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let image {
            // aspect-fill
            let s = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * s, height: image.size.height * s)
            image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height))
            return
        }
        NSGradient(colors: [NSColor(hex: 0x0B0B14), NSColor(hex: 0x161626), NSColor(hex: 0x10121F)])?
            .draw(in: bounds, angle: -60)
        let glows: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (0.18, 0.25, 0.55, NSColor(hex: 0x33CCFF, alpha: 0.22)),
            (0.85, 0.80, 0.60, NSColor(hex: 0x00FF99, alpha: 0.14)),
            (0.70, 0.15, 0.40, NSColor(hex: 0xCBA6F7, alpha: 0.16)),
            (0.30, 0.90, 0.45, NSColor(hex: 0xF5C2E7, alpha: 0.10)),
        ]
        let m = max(bounds.width, bounds.height)
        for (x, y, r, color) in glows {
            let g = NSGradient(colors: [color, color.withAlphaComponent(0)])
            g?.draw(fromCenter: CGPoint(x: bounds.width * x, y: bounds.height * y), radius: 0,
                    toCenter: CGPoint(x: bounds.width * x, y: bounds.height * y), radius: m * r, options: [])
        }
    }
}

/// Base class for modal overlays (launcher, help).
class OverlayView: NSView {
    var onDismiss: (() -> Void)?
    let panel = NSVisualEffectView()
    var panelFrame: CGRect { panel.frame }
    var panelSize: NSSize { NSSize(width: 520, height: 360) }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        let c = Config.shared
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = c.rounding + 4
        panel.layer?.cornerCurve = .continuous
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = c.borderSize
        panel.layer?.borderColor = c.accent.withAlphaComponent(0.7).cgColor
        addSubview(panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let s = panelSize
        panel.frame = CGRect(x: (bounds.width - s.width) / 2, y: max(60, bounds.height * 0.22),
                             width: s.width, height: s.height)
        layoutPanel()
    }

    func layoutPanel() {}
    func didAppear() {}
}
