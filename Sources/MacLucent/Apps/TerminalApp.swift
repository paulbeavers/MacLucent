import AppKit
import SwiftTerm

/// A terminal window running bash in a real PTY.
final class TerminalApp: NSObject, TileApp, LocalProcessTerminalViewDelegate {
    let view: NSView
    let terminal: LucentTerminalView
    private(set) var title = "bash"
    private(set) var currentDirectory: String?
    var symbolName: String { "terminal" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?
    /// Per-window zoom (⌘+/⌘−) on top of the configured font size.
    private var zoom: CGFloat = 0
    private var container: PaddedContainer { view as! PaddedContainer }
    private let padding: CGFloat = 8

    init(directory: String? = nil) {
        let c = Config.shared
        let effect = PaddedContainer(blur: c.blur)
        effect.tintColor = c.base.withAlphaComponent(c.terminalOpacity)
        view = effect

        terminal = LucentTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()

        terminal.font = c.terminalFont()
        Self.applyTheme(to: terminal)
        // Hyprland-style: no scrollbar (scroll with the trackpad / wheel).
        terminal.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        terminal.processDelegate = self
        terminal.optionAsMetaKey = true
        effect.content = terminal
        effect.padding = padding
        effect.addSubview(terminal)
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)

        let shell = Self.shellPath
        let dir = directory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        currentDirectory = dir
        terminal.startProcess(executable: shell, args: ["--login"], environment: Self.environment(shell: shell),
                              execName: nil, currentDirectory: dir)
    }

    static var shellPath: String {
        for p in ["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"]
            where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return "/bin/bash"
    }

    static func environment(shell: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Strip variables that belong to whatever launched us.
        for k in ["TERM_SESSION_ID", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "ITERM_SESSION_ID", "KITTY_WINDOW_ID",
                  "PROMPT_COMMAND", "PS1", "OLDPWD", "PWD", "SHLVL", "_", "__CFBundleIdentifier", "XPC_SERVICE_NAME"] {
            env[k] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "mac-lucent"
        env["SHELL"] = shell
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.contains("/opt/homebrew/bin") {
            env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + path
        }
        // Report the working directory (OSC 7) so new terminals open where you are.
        env["PROMPT_COMMAND"] = #"printf '\033]7;file://%s%s\007' "${HOSTNAME:-localhost}" "$PWD""#
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Catppuccin Mocha.
    static func applyTheme(to t: TerminalView) {
        let c = Config.shared
        let hex: [UInt32] = [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
            0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
        ]
        t.installColors(hex.map {
            SwiftTerm.Color(red: UInt16(($0 >> 16) & 0xFF) * 257, green: UInt16(($0 >> 8) & 0xFF) * 257, blue: UInt16($0 & 0xFF) * 257)
        })
        t.nativeForegroundColor = c.text
        // Same translucent color as the container's tint, so the padding and text area match.
        t.nativeBackgroundColor = c.base.withAlphaComponent(c.terminalOpacity)
        t.caretColor = NSColor(hex: 0xF5E0DC)
        t.selectedTextBackgroundColor = c.surface1
    }

    func focus() {
        terminal.window?.makeFirstResponder(terminal)
    }

    func shutdown() {
        terminal.processDelegate = nil
        terminal.terminate()
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let mod = Config.shared.mod
        guard flags == mod || flags == [mod, .shift] else { return false }
        switch e.charactersIgnoringModifiers {
        case "=", "+": setZoom(zoom + 1)
        case "-", "_": setZoom(zoom - 1)
        case "0": setZoom(0)
        case "k": terminal.send(txt: "\u{0C}")
        default: return false
        }
        return true
    }

    private func setZoom(_ z: CGFloat) {
        let base = Config.shared.terminalFontSize
        zoom = min(40, max(7, base + z)) - base
        terminal.font = Config.shared.terminalFont(size: base + zoom)
    }

    @objc private func configChanged() {
        let c = Config.shared
        let font = c.terminalFont(size: max(7, c.terminalFontSize + zoom))
        if font != terminal.font { terminal.font = font }
        terminal.nativeBackgroundColor = c.base.withAlphaComponent(c.terminalOpacity)
        container.tintColor = c.base.withAlphaComponent(c.terminalOpacity)
        container.setBlur(c.blur)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title.isEmpty ? "bash" : title
        onTitleChange?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        if let url = URL(string: directory), url.isFileURL {
            currentDirectory = url.path
        } else {
            currentDirectory = directory
        }
        if title == "bash" || title.hasPrefix("bash ") {
            let home = NSHomeDirectory()
            let short = currentDirectory.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 } ?? ""
            title = "bash  \(short)"
            onTitleChange?()
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onRequestClose?()
    }
}

/// Optional blurred backdrop, with the terminal inset by `padding`. The tint fills only the
/// padding ring, so it matches (rather than stacks on) the terminal's own translucent background.
final class PaddedContainer: NSView {
    private let tint = CAShapeLayer()
    var tintColor: NSColor = .clear {
        didSet { tint.fillColor = tintColor.cgColor }
    }
    private var backdrop: NSVisualEffectView?
    weak var content: NSView?
    var padding: CGFloat = 8

    init(blur: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        setBlur(blur)
        tint.fillRule = .evenOdd
        layer?.addSublayer(tint)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setBlur(_ on: Bool) {
        if on, backdrop == nil {
            let b = NSVisualEffectView(frame: bounds)
            b.material = .hudWindow
            b.blendingMode = .withinWindow
            b.state = .active
            b.appearance = NSAppearance(named: .darkAqua)
            addSubview(b, positioned: .below, relativeTo: nil)
            backdrop = b
        } else if !on, let b = backdrop {
            b.removeFromSuperview()
            backdrop = nil
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        backdrop?.frame = bounds
        let r = bounds.insetBy(dx: padding, dy: padding)
        content?.frame = r.width > 0 && r.height > 0 ? r : .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        if let f = content?.frame { path.addRect(f) }
        tint.frame = bounds
        tint.path = path
        CATransaction.commit()
    }
}
