import AppKit

/// Live statistics about mac-lucent: version, windows, CPU and memory of the app and its
/// shells, and a few system numbers. Refreshes once per second.
final class StatsApp: NSObject, TileApp {
    let view: NSView
    var title: String { "Stats" }
    var symbolName: String { "chart.xyaxis.line" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private weak var manager: WindowManager?
    private let sampler = StatsSampler()
    private var timer: Timer?
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private var c: Config { .shared }

    // header
    private let heading = NSTextField(labelWithString: "mac-lucent")
    private let subheading = NSTextField(labelWithString: "")

    // tiles
    private let appCPU = StatTile(label: "mac-lucent CPU")
    private let appMemory = StatTile(label: "mac-lucent memory")
    private let shellCPU = StatTile(label: "Shells CPU")
    private let shellMemory = StatTile(label: "Shells memory")
    private let systemCPU = StatTile(label: "System CPU")
    private let systemMemory = StatTile(label: "System memory")
    private let windowsTile = StatTile(label: "Open windows")
    private let diskTile = StatTile(label: "Disk free")
    private var tiles: [StatTile] { [appCPU, appMemory, shellCPU, shellMemory, systemCPU, systemMemory, windowsTile, diskTile] }

    // tables
    private let workspacesTable = InfoTable(title: "Workspaces")
    private let terminalsTable = InfoTable(title: "Terminals")
    private let systemTable = InfoTable(title: "System")
    private let buildTable = InfoTable(title: "Build")

    private let launched = ProcStats.startTime(getpid()) ?? Date()

    init(manager: WindowManager?) {
        self.manager = manager
        let root = FlippedView()
        view = root
        super.init()
        root.wantsLayer = true
        root.layer?.backgroundColor = Config.shared.mantle.cgColor
        root.appearance = NSAppearance(named: .darkAqua)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        root.addSubview(scroll)
        root.onLayout = { [weak self] in self?.layout() }

        heading.font = c.uiFont(22, weight: .semibold)
        heading.textColor = c.text
        subheading.font = c.uiFont(12.5, weight: .regular)
        subheading.textColor = c.subtext
        [heading, subheading].forEach(doc.addSubview)
        tiles.forEach(doc.addSubview)
        [workspacesTable, terminalsTable, systemTable, buildTable].forEach(doc.addSubview)

        // Sparklines: CPU on a % axis with a floor so idle noise isn't magnified; memory auto-scaled.
        appCPU.sparkline.format = { String(format: "%.1f%%", $0) }
        appCPU.sparkline.minimumCeiling = 10
        shellCPU.sparkline.format = appCPU.sparkline.format
        shellCPU.sparkline.minimumCeiling = 10
        systemCPU.sparkline.format = appCPU.sparkline.format
        systemCPU.sparkline.minimumCeiling = 100
        appMemory.sparkline.format = { Self.bytes($0) }
        shellMemory.sparkline.format = { Self.bytes($0) }
        appMemory.sparkline.minimumCeiling = 64 * 1_048_576
        shellMemory.sparkline.minimumCeiling = 16 * 1_048_576
        for t in [systemMemory, windowsTile, diskTile] { t.sparkline.isHidden = true }
        systemMemory.showsMeter = true
        diskTile.showsMeter = true

        fillStatic()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Updating

    private func tick() {
        let terminals = manager?.allWindows.compactMap { $0.app as? TerminalApp } ?? []
        sampler.sample(terminals: terminals)
        // Skip the UI work while the tile isn't on screen (other workspace, app hidden).
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        refresh()
    }

    private func refresh() {
        let s = sampler
        let uptime = Self.duration(Date().timeIntervalSince(launched))
        subheading.stringValue = "\(Self.versionString) · up \(uptime) · pid \(getpid())"

        appCPU.set(value: s.appCPU.last.map { String(format: "%.1f%%", $0) } ?? "–", detail: "of one core", series: s.appCPU)
        appMemory.set(value: s.appMemory.last.map { Self.bytes($0) } ?? "–", detail: "physical footprint", series: s.appMemory)
        let shells = s.terminals.reduce(0) { $0 + $1.processes }
        shellCPU.set(value: s.shellCPU.last.map { String(format: "%.1f%%", $0) } ?? "–",
                     detail: "\(shells) process\(shells == 1 ? "" : "es")", series: s.shellCPU)
        shellMemory.set(value: s.shellMemory.last.map { Self.bytes($0) } ?? "–",
                        detail: "\(s.terminals.count) terminal\(s.terminals.count == 1 ? "" : "s")", series: s.shellMemory)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        systemCPU.set(value: s.systemCPU.last.map { String(format: "%.0f%%", $0) } ?? "–",
                      detail: "all \(cores) cores", series: s.systemCPU)

        let total = ProcessInfo.processInfo.physicalMemory
        let used = s.systemMemoryUsed
        systemMemory.set(value: Self.bytes(Double(used)), detail: "of \(Self.bytes(Double(total)))", series: [])
        systemMemory.meter.fraction = total > 0 ? Double(used) / Double(total) : 0

        if let d = HostStats.disk() {
            diskTile.set(value: Self.bytes(Double(d.free)), detail: "of \(Self.bytes(Double(d.total)))", series: [])
            diskTile.meter.fraction = d.total > 0 ? 1 - Double(d.free) / Double(d.total) : 0
        }

        let windows = manager?.allWindows ?? []
        var kinds: [String: Int] = [:]
        for w in windows { kinds[Self.kind(of: w), default: 0] += 1 }
        let kindText = kinds.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: " · ")
        windowsTile.set(value: "\(windows.count)", detail: kindText.isEmpty ? "none" : kindText, series: [])

        refreshWorkspaces()
        refreshTerminals()
        refreshSystem()
        layout()
    }

    private func refreshWorkspaces() {
        guard let wm = manager else { return }
        let rows = wm.workspaces.filter { !$0.isEmpty || $0 === wm.current }.map { ws -> [String] in
            var kinds: [String: Int] = [:]
            for w in ws.windows { kinds[Self.kind(of: w), default: 0] += 1 }
            let detail = kinds.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            let mode = ws.fullscreen != nil ? "fullscreen" : (ws.mode == .floating ? "floating" : "tiled")
            return ["\(ws.index)\(ws === wm.current ? "  •" : "")", mode, "\(ws.windows.count)", detail.isEmpty ? "empty" : detail]
        }
        workspacesTable.set(columns: ["Workspace", "Mode", "Windows", "Contents"], rows: rows, numeric: [2])
    }

    private func refreshTerminals() {
        let home = NSHomeDirectory()
        let rows = sampler.terminals.map { t -> [String] in
            let dir = t.directory.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 } ?? ""
            return [t.title, dir, "\(t.processes)", String(format: "%.1f%%", t.cpu), Self.bytes(Double(t.memory))]
        }
        terminalsTable.set(columns: ["Title", "Directory", "Processes", "CPU", "Memory"], rows: rows, numeric: [2, 3, 4],
                           empty: "No terminals open")
    }

