import AppKit
import CoreText

/// Registers the coding fonts shipped in Resources/Fonts (JetBrains Mono, JetBrains Mono Nerd
/// Font, Fira Code, Cascadia Code, Hack) for this process, so they're available without
/// installing anything system-wide. Licenses are shipped alongside each family.
enum BundledFonts {
    /// Directory holding the bundled fonts: the app bundle's Resources/Fonts, or the repo's
    /// Resources/Fonts when running via `swift run`.
    static var directory: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func register() {
        guard let dir = directory,
              let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        let urls = files.compactMap { $0 as? URL }.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
}
