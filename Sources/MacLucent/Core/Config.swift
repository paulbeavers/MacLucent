import AppKit

extension Notification.Name {
    static let configDidChange = Notification.Name("MacLucentConfigDidChange")
}

extension NSColor {
    /// Create a color from a 0xRRGGBB value.
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Runtime configuration, modelled on hyprland.conf's `general`, `decoration` and
/// `animations` sections. Everything is mutable so a future Settings app can edit it
/// and post `.configDidChange`.
@MainActor
final class Config {
    static let shared = Config()

    // general
    var gapsIn: CGFloat = 5
    var gapsOut: CGFloat = 12
    var borderSize: CGFloat = 2
    var activeBorder: [NSColor] = [NSColor(hex: 0x33CCFF, alpha: 0.93), NSColor(hex: 0x00FF99, alpha: 0.93)]
    var inactiveBorder = NSColor(hex: 0x595959, alpha: 0.67)
    var focusFollowsMouse = false

    // decoration
    var rounding: CGFloat = 10
    var shadow = true
    var inactiveDim: CGFloat = 0.0   // 0...1, how much inactive windows are dimmed
    var terminalOpacity: CGFloat = 0.86

    // animations
    var animationsEnabled = true
    var animationDuration: TimeInterval = 0.22
    var workspaceAnimationDuration: TimeInterval = 0.32

    // bar
    var barHeight: CGFloat = 30
    var barMargin: CGFloat = 8

    // workspaces
    var workspaceCount = 9
    var minVisibleWorkspaces = 5

    // apps
    var homepage = "https://duckduckgo.com"
    var searchURL = "https://duckduckgo.com/?q=%s"
    var terminalFontSize: CGFloat = 13
    var terminalFontNames = ["JetBrainsMono Nerd Font Mono", "JetBrainsMono Nerd Font", "JetBrains Mono",
                             "MesloLGS NF", "FiraCode Nerd Font Mono", "SF Mono", "Menlo"]
    /// Optional wallpaper image; falls back to the built-in gradient when nil or missing.
    var wallpaperPath: String? = {
        let p = NSHomeDirectory() + "/.config/mac-lucent/wallpaper.png"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }()

    // palette (Catppuccin Mocha – a common Hyprland rice)
    let base = NSColor(hex: 0x1E1E2E)
    let mantle = NSColor(hex: 0x181825)
    let crust = NSColor(hex: 0x11111B)
    let surface0 = NSColor(hex: 0x313244)
    let surface1 = NSColor(hex: 0x45475A)
    let overlay0 = NSColor(hex: 0x6C7086)
    let text = NSColor(hex: 0xCDD6F4)
    let subtext = NSColor(hex: 0xA6ADC8)
    let accent = NSColor(hex: 0x89B4FA)
    let accent2 = NSColor(hex: 0xA6E3A1)
    let pink = NSColor(hex: 0xF5C2E7)
    let red = NSColor(hex: 0xF38BA8)

    func terminalFont(size: CGFloat? = nil) -> NSFont {
        let s = size ?? terminalFontSize
        for name in terminalFontNames {
            if let f = NSFont(name: name, size: s) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: s, weight: .regular)
    }

    func uiFont(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    func monoUIFont(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: .configDidChange, object: self)
    }
}