    private func refreshSystem() {
        let p = ProcessInfo.processInfo
        let load = HostStats.loadAverage()
        systemTable.set(columns: ["", ""], rows: [
            ["macOS", p.operatingSystemVersionString],
            ["Chip", HostStats.sysctlString("machdep.cpu.brand_string") ?? "–"],
            ["Model", HostStats.sysctlString("hw.model") ?? "–"],
            ["Cores", "\(p.activeProcessorCount)"],
            ["Memory", Self.bytes(Double(p.physicalMemory))],
            ["Load average", String(format: "%.2f  %.2f  %.2f", load.0, load.1, load.2)],
            ["System uptime", Self.duration(p.systemUptime)],
        ], headerless: true)
    }

    private func fillStatic() {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = info["MLGitCommit"] as? String ?? "dev build"
        buildTable.set(columns: ["", ""], rows: [
            ["Version", Self.versionString],
            ["Commit", commit],
            ["SwiftTerm", info["MLSwiftTermVersion"] as? String ?? "–"],
            ["Bundle", Bundle.main.bundlePath.hasSuffix(".app") ? (Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath : "not bundled (swift run)"],
            ["Settings", (Config.settingsURL.path as NSString).abbreviatingWithTildeInPath],
            ["Shell", TerminalApp.shellPath],
        ], headerless: true)
    }

    // MARK: Layout

    private func layout() {
        scroll.frame = view.bounds
        let width = max(300, min(980, view.bounds.width - 40))
        let x0 = (view.bounds.width - width) / 2
        var y: CGFloat = 22
        heading.sizeToFit()
        heading.frame.origin = CGPoint(x: x0, y: y)
        y += heading.frame.height + 2
        subheading.frame = CGRect(x: x0, y: y, width: width, height: 18)
        y += 32

        let gap: CGFloat = 12
        let columns = max(1, min(4, Int((width + gap) / (210 + gap))))
        let tileW = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let tileH: CGFloat = 112
        for (i, t) in tiles.enumerated() {
            let col = i % columns, row = i / columns
            t.frame = CGRect(x: x0 + CGFloat(col) * (tileW + gap), y: y + CGFloat(row) * (tileH + gap), width: tileW, height: tileH)
        }
        y += CGFloat((tiles.count + columns - 1) / columns) * (tileH + gap) + 12

        for table in [workspacesTable, terminalsTable] {
            table.frame = CGRect(x: x0, y: y, width: width, height: table.preferredHeight)
            y += table.preferredHeight + 18
        }
        // System and build side by side when there's room.
        if width >= 640 {
            let half = (width - gap) / 2
            systemTable.frame = CGRect(x: x0, y: y, width: half, height: systemTable.preferredHeight)
            buildTable.frame = CGRect(x: x0 + half + gap, y: y, width: half, height: buildTable.preferredHeight)
            y += max(systemTable.preferredHeight, buildTable.preferredHeight) + 18
        } else {
            for table in [systemTable, buildTable] {
                table.frame = CGRect(x: x0, y: y, width: width, height: table.preferredHeight)
                y += table.preferredHeight + 18
            }
        }
        doc.frame = CGRect(x: 0, y: 0, width: max(0, scroll.contentSize.width), height: y + 12)
    }

    // MARK: TileApp

    func focus() { view.window?.makeFirstResponder(scroll.documentView) }

    func shutdown() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Formatting

    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "dev"
        let b = info["CFBundleVersion"] as? String
        return b.map { "v\(v) (\($0))" } ?? "v\(v)"
    }

