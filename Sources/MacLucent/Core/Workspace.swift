import AppKit

@MainActor
final class Workspace {
    let index: Int
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
    private let hint = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let c = Config.shared
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 6
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "mac-lucent\n", attributes: [
            .font: NSFont.systemFont(ofSize: 34, weight: .ultraLight), .foregroundColor: c.text.withAlphaComponent(0.55), .paragraphStyle: para]))
        let rows = [("⌘ ↩", "terminal"), ("⌘ B", "browser"), ("⌘ D", "launcher"), ("⌘ /", "keybindings")]
        for (k, v) in rows {
            s.append(NSAttributedString(string: "\(k)  ", attributes: [
                .font: c.monoUIFont(13, weight: .semibold), .foregroundColor: c.accent.withAlphaComponent(0.8), .paragraphStyle: para]))
            s.append(NSAttributedString(string: "\(v)\n", attributes: [
                .font: c.uiFont(13, weight: .regular), .foregroundColor: c.subtext.withAlphaComponent(0.6), .paragraphStyle: para]))
        }
        hint.attributedStringValue = s
        hint.alignment = .center
        addSubview(hint)
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

    private func divider(at p: CGPoint) -> Divider? {
        guard workspace?.fullscreen == nil else { return nil }
        return workspace?.tree.dividers.last { $0.rect.contains(p) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if divider(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        for d in workspace?.tree.dividers ?? [] {
            addCursorRect(d.rect, cursor: d.node.stacked ? .resizeUpDown : .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = divider(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let r = d.region
        let ratio = d.node.stacked ? (p.y - r.minY) / r.height : (p.x - r.minX) / r.width
        d.node.ratio = min(0.9, max(0.1, ratio))
        onLayoutChange?()
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        window?.invalidateCursorRects(for: self)
    }
}
