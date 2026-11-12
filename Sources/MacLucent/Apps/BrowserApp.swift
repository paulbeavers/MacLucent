import AppKit
import WebKit

/// One browser tab: a web view plus observers that report changes to its owner.
@MainActor
final class BrowserTab: NSObject {
    enum Change { case title, url, navigation, progress }

    let webView: WKWebView
    var onChange: ((BrowserTab, Change) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    /// The last main-frame URL we were asked to load.
    var requestedURL: URL?
    /// Set while the tab shows our error page, so the address bar and title keep the real URL.
    var failedURL: URL?

    /// What the address bar should show.
    var displayURL: URL? { failedURL ?? webView.url }

    var title: String {
        if let f = failedURL { return f.host ?? f.absoluteString }
        if let t = webView.title, !t.isEmpty { return t }
        if let host = webView.url?.host, !host.isEmpty { return host }
        return "New Tab"
    }

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.customUserAgent = BrowserApp.userAgent
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.underPageBackgroundColor = Config.shared.base
        observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed(.title) } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed(.url) } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed(.navigation) } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed(.navigation) } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed(.progress) } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed(.progress) } },
        ]
    }

    private func changed(_ c: Change) { onChange?(self, c) }

    func shutdown() {
        observations.removeAll()
        onChange = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }
}

