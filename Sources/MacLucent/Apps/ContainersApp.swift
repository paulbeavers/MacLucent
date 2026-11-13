import AppKit

/// Containers: Docker containers and images on this Mac (Docker Desktop, Colima, OrbStack,
/// Podman — anything serving the Docker API on a Unix socket). Live via the events stream.
final class ContainersApp: NSObject, TileApp {
    enum Tab: Int { case containers, images }

    let view: NSView
    var title: String { "Containers" }
    var symbolName: String { "shippingbox" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private weak var manager: WindowManager?
    private var client: DockerClient?
    private var events: DockerStream?
    private var pull: DockerStream?
    private var timer: Timer?
    private var reloadPending = false
    private var tab: Tab
    private var showStopped = false
    private var containers: [DockerContainer] = []
    private var images: [DockerImage] = []
    private var stats: [String: DockerStats] = [:]
    private var statsInFlight = false
    private var selectedID: String?
    private var message: String?
    private var messageIsError = false
    private var connected = false
    private var c: Config { .shared }

    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let heading = NSTextField(labelWithString: "Containers")
    private let tabs = NSSegmentedControl(labels: ["Containers", "Images"], trackingMode: .selectOne, target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let stoppedToggle = NSButton(checkboxWithTitle: "Show stopped", target: nil, action: nil)
    private let pullField = NSTextField()
    private let pullButton = NSButton(title: "Pull", target: nil, action: nil)
    private let pruneButton = NSButton(title: "Remove unused…", target: nil, action: nil)
    private let startDockerButton = NSButton(title: "Start Docker", target: nil, action: nil)
    private var rows: [NSView] = []
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let rowHeight: CGFloat = 50

    init(manager: WindowManager?, tab: Tab = .containers) {
        self.manager = manager
        self.tab = tab
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
        summary.lineBreakMode = .byTruncatingTail
        tabs.selectedSegment = tab.rawValue
        tabs.target = self
        tabs.action = #selector(tabChanged)
        stoppedToggle.target = self
        stoppedToggle.action = #selector(toggleStopped)
        pullField.placeholderString = "image to pull, e.g. postgres:17"
        pullField.font = c.uiFont(12.5, weight: .regular)
        pullField.target = self
        pullField.action = #selector(pullTapped)
        for b in [pullButton, pruneButton, startDockerButton] { b.bezelStyle = .rounded; b.target = self }
        pullButton.action = #selector(pullTapped)
        pruneButton.action = #selector(pruneTapped)
        startDockerButton.action = #selector(startDocker)
        empty.font = c.uiFont(13, weight: .regular)
        [heading, tabs, summary, stoppedToggle, pullField, pullButton, pruneButton, startDockerButton, empty].forEach(doc.addSubview)
        applyColors()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)

        connect()
        // Reconnect when Docker starts later, and refresh CPU/memory, while on screen.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else { return }
                guard self.connected else { self.connect(); return }
                // Status text ("Up 5 minutes") only changes between events; keep it current.
                if self.tab == .containers {
                    Task { @MainActor in await self.reload() }
                    self.refreshStats()
                }
            }
        }
    }

    // MARK: Connection & data

    private func connect() {
        guard let client = DockerClient.discover() else { setDisconnected(); return }
        self.client = client
        Task { @MainActor in
            guard (try? await client.request("GET", "/_ping", timeout: 3))?.ok == true else { setDisconnected(); return }
            connected = true
            startEvents()
            await reload()
            refreshStats()
        }
    }

    private func setDisconnected() {
        connected = false
        events?.cancel()
        events = nil
        containers = []
        images = []
        rebuildRows()
    }

    /// Docker's event stream: reload whenever a container or image changes.
    private func startEvents() {
        guard let client, events == nil else { return }
        let filters = #"{"type":["container","image"]}"#.urlQueryEscaped
        events = client.stream("GET", "/events?filters=\(filters)", onLine: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleReload() } }
        }, onEnd: { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.events != nil else { return } // cancelled by us
                    self.events = nil
                    self.setDisconnected() // daemon went away; the timer reconnects
                }
            }
        })
    }

    /// Events come in bursts (a compose up is dozens); coalesce them.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadPending = false
                Task { @MainActor in await self?.reload() }
            }
        }
    }

    private func reload() async {
        guard let client else { return }
        do {
            let cs = try await client.get("/containers/json?all=1", as: [DockerContainer].self)
            let ims = try await client.get("/images/json", as: [DockerImage].self)
            let sorted = cs.sorted { a, b in
                let pa = a.composeProject ?? "~", pb = b.composeProject ?? "~" // compose groups first
                return (pa, a.name) < (pb, b.name)
            }
            let newImages = ims.sorted { $0.created > $1.created }
            // Only the status text changed (the periodic refresh): update rows in place, so
            // hover and buttons aren't rebuilt every few seconds.
            func shape(_ c: DockerContainer) -> String { "\(c.id)|\(c.state)|\(c.ports.count)|\(c.image)" }
            let sameShape = sorted.map(shape) == containers.map(shape) && newImages == images
            containers = sorted
            images = newImages
            stats = stats.filter { id, _ in containers.contains { $0.id == id && $0.isRunning } }
            if sameShape && !rows.isEmpty {
                for case let row as ContainerRowView in rows {
                    if let ct = containers.first(where: { $0.id == row.container.id }) { row.columns[0].stringValue = ct.status }
                }
                updateSummary()
            } else {
                rebuildRows()
            }
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func refreshStats() {
        guard let client, !statsInFlight else { return }
        let running = containers.filter(\.isRunning).map(\.id)
        guard !running.isEmpty else { return }
        statsInFlight = true
        Task { @MainActor in
            // stream=false waits for two samples (≈1 s), which gives the CPU delta.
            await withTaskGroup(of: (String, DockerStats?).self) { group in
                for id in running {
                    group.addTask {
                        let r = try? await client.request("GET", "/containers/\(id)/stats?stream=false", timeout: 10)
                        return (id, r.flatMap { $0.ok ? DockerStats(json: $0.body) : nil })
                    }
                }
                for await (id, s) in group { if let s { stats[id] = s } }
            }
            statsInFlight = false
            for case let row as ContainerRowView in rows { row.stats = stats[row.container.id] }
        }
    }

    private var visibleContainers: [DockerContainer] {
        showStopped ? containers : containers.filter { $0.isRunning || $0.isPaused || $0.state == "restarting" }
    }

    // MARK: Rows

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        if connected {
            switch tab {
            case .containers:
                var lastProject: String?? = .none
                for ct in visibleContainers {
                    if lastProject != .some(ct.composeProject) {
                        lastProject = .some(ct.composeProject)
                        let title = ct.composeProject.map { "\($0)  ·  compose" } ?? "Standalone"
                        rows.append(GroupHeaderView(title: title))
                    }
                    let row = ContainerRowView(container: ct)
                    row.stats = stats[ct.id]
                    row.isSelected = ct.id == selectedID
                    row.onSelect = { [weak self] in self?.select(ct.id) }
                    row.onAction = { [weak self] action in self?.perform(action, on: ct) }
                    rows.append(row)
                }
            case .images:
                let inUse = Dictionary(grouping: containers, by: \.imageID).mapValues(\.count)
                for im in images {
                    let row = ImageRowView(image: im, containers: inUse[im.id] ?? 0)
                    row.isSelected = im.id == selectedID
                    row.onSelect = { [weak self] in self?.select(im.id) }
                    row.onAction = { [weak self] action in self?.perform(action, on: im) }
                    rows.append(row)
                }
            }
        }
        rows.forEach(doc.addSubview)
        updateChrome()
        layout()
    }

    private func updateChrome() {
        let onContainers = tab == .containers
        stoppedToggle.isHidden = !connected || !onContainers
        [pullField, pullButton, pruneButton].forEach { $0.isHidden = !connected || onContainers }
        startDockerButton.isHidden = connected || !FileManager.default.fileExists(atPath: "/Applications/Docker.app")
        tabs.isEnabled = connected

        if !connected {
            empty.stringValue = "Docker isn't running (no Docker socket found). Start Docker Desktop, Colima, OrbStack "
                + "or Podman and this connects by itself."
        } else if onContainers {
            empty.stringValue = containers.isEmpty
                ? "No containers yet. Run one from the Images tab, or with docker run / docker compose up in a terminal."
                : "No running containers — tick Show stopped to see the \(containers.count) stopped one\(containers.count == 1 ? "" : "s")."
        } else {
            empty.stringValue = "No images. Pull one above (e.g. postgres:17, redis, nginx)."
        }
        empty.isHidden = !rows.isEmpty
        updateSummary()
    }

    private func updateSummary() {
        summary.textColor = messageIsError && message != nil ? c.red : c.subtext
        if let message { summary.stringValue = message; return }
        guard connected else { summary.stringValue = "Not connected"; return }
        let socket = client.map { ($0.socketPath as NSString).abbreviatingWithTildeInPath } ?? ""
        switch tab {
        case .containers:
            let running = containers.filter(\.isRunning).count
            summary.stringValue = "\(running) running · \(containers.count - running) stopped · \(socket)"
        case .images:
            let total = images.reduce(Int64(0)) { $0 + $1.size }
            summary.stringValue = "\(images.count) images · \(Self.bytes(total)) · \(socket)"
        }
    }

    private func show(_ text: String?, error: Bool = false) {
        message = text
        messageIsError = error
        updateSummary()
    }

    private func select(_ id: String) {
        selectedID = id
        for case let row as SelectableRow in rows { row.isSelected = row.rowID == id }
        view.window?.makeFirstResponder(view)
    }

    // MARK: Container actions

    enum ContainerAction { case startStop, restart, pause, shell, logs, open, remove }
    enum ImageAction { case run, remove }

    private func perform(_ action: ContainerAction, on ct: DockerContainer) {
        guard let client else { return }
        let docker = DockerClient.cliPath
        switch action {
        case .shell:
            // bash when the image has it, else sh.
            manager?.openTerminal(in: nil, command: "'\(docker)' exec -it \(ct.name) sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
        case .logs:
            manager?.openTerminal(in: nil, command: "'\(docker)' logs -f --tail 500 \(ct.name)")
        case .open:
            if let port = ct.publishedPorts.first { manager?.openURL("http://localhost:\(port)") }
        case .remove:
            let alert = NSAlert()
            alert.messageText = "Remove container \(ct.name)?"
            alert.informativeText = "\(ct.image) · \(ct.status)\nIts filesystem changes are lost; named volumes are kept."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            api("Removing \(ct.name)…") { try await client.call("DELETE", "/containers/\(ct.id)") }
        case .startStop:
            if ct.isPaused {
                api("Resuming \(ct.name)…") { try await client.call("POST", "/containers/\(ct.id)/unpause") }
            } else if ct.isRunning {
                api("Stopping \(ct.name)…") { try await client.call("POST", "/containers/\(ct.id)/stop", timeout: 60) }
            } else {
                api("Starting \(ct.name)…") { try await client.call("POST", "/containers/\(ct.id)/start", timeout: 60) }
            }
        case .restart:
            api("Restarting \(ct.name)…") { try await client.call("POST", "/containers/\(ct.id)/restart", timeout: 60) }
        case .pause:
            api("Pausing \(ct.name)…") { try await client.call("POST", "/containers/\(ct.id)/pause") }
        }
    }

    private func perform(_ action: ImageAction, on im: DockerImage) {
        guard let client else { return }
        switch action {
        case .run:
            let ref = im.tags.first ?? im.shortID
            manager?.openTerminal(in: nil, command: "'\(DockerClient.cliPath)' run --rm -it \(ref)")
        case .remove:
            let alert = NSAlert()
            alert.messageText = "Remove image \(im.displayName)?"
            alert.informativeText = "\(im.shortID) · \(Self.bytes(im.size))"
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // By tag when it has exactly one (removes just that tag), else by id.
            let ref = im.tags.count == 1 ? im.tags[0] : im.id
            api("Removing \(im.displayName)…") { try await client.call("DELETE", "/images/\(ref.urlQueryEscaped)") }
        }
    }

    /// Run an API call, showing progress and any error in the summary line. The events stream
    /// refreshes the list.
    private func api(_ progress: String, _ work: @escaping () async throws -> Data) {
        show(progress)
        Task { @MainActor in
            do {
                _ = try await work()
                show(nil)
                await reload()
            } catch {
                show(error.localizedDescription, error: true)
            }
        }
    }

    // MARK: Images

    @objc private func pullTapped() {
        guard let client, pull == nil else { return }
        let ref = pullField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return }
        // "name[:tag]" (a registry port's colon comes before the last slash) or "name@digest".
        var image = ref, tag = "latest"
        if !ref.contains("@"), let colon = ref.lastIndex(of: ":"), !ref[colon...].contains("/") {
            image = String(ref[..<colon])
            tag = String(ref[ref.index(after: colon)...])
        }
        let path = ref.contains("@") ? "/images/create?fromImage=\(ref.urlQueryEscaped)"
                                     : "/images/create?fromImage=\(image.urlQueryEscaped)&tag=\(tag.urlQueryEscaped)"
        pullButton.isEnabled = false
        show("Pulling \(ref)…")
        var layers: [String: (current: Double, total: Double)] = [:]
        pull = client.stream("POST", path, onLine: { [weak self] line in
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let err = o["error"] as? String { self.show(err, error: true); return }
                    if let id = o["id"] as? String, let d = o["progressDetail"] as? [String: Any],
                       let total = (d["total"] as? NSNumber)?.doubleValue, total > 0 {
                        layers[id] = ((d["current"] as? NSNumber)?.doubleValue ?? 0, total)
                    }
                    let cur = layers.values.reduce(0) { $0 + $1.current }, tot = layers.values.reduce(0) { $0 + $1.total }
                    let pct = tot > 0 ? String(format: " %.0f%%", cur / tot * 100) : ""
                    let status = o["status"] as? String ?? ""
                    self.show("Pulling \(ref)…\(pct)  \(status)")
                }
            }
        }, onEnd: { [weak self] response, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pull = nil
                    self.pullButton.isEnabled = true
                    if let error { self.show(error.localizedDescription, error: true) }
                    else if let r = response, !r.ok { self.show(r.errorMessage, error: true) }
                    else if !self.messageIsError {
                        self.show("Pulled \(ref)")
                        self.pullField.stringValue = ""
                    }
                    Task { @MainActor in await self.reload() }
                }
            }
        })
    }

    /// Prune dangling (untagged) images, after showing what that frees.
    @objc private func pruneTapped() {
        guard let client else { return }
        let dangling = images.filter(\.isDangling)
        let alert = NSAlert()
        if dangling.isEmpty {
            alert.messageText = "No unused images"
            alert.informativeText = "Every image has a tag. Remove individual images with their trash button."
            alert.runModal()
            return
        }
        alert.messageText = "Remove \(dangling.count) untagged image\(dangling.count == 1 ? "" : "s")?"
        alert.informativeText = "Frees up to \(Self.bytes(dangling.reduce(0) { $0 + $1.size })). Images used by a container are kept."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let filters = #"{"dangling":["true"]}"#.urlQueryEscaped
        Task { @MainActor in
            do {
                let data = try await client.call("POST", "/images/prune?filters=\(filters)", timeout: 120)
                let freed = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["SpaceReclaimed"] as? NSNumber)?.int64Value ?? 0
                show("Freed \(Self.bytes(freed))")
                await reload()
            } catch {
                show(error.localizedDescription, error: true)
            }
        }
    }

    @objc private func startDocker() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
        show("Starting Docker Desktop…")
    }

    // MARK: Controls

    @objc private func tabChanged() {
        tab = Tab(rawValue: tabs.selectedSegment) ?? .containers
        selectedID = nil
        show(nil)
        rebuildRows()
        if tab == .containers { refreshStats() }
    }

    @objc private func toggleStopped() {
        showStopped = stoppedToggle.state == .on
        rebuildRows()
    }

    // MARK: Layout & colours

    @objc private func configChanged() {
        applyColors()
        for case let row as ThemedRow in rows { row.applyColors() }
    }

    private func applyColors() {
        view.appearance = c.appearance
        view.layer?.backgroundColor = c.mantle.cgColor
        heading.textColor = c.text
        empty.textColor = c.overlay0
        updateSummary()
    }

    private func layout() {
        scroll.frame = view.bounds
        let width = max(420, min(1100, view.bounds.width - 40))
        let x0 = (view.bounds.width - width) / 2
        var y: CGFloat = 22
        heading.sizeToFit()
        heading.frame.origin = CGPoint(x: x0, y: y)
        tabs.sizeToFit()
        tabs.frame.origin = CGPoint(x: x0 + width - tabs.frame.width, y: y + 3)
        y += heading.frame.height + 2
        summary.frame = CGRect(x: x0, y: y, width: width, height: 18)
        y += 30
        if !stoppedToggle.isHidden {
            stoppedToggle.sizeToFit()
            stoppedToggle.frame.origin = CGPoint(x: x0, y: y)
            y += 30
        }
        if !pullField.isHidden {
            pruneButton.sizeToFit()
            pullButton.sizeToFit()
            pruneButton.frame.origin = CGPoint(x: x0 + width - pruneButton.frame.width, y: y - 2)
            pullButton.frame.origin = CGPoint(x: pruneButton.frame.minX - 16 - pullButton.frame.width, y: y - 2)
            pullField.frame = CGRect(x: x0, y: y, width: min(360, pullButton.frame.minX - x0 - 8), height: 24)
            y += 38
        }
        if !startDockerButton.isHidden {
            startDockerButton.sizeToFit()
            startDockerButton.frame.origin = CGPoint(x: x0, y: y)
            y += 36
        }
        for row in rows {
            let h: CGFloat = row is GroupHeaderView ? 26 : rowHeight
            row.frame = CGRect(x: x0, y: y, width: width, height: h)
            y += h + 4
        }
        empty.frame = CGRect(x: x0, y: y + 6, width: width, height: 40)
        doc.frame = CGRect(x: 0, y: 0, width: max(0, scroll.contentSize.width), height: y + 60)
    }

    // MARK: TileApp

    func focus() { view.window?.makeFirstResponder(view) }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        let e = events
        events = nil // so onEnd doesn't treat it as a lost daemon
        e?.cancel()
        pull?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    var sessionState: JSONValue? { .object(["tab": .number(Double(tab.rawValue))]) }

    /// ↑/↓ select; Enter: shell into a container / run an image.
    func handleKey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !(view.window?.firstResponder is NSText) else { return false }
        let items = rows.compactMap { $0 as? SelectableRow }
        guard !items.isEmpty else { return false }
        let i = items.firstIndex { $0.rowID == selectedID }
        switch e.keyCode {
        case 125: select(items[min((i ?? -1) + 1, items.count - 1)].rowID); return true
        case 126: select(items[max((i ?? items.count) - 1, 0)].rowID); return true
        case 36, 76:
            if let i { items[i].activate() }
            return true
        default: return false
        }
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func age(_ unix: Int) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(unix)), relativeTo: Date())
    }
}

