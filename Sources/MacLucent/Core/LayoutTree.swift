import AppKit

enum Direction {
    case left, right, up, down
}

/// A node in a workspace's dwindle tree. A node is either a leaf holding a window,
/// or a split holding two children.
@MainActor
final class LayoutNode {
    weak var parent: LayoutNode?
    var window: TileWindow?
    var first: LayoutNode?
    var second: LayoutNode?
    /// true = children stacked top/bottom, false = side by side.
    var stacked = false
    var ratio: CGFloat = 0.5

    init(window: TileWindow? = nil) { self.window = window }

    var isLeaf: Bool { window != nil }

    func leaves() -> [LayoutNode] {
        if isLeaf { return [self] }
        return (first?.leaves() ?? []) + (second?.leaves() ?? [])
    }

    /// Copy the content (not the parent link) of `other` into self.
    func adopt(_ other: LayoutNode) {
        window = other.window
        first = other.first
        second = other.second
        stacked = other.stacked
        ratio = other.ratio
        first?.parent = self
        second?.parent = self
    }
}

/// A draggable boundary between the two children of a split.
struct Divider {
    let node: LayoutNode
    let rect: CGRect      // hit area, in workspace coordinates
    let region: CGRect    // the full rect of the split node
}

/// Dwindle layout: new windows split the focused window along its longer side.
@MainActor
final class LayoutTree {
    private(set) var root: LayoutNode?
    private(set) var rects: [ObjectIdentifier: CGRect] = [:]
    private(set) var dividers: [Divider] = []

    var windows: [TileWindow] { root?.leaves().compactMap { $0.window } ?? [] }
    var isEmpty: Bool { root == nil }

    /// Replace the whole tree (session restore).
    func setRoot(_ node: LayoutNode?) {
        root = node
        node?.parent = nil
        rects = [:]
    }

    func leaf(for window: TileWindow) -> LayoutNode? {
        root?.leaves().first { $0.window === window }
    }

    func insert(_ window: TileWindow, near target: TileWindow?) {
        guard let root else {
            self.root = LayoutNode(window: window)
            return
        }
        let node = target.flatMap { leaf(for: $0) } ?? root.leaves().last!
        let rect = rects[ObjectIdentifier(node.window!)] ?? .zero
        let old = LayoutNode(window: node.window)
        let new = LayoutNode(window: window)
        node.window = nil
        node.stacked = rect.height > rect.width
        node.ratio = 0.5
        node.first = old
        node.second = new
        old.parent = node
        new.parent = node
    }

    func remove(_ window: TileWindow) {
        guard let node = leaf(for: window) else { return }
        guard let parent = node.parent else {
            root = nil
            return
        }
        let sibling = parent.first === node ? parent.second! : parent.first!
        parent.adopt(sibling)
        rects[ObjectIdentifier(window)] = nil
    }

    func swap(_ a: TileWindow, _ b: TileWindow) {
        guard let la = leaf(for: a), let lb = leaf(for: b) else { return }
        la.window = b
        lb.window = a
    }

    func toggleSplit(of window: TileWindow) {
        guard let parent = leaf(for: window)?.parent else { return }
        parent.stacked.toggle()
    }

    /// Move the nearest matching divider in `direction`.
    func resize(_ window: TileWindow, direction: Direction, amount: CGFloat = 0.05) {
        let wantStacked = (direction == .up || direction == .down)
        var node = leaf(for: window)?.parent
        while let n = node, n.stacked != wantStacked { node = n.parent }
        guard let split = node else { return }
        let delta = (direction == .right || direction == .down) ? amount : -amount
        split.ratio = min(0.9, max(0.1, split.ratio + delta))
    }

    /// Compute the rect of every window inside `bounds` (a flipped coordinate space).
    func layout(in bounds: CGRect) {
        let c = Config.shared
        rects = [:]
        dividers = []
        guard let root else { return }
        place(root, in: bounds.insetBy(dx: c.gapsOut, dy: c.gapsOut), gap: c.gapsIn * 2)
    }

    private func place(_ node: LayoutNode, in rect: CGRect, gap: CGFloat) {
        if let w = node.window {
            rects[ObjectIdentifier(w)] = rect.integral
            return
        }
        guard let a = node.first, let b = node.second else { return }
        let r1: CGRect, r2: CGRect, hit: CGRect
        if node.stacked {
            let h = (rect.height - gap) * node.ratio
            r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
            r2 = CGRect(x: rect.minX, y: r1.maxY + gap, width: rect.width, height: rect.height - h - gap)
            hit = CGRect(x: rect.minX, y: r1.maxY - 2, width: rect.width, height: gap + 4)
        } else {
            let w = (rect.width - gap) * node.ratio
            r1 = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
            r2 = CGRect(x: r1.maxX + gap, y: rect.minY, width: rect.width - w - gap, height: rect.height)
            hit = CGRect(x: r1.maxX - 2, y: rect.minY, width: gap + 4, height: rect.height)
        }
        dividers.append(Divider(node: node, rect: hit, region: rect))
        place(a, in: r1, gap: gap)
        place(b, in: r2, gap: gap)
    }

    func rect(for window: TileWindow) -> CGRect? { rects[ObjectIdentifier(window)] }

    /// The geometrically nearest window in `direction` (flipped coordinates: up = smaller y).
    func neighbor(of window: TileWindow, _ direction: Direction) -> TileWindow? {
        guard let r = rect(for: window) else { return nil }
        let others = windows.filter { $0 !== window }.compactMap { w in rect(for: w).map { (w, $0) } }
        return LayoutTree.nearest(from: r, among: others, direction, overlapping: false)
    }

    /// Geometric neighbour search shared by tiled and floating layouts. Tiles never overlap, so
    /// tiled search requires the candidate to lie entirely beyond the edge; floating windows may
    /// overlap, so there it only requires the candidate's center to be in that direction.
    static func nearest(from r: CGRect, among candidates: [(TileWindow, CGRect)], _ direction: Direction,
                        overlapping: Bool) -> TileWindow? {
        let eps: CGFloat = 1
        var best: (TileWindow, CGFloat)?
        for (w, o) in candidates {
            let inDirection: Bool
            let overlap: CGFloat
            switch direction {
            case .left:  inDirection = overlapping ? o.midX < r.midX : o.maxX <= r.minX + eps; overlap = min(o.maxY, r.maxY) - max(o.minY, r.minY)
            case .right: inDirection = overlapping ? o.midX > r.midX : o.minX >= r.maxX - eps; overlap = min(o.maxY, r.maxY) - max(o.minY, r.minY)
            case .up:    inDirection = overlapping ? o.midY < r.midY : o.maxY <= r.minY + eps; overlap = min(o.maxX, r.maxX) - max(o.minX, r.minX)
            case .down:  inDirection = overlapping ? o.midY > r.midY : o.minY >= r.maxY - eps; overlap = min(o.maxX, r.maxX) - max(o.minX, r.minX)
            }
            guard inDirection else { continue }
            let dx = o.midX - r.midX, dy = o.midY - r.midY
            // Prefer windows that share an edge; break ties by center distance.
            let score = (overlap > 0 ? 0 : 100_000) + (dx * dx + dy * dy).squareRoot()
            if best == nil || score < best!.1 { best = (w, score) }
        }
        return best?.0
    }
}
