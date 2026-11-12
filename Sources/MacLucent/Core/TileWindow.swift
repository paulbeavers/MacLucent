import AppKit
import QuartzCore

/// The "window" decoration: rounded corners, gradient border, shadow. Hosts a TileApp's view.
final class TileWindow: NSView {
    let app: TileApp
    /// The AppRegistry id this window was launched from, if any.
    var appID: String?
    /// Position and size when its workspace is floating (nil until it has floated once).
    var floatFrame: CGRect?
    static let minFloatingSize = CGSize(width: 220, height: 140)
    private let gradient = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    private let content = NSView()
    /// Dims inactive windows. Must never take mouse events: it covers the whole app area, and
    /// AppKit hit-tests even fully transparent views — it used to swallow mouse-wheel scrolling.
    private let dim = PassthroughView()
    private var dimLayerAlpha: CGFloat = 0

    var isActive = false {
        didSet { if oldValue != isActive { updateBorder() } }
    }

    override var isFlipped: Bool { true }

    init(app: TileApp) {
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        addSubview(content)
        app.view.frame = content.bounds
        app.view.autoresizingMask = [.width, .height]
        content.addSubview(app.view)

        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.cgColor
        dim.alphaValue = 0
        dim.autoresizingMask = [.width, .height]
        content.addSubview(dim)

        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.mask = borderMask
        borderMask.fillColor = nil
        borderMask.strokeColor = NSColor.black.cgColor
        layer?.addSublayer(gradient)

        updateBorder()
        updateGeometry()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func configChanged() {
        updateBorder()
        updateGeometry()
    }

    // Clicks on the transparent border area should still reach the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    func updateGeometry() {
        let c = Config.shared
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bw = c.borderSize
        content.frame = bounds.insetBy(dx: bw, dy: bw)
        content.layer?.cornerRadius = max(0, c.rounding - bw)
        dim.frame = content.bounds
        app.view.frame = content.bounds
        gradient.frame = bounds
        let path = CGPath(roundedRect: bounds.insetBy(dx: bw / 2, dy: bw / 2),
                          cornerWidth: max(0, c.rounding - bw / 2), cornerHeight: max(0, c.rounding - bw / 2),
                          transform: nil)
        borderMask.path = path
        borderMask.lineWidth = bw
        if c.shadow, ProcessInfo.processInfo.environment["ML_NO_SHADOW"] == nil, let layer {
            layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: c.rounding, cornerHeight: c.rounding, transform: nil)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.45
            layer.shadowRadius = 14
            layer.shadowOffset = CGSize(width: 0, height: -4)
        } else {
            layer?.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    private func updateBorder() {
        let c = Config.shared
        CATransaction.begin()
        CATransaction.setAnimationDuration(c.animationsEnabled ? 0.18 : 0)
        if isActive {
            gradient.colors = c.activeBorder.map { $0.cgColor }
        } else {
            gradient.colors = [c.inactiveBorder.cgColor, c.inactiveBorder.cgColor]
        }
        CATransaction.commit()
        // Dark themes dim toward black; light ones fade toward their background — black over
        // a light window just turns it a muddy grey.
        dim.layer?.backgroundColor = (c.isLight ? c.base : NSColor.black).cgColor
        dim.alphaValue = isActive ? 0 : c.inactiveDim * (c.isLight ? 0.7 : 1)
    }
}

/// A view that is purely visual: it never receives mouse events.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