// MARK: - Rows

@MainActor protocol ThemedRow: AnyObject { func applyColors() }
@MainActor protocol SelectableRow: ThemedRow {
    var rowID: String { get }
    var isSelected: Bool { get set }
    func activate()
}

/// A compose project's heading.
final class GroupHeaderView: NSView, ThemedRow {
    private let label: NSTextField
    override var isFlipped: Bool { true }

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = Config.shared.uiFont(11.5, weight: .semibold)
        addSubview(label)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyColors() { label.textColor = Config.shared.overlay0 }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = CGPoint(x: 4, y: bounds.height - label.frame.height - 3)
    }
}

/// Shared row look: rounded, hover and selection, a status dot, title/subtitle, three text
/// columns and icon buttons.
class DockerRowView: NSView, SelectableRow {
    var rowID: String { "" }
    var onSelect: (() -> Void)?
    var isSelected = false { didSet { applyColors() } }

    let dot = NSView()
    let name = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let columns = (0..<3).map { _ in NSTextField(labelWithString: "") }
    var buttons: [NSButton] = []
    private var actions: [() -> Void] = []
    private var hovering = false { didSet { applyColors() } }
    var dotColor: NSColor { Config.shared.overlay0 }
    /// Relative widths of the three columns.
    var columnShares: [CGFloat] { [0.4, 0.35, 0.25] }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        let c = Config.shared
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        name.font = c.uiFont(13.5, weight: .semibold)
        detail.font = c.monoUIFont(11, weight: .regular)
        columns.forEach { $0.font = c.monoUIFont(11.5, weight: .regular) }
        ([name, detail] + columns).forEach { $0.lineBreakMode = .byTruncatingTail }
        ([dot, name, detail] + columns).forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    func addButton(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self,
                         action: #selector(buttonTapped(_:)))
        b.isBordered = false
        b.toolTip = tip
        b.tag = actions.count
        b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        addSubview(b)
        buttons.append(b)
        actions.append(action)
    }

