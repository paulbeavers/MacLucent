import AppKit

/// Ports: what's listening on TCP ports right now — dev servers, databases, local tools — with
/// actions to open each in a browser tile, open a terminal in its folder, or stop it.
final class PortsApp: NSObject, TileApp {
    let view: NSView
    var title: String { "Ports" }
    var symbolName: String { "network" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private weak var manager: WindowManager?
    private var timer: Timer?
    private var ports: [ListeningPort] = []
    private var showAll = false
    private var selectedKey: String?
    private var c: Config { .shared }

    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let heading = NSTextField(labelWithString: "Ports")
    private let summary = NSTextField(labelWithString: "")
    private let systemToggle = NSButton(checkboxWithTitle: "Show all", target: nil, action: nil)
    private let header = PortRowView(header: true)
    private var rows: [PortRowView] = []
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let rowHeight: CGFloat = 46

    init(manager: WindowManager?) {
        self.manager = manager
        let root = FlippedView()
        view = root
        super.init()
        root.wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        root.addSubview(scroll)
        root.onLayout = { [weak self] in self?.layout() }

        heading.font = c.uiFont(22, weight: .semibold)
        summary.font = c.uiFont(12.5, weight: .regular)
        systemToggle.target = self
        systemToggle.action = #selector(toggleSystem)
        empty.font = c.uiFont(13, weight: .regular)
        empty.stringValue = "No dev servers listening. Start one (npm run dev, rails s, python -m http.server…) and it shows up here — or tick Show all."
        [heading, summary, systemToggle, header, empty].forEach(doc.addSubview)
        applyColors()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else { return }
                self.refresh()
            }
        }
    }

    // MARK: Data

    private func key(_ p: ListeningPort) -> String { "\(p.pid):\(p.port)" }

    private func refresh() {
        let all = PortScanner.scan()
        let visible = showAll ? all : all.filter(\.isDev)
        guard visible != ports || rows.isEmpty != visible.isEmpty else {
            for (row, p) in zip(rows, ports) { row.configure(p) } // keep "running" times current
            updateSummary(all)
            return
        }
        ports = visible
        if let sel = selectedKey, !ports.contains(where: { key($0) == sel }) { selectedKey = nil }
        rebuildRows()
        updateSummary(all)
        layout()
    }

    private func updateSummary(_ all: [ListeningPort]) {
        let hidden = showAll ? 0 : all.count - ports.count
        var text = "\(ports.count) listening"
        if hidden > 0 { text += " · \(hidden) background app & macOS port\(hidden == 1 ? "" : "s") hidden (Show all)" }
        summary.stringValue = text + " · refreshes every 2 s"
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = ports.map { p in
            let row = PortRowView(header: false)
            row.configure(p)
            row.isSelected = key(p) == selectedKey
            row.onSelect = { [weak self] in self?.select(p) }
            row.onOpen = { [weak self] in self?.open(p) }
            row.onTerminal = { [weak self] in self?.terminal(p) }
            row.onStop = { [weak self] in self?.stop(p) }
            doc.addSubview(row)
            return row
        }
        empty.isHidden = !ports.isEmpty
        header.isHidden = ports.isEmpty
    }

    @objc private func toggleSystem() {
        showAll = systemToggle.state == .on
        ports = []
        refresh()
    }

    // MARK: Actions

    private func select(_ p: ListeningPort) {
        selectedKey = key(p)
        for (row, port) in zip(rows, ports) { row.isSelected = key(port) == selectedKey }
        view.window?.makeFirstResponder(view)
    }

    private func open(_ p: ListeningPort) {
        let host = p.address == "localhost" || p.address == "*" ? "localhost" : p.address
        manager?.openURL("http://\(host.contains(":") ? "[\(host)]" : host):\(p.port)")
    }

    private func terminal(_ p: ListeningPort) {
        manager?.openTerminal(in: p.directory)
    }

    /// SIGTERM; if it's still running after a moment, offer SIGKILL.
    private func stop(_ p: ListeningPort) {
        let alert = NSAlert()
        alert.messageText = "Stop \(p.name) on port \(p.port)?"
        alert.informativeText = "\(p.command)\nPID \(p.pid)"
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        kill(p.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if kill(p.pid, 0) == 0 { // still alive
                let again = NSAlert()
                again.messageText = "\(p.name) is still running"
                again.informativeText = "It didn't quit when asked. Force it to stop?"
                again.addButton(withTitle: "Force Stop")
                again.addButton(withTitle: "Cancel")
                if again.runModal() == .alertFirstButtonReturn { kill(p.pid, SIGKILL) }
            }
            self.ports = []
            self.refresh()
        }
    }

    // MARK: Layout & colours

    @objc private func configChanged() {
        applyColors()
        rows.forEach { $0.applyColors() }
        header.applyColors()
    }

    private func applyColors() {
        view.appearance = c.appearance
        view.layer?.backgroundColor = c.mantle.cgColor
        heading.textColor = c.text
        summary.textColor = c.subtext
        empty.textColor = c.overlay0
    }

    private func layout() {
        scroll.frame = view.bounds
        let width = max(360, min(1000, view.bounds.width - 40))
        let x0 = (view.bounds.width - width) / 2
        var y: CGFloat = 22
        heading.sizeToFit()
        heading.frame.origin = CGPoint(x: x0, y: y)
        systemToggle.sizeToFit()
        systemToggle.frame.origin = CGPoint(x: x0 + width - systemToggle.frame.width, y: y + 6)
        y += heading.frame.height + 2
        summary.frame = CGRect(x: x0, y: y, width: width, height: 18)
        y += 34
        header.frame = CGRect(x: x0, y: y, width: width, height: 26)
        y += 28
        for row in rows {
            row.frame = CGRect(x: x0, y: y, width: width, height: rowHeight)
            y += rowHeight + 4
        }
        empty.frame = CGRect(x: x0, y: y + 10, width: width, height: 40)
        doc.frame = CGRect(x: 0, y: 0, width: max(0, scroll.contentSize.width), height: y + 60)
    }

    // MARK: TileApp

    func focus() { view.window?.makeFirstResponder(view) }

    func shutdown() {
        timer?.invalidate()
        timer = nil
    }

    /// ↑/↓ select, Enter opens the selected port in a browser tile.
    func handleKey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, !ports.isEmpty else { return false }
        let i = ports.firstIndex { key($0) == selectedKey }
        switch e.keyCode {
        case 125: select(ports[min((i ?? -1) + 1, ports.count - 1)]); return true
        case 126: select(ports[max((i ?? ports.count) - 1, 0)]); return true
        case 36, 76: if let i { open(ports[i]) }; return true
        default: return false
        }
    }
}

