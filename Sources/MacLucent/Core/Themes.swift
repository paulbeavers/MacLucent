import AppKit

/// The 19 colour roles every Lucent theme defines, darkest background to brightest accent —
/// the same keys as the Lucent Hyprland config's `*.theme` files (see its hypr/scripts/theme.sh).
struct Palette {
    var crust, mantle, base, surface0, surface1, overlay, subtext, text: NSColor
    var rosewater, red, peach, yellow, green, teal, sapphire, blue, lavender, mauve, pink: NSColor
    var isLight: Bool

    static let roles = ["crust", "mantle", "base", "surface0", "surface1", "overlay", "subtext", "text",
                        "rosewater", "red", "peach", "yellow", "green", "teal", "sapphire", "blue",
                        "lavender", "mauve", "pink"]

    /// Catppuccin Mocha — used until a theme is loaded, and for any role a theme leaves out.
    static let mocha = Palette(
        crust: NSColor(hex: 0x11111B), mantle: NSColor(hex: 0x181825), base: NSColor(hex: 0x1E1E2E),
        surface0: NSColor(hex: 0x313244), surface1: NSColor(hex: 0x45475A), overlay: NSColor(hex: 0x6C7086),
        subtext: NSColor(hex: 0xA6ADC8), text: NSColor(hex: 0xCDD6F4), rosewater: NSColor(hex: 0xF5E0DC),
        red: NSColor(hex: 0xF38BA8), peach: NSColor(hex: 0xFAB387), yellow: NSColor(hex: 0xF9E2AF),
        green: NSColor(hex: 0xA6E3A1), teal: NSColor(hex: 0x94E2D5), sapphire: NSColor(hex: 0x74C7EC),
        blue: NSColor(hex: 0x89B4FA), lavender: NSColor(hex: 0xB4BEFE), mauve: NSColor(hex: 0xCBA6F7),
        pink: NSColor(hex: 0xF5C2E7), isLight: false)

    init(crust: NSColor, mantle: NSColor, base: NSColor, surface0: NSColor, surface1: NSColor, overlay: NSColor,
         subtext: NSColor, text: NSColor, rosewater: NSColor, red: NSColor, peach: NSColor, yellow: NSColor,
         green: NSColor, teal: NSColor, sapphire: NSColor, blue: NSColor, lavender: NSColor, mauve: NSColor,
         pink: NSColor, isLight: Bool) {
        self.crust = crust; self.mantle = mantle; self.base = base; self.surface0 = surface0
        self.surface1 = surface1; self.overlay = overlay; self.subtext = subtext; self.text = text
        self.rosewater = rosewater; self.red = red; self.peach = peach; self.yellow = yellow
        self.green = green; self.teal = teal; self.sapphire = sapphire; self.blue = blue
        self.lavender = lavender; self.mauve = mauve; self.pink = pink; self.isLight = isLight
    }

    /// Build from a theme's role → colour map, falling back to Mocha per role.
    init(roles c: [String: NSColor], isLight: Bool) {
        let m = Palette.mocha
        self.init(crust: c["crust"] ?? m.crust, mantle: c["mantle"] ?? m.mantle, base: c["base"] ?? m.base,
                  surface0: c["surface0"] ?? m.surface0, surface1: c["surface1"] ?? m.surface1,
                  overlay: c["overlay"] ?? m.overlay, subtext: c["subtext"] ?? m.subtext, text: c["text"] ?? m.text,
                  rosewater: c["rosewater"] ?? m.rosewater, red: c["red"] ?? m.red, peach: c["peach"] ?? m.peach,
                  yellow: c["yellow"] ?? m.yellow, green: c["green"] ?? m.green, teal: c["teal"] ?? m.teal,
                  sapphire: c["sapphire"] ?? m.sapphire, blue: c["blue"] ?? m.blue,
                  lavender: c["lavender"] ?? m.lavender, mauve: c["mauve"] ?? m.mauve, pink: c["pink"] ?? m.pink,
                  isLight: isLight)
    }

    /// The 16 ANSI colours, mapped exactly like Lucent's foot terminal (theme.sh render_foot_palette).
    var ansi: [NSColor] {
        let (r0, b0, r7, b7) = isLight ? (subtext, overlay, surface1, surface0) : (surface1, overlay, subtext, text)
        let mid = [red, green, yellow, blue, pink, teal]
        return [r0] + mid + [r7] + [b0] + mid + [b7]
    }
}

/// One `*.theme` file.
struct LucentTheme {
    let id: String          // file name without extension, e.g. "catppuccin-mocha"
    let name: String        // its `name` key
    let palette: Palette
    let font: String?       // UI font (unused on the Mac unless installed)
    let mono: String?       // terminal font
    let border: NSColor?    // unfocused window border (else surface0)
    let terminal: String?   // id of another theme whose palette the terminal uses
    let terminalAlpha: Double?

    var isLight: Bool { palette.isLight }

    /// Parse `key = value   # comment` lines; blank lines and `#` comments are ignored.
    static func parse(id: String, text: String) -> LucentTheme? {
        var kv: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { kv[key] = value }
        }
        var colors: [String: NSColor] = [:]
        for role in Palette.roles { if let v = kv[role], let c = NSColor(hexString: v) { colors[role] = c } }
        guard colors.count >= 8 else { return nil } // not a theme file
        return LucentTheme(
            id: id, name: kv["name"] ?? id,
            palette: Palette(roles: colors, isLight: kv["mode"]?.lowercased() == "light"),
            font: kv["font"], mono: kv["mono"],
            border: kv["border"].flatMap(NSColor.init(hexString:)),
            terminal: kv["terminal"], terminalAlpha: kv["terminal_alpha"].flatMap(Double.init))
    }
}

/// The available themes: the Lucent themes bundled with the app (synced from the Lucent
/// Hyprland config by scripts/sync-themes.sh), plus any in ~/.config/lucent/themes, which
/// override bundled ones with the same file name.
enum ThemeLibrary {
    /// Lucent's own default (the Hyprland install.sh default).
    static let defaultID = "catppuccin-mocha-blue-contrast"

    nonisolated static var userDirectory: URL { Config.directory.appendingPathComponent("themes") }

    static var bundledDirectory: URL? {
        [Bundle.main.resourceURL?.appendingPathComponent("Themes"),
         URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Themes")]
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var cache: [LucentTheme]?

    static func all(reload: Bool = false) -> [LucentTheme] {
        if let cache, !reload { return cache }
        var byID: [String: LucentTheme] = [:]
        for dir in [bundledDirectory, userDirectory].compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "theme" {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let id = f.deletingPathExtension().lastPathComponent
                if let t = LucentTheme.parse(id: id, text: text) { byID[id] = t }
            }
        }
        // Dark themes first, then light; alphabetical within each.
        let list = byID.values.sorted { ($0.isLight ? 1 : 0, $0.name.lowercased()) < ($1.isLight ? 1 : 0, $1.name.lowercased()) }
        cache = list
        return list
    }

    static func theme(_ id: String?) -> LucentTheme? {
        guard let id else { return nil }
        return all().first { $0.id == id }
    }
}