    @objc private func buttonTapped(_ b: NSButton) { actions[b.tag]() }

    func activate() {}

    func applyColors() {
        let c = Config.shared
        layer?.backgroundColor = (isSelected ? c.accent.withAlphaComponent(0.18)
                                  : hovering ? c.surface0.withAlphaComponent(0.6) : c.base).cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = c.accent.withAlphaComponent(0.6).cgColor
        dot.layer?.backgroundColor = dotColor.cgColor
        name.textColor = c.text
        detail.textColor = c.overlay0
        columns[0].textColor = c.subtext
        columns[1].textColor = c.accent
        columns[2].textColor = c.subtext
        buttons.forEach { $0.contentTintColor = $0.isEnabled ? c.subtext : c.surface1 }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let actionsW = CGFloat(buttons.count) * 30 + 6
        dot.frame = CGRect(x: 14, y: (h - 8) / 2, width: 8, height: 8)
        var x: CGFloat = 32
        let rest = w - x - actionsW - 12
        let mainW = max(170, rest * 0.4)
        name.sizeToFit()
        name.frame = CGRect(x: x, y: 7, width: mainW - 10, height: name.frame.height)
        detail.sizeToFit()
        detail.frame = CGRect(x: x, y: h - detail.frame.height - 7, width: mainW - 10, height: detail.frame.height)
        x += mainW
        let colsW = rest - mainW
        for (i, col) in columns.enumerated() {
            let cw = colsW * columnShares[i]
            col.sizeToFit()
            col.frame = CGRect(x: x, y: (h - col.frame.height) / 2, width: max(0, cw - 10), height: col.frame.height)
            x += cw
        }
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
        if event.clickCount == 2 { activate() } else { onSelect?() }
    }
}