/// A developer-friendly tabbed browser built on WebKit.
final class BrowserApp: NSObject, TileApp, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    let view: NSView
    var symbolName: String { "globe" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?
    private weak var manager: WindowManager?

    private(set) var tabs: [BrowserTab] = []
    private(set) var activeIndex = 0
    /// URLs of recently closed tabs, most recent last (⌘⇧T reopens).
    private var closedTabs: [URL] = []

    private let tabBar = TabBarView()
    private let toolbar = FlippedView()
    private let urlBox = NSView()
    private let urlField = NSTextField()
    private let lockIcon = NSImageView()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private let progress = CALayer()
    private let tabBarHeight: CGFloat = 30
    private let toolbarHeight: CGFloat = 38

    var activeTab: BrowserTab { tabs[activeIndex] }
    /// The active tab's web view.
    var webView: WKWebView { activeTab.webView }

    var title: String {
        tabs.count > 1 ? "\(activeTab.title)  (\(activeIndex + 1)/\(tabs.count))" : activeTab.title
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default() // shared by all tabs: stay signed in across them
        c.preferences.isElementFullscreenEnabled = true
        return c
    }

    /// Restore a browser with several tabs (session restore).
    convenience init(manager: WindowManager?, urls: [String], activeTab: Int) {
        self.init(manager: manager, url: urls.first)
        for u in urls.dropFirst() { newTab(url: u, select: false, atEnd: true) }
        selectTab(min(max(0, activeTab), tabs.count - 1))
    }

    init(manager: WindowManager?, url: String? = nil) {
        self.manager = manager
        let container = FlippedView()
        view = container
        super.init()

        let c = Config.shared
        container.wantsLayer = true
        container.layer?.backgroundColor = c.mantle.cgColor

        buildToolbar()
        container.addSubview(tabBar)
        container.addSubview(toolbar)
        container.onLayout = { [weak self] in self?.layout() }

        tabBar.onSelect = { [weak self] i in self?.selectTab(i) }
        tabBar.onClose = { [weak self] i in self?.closeTab(i) }
        tabBar.onNewTab = { [weak self] in self?.newTab(focusAddressBar: true) }

        newTab(url: url ?? c.homepage)
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)
    }

    private var appliedTheme = Config.shared.themeID

    /// Recolour the browser chrome when the theme changes.
    @objc private func configChanged() {
        let c = Config.shared
        guard c.themeID != appliedTheme else { return }
        appliedTheme = c.themeID
        view.appearance = c.appearance
        view.layer?.backgroundColor = c.mantle.cgColor
        toolbar.layer?.backgroundColor = c.mantle.cgColor
        urlBox.layer?.backgroundColor = c.surface0.withAlphaComponent(0.8).cgColor
        lockIcon.contentTintColor = c.overlay0
        urlField.textColor = c.text
        progress.backgroundColor = c.accent.cgColor
        reloadButton.contentTintColor = c.subtext
        syncButtons()
        tabBar.refreshColors()
        for t in tabs { t.webView.underPageBackgroundColor = c.base }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: String? = nil, configuration: WKWebViewConfiguration? = nil, select: Bool = true,
                focusAddressBar: Bool = false, atEnd: Bool = false) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration ?? Self.makeConfiguration())
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tab.onChange = { [weak self] tab, change in self?.tabChanged(tab, change) }
        tab.webView.isHidden = true
        view.addSubview(tab.webView)
        // Open next to the current tab, like Safari (or at the end when restoring).
        let index = tabs.isEmpty ? 0 : (atEnd ? tabs.count : activeIndex + 1)
        tabs.insert(tab, at: index)
        if !select, index <= activeIndex { activeIndex += 1 }
        if let url, let u = Self.resolve(url) { tab.webView.load(URLRequest(url: u)) }
        if select || tabs.count == 1 {
            selectTab(index)
        } else {
            refreshTabBar()
        }
        if focusAddressBar {
            urlField.stringValue = ""
            view.window?.makeFirstResponder(urlField)
        }
        layout()
        return tab
    }

    func selectTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        for (j, t) in tabs.enumerated() { t.webView.isHidden = j != i }
        activeIndex = i
        syncURL(force: true)
        syncButtons()
        syncProgress()
        refreshTabBar()
        onTitleChange?()
        focus()
    }

    func closeTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        if tabs.count == 1 {
            onRequestClose?() // last tab closes the tile
            return
        }
        let tab = tabs.remove(at: i)
        if let u = tab.webView.url, u.scheme != "about" { closedTabs.append(u) }
        if closedTabs.count > 25 { closedTabs.removeFirst() }
        tab.shutdown()
        // Prefer the tab to the right of the closed one, else the one to its left.
        let next = i < activeIndex ? activeIndex - 1 : (i == activeIndex ? min(i, tabs.count - 1) : activeIndex)
        activeIndex = -1
        selectTab(next)
    }

    func reopenClosedTab() {
        guard let u = closedTabs.popLast() else { NSSound.beep(); return }
        newTab(url: u.absoluteString)
    }

    private func cycleTab(_ delta: Int) {
        guard tabs.count > 1 else { return }
        selectTab((activeIndex + delta + tabs.count) % tabs.count)
    }

    private func tabChanged(_ tab: BrowserTab, _ change: BrowserTab.Change) {
        let isActive = tab === activeTab
        switch change {
        case .title:
            refreshTabBar()
            if isActive { onTitleChange?() }
        case .url:
            if isActive { syncURL(); onTitleChange?() }
        case .navigation:
            if isActive { syncButtons() }
        case .progress:
            refreshTabBar()
            if isActive { syncProgress(); syncButtons() }
        }
    }

    private func refreshTabBar() {
        tabBar.items = tabs.map { .init(title: $0.title, loading: $0.webView.isLoading) }
        tabBar.selected = activeIndex
    }

    // MARK: Toolbar

    private func buildToolbar() {
        let c = Config.shared
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = c.mantle.cgColor

        func button(_ symbol: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: action)
            b.isBordered = false
            b.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
            b.contentTintColor = c.subtext
            toolbar.addSubview(b)
            return b
        }
        backButton = button("chevron.left", #selector(goBack))
        forwardButton = button("chevron.right", #selector(goForward))
        reloadButton = button("arrow.clockwise", #selector(reload))

        urlBox.wantsLayer = true
        urlBox.layer?.backgroundColor = c.surface0.withAlphaComponent(0.8).cgColor
        urlBox.layer?.cornerRadius = 7
        toolbar.addSubview(urlBox)

        lockIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        lockIcon.contentTintColor = c.overlay0
        urlBox.addSubview(lockIcon)

        urlField.isBordered = false
        urlField.drawsBackground = false
        urlField.focusRingType = .none
        urlField.font = c.uiFont(12.5, weight: .regular)
        urlField.textColor = c.text
        urlField.placeholderString = "Search or enter address"
        urlField.cell?.isScrollable = true
        urlField.cell?.wraps = false
        urlField.target = self
        urlField.action = #selector(submitURL)
        urlField.delegate = self
        urlBox.addSubview(urlField)

        progress.backgroundColor = c.accent.cgColor
        progress.isHidden = true
        toolbar.layer?.addSublayer(progress)
    }

    private func layout() {
        let b = view.bounds
        tabBar.frame = CGRect(x: 0, y: 0, width: b.width, height: tabBarHeight)
        toolbar.frame = CGRect(x: 0, y: tabBarHeight, width: b.width, height: toolbarHeight)
        let top = tabBarHeight + toolbarHeight
        for t in tabs { t.webView.frame = CGRect(x: 0, y: top, width: b.width, height: max(0, b.height - top)) }
        let s: CGFloat = 26, y = (toolbarHeight - s) / 2
        backButton.frame = CGRect(x: 8, y: y, width: s, height: s)
        forwardButton.frame = CGRect(x: 8 + s, y: y, width: s, height: s)
        reloadButton.frame = CGRect(x: 8 + 2 * s, y: y, width: s, height: s)
        let ux = reloadButton.frame.maxX + 8
        urlBox.frame = CGRect(x: ux, y: 6, width: max(0, b.width - ux - 10), height: toolbarHeight - 12)
        lockIcon.frame = CGRect(x: 8, y: (urlBox.bounds.height - 12) / 2, width: 12, height: 12)
        let fh: CGFloat = 17
        urlField.frame = CGRect(x: 26, y: (urlBox.bounds.height - fh) / 2, width: max(0, urlBox.bounds.width - 34), height: fh)
        syncProgress()
    }

    // MARK: Navigation

    func load(_ input: String) {
        guard let url = Self.resolve(input) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Turn address-bar input into a URL: explicit URLs, localhost/IPs, domains, or a search.
    static func resolve(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s), let scheme = u.scheme, ["http", "https", "file", "about", "data"].contains(scheme.lowercased()) {
            return u
        }
        if s.hasPrefix("/") || s.hasPrefix("~") {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        let hostPart = s.split(separator: "/").first.map(String.init) ?? s
        let isLocal = hostPart.hasPrefix("localhost") || hostPart.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?$"#, options: .regularExpression) != nil
        if isLocal { return URL(string: "http://" + s) }
        if !s.contains(" ") && hostPart.contains(".") { return URL(string: "https://" + s) }
        let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        return URL(string: Config.shared.searchURL.replacingOccurrences(of: "%s", with: q))
    }

    @objc private func submitURL() {
        load(urlField.stringValue)
        webView.window?.makeFirstResponder(webView)
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() {
        if webView.isLoading { webView.stopLoading() } else { reloadActive() }
    }

    /// Reload, or retry the failed URL when the tab is showing an error page.
    private func reloadActive(fromOrigin: Bool = false) {
        if let failed = activeTab.failedURL {
            webView.load(URLRequest(url: failed))
        } else if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    private func syncURL(force: Bool = false) {
        if force || urlField.currentEditor() == nil {
            urlField.stringValue = activeTab.displayURL?.absoluteString ?? ""
        }
        let secure = activeTab.failedURL == nil && webView.url?.scheme == "https"
        lockIcon.image = NSImage(systemSymbolName: secure ? "lock.fill" : "globe", accessibilityDescription: nil)
    }

    private func syncButtons() {
        let c = Config.shared
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        backButton.contentTintColor = webView.canGoBack ? c.subtext : c.surface1
        forwardButton.contentTintColor = webView.canGoForward ? c.subtext : c.surface1
        reloadButton.image = NSImage(systemSymbolName: webView.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: nil)
    }

    private func syncProgress() {
        guard !tabs.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!webView.isLoading)
        progress.isHidden = !webView.isLoading
        progress.frame = CGRect(x: 0, y: toolbarHeight - 2, width: toolbar.bounds.width * webView.estimatedProgress, height: 2)
        CATransaction.commit()
    }

    // MARK: TileApp

    func focus() {
        guard let window = view.window else { return }
        if webView.url == nil {
            window.makeFirstResponder(urlField)
        } else if urlField.currentEditor() == nil {
            window.makeFirstResponder(webView)
        }
    }

    func shutdown() {
        tabs.forEach { $0.shutdown() }
        tabs.removeAll()
    }

    var sessionState: JSONValue? {
        let urls = tabs.compactMap { $0.displayURL?.absoluteString }.filter { !$0.isEmpty }
        return .object(["tabs": .array(urls.map { .string($0) }), "activeTab": .number(Double(activeIndex))])
    }

    /// ⌘W closes the current tab; the tile closes with its last tab.
    func requestClose() -> Bool {
        guard tabs.count > 1 else { return false }
        closeTab(activeIndex)
        return true
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = e.keyCode
        // ⌃Tab / ⌃⇧Tab: next / previous tab.
        if code == 48, flags == .control { cycleTab(1); return true }
        if code == 48, flags == [.control, .shift] { cycleTab(-1); return true }
        let mod = Config.shared.mod
        if flags == mod {
            switch ch {
            case "t": newTab(focusAddressBar: true)
            case "l": webView.window?.makeFirstResponder(urlField); urlField.selectText(nil)
            case "r": reloadActive()
            case "[": webView.goBack()
            case "]": webView.goForward()
            case "=", "+": webView.pageZoom = min(3, webView.pageZoom + 0.1)
            case "-": webView.pageZoom = max(0.3, webView.pageZoom - 0.1)
            case "0": webView.pageZoom = 1
            default: return false
            }
            return true
        }
        if flags == [mod, .shift] {
            switch (code, ch) {
            case (_, "t"): reopenClosedTab()
            case (_, "r"): reloadActive(fromOrigin: true)
            case (30, _): cycleTab(1)   // ⌘⇧]
            case (33, _): cycleTab(-1)  // ⌘⇧[
            default: return false
            }
            return true
        }
        return false
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            urlField.stringValue = activeTab.displayURL?.absoluteString ?? ""
            webView.window?.makeFirstResponder(webView)
            return true
        }
        return false
    }

    // MARK: WKNavigationDelegate

    /// ⌘-click and middle-click open links in a background tab.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2,
           let url = navigationAction.request.url {
            newTab(url: url.absoluteString, select: false)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url,
           url.scheme != "about", let tab = tab(for: webView) {
            tab.requestedURL = url
        }
        decisionHandler(.allow)
    }

    private func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A real page loaded: leave error-page mode.
        guard let tab = tab(for: webView), webView.url?.scheme != "about", tab.failedURL != nil else { return }
        tab.failedURL = nil
        refreshTabBar()
        if tab === activeTab { syncURL(force: true); onTitleChange?() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled { return }
        let tab = tab(for: webView)
        let failedURL = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab?.requestedURL
        let failing = failedURL?.absoluteString ?? (e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ""
        let p = Config.shared.palette
        func css(_ c: NSColor) -> String { "#" + c.hexString.dropFirst().prefix(6) }
        tab?.failedURL = failedURL
        let html = """
        <html><body style="background:\(css(p.base));color:\(css(p.text));font:15px -apple-system;display:flex;align-items:center;justify-content:center;height:90vh">
        <div style="max-width:520px"><h2 style="font-weight:500;color:\(css(p.red))">Can't open this page</h2>
        <p style="color:\(css(p.subtext))">\(failing.htmlEscaped)</p><p style="color:\(css(p.overlay))">\(e.localizedDescription.htmlEscaped)</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        refreshTabBar()
        if tab === activeTab { syncURL(force: true); onTitleChange?() }
    }

    // MARK: WKUIDelegate

    /// target=_blank / window.open → a new tab in this browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let background = navigationAction.modifierFlags.contains(.command)
        return newTab(configuration: configuration, select: !background).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let i = tabs.firstIndex(where: { $0.webView === webView }) { closeTab(i) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "Alert"
        a.informativeText = message
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "Confirm"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert()
        a.messageText = prompt
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        completionHandler(p.runModal() == .OK ? p.urls : nil)
    }
}

/// The strip of tabs above the address bar.
final class TabBarView: NSView {
    struct Item: Equatable {
        let title: String
        let loading: Bool
    }

    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private var hover: Int?
    private var hoverClose = false
    private var hoverPlus = false
    private let plusWidth: CGFloat = 30
    private let maxTabWidth: CGFloat = 220
    private let inset: CGFloat = 6

    override var isFlipped: Bool { true }

    func refreshColors() {
        layer?.backgroundColor = Config.shared.crust.cgColor
        needsDisplay = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Config.shared.crust.cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tabWidth: CGFloat {
        guard !items.isEmpty else { return 0 }
        let available = bounds.width - plusWidth - 2 * inset
        return max(40, min(maxTabWidth, available / CGFloat(items.count)))
    }

    private func tabRect(_ i: Int) -> CGRect {
        CGRect(x: inset + CGFloat(i) * tabWidth, y: 4, width: tabWidth - 2, height: bounds.height - 4)
    }

    private func closeRect(_ i: Int) -> CGRect {
        let r = tabRect(i)
        return CGRect(x: r.maxX - 22, y: r.midY - 8, width: 16, height: 16)
    }

    private var plusRect: CGRect {
        CGRect(x: inset + CGFloat(items.count) * tabWidth + 4, y: 6, width: 22, height: bounds.height - 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Config.shared
        for (i, item) in items.enumerated() {
            let r = tabRect(i)
            let isSelected = i == selected
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: 3), xRadius: 7, yRadius: 7)
            if isSelected {
                c.mantle.setFill(); path.fill()
            } else if hover == i {
                c.surface0.withAlphaComponent(0.6).setFill(); path.fill()
            }
            var textX = r.minX + 10
            if item.loading {
                c.accent.setFill()
                NSBezierPath(ovalIn: CGRect(x: textX, y: r.midY - 3, width: 6, height: 6)).fill()
                textX += 12
            }
            let showClose = items.count > 1 && (isSelected || hover == i) && r.width > 70
            let textW = r.maxX - textX - (showClose ? 26 : 8)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: c.uiFont(11.5, weight: isSelected ? .medium : .regular),
                .foregroundColor: isSelected ? c.text : c.subtext,
                .paragraphStyle: para,
            ]
            (item.title as NSString).draw(in: CGRect(x: textX, y: r.midY - 7, width: max(0, textW), height: 16), withAttributes: attrs)
            if showClose {
                let cr = closeRect(i)
                if hover == i && hoverClose {
                    c.surface1.setFill()
                    NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill()
                }
                drawX(in: cr.insetBy(dx: 4.5, dy: 4.5), color: isSelected ? c.text : c.subtext)
            }
            // Thin separators between unselected tabs.
            if !isSelected, i + 1 != selected, i < items.count - 1, hover != i {
                c.surface0.setFill()
                NSRect(x: r.maxX, y: r.minY + 8, width: 1, height: r.height - 12).fill()
            }
        }
        let p = plusRect
        if hoverPlus {
            c.surface0.setFill()
            NSBezierPath(roundedRect: p, xRadius: 5, yRadius: 5).fill()
        }
        c.subtext.setStroke()
        let plus = NSBezierPath()
        plus.lineWidth = 1.5
        plus.move(to: CGPoint(x: p.midX - 5, y: p.midY)); plus.line(to: CGPoint(x: p.midX + 5, y: p.midY))
        plus.move(to: CGPoint(x: p.midX, y: p.midY - 5)); plus.line(to: CGPoint(x: p.midX, y: p.midY + 5))
        plus.stroke()
    }

    private func drawX(in r: CGRect, color: NSColor) {
        color.setStroke()
        let x = NSBezierPath()
        x.lineWidth = 1.4
        x.lineCapStyle = .round
        x.move(to: CGPoint(x: r.minX, y: r.minY)); x.line(to: CGPoint(x: r.maxX, y: r.maxY))
        x.move(to: CGPoint(x: r.maxX, y: r.minY)); x.line(to: CGPoint(x: r.minX, y: r.maxY))
        x.stroke()
    }

    private func tab(at p: CGPoint) -> Int? {
        items.indices.first { tabRect($0).contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = tab(at: p)
        hoverClose = hover.map { closeRect($0).contains(p) } ?? false
        hoverPlus = plusRect.contains(p)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        hoverClose = false
        hoverPlus = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if plusRect.contains(p) { onNewTab?(); return }
        guard let i = tab(at: p) else { return }
        if items.count > 1, closeRect(i).contains(p) { onClose?(i); return }
        onSelect?(i)
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click closes a tab.
        guard event.buttonNumber == 2, let i = tab(at: convert(event.locationInWindow, from: nil)) else { return }
        onClose?(i)
    }

    /// Double-clicking empty space opens a new tab.
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, tab(at: p) == nil, !plusRect.contains(p) { onNewTab?() }
    }
}

/// Flipped container that reports layout passes.
final class FlippedView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
