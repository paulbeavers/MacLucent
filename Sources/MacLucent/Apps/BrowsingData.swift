import AppKit
import WebKit

extension Notification.Name {
    /// Every open browser clears its back/forward history and closed-tab list.
    static let clearBrowserHistory = Notification.Name("LucentClearBrowserHistory")
}

/// Clearing what the browser tiles store. Cookies, caches and site data live in WebKit's default
/// data store (shared by all tabs); back/forward history lives in each tab's web view.
@MainActor
enum BrowsingData {
    struct Choice {
        var since: Date
        var siteData = true   // cookies, logins, local storage, databases…
        var cache = true      // cached images and files
        var history = true    // back/forward history and recently closed tabs
    }

    static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                          WKWebsiteDataTypeFetchCache]

    static func clear(_ choice: Choice, completion: @escaping () -> Void) {
        var types = Set<String>()
        if choice.cache { types.formUnion(cacheTypes) }
        if choice.siteData { types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cacheTypes)) }
        if choice.history { NotificationCenter.default.post(name: .clearBrowserHistory, object: nil) }
        guard !types.isEmpty else { completion(); return }
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: choice.since) {
            MainActor.assumeIsolated { completion() }
        }
    }

    /// The "Clear browsing data…" dialog. Runs modally; returns after clearing (or Cancel).
    static func presentClearDialog() {
        let ranges: [(String, TimeInterval?)] = [("Last hour", 3600), ("Last day", 86_400),
                                                 ("Last week", 7 * 86_400), ("All time", nil)]
        let range = NSPopUpButton(frame: .zero, pullsDown: false)
        range.addItems(withTitles: ranges.map(\.0))
        range.selectItem(at: ranges.count - 1)
        let siteData = NSButton(checkboxWithTitle: "Cookies and site data — signs you out of websites", target: nil, action: nil)
        let cache = NSButton(checkboxWithTitle: "Cached images and files", target: nil, action: nil)
        let history = NSButton(checkboxWithTitle: "Back/forward history and recently closed tabs (open tabs reload)",
                               target: nil, action: nil)
        [siteData, cache, history].forEach { $0.state = .on }

        let rangeRow = NSStackView(views: [NSTextField(labelWithString: "Time range:"), range])
        rangeRow.spacing = 8
        let stack = NSStackView(views: [rangeRow, siteData, cache, history])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = CGRect(x: 0, y: 0, width: 440, height: 110)

        let alert = NSAlert()
        alert.messageText = "Clear browsing data"
        alert.informativeText = "Applies to every browser tile in Lucent."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let seconds = ranges[range.indexOfSelectedItem].1
        let choice = Choice(since: seconds.map { Date().addingTimeInterval(-$0) } ?? .distantPast,
                            siteData: siteData.state == .on, cache: cache.state == .on, history: history.state == .on)
        clear(choice) {
            var what: [String] = []
            if choice.siteData { what.append("cookies and site data") }
            if choice.cache { what.append("cached files") }
            if choice.history { what.append("history") }
            let done = NSAlert()
            done.messageText = what.isEmpty ? "Nothing selected" : "Cleared"
            done.informativeText = what.isEmpty ? "" : "\(what.joined(separator: ", ").capitalizedFirst) — \(ranges[range.indexOfSelectedItem].0.lowercased())."
            done.runModal()
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