/// One port (or the column header).
final class PortRowView: NSView {
    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?
    var onTerminal: (() -> Void)?
    var onStop: (() -> Void)?
    var isSelected = false { didSet { applyColors() } }

    private let isHeader: Bool
    private let port = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let command = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let uptime = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var hovering = false { didSet { applyColors() } }

    override var isFlipped: Bool { true }

    init(header: Bool) {
        isHeader = header
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let c = Config.shared
        [port, address, name, command, folder, uptime].forEach {
            $0.lineBreakMode = .byTruncatingMiddle
            addSubview($0)
        }
        if header {
            port.stringValue = "Port"; address.stringValue = "Address"; name.stringValue = "Process"
            folder.stringValue = "Folder"; uptime.stringValue = "Running"
            [port, address, name, folder, uptime].forEach { $0.font = c.uiFont(11, weight: .medium) }
            command.isHidden = true
        } else {
            port.font = c.monoUIFont(15, weight: .semibold)
            address.font = c.monoUIFont(11.5, weight: .regular)
            name.font = c.uiFont(13, weight: .semibold)
            command.font = c.monoUIFont(11, weight: .regular)
            folder.font = c.uiFont(12, weight: .regular)
            uptime.font = c.monoUIFont(11.5, weight: .regular)
            func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
                let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
                b.isBordered = false
                b.toolTip = tip
                b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
                addSubview(b)
                buttons.append(b)
                return b
            }
            _ = button("safari", "Open in a browser tile", #selector(openTapped))
            _ = button("terminal", "Open a terminal in this folder", #selector(terminalTapped))
            _ = button("stop.circle", "Stop this process", #selector(stopTapped))
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ p: ListeningPort) {
        port.stringValue = "\(p.port)"
        address.stringValue = p.address == "*" ? "all interfaces" : p.address
        address.toolTip = p.isLocalOnly ? "Only reachable from this Mac" : "Reachable from your network"
        name.stringValue = p.name
        command.stringValue = p.command
        command.toolTip = p.command
        let home = NSHomeDirectory()
        let dir = p.directory.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 } ?? "–"
        folder.stringValue = dir
        folder.toolTip = p.directory
        uptime.stringValue = p.started.map { StatsApp.duration(Date().timeIntervalSince($0)) } ?? "–"
        buttons[1].isEnabled = p.directory != nil
    }

    func applyColors() {
        let c = Config.shared
        if isHeader {
            layer?.backgroundColor = NSColor.clear.cgColor
            [port, address, name, folder, uptime].forEach { $0.textColor = c.overlay0 }
            return
        }
        layer?.backgroundColor = (isSelected ? c.accent.withAlphaComponent(0.18)
                                  : hovering ? c.surface0.withAlphaComponent(0.6) : c.base).cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = c.accent.withAlphaComponent(0.6).cgColor
        port.textColor = c.accent
        address.textColor = c.subtext
        name.textColor = c.text
        command.textColor = c.overlay0
        folder.textColor = c.subtext
        uptime.textColor = c.subtext
        buttons.forEach { $0.contentTintColor = $0.isEnabled ? c.subtext : c.surface1 }
        buttons.last?.contentTintColor = c.red.withAlphaComponent(0.85)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // Columns: port | address | process + command | folder | running | actions
        let actionsW: CGFloat = isHeader ? 96 : CGFloat(buttons.count) * 30 + 6
        let cols: [CGFloat] = [70, 110]
        var x: CGFloat = 12
        func place(_ f: NSTextField, _ width: CGFloat, top: Bool = false) {
            f.sizeToFit()
            let fh = f.frame.height
            let y = isHeader ? (h - fh) / 2 : (top ? 6 : (h - fh) / 2)
            f.frame = CGRect(x: x, y: y, width: max(0, width - 10), height: fh)
        }
        place(port, cols[0]); x += cols[0]
        place(address, cols[1]); x += cols[1]
        let rest = w - x - actionsW - 12
        let procW = max(140, rest * 0.42), folderW = max(100, rest * 0.38), upW = rest - procW - folderW
        if isHeader {
            place(name, procW)
        } else {
            name.sizeToFit()
            name.frame = CGRect(x: x, y: 6, width: procW - 10, height: name.frame.height)
            command.sizeToFit()
            command.frame = CGRect(x: x, y: h - command.frame.height - 6, width: procW - 10, height: command.frame.height)
        }
        x += procW
        place(folder, folderW); x += folderW
        place(uptime, upW); x += upW
        for (i, b) in buttons.enumerated() {
            b.frame = CGRect(x: w - actionsW + CGFloat(i) * 30, y: (h - 26) / 2, width: 26, height: 26)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        if isHeader { return }
        if event.clickCount == 2 { onOpen?() } else { onSelect?() }
    }

    @objc private func openTapped() { onOpen?() }
    @objc private func terminalTapped() { onTerminal?() }
    @objc private func stopTapped() { onStop?() }
}
