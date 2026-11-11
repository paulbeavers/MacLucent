import AppKit
import SwiftTerm

/// A terminal window running bash in a real PTY.
final class TerminalApp: NSObject, TileApp, LocalProcessTerminalViewDelegate {
    let view: NSView
    let terminal: LocalProcessTerminalView
    private(set) var title = "bash"
    private(set) var currentDirectory: String?
    var symbolName: String { "terminal" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?
    private var fontSize = Config.shared.terminalFontSize
    private let padding: CGFloat = 8

    init(directory: String? = nil) {
        let c = Config.shared
        let effect = PaddedContainer()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.tint.layer?.backgroundColor = c.base.withAlphaComponent(c.terminalOpacity).cgColor
        view = effect

        terminal = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()

        terminal.font = c.terminalFont()
        Self.applyTheme(to: terminal)
        terminal.processDelegate = self
        terminal.optionAsMetaKey = true
        effect.content = terminal
        effect.padding = padding
        effect.addSubview(terminal)

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
            SwiftTerm.Color(red8: UInt16(($0 >> 16) & 0xFF), green8: UInt16(($0 >> 8) & 0xFF), blue8: UInt16($0 & 0xFF))
        })
        t.nativeForegroundColor = c.text
        t.nativeBackgroundColor = c.base
        t.backgroundOpacity = 0 // the window's blurred background shows through
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
        guard flags == .command || flags == [.command, .shift] else { return false }
        switch e.charactersIgnoringModifiers {
        case "=", "+": setFontSize(fontSize + 1)
        case "-", "_": setFontSize(fontSize - 1)
        case "0": setFontSize(Config.shared.terminalFontSize)
        case "k": terminal.send(txt: "\u{0C}")
        default: return false
        }
        return true
    }

    private func setFontSize(_ s: CGFloat) {
        fontSize = min(40, max(7, s))
        terminal.font = Config.shared.terminalFont(size: fontSize)
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

/// Blurred backdrop + tint, with the terminal inset by `padding`.
final class PaddedContainer: NSVisualEffectView {
    let tint = NSView()
    weak var content: NSView?
    var padding: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tint.frame = bounds
        let r = bounds.insetBy(dx: padding, dy: padding)
        content?.frame = r.width > 0 && r.height > 0 ? r : .zero
    }
}