    static func bytes(_ v: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var x = v, i = 0
        while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
        return i == 0 ? "\(Int(x)) B" : String(format: x >= 100 ? "%.0f %@" : "%.1f %@", x, units[i])
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s % 60)s" }
        return "\(s)s"
    }

    /// Windows are grouped by their registry app's name ("terminal", "browser", …).
    static func kind(of w: TileWindow) -> String {
        AppRegistry.app(w.appID)?.name.lowercased() ?? "other"
    }
}

// MARK: - Components

/// Label, headline value, detail line, and a sparkline or meter.
final class StatTile: NSView {
    let sparkline = SparklineView()
    let meter = MeterView()
    var showsMeter = false { didSet { meter.isHidden = !showsMeter; needsLayout = true } }
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "–")
    private let detail = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init(label text: String) {
        super.init(frame: .zero)
        let c = Config.shared
        wantsLayer = true
        layer?.backgroundColor = c.base.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = c.surface0.cgColor
        label.stringValue = text
        label.font = c.uiFont(11.5, weight: .medium)
        label.textColor = c.subtext
        value.font = c.uiFont(22, weight: .semibold)
        value.textColor = c.text
        detail.font = c.uiFont(11, weight: .regular)
        detail.textColor = c.overlay0
        detail.lineBreakMode = .byTruncatingTail
        meter.isHidden = true
        [label, value, detail, sparkline, meter].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(value v: String, detail d: String, series: [Double]) {
        value.stringValue = v
        detail.stringValue = d
        sparkline.values = series
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let w = bounds.width - 2 * pad
        label.frame = CGRect(x: pad, y: 12, width: w, height: 15)
        value.sizeToFit()
        value.frame = CGRect(x: pad, y: 28, width: w, height: value.frame.height)
        detail.frame = CGRect(x: pad, y: 58, width: w, height: 15)
        sparkline.frame = CGRect(x: pad, y: 78, width: w, height: 24)
        meter.frame = CGRect(x: pad, y: 86, width: w, height: 8)
    }
}