final class ContainerRowView: DockerRowView {
    let container: DockerContainer
    var onAction: ((ContainersApp.ContainerAction) -> Void)?
    var stats: DockerStats? { didSet { updateStats() } }
    override var rowID: String { container.id }

    override var dotColor: NSColor {
        let c = Config.shared
        switch container.state {
        case "running": return c.accent2
        case "paused", "restarting", "created": return c.yellow
        case "dead": return c.red
        default: return container.status.hasPrefix("Exited (0)") ? c.overlay0 : c.red.withAlphaComponent(0.7)
        }
    }

    init(container: DockerContainer) {
        self.container = container
        super.init(frame: .zero)
        let ct = container
        name.stringValue = ct.composeService.map { "\($0)  (\(ct.name))" } ?? ct.name
        detail.stringValue = ct.image.hasPrefix("sha256:") ? String(ct.image.dropFirst(7).prefix(12)) : ct.image
        detail.toolTip = ct.image
        columns[0].stringValue = ct.status
        columns[1].stringValue = ct.portsText
        columns[1].toolTip = ct.ports.map { "\($0.ip ?? "") \($0.publicPort.map(String.init) ?? "-")→\($0.privatePort)/\($0.type)" }
            .joined(separator: "\n")
        let active = ct.isRunning || ct.isPaused
        addButton(ct.isPaused ? "play.fill" : active ? "stop.fill" : "play.fill",
                  ct.isPaused ? "Resume" : active ? "Stop" : "Start") { [weak self] in self?.onAction?(.startStop) }
        addButton("arrow.clockwise", "Restart") { [weak self] in self?.onAction?(.restart) }
        addButton("terminal", "Shell in a terminal tile (docker exec)") { [weak self] in self?.onAction?(.shell) }
        addButton("doc.text", "Follow logs in a terminal tile") { [weak self] in self?.onAction?(.logs) }
        addButton("safari", "Open the first published port in a browser tile") { [weak self] in self?.onAction?(.open) }
        addButton("trash", "Remove") { [weak self] in self?.onAction?(.remove) }
        buttons[1].isEnabled = ct.isRunning
        buttons[2].isEnabled = ct.isRunning
        buttons[4].isEnabled = ct.isRunning && !ct.publishedPorts.isEmpty
        buttons[5].isEnabled = !active
        updateStats()
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var columnShares: [CGFloat] { [0.34, 0.33, 0.33] }

    private func updateStats() {
        guard let s = stats, container.isRunning else {
            columns[2].stringValue = container.isRunning ? "…" : ""
            return
        }
        columns[2].stringValue = String(format: "%.0f%%  ", s.cpuPercent) + ContainersApp.bytes(s.memoryBytes)
        columns[2].toolTip = String(format: "CPU %.1f%% · memory %@", s.cpuPercent, ContainersApp.bytes(s.memoryBytes))
            + (s.memoryLimit > 0 ? " of \(ContainersApp.bytes(s.memoryLimit))" : "")
    }

    override func activate() { if container.isRunning { onAction?(.shell) } }

    override func applyColors() {
        super.applyColors()
        let c = Config.shared
        if buttons.count > 5, buttons[5].isEnabled { buttons[5].contentTintColor = c.red.withAlphaComponent(0.85) }
        if !container.isRunning && !container.isPaused { name.textColor = c.subtext }
    }
}

final class ImageRowView: DockerRowView {
    let image: DockerImage
    var onAction: ((ContainersApp.ImageAction) -> Void)?
    private let containerCount: Int
    override var rowID: String { image.id }
    override var dotColor: NSColor {
        let c = Config.shared
        return containerCount > 0 ? c.accent2 : image.isDangling ? c.yellow : c.overlay0
    }

