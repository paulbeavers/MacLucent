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

extension NSColor {
    /// "#RRGGBBAA" in sRGB.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func b(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent), b(c.alphaComponent))
    }

    /// Parses "#RRGGBB" or "#RRGGBBAA".
    convenience init?(hexString: String) {
        var h = hexString.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let rgba = h.count == 6 ? (v << 8) | 0xFF : v
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}

/// The modifier used for mac-lucent's shortcuts (Hyprland's "Super").
enum ModifierKey: String {
    case command, option
}

/// The user-editable subset of `Config`, as stored in ~/.config/mac-lucent/settings.json.
/// Every field is optional so older or hand-edited files still load.
struct SettingsFile: Codable {
    var gapsIn: Double?
    var gapsOut: Double?
    var borderSize: Double?
    var activeBorderStart: String?
    var activeBorderEnd: String?
    var inactiveBorder: String?
    var focusFollowsMouse: Bool?
    var raiseOnHover: Bool?
    var rounding: Double?
    var shadow: Bool?
    var inactiveDim: Double?
    var terminalOpacity: Double?
    var blur: Bool?
    var animationsEnabled: Bool?
    var animationDuration: Double?
    var workspaceAnimationDuration: Double?
    var homepage: String?
    var searchURL: String?
    var terminalFontSize: Double?
    var terminalFontFamily: String?
    var wallpaperPath: String?
    var floatingWorkspaces: [Int]?
    var modifierKey: String?
}

/// Runtime configuration, modelled on hyprland.conf's `general`, `decoration` and
/// `animations` sections. The Settings app edits it, then calls `notifyChanged()` and `save()`.
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
    /// ⌘ (default) or ⌥ for all mac-lucent shortcuts. Standard macOS ones (copy/paste, quit) stay on ⌘.
    var modifierKey: ModifierKey = .command
    var mod: NSEvent.ModifierFlags { modifierKey == .option ? .option : .command }
    var modSymbol: String { modifierKey == .option ? "⌥" : "⌘" }

    /// Render a shortcut written with "⌘" for the mac-lucent modifier, using the current one.
    func shortcut(_ s: String) -> String { s.replacingOccurrences(of: "⌘", with: modSymbol) }
    /// With focus-follows-mouse on a floating workspace, also bring the hovered window to the front.
    var raiseOnHover = true

    // decoration
    var rounding: CGFloat = 10
    var shadow = true
    var inactiveDim: CGFloat = 0.0   // 0...1, how much inactive windows are dimmed
    var terminalOpacity: CGFloat = 0.86
    /// Live background blur behind terminals and the bar (NSVisualEffectView). Costs window-server
    /// compositing time on every redraw.
    var blur = ProcessInfo.processInfo.environment["ML_BLUR"] != nil

    // animations
    var animationsEnabled = true
    var animationDuration: TimeInterval = 0.22
    var workspaceAnimationDuration: TimeInterval = 0.32

    // bar
    var barHeight: CGFloat = 30
    var barMargin: CGFloat = 8

    // workspaces
    /// Workspaces (1-based) that use floating instead of tiled layout.
    var floatingWorkspaces: Set<Int> = []
    var workspaceCount = 9
    var minVisibleWorkspaces = 5

    // apps
    var homepage = "https://duckduckgo.com"
    var searchURL = "https://duckduckgo.com/?q=%s"
    var terminalFontSize: CGFloat = 13
    /// User-chosen terminal font family; nil picks the first installed of `terminalFontNames`.
    var terminalFontFamily: String?
    /// "Automatic" picks the first available; the first ones are bundled with the app.
    var terminalFontNames = ["JetBrainsMono Nerd Font Mono", "JetBrains Mono", "JetBrainsMono Nerd Font",
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
        if let family = terminalFontFamily,
           let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: s) {
            return f
        }
        for name in terminalFontNames {
            if let f = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: s) ?? NSFont(name: name, size: s) {
                return f
            }
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

    // MARK: Persistence

    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/mac-lucent/settings.json")
    }

    func snapshot() -> SettingsFile {
        SettingsFile(
            gapsIn: gapsIn, gapsOut: gapsOut, borderSize: borderSize,
            activeBorderStart: activeBorder.first?.hexString, activeBorderEnd: activeBorder.last?.hexString,
            inactiveBorder: inactiveBorder.hexString, focusFollowsMouse: focusFollowsMouse, raiseOnHover: raiseOnHover,
            rounding: rounding, shadow: shadow, inactiveDim: inactiveDim, terminalOpacity: terminalOpacity,
            blur: blur, animationsEnabled: animationsEnabled, animationDuration: animationDuration,
            workspaceAnimationDuration: workspaceAnimationDuration, homepage: homepage, searchURL: searchURL,
            terminalFontSize: terminalFontSize, terminalFontFamily: terminalFontFamily ?? "",
            wallpaperPath: wallpaperPath ?? "", floatingWorkspaces: floatingWorkspaces.sorted(),
            modifierKey: modifierKey.rawValue)
    }

    func apply(_ f: SettingsFile) {
        if let v = f.gapsIn { gapsIn = CGFloat(v) }
        if let v = f.gapsOut { gapsOut = CGFloat(v) }
        if let v = f.borderSize { borderSize = CGFloat(v) }
        if let a = f.activeBorderStart.flatMap(NSColor.init(hexString:)),
           let b = f.activeBorderEnd.flatMap(NSColor.init(hexString:)) { activeBorder = [a, b] }
        if let v = f.inactiveBorder.flatMap(NSColor.init(hexString:)) { inactiveBorder = v }
        if let v = f.focusFollowsMouse { focusFollowsMouse = v }
        if let v = f.raiseOnHover { raiseOnHover = v }
        if let v = f.rounding { rounding = CGFloat(v) }
        if let v = f.shadow { shadow = v }
        if let v = f.inactiveDim { inactiveDim = CGFloat(v) }
        if let v = f.terminalOpacity { terminalOpacity = CGFloat(v) }
        if let v = f.blur { blur = v }
        if let v = f.animationsEnabled { animationsEnabled = v }
        if let v = f.animationDuration { animationDuration = v }
        if let v = f.workspaceAnimationDuration { workspaceAnimationDuration = v }
        if let v = f.homepage { homepage = v }
        if let v = f.searchURL { searchURL = v }
        if let v = f.terminalFontSize { terminalFontSize = CGFloat(v) }
        if let v = f.terminalFontFamily { terminalFontFamily = v.isEmpty ? nil : v }
        if let v = f.wallpaperPath { wallpaperPath = v.isEmpty ? nil : v }
        if let v = f.floatingWorkspaces { floatingWorkspaces = Set(v) }
        if let v = f.modifierKey.flatMap(ModifierKey.init(rawValue:)) { modifierKey = v }
    }

    /// Load saved settings, if any. Call once at launch, before any views are built.
    func load() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              let f = try? JSONDecoder().decode(SettingsFile.self, from: data) else { return }
        apply(f)
        if ProcessInfo.processInfo.environment["ML_BLUR"] != nil { blur = true }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshot()) else { return }
        try? FileManager.default.createDirectory(at: Self.settingsURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.settingsURL, options: .atomic)
    }

    func resetToDefaults() {
        let defaults = Config()
        defaults.wallpaperPath = nil
        apply(defaults.snapshot())
        notifyChanged()
        save()
    }
}
