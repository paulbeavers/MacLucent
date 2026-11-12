import AppKit
import SwiftTerm

/// A VM's serial console (hvc0) in a terminal tile. The VM keeps running when this closes.
final class VMConsoleApp: NSObject, TileApp, TerminalViewDelegate {
    let view: NSView
    let terminal: TerminalView
    let vm: VMInstance
    var title: String { "\(vm.config.name) — console" }
    var symbolName: String { "server.rack" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private var container: PaddedContainer { view as! PaddedContainer }
    private var filter = TerminalOutputFilter()
    private var listener: UUID?
    private var lastState: VMInstance.State
    private var zoom: CGFloat = 0
    private var appliedTheme = Config.shared.themeID

    init(vm: VMInstance) {
        self.vm = vm
        lastState = vm.state
        let c = Config.shared
        let box = PaddedContainer(blur: c.blur)
        box.tintColor = c.terminalPalette.base.withAlphaComponent(c.terminalOpacity)
        view = box
        terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()

        terminal.font = c.terminalFont()
        TerminalApp.applyTheme(to: terminal)
        terminal.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        terminal.optionAsMetaKey = true
        terminal.terminalDelegate = self
        box.content = terminal
        box.padding = 8
        box.addSubview(terminal)

        filter.onWindowOp = { [weak self] params in
            MainActor.assumeIsolated { self?.terminal.answerWindowOp(params) }
        }
        if !vm.consoleHistory.isEmpty { feed(vm.consoleHistory) }
        listener = vm.addConsoleListener { [weak self] data in self?.feed(data) }
        if !vm.state.isActive { vm.start() }
        if vm.state == .starting { status("Starting \(vm.config.name)…") }

        NotificationCenter.default.addObserver(self, selector: #selector(vmChanged), name: .vmsDidChange, object: vm.id)
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)
    }

    private func feed(_ data: Data) {
        let out = filter.filter(ArraySlice([UInt8](data)))
        if !out.isEmpty { terminal.feed(byteArray: out) }
    }

    /// A Lucent message in the console, dimmed so it isn't mistaken for guest output.
    private func status(_ text: String) {
        terminal.feed(text: "\r\n\u{1B}[2m[lucent] \(text)\u{1B}[0m\r\n")
    }

    @objc private func vmChanged() {
        let s = vm.state
        defer { lastState = s }
        guard s != lastState else { return }
        switch s {
        case .stopped: status("\(vm.config.name) is off. Press Enter to start it.")
        case .failed(let message): status("\(vm.config.name) stopped: \(message)")
        case .stopping: status("Shutting down…")
        case .starting: status("Starting \(vm.config.name)…")
        case .running: break
        }
    }

    @objc private func configChanged() {
        let c = Config.shared
        let font = c.terminalFont(size: max(7, c.terminalFontSize + zoom))
        if font != terminal.font { terminal.font = font }
        if c.themeID != appliedTheme {
            appliedTheme = c.themeID
            TerminalApp.applyTheme(to: terminal)
            terminal.needsDisplay = true
        }
        terminal.nativeBackgroundColor = c.terminalPalette.base.withAlphaComponent(c.terminalOpacity)
        container.tintColor = c.terminalPalette.base.withAlphaComponent(c.terminalOpacity)
        container.setBlur(c.blur)
    }

    // MARK: TileApp

    func focus() { terminal.window?.makeFirstResponder(terminal) }

    func shutdown() {
        if let listener { vm.removeConsoleListener(listener) }
        listener = nil
        terminal.terminalDelegate = nil
        NotificationCenter.default.removeObserver(self)
    }

    var sessionState: JSONValue? { nil } // VMs don't survive a quit; reopen from Machines

    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let mod = Config.shared.mod
        guard flags == mod || flags == [mod, .shift] else { return false }
        switch e.charactersIgnoringModifiers {
        case "=", "+": setZoom(zoom + 1)
        case "-", "_": setZoom(zoom - 1)
        case "0": setZoom(0)
        default: return false
        }
        return true
    }

    private func setZoom(_ z: CGFloat) {
        let base = Config.shared.terminalFontSize
        zoom = min(40, max(7, base + z)) - base
        terminal.font = Config.shared.terminalFont(size: base + zoom)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !vm.state.isActive {
            if data.contains(13) { vm.start() } // Enter starts a stopped VM
            return
        }
        vm.sendToConsole(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func bell(source: TerminalView) { NSSound.beep() }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