    init(image: DockerImage, containers: Int) {
        self.image = image
        containerCount = containers
        super.init(frame: .zero)
        name.stringValue = image.displayName
        let extra = image.tags.count > 1 ? "  +\(image.tags.count - 1) tag\(image.tags.count == 2 ? "" : "s")" : ""
        detail.stringValue = image.shortID + extra
        detail.toolTip = image.tags.joined(separator: "\n")
        columns[0].stringValue = ContainersApp.age(image.created)
        columns[1].stringValue = ContainersApp.bytes(image.size)
        columns[2].stringValue = containers > 0 ? "used by \(containers)" : image.isDangling ? "unused, untagged" : "unused"
        addButton("play.fill", "Run in a terminal tile (docker run --rm -it)") { [weak self] in self?.onAction?(.run) }
        addButton("trash", containers > 0 ? "In use — remove its containers first" : "Remove") { [weak self] in self?.onAction?(.remove) }
        buttons[1].isEnabled = containers == 0
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func activate() { onAction?(.run) }

    override func applyColors() {
        super.applyColors()
        let c = Config.shared
        columns[1].textColor = c.subtext
        if buttons.count > 1, buttons[1].isEnabled { buttons[1].contentTintColor = c.red.withAlphaComponent(0.85) }
    }
}
