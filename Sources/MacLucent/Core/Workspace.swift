import AppKit

enum LayoutMode {
    case tiled
    /// Windows keep their own frames and may overlap; the tiling tree is kept so switching
    /// back to tiled restores the previous arrangement.
    case floating
}

@MainActor
final class Workspace {
    let index: Int
    var mode: LayoutMode = .tiled
    let tree = LayoutTree()
    let view: WorkspaceView
    var focused: TileWindow?
    /// Most-recently-focused last.
    var history: [TileWindow] = []
    var fullscreen: TileWindow?

    var windows: [TileWindow] { tree.windows }
    var isEmpty: Bool { tree.isEmpty }

    init(index: Int) {
        self.index = index
        self.view = WorkspaceView()
        view.workspace = self
    }

    func noteFocused(_ w: TileWindow) {
        history.removeAll { $0 === w }
        history.append(w)
        focused = w
    }

    func forget(_ w: TileWindow) {
        history.removeAll { $0 === w }
        if focused === w { focused = nil }
        if fullscreen === w { fullscreen = nil }
    }
}

/// Container for one workspace's windows. Handles drag-resizing via the gaps between windows
/// and shows a hint when empty.
final class WorkspaceView: NSView {
    weak var workspace: Workspace?
    var onLayoutChange: (() -> Void)?
    private var dragging: Divider?
    private var edgeDrag: EdgeDrag?
    /// Called when a floating window starts being resized from its edge.
    var onFloatingEdgeDrag: ((TileWindow) -> Void)?
    /// Width of the grab zone just outside a floating window's border.
    private let edgeZone: CGFloat = 8

    private struct EdgeDrag {
        let window: TileWindow
        let left, right, top, bottom: Bool
        let startFrame: CGRect
        let startPoint: CGPoint
    }
    private let hint = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        buildHint()
        hint.alignment = .center
        addSubview(hint)
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)
    }

    @objc private func configChanged() {
        buildHint()
        updateHint()
    }

    /// The "empty workspace" hint, showing shortcuts with the current modifier key.
    private func buildHint() {
        let c = Config.shared
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 6
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "mac-lucent\n", attributes: [
            .font: NSFont.systemFont(ofSize: 34, weight: .ultraLight), .foregroundColor: c.text.withAlphaComponent(0.55), .paragraphStyle: para]))
        // The first couple of apps with shortcuts (from the registry), then the launcher and help.
        let apps = AppRegistry.apps.filter { $0.shortcut != nil && !$0.singleInstance }.prefix(2)
            .map { ("⌘ \($0.shortcut!.label)", $0.name.lowercased()) }
        let rows = Array(apps) + [("⌘ D", "launcher"), ("⌘ /", "keybindings")]
        for (k, v) in rows {
            s.append(NSAttributedString(string: "\(c.shortcut(k))  ", attributes: [
                .font: c.monoUIFont(13, weight: .semibold), .foregroundColor: c.accent.withAlphaComponent(0.8), .paragraphStyle: para]))
            s.append(NSAttributedString(string: "\(v)\n", attributes: [
                .font: c.uiFont(13, weight: .regular), .foregroundColor: c.subtext.withAlphaComponent(0.6), .paragraphStyle: para]))
        }
        hint.attributedStringValue = s
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateHint() {
        hint.isHidden = !(workspace?.isEmpty ?? true)
        hint.sizeToFit()
        hint.frame.origin = CGPoint(x: (bounds.width - hint.frame.width) / 2, y: (bounds.height - hint.frame.height) / 2)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateHint()
    }

    // MARK: divider dragging

    private var isFloating: Bool { workspace?.mode == .floating && workspace?.fullscreen == nil }

    private func divider(at p: CGPoint) -> Divider? {
        guard workspace?.fullscreen == nil, workspace?.mode == .tiled else { return nil }
        return workspace?.tree.dividers.last { $0.rect.contains(p) }
    }

    /// Floating windows, front-most first.
    private var floatingWindowsFrontFirst: [TileWindow] {
        subviews.reversed().compactMap { $0 as? TileWindow }.filter { !$0.isHidden }
    }

    /// The floating window whose edge zone contains `p`, unless another window covers `p`.
    private func edgeHit(at p: CGPoint) -> EdgeDrag? {
        guard isFloating else { return nil }
        for w in floatingWindowsFrontFirst {
            let f = w.frame
            if f.contains(p) { return nil }
            if f.insetBy(dx: -edgeZone, dy: -edgeZone).contains(p) {
                return EdgeDrag(window: w, left: p.x < f.minX, right: p.x > f.maxX,
                                top: p.y < f.minY, bottom: p.y > f.maxY, startFrame: f, startPoint: p)
            }
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if divider(at: local) != nil || edgeHit(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        if isFloating {
            // Back-most first, so cursor rects of front windows win where zones overlap.
            for w in floatingWindowsFrontFirst.reversed() {
                let f = w.frame, z = edgeZone
                addCursorRect(CGRect(x: f.minX - z, y: f.minY, width: z, height: f.height), cursor: .resizeLeftRight)
                addCursorRect(CGRect(x: f.maxX, y: f.minY, width: z, height: f.height), cursor: .resizeLeftRight)
                addCursorRect(CGRect(x: f.minX, y: f.minY - z, width: f.width, height: z), cursor: .resizeUpDown)
                addCursorRect(CGRect(x: f.minX, y: f.maxY, width: f.width, height: z), cursor: .resizeUpDown)
            }
            return
        }
        for d in workspace?.tree.dividers ?? [] {
            addCursorRect(d.rect, cursor: d.node.stacked ? .resizeUpDown : .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let e = edgeHit(at: p) {
            edgeDrag = e
            onFloatingEdgeDrag?(e.window)
            return
        }
        dragging = divider(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        if let e = edgeDrag {
            let p = convert(event.locationInWindow, from: nil)
            let dx = p.x - e.startPoint.x, dy = p.y - e.startPoint.y
            var f = e.startFrame
            let minW = TileWindow.minFloatingSize.width, minH = TileWindow.minFloatingSize.height
            if e.left { let x = min(f.maxX - minW, f.minX + dx); f.size.width = f.maxX - x; f.origin.x = x }
            if e.right { f.size.width = max(minW, f.width + dx) }
            if e.top { let y = min(f.maxY - minH, f.minY + dy); f.size.height = f.maxY - y; f.origin.y = y }
            if e.bottom { f.size.height = max(minH, f.height + dy) }
            e.window.floatFrame = f.integral
            e.window.frame = f.integral
            return
        }
        guard let d = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let r = d.region
        let ratio = d.node.stacked ? (p.y - r.minY) / r.height : (p.x - r.minX) / r.width
        d.node.ratio = min(0.9, max(0.1, ratio))
        onLayoutChange?()
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        edgeDrag = nil
        window?.invalidateCursorRects(for: self)
    }
}