/// Single-series trend line: muted 2px line, faint area, latest point in the accent,
/// and a hover readout of the value under the pointer.
final class SparklineView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var minimumCeiling: Double = 1
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    private var hoverIndex: Int?
    private let readout = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        readout.font = Config.shared.monoUIFont(10, weight: .medium)
        readout.textColor = Config.shared.text
        readout.drawsBackground = true
        readout.backgroundColor = Config.shared.crust
        readout.isHidden = true
        addSubview(readout)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Points span the full history width so the line grows in from the left at first.
    private func point(_ i: Int, _ v: Double, ceiling: Double) -> CGPoint {
        let n = max(StatsSampler.historyLength - 1, 1)
        let offset = StatsSampler.historyLength - values.count
        let x = CGFloat(i + offset) / CGFloat(n) * (bounds.width - 4) + 2
        let y = bounds.height - 2 - CGFloat(v / ceiling) * (bounds.height - 4)
        return CGPoint(x: x, y: y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard values.count >= 2 else { return }
        let c = Config.shared
        let ceiling = max(minimumCeiling, (values.max() ?? 0) * 1.15)
        let pts = values.enumerated().map { point($0.offset, $0.element, ceiling: ceiling) }

        let area = NSBezierPath()
        area.move(to: CGPoint(x: pts[0].x, y: bounds.height))
        pts.forEach { area.line(to: $0) }
        area.line(to: CGPoint(x: pts.last!.x, y: bounds.height))
        area.close()
        c.accent.withAlphaComponent(0.10).setFill()
        area.fill()

        let line = NSBezierPath()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.move(to: pts[0])
        pts.dropFirst().forEach { line.line(to: $0) }
        c.overlay0.setStroke()
        line.stroke()

        // Current value in the accent.
        let last = pts.last!
        c.accent.setFill()
        NSBezierPath(ovalIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)).fill()

        if let i = hoverIndex, values.indices.contains(i) {
            let p = pts[i]
            c.surface1.setStroke()
            let guide = NSBezierPath()
            guide.move(to: CGPoint(x: p.x, y: 0))
            guide.line(to: CGPoint(x: p.x, y: bounds.height))
            guide.lineWidth = 1
            guide.stroke()
            c.text.setFill()
            NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard values.count >= 2 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let n = max(StatsSampler.historyLength - 1, 1)
        let offset = StatsSampler.historyLength - values.count
        let i = Int((x - 2) / max(1, bounds.width - 4) * CGFloat(n) + 0.5) - offset
        hoverIndex = min(max(0, i), values.count - 1)
        let secondsAgo = values.count - 1 - hoverIndex!
        readout.stringValue = " \(format(values[hoverIndex!]))\(secondsAgo > 0 ? " · \(secondsAgo)s ago" : " · now") "
        readout.sizeToFit()
        let px = point(hoverIndex!, values[hoverIndex!], ceiling: 1).x
        readout.frame.origin = CGPoint(x: min(max(0, px - readout.frame.width / 2), bounds.width - readout.frame.width), y: -18)
        readout.isHidden = false
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        readout.isHidden = true
        needsDisplay = true
    }
}

