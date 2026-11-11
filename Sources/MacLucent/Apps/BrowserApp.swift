import AppKit
import WebKit

/// A minimal developer-friendly browser window built on WebKit.
final class BrowserApp: NSObject, TileApp, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let view: NSView
    let webView: WKWebView
    var symbolName: String { "globe" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?
    private weak var manager: WindowManager?

    private let toolbar = FlippedView()
    private let urlBox = NSView()
    private let urlField = NSTextField()
    private let lockIcon = NSImageView()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private let progress = CALayer()
    private var observations: [NSKeyValueObservation] = []
    private let toolbarHeight: CGFloat = 38

    var title: String {
        if let t = webView.title, !t.isEmpty { return t }
        return webView.url?.host ?? "New Tab"
    }

    init(manager: WindowManager?, configuration: WKWebViewConfiguration? = nil, url: String? = nil) {
        self.manager = manager
        let config = configuration ?? {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .default()
            c.preferences.isElementFullscreenEnabled = true
            return c
        }()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let container = FlippedView()
        view = container
        super.init()

        let c = Config.shared
        container.wantsLayer = true
        container.layer?.backgroundColor = c.mantle.cgColor

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.underPageBackgroundColor = c.base

        buildToolbar()
        container.addSubview(toolbar)
        container.addSubview(webView)
        container.onLayout = { [weak self] in self?.layout() }

        observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.onTitleChange?() } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncURL() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncButtons() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncButtons() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncProgress() } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncProgress(); self?.syncButtons() } },
        ]

        if configuration == nil {
            load(url ?? c.homepage)
        }
        syncButtons()
    }

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
        toolbar.frame = CGRect(x: 0, y: 0, width: b.width, height: toolbarHeight)
        webView.frame = CGRect(x: 0, y: toolbarHeight, width: b.width, height: max(0, b.height - toolbarHeight))
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
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    private func syncURL() {
        if urlField.currentEditor() == nil {
            urlField.stringValue = webView.url?.absoluteString ?? ""
        }
        let secure = webView.url?.scheme == "https"
        lockIcon.image = NSImage(systemSymbolName: secure ? "lock.fill" : "globe", accessibilityDescription: nil)
        onTitleChange?()
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
        CATransaction.begin()
        CATransaction.setDisableActions(!webView.isLoading)
        progress.isHidden = !webView.isLoading
        progress.frame = CGRect(x: 0, y: toolbarHeight - 2, width: toolbar.bounds.width * webView.estimatedProgress, height: 2)
        CATransaction.commit()
    }

    // MARK: TileApp

    func focus() {
        guard let window = webView.window else { return }
        if webView.url == nil {
            window.makeFirstResponder(urlField)
        } else if urlField.currentEditor() == nil {
            window.makeFirstResponder(webView)
        }
    }

    func shutdown() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch ch {
            case "l": webView.window?.makeFirstResponder(urlField); urlField.selectText(nil)
            case "r": webView.reload()
            case "[": webView.goBack()
            case "]": webView.goForward()
            case "=", "+": webView.pageZoom = min(3, webView.pageZoom + 0.1)
            case "-": webView.pageZoom = max(0.3, webView.pageZoom - 0.1)
            case "0": webView.pageZoom = 1
            default: return false
            }
            return true
        }
        if flags == [.command, .shift], ch == "r" {
            webView.reloadFromOrigin()
            return true
        }
        return false
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            urlField.stringValue = webView.url?.absoluteString ?? ""
            webView.window?.makeFirstResponder(webView)
            return true
        }
        return false
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open → new tiled browser window.
        let app = BrowserApp(manager: manager, configuration: configuration)
        manager?.open(app)
        return app.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        onRequestClose?()
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

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled { return }
        let failing = (e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ""
        let html = """
        <html><body style="background:#1e1e2e;color:#cdd6f4;font:15px -apple-system;display:flex;align-items:center;justify-content:center;height:90vh">
        <div style="max-width:520px"><h2 style="font-weight:500;color:#f38ba8">Can't open this page</h2>
        <p style="color:#a6adc8">\(failing.htmlEscaped)</p><p style="color:#6c7086">\(e.localizedDescription.htmlEscaped)</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        urlField.stringValue = failing
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
