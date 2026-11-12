import AppKit

/// Machines: Linux server VMs (Apple Virtualization.framework, Debian cloud images) — create,
/// start/stop, open a console tile or an SSH terminal, delete.
final class MachinesApp: NSObject, TileApp, NSTextFieldDelegate {
    let view: NSView
    var title: String { "Machines" }
    var symbolName: String { "server.rack" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private weak var manager: WindowManager?
    private var timer: Timer?
    private var vms: [VMInstance] = []
    private var selectedID: String?
    private var message: String?
    private var creating = false
    private var c: Config { .shared }

    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let heading = NSTextField(labelWithString: "Machines")
    private let summary = NSTextField(labelWithString: "")
    private let newButton = NSButton(title: "New VM", target: nil, action: nil)
    private let form = NewVMForm()
    private var rows: [VMRowView] = []
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let rowHeight: CGFloat = 52

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
        summary.lineBreakMode = .byTruncatingTail
        newButton.bezelStyle = .rounded
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newButton.imagePosition = .imageLeading
        newButton.target = self
        newButton.action = #selector(toggleForm)
        form.isHidden = true
        form.onCreate = { [weak self] spec in self?.create(spec) }
        form.onCancel = { [weak self] in self?.toggleForm() }
        empty.font = c.uiFont(13, weight: .regular)
        empty.stringValue = "No virtual machines yet. Click New VM to make a Debian 13 server: it boots in a few seconds, "
            + "logs you in as \(NSUserName().lowercased()) with your SSH keys, and gets its own IP address on this Mac."
        [heading, summary, newButton, form, empty].forEach(doc.addSubview)
        applyColors()
        NotificationCenter.default.addObserver(self, selector: #selector(vmsChanged), name: .vmsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)

        reload()
        // IP addresses appear a few seconds after boot; keep rows current while on screen.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else { return }
                self.rows.forEach { $0.refresh() }
            }
        }
    }

    // MARK: Data

    private func reload() {
        vms = VMManager.shared.all
        if let sel = selectedID, !vms.contains(where: { $0.id == sel }) { selectedID = nil }
        rows.forEach { $0.removeFromSuperview() }
        rows = vms.map { vm in
            let row = VMRowView(vm: vm)
            row.isSelected = vm.id == selectedID
            row.onSelect = { [weak self] in self?.select(vm) }
            row.onStartStop = { [weak self] in self?.startStop(vm) }
            row.onConsole = { [weak self] in self?.console(vm) }
            row.onSSH = { [weak self] in self?.ssh(vm) }
            row.onDelete = { [weak self] in self?.delete(vm) }
            doc.addSubview(row)
            return row
        }
        empty.isHidden = !vms.isEmpty || !form.isHidden
        updateSummary()
        layout()
    }

    private func updateSummary() {
        if let message { summary.stringValue = message; return }
        let running = vms.filter { $0.state.isActive }.count
        summary.stringValue = "\(vms.count) machine\(vms.count == 1 ? "" : "s") · \(running) running · "
            + "Debian 13 cloud images · Apple Virtualization"
    }

    @objc private func vmsChanged() {
        if vms.map(\.id) != VMManager.shared.all.map(\.id) { reload(); return }
        rows.forEach { $0.refresh() }
        updateSummary()
    }

    // MARK: Actions

    @objc private func toggleForm() {
        guard !creating else { return }
        form.isHidden.toggle()
        if !form.isHidden { form.reset(existing: Set(vms.map(\.id))); view.window?.makeFirstResponder(form.nameField) }
        empty.isHidden = !vms.isEmpty || !form.isHidden
        layout()
    }

    private func create(_ spec: NewVMForm.Spec) {
        creating = true
        form.setBusy(true, status: "Preparing…")
        let form = self.form
        Task { @MainActor in
            do {
                let config = try await VMLibrary.create(name: spec.name, cpus: spec.cpus, memoryMB: spec.memoryMB,
                                                        diskGB: spec.diskGB, imageID: "debian-13") { text, fraction in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let pct = fraction.map { String(format: " %.0f%%", $0 * 100) } ?? ""
                            form.setBusy(true, status: text + pct, fraction: fraction)
                        }
                    }
                }
                creating = false
                form.setBusy(false, status: "")
                form.isHidden = true
                selectedID = config.id
                reload()
                if let vm = VMManager.shared.instance(config.id) { console(vm) } // first boot: watch cloud-init
            } catch {
                creating = false
                form.setBusy(false, status: error.localizedDescription, isError: true)
            }
        }
    }

    private func select(_ vm: VMInstance) {
        selectedID = vm.id
        rows.forEach { $0.isSelected = $0.vm.id == vm.id }
        view.window?.makeFirstResponder(view)
    }

    private func startStop(_ vm: VMInstance) {
        message = nil
        if vm.state.isActive {
            if vm.state == .stopping { vm.forceStop() } else { vm.stop() }
        } else {
            vm.start()
        }
    }

    /// Focus the VM's console tile, or open one (which starts the VM if it's off).
    private func console(_ vm: VMInstance) {
        guard let manager else { return }
        if let tile = manager.allWindows.first(where: { ($0.app as? VMConsoleApp)?.vm === vm }) {
            manager.focus(tile)
            if !vm.state.isActive { vm.start() }
        } else {
            manager.open(VMConsoleApp(vm: vm)).appID = "vm-console"
        }
    }

    private func ssh(_ vm: VMInstance) {
        guard let ip = vm.ipAddress else {
            message = vm.state == .running ? "\(vm.config.name) has no IP address yet — give it a few seconds to boot."
                                            : "Start \(vm.config.name) first."
            updateSummary()
            return
        }
        message = nil
        updateSummary()
        // A separate known_hosts: recreated VMs reuse addresses with new host keys.
        let known = VMLibrary.directory.appendingPathComponent("known_hosts").path
        manager?.openTerminal(in: nil, command: "ssh -o StrictHostKeyChecking=accept-new "
            + "-o UserKnownHostsFile='\(known)' \(vm.config.user)@\(ip)")
    }

    private func delete(_ vm: VMInstance) {
        let alert = NSAlert()
        alert.messageText = "Delete \(vm.config.name)?"
        alert.informativeText = vm.state.isActive
            ? "Stop it first."
            : "Its disk (\(vm.config.diskGB) GB) and settings go to the Trash."
        if vm.state.isActive {
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try VMManager.shared.delete(vm)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    // MARK: Layout & colours

    @objc private func configChanged() {
        applyColors()
        rows.forEach { $0.applyColors() }
        form.applyColors()
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
        let width = max(380, min(1000, view.bounds.width - 40))
        let x0 = (view.bounds.width - width) / 2
        var y: CGFloat = 22
        heading.sizeToFit()
        heading.frame.origin = CGPoint(x: x0, y: y)
        newButton.sizeToFit()
        newButton.frame.origin = CGPoint(x: x0 + width - newButton.frame.width, y: y + 2)
        y += heading.frame.height + 2
        summary.frame = CGRect(x: x0, y: y, width: width, height: 18)
        y += 32
        if !form.isHidden {
            form.frame = CGRect(x: x0, y: y, width: width, height: NewVMForm.height)
            y += NewVMForm.height + 14
        }
        for row in rows {
            row.frame = CGRect(x: x0, y: y, width: width, height: rowHeight)
            y += rowHeight + 4
        }
        empty.frame = CGRect(x: x0, y: y + 6, width: width, height: 54)
        doc.frame = CGRect(x: 0, y: 0, width: max(0, scroll.contentSize.width), height: y + 70)
    }

    // MARK: TileApp

    func focus() { view.window?.makeFirstResponder(form.isHidden ? view : form.nameField) }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// ↑/↓ select, Enter opens the console, Space starts/stops.
    func handleKey(_ e: NSEvent) -> Bool {
        guard form.isHidden, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !vms.isEmpty else { return false }
        let i = vms.firstIndex { $0.id == selectedID }
        switch e.keyCode {
        case 125: select(vms[min((i ?? -1) + 1, vms.count - 1)]); return true
        case 126: select(vms[max((i ?? vms.count) - 1, 0)]); return true
        case 36, 76: if let i { console(vms[i]) }; return true
        case 49: if let i { startStop(vms[i]) }; return true
        default: return false
        }
    }
}

/// The inline "New VM" form.
final class NewVMForm: NSView {
    struct Spec { let name: String; let cpus: Int; let memoryMB: Int; let diskGB: Int }
    static let height: CGFloat = 132

    var onCreate: ((Spec) -> Void)?
    var onCancel: (() -> Void)?
    let nameField = NSTextField()
    private let cpus = NSPopUpButton()
    private let memory = NSPopUpButton()
    private let disk = NSPopUpButton()
    private let labels = ["Name", "CPUs", "Memory", "Disk"].map { NSTextField(labelWithString: $0) }
    private let note = NSTextField(labelWithString: "Debian 13 (trixie) · first VM downloads the 300 MB cloud image once")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var statusIsError = false
    private var existing: Set<String> = []

    private let memoryChoices = [1024, 2048, 4096, 8192, 16384]
    private let diskChoices = [10, 20, 40, 80, 160]

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        let c = Config.shared
        let cores = ProcessInfo.processInfo.activeProcessorCount
        cpus.addItems(withTitles: [1, 2, 4, 6, 8, 12].filter { $0 <= cores }.map { "\($0)" })
        cpus.selectItem(withTitle: "2")
        let ramMB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        memory.addItems(withTitles: memoryChoices.filter { $0 <= ramMB / 2 }.map { "\($0 / 1024) GB" })
        memory.selectItem(withTitle: "2 GB")
        disk.addItems(withTitles: diskChoices.map { "\($0) GB" })
        disk.selectItem(withTitle: "20 GB")
        nameField.placeholderString = "e.g. dev-server"
        nameField.font = c.uiFont(13, weight: .regular)
        nameField.target = self
        nameField.action = #selector(createTapped)
        labels.forEach { $0.font = c.uiFont(11, weight: .medium) }
        note.font = c.uiFont(11.5, weight: .regular)
        status.font = c.uiFont(12, weight: .regular)
        status.lineBreakMode = .byTruncatingTail
        progress.style = .bar
        progress.isIndeterminate = true
        progress.isHidden = true
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(createTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        ([nameField, cpus, memory, disk, note, status, progress, createButton, cancelButton] + labels).forEach(addSubview)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset(existing: Set<String>) {
        self.existing = existing
        var n = 1
        while existing.contains(n == 1 ? "debian" : "debian-\(n)") { n += 1 }
        nameField.stringValue = n == 1 ? "debian" : "debian-\(n)"
        setBusy(false, status: "")
    }

    func setBusy(_ busy: Bool, status text: String, fraction: Double? = nil, isError: Bool = false) {
        [nameField, cpus, memory, disk, createButton, cancelButton].forEach { $0.isEnabled = !busy }
        status.stringValue = text
        statusIsError = isError
        progress.isHidden = !busy
        if let fraction {
            progress.isIndeterminate = false
            progress.doubleValue = fraction * 100
        } else {
            progress.isIndeterminate = true
        }
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        note.isHidden = busy || !text.isEmpty
        applyColors()
    }

    func applyColors() {
        let c = Config.shared
        layer?.backgroundColor = c.base.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = c.accent.withAlphaComponent(0.5).cgColor
        labels.forEach { $0.textColor = c.overlay0 }
        note.textColor = c.overlay0
        status.textColor = statusIsError ? c.red : c.subtext
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 16
        var x = pad
        let widths: [CGFloat] = [max(160, bounds.width - pad * 2 - 3 * 110 - 3 * 12), 110, 110, 110]
        let controls: [NSView] = [nameField, cpus, memory, disk]
        for (i, control) in controls.enumerated() {
            labels[i].sizeToFit()
            labels[i].frame.origin = CGPoint(x: x, y: 14)
            control.frame = CGRect(x: x, y: 34, width: widths[i], height: i == 0 ? 24 : 26)
            x += widths[i] + 12
        }
        createButton.sizeToFit()
        cancelButton.sizeToFit()
        let by: CGFloat = bounds.height - 44
        createButton.frame.origin = CGPoint(x: bounds.width - pad - createButton.frame.width, y: by)
        cancelButton.frame.origin = CGPoint(x: createButton.frame.minX - 8 - cancelButton.frame.width, y: by)
        let textW = cancelButton.frame.minX - pad - 12
        note.frame = CGRect(x: pad, y: by + 6, width: textW, height: 18)
        status.frame = CGRect(x: pad, y: by - 6, width: textW, height: 18)
        progress.frame = CGRect(x: pad, y: by + 16, width: min(textW, 360), height: 12)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    @objc private func createTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { setBusy(false, status: "Give the VM a name.", isError: true); return }
        guard !existing.contains(VMLibrary.slug(name)) else {
            setBusy(false, status: "There's already a VM called \(VMLibrary.slug(name)).", isError: true); return
        }
        let mem = memoryChoices[safe: memory.indexOfSelectedItem] ?? 2048
        let gb = diskChoices[safe: disk.indexOfSelectedItem] ?? 20
        onCreate?(Spec(name: name, cpus: Int(cpus.titleOfSelectedItem ?? "2") ?? 2, memoryMB: mem, diskGB: gb))
    }

    @objc private func cancelTapped() { onCancel?() }
}

/// One VM in the list.
final class VMRowView: NSView {
    let vm: VMInstance
    var onSelect: (() -> Void)?
    var onStartStop: (() -> Void)?
    var onConsole: (() -> Void)?
    var onSSH: (() -> Void)?
    var onDelete: (() -> Void)?
    var isSelected = false { didSet { applyColors() } }

    private let dot = NSView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var hovering = false { didSet { applyColors() } }

    override var isFlipped: Bool { true }

    init(vm: VMInstance) {
        self.vm = vm
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let c = Config.shared
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        name.font = c.uiFont(13.5, weight: .semibold)
        detail.font = c.monoUIFont(11, weight: .regular)
        state.font = c.uiFont(12, weight: .medium)
        address.font = c.monoUIFont(12, weight: .regular)
        [name, detail, state, address].forEach { $0.lineBreakMode = .byTruncatingTail }
        [dot, name, detail, state, address].forEach(addSubview)
        func button(_ symbol: String, _ tip: String, _ action: Selector) {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
            addSubview(b)
            buttons.append(b)
        }
        button("play.fill", "Start", #selector(startStopTapped))
        button("terminal", "Console (serial) — works without networking", #selector(consoleTapped))
        button("key.horizontal", "SSH session in a new terminal tile", #selector(sshTapped))
        button("trash", "Delete", #selector(deleteTapped))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let cfg = vm.config
        name.stringValue = cfg.name
        let mem = cfg.memoryMB >= 1024 ? "\(cfg.memoryMB / 1024) GB" : "\(cfg.memoryMB) MB"
        detail.stringValue = "\(CloudImage.image(cfg.image)?.name ?? cfg.image) · \(cfg.cpus) CPU · \(mem) RAM · \(cfg.diskGB) GB disk"
        var label = vm.state.label
        if vm.state == .running, let t = vm.startedAt { label += " · " + StatsApp.duration(Date().timeIntervalSince(t)) }
        state.stringValue = label
        if case .failed(let m) = vm.state { state.toolTip = m } else { state.toolTip = nil }
        if vm.state == .running {
            address.stringValue = vm.ipAddress.map { "\(cfg.user)@\($0)" } ?? "waiting for IP…"
        } else {
            address.stringValue = ""
        }
        let active = vm.state.isActive
        buttons[0].image = NSImage(systemSymbolName: active ? "stop.fill" : "play.fill", accessibilityDescription: nil)
        buttons[0].toolTip = vm.state == .stopping ? "Force off" : active ? "Shut down" : "Start"
        buttons[2].isEnabled = vm.state == .running
        buttons[3].isEnabled = !active
        applyColors()
        needsLayout = true
    }

    func applyColors() {
        let c = Config.shared
        layer?.backgroundColor = (isSelected ? c.accent.withAlphaComponent(0.18)
                                  : hovering ? c.surface0.withAlphaComponent(0.6) : c.base).cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = c.accent.withAlphaComponent(0.6).cgColor
        let stateColor: NSColor
        switch vm.state {
        case .running: stateColor = c.accent2
        case .starting, .stopping: stateColor = c.yellow
        case .failed: stateColor = c.red
        case .stopped: stateColor = c.overlay0
        }
        dot.layer?.backgroundColor = stateColor.cgColor
        name.textColor = c.text
        detail.textColor = c.overlay0
        state.textColor = c.subtext
        address.textColor = c.accent
        buttons.forEach { $0.contentTintColor = $0.isEnabled ? c.subtext : c.surface1 }
        if buttons[3].isEnabled { buttons[3].contentTintColor = c.red.withAlphaComponent(0.85) }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let actionsW = CGFloat(buttons.count) * 30 + 6
        dot.frame = CGRect(x: 14, y: (h - 8) / 2, width: 8, height: 8)
        let x: CGFloat = 32
        let rest = w - x - actionsW - 12
        let mainW = max(180, rest * 0.5), stateW = max(90, rest * 0.2), addrW = rest - mainW - stateW
        name.sizeToFit()
        name.frame = CGRect(x: x, y: 8, width: mainW - 10, height: name.frame.height)
        detail.sizeToFit()
        detail.frame = CGRect(x: x, y: h - detail.frame.height - 8, width: mainW - 10, height: detail.frame.height)
        state.sizeToFit()
        state.frame = CGRect(x: x + mainW, y: (h - state.frame.height) / 2, width: stateW - 10, height: state.frame.height)
        address.sizeToFit()
        address.frame = CGRect(x: x + mainW + stateW, y: (h - address.frame.height) / 2, width: max(0, addrW - 10),
                               height: address.frame.height)
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
        if event.clickCount == 2 { onConsole?() } else { onSelect?() }
    }

    @objc private func startStopTapped() { onStartStop?() }
    @objc private func consoleTapped() { onConsole?() }
    @objc private func sshTapped() { onSSH?() }
    @objc private func deleteTapped() { onDelete?() }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