/// 8px usage bar; the fill carries severity (accent → warning → critical).
final class MeterView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let c = Config.shared
        let r = bounds.height / 2
        let fill: NSColor = fraction >= 0.9 ? c.red : (fraction >= 0.75 ? NSColor(hex: 0xF9E2AF) : c.accent)
        fill.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let w = max(bounds.height, bounds.width * CGFloat(min(1, max(0, fraction))))
        fill.setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: r, yRadius: r).fill()
    }
}

/// A titled table of text rows with right-aligned numeric columns.
final class InfoTable: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private var columns: [String] = []
    private var rows: [[String]] = []
    private var numeric: Set<Int> = []
    private var headerless = false
    private var emptyText = ""
    private let rowHeight: CGFloat = 26

    override var isFlipped: Bool { true }

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = Config.shared.uiFont(14, weight: .semibold)
        titleLabel.textColor = Config.shared.text
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredHeight: CGFloat {
        28 + (headerless ? 0 : rowHeight) + CGFloat(max(rows.count, 1)) * rowHeight + 4
    }

    func set(columns: [String], rows: [[String]], numeric: Set<Int> = [], headerless: Bool = false, empty: String = "") {
        self.columns = columns
        self.rows = rows
        self.numeric = numeric
        self.headerless = headerless
        self.emptyText = empty
        needsDisplay = true
    }

    /// Column widths: numeric columns get a fixed width; text columns share the rest.
    private func columnRects() -> [(CGFloat, CGFloat)] {
        let numW: CGFloat = 92
        let textCols = columns.indices.filter { !numeric.contains($0) }
        let textW = (bounds.width - CGFloat(numeric.count) * numW) / CGFloat(max(textCols.count, 1))
        var x: CGFloat = 0
        var out: [(CGFloat, CGFloat)] = []
        for i in columns.indices {
            var w = numeric.contains(i) ? numW : textW
            if headerless && columns.count == 2 { w = i == 0 ? bounds.width * 0.38 : bounds.width * 0.62 }
            out.append((x, w))
            x += w
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Config.shared
        titleLabel.sizeToFit()
        titleLabel.frame.origin = .zero
        let rects = columnRects()
        var y: CGFloat = 28
        let para = { (align: NSTextAlignment) -> NSParagraphStyle in
            let p = NSMutableParagraphStyle()
            p.alignment = align
            p.lineBreakMode = .byTruncatingMiddle
            return p
        }
        func text(_ s: String, _ col: Int, _ y: CGFloat, color: NSColor, font: NSFont) {
            guard rects.indices.contains(col) else { return }
            let (x, w) = rects[col]
            let align: NSTextAlignment = numeric.contains(col) ? .right : .left
            let inset: CGFloat = 10
            (s as NSString).draw(in: CGRect(x: x + inset, y: y + 5, width: max(0, w - 2 * inset), height: rowHeight - 6),
                                 withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para(align)])
        }
        if !headerless {
            for (i, h) in columns.enumerated() { text(h, i, y, color: c.overlay0, font: c.uiFont(11, weight: .medium)) }
            y += rowHeight
            c.surface0.setFill()
            NSRect(x: 0, y: y - 1, width: bounds.width, height: 1).fill()
        }
        if rows.isEmpty {
            (emptyText as NSString).draw(at: CGPoint(x: 10, y: y + 5),
                                         withAttributes: [.font: c.uiFont(12, weight: .regular), .foregroundColor: c.overlay0])
            return
        }
        for (r, row) in rows.enumerated() {
            if r % 2 == 1 {
                c.base.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: rowHeight), xRadius: 6, yRadius: 6).fill()
            }
            for (i, cell) in row.enumerated() where i < rects.count {
                let isKey = headerless && i == 0
                text(cell, i, y, color: isKey ? c.subtext : c.text,
                     font: numeric.contains(i) ? c.monoUIFont(12, weight: .regular) : c.uiFont(12.5, weight: .regular))
            }
            y += rowHeight
        }
    }
}
