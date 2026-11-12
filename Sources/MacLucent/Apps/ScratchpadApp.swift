import AppKit

/// Scratchpad: persistent Markdown notes — snippets, commands, TODOs — in a tile.
/// Notes are plain files in ~/.config/lucent/notes, autosaved as you type.
final class ScratchpadApp: NSObject, TileApp, NSTextViewDelegate, NSTextStorageDelegate, NSSearchFieldDelegate {
    let view: NSView
    var symbolName: String { "note.text" }
    var onTitleChange: (() -> Void)?
    var onRequestClose: (() -> Void)?

    private var notes: [Note] = []
    private var current: Note?
    private var query = ""
    private var saveWork: DispatchWorkItem?
    private var c: Config { .shared }

    private let sidebar = FlippedView()
    private let search = NSSearchField()
    private let listScroll = NSScrollView()
    private let list = FlippedView()
    private var rows: [NoteRowView] = []
    private let newButton = NSButton(title: "New note", target: nil, action: nil)
    private let editorScroll = NSScrollView()
    private let editor = NoteTextView()
    private let placeholder = NSTextField(labelWithString: "Start typing — # for a heading, - [ ] for a task, `code`")
    private let divider = NSView()
    private let sidebarWidth: CGFloat = 220

    var title: String { current.map { "Scratchpad — \($0.title)" } ?? "Scratchpad" }

    init(noteID: String? = nil) {
        let root = FlippedView()
        view = root
        super.init()
        root.wantsLayer = true
        root.onLayout = { [weak self] in self?.layout() }

        sidebar.wantsLayer = true
        search.placeholderString = "Search notes"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.documentView = list
        newButton.bezelStyle = .rounded
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        newButton.imagePosition = .imageLeading
        newButton.target = self
        newButton.action = #selector(newNote)
        [search, listScroll, newButton].forEach(sidebar.addSubview)
        divider.wantsLayer = true

        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.textContainerInset = NSSize(width: 22, height: 20)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.textStorage?.delegate = self
        editor.onToggleTask = { [weak self] in self?.scheduleSave() }
        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.documentView = editor
        placeholder.font = c.uiFont(13, weight: .regular)

        [sidebar, divider, editorScroll, placeholder].forEach(root.addSubview)
        applyColors()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)

        reload()
        if let id = noteID, let n = notes.first(where: { $0.id == id }) { show(n) }
        else if let first = notes.first { show(first) }
        else { show(NotesStore.create(text: "# Scratchpad\n\n")) ; reload() }
    }

    // MARK: Notes

    private func reload() {
        notes = NotesStore.all()
        rebuildList()
    }

    private var filtered: [Note] {
        guard !query.isEmpty else { return notes }
        let q = query.lowercased()
        return notes.filter { $0.text.lowercased().contains(q) }
    }

    private func rebuildList() {
        rows.forEach { $0.removeFromSuperview() }
        rows = filtered.map { n in
            let row = NoteRowView(note: n)
            row.isSelected = n.url == current?.url
            row.onSelect = { [weak self] in self?.select(n) }
            row.onDelete = { [weak self] in self?.delete(n) }
            list.addSubview(row)
            return row
        }
        layout()
    }

    private func select(_ n: Note) {
        saveNow()
        // Re-read it: it may have been changed outside Lucent.
        show(NotesStore.all().first { $0.url == n.url } ?? n)
        view.window?.makeFirstResponder(editor)
    }

    private func show(_ n: Note) {
        current = n
        editor.string = n.text
        editor.undoManager?.removeAllActions()
        restyle()
        placeholder.isHidden = !n.text.isEmpty
        for row in rows { row.isSelected = row.note.url == n.url }
        onTitleChange?()
    }

    @objc private func newNote() {
        saveNow()
        let n = NotesStore.create()
        reload()
        show(n)
        view.window?.makeFirstResponder(editor)
    }

    private func delete(_ n: Note) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(n.title)”?"
        alert.informativeText = "The note is moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if n.url == current?.url { saveWork?.cancel(); current = nil }
        NotesStore.delete(n)
        reload()
        if current == nil { if let first = notes.first { show(first) } else { show(NotesStore.create()); reload() } }
    }

    // MARK: Saving

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !editor.string.isEmpty
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard var n = current, n.text != editor.string else { return }
        n.text = editor.string
        n.modified = Date()
        NotesStore.save(n)
        current = n
        if let i = notes.firstIndex(where: { $0.url == n.url }) { notes[i] = n }
        // Keep the list in recency order and titles current.
        notes.sort { $0.modified > $1.modified }
        rebuildList()
        onTitleChange?()
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        query = search.stringValue
        rebuildList()
    }

    // MARK: Markdown styling

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MarkdownStyler.style(textStorage)
    }

    private func restyle() {
        guard let storage = editor.textStorage else { return }
        storage.beginEditing()
        MarkdownStyler.style(storage)
        storage.endEditing()
        editor.typingAttributes = MarkdownStyler.baseAttributes
        editor.insertionPointColor = c.palette.rosewater
        editor.selectedTextAttributes = [.backgroundColor: c.accent.withAlphaComponent(0.3)]
        editor.linkTextAttributes = [.foregroundColor: c.palette.blue, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                     .cursor: NSCursor.pointingHand]
    }

    // MARK: Colours & layout

    @objc private func configChanged() {
        applyColors()
        restyle()
        rows.forEach { $0.applyColors() }
    }

    private func applyColors() {
        view.appearance = c.appearance
        view.layer?.backgroundColor = c.base.cgColor
        sidebar.layer?.backgroundColor = c.mantle.cgColor
        divider.layer?.backgroundColor = c.surface0.cgColor
        placeholder.textColor = c.overlay0
        editor.backgroundColor = c.base
        editor.drawsBackground = true
    }

    private func layout() {
        let b = view.bounds
        let sw = min(sidebarWidth, b.width * 0.4)
        sidebar.frame = CGRect(x: 0, y: 0, width: sw, height: b.height)
        divider.frame = CGRect(x: sw, y: 0, width: 1, height: b.height)
        search.frame = CGRect(x: 10, y: 12, width: sw - 20, height: 26)
        newButton.sizeToFit()
        newButton.frame = CGRect(x: 10, y: b.height - newButton.frame.height - 12, width: sw - 20, height: newButton.frame.height)
        let listTop: CGFloat = 46
        listScroll.frame = CGRect(x: 0, y: listTop, width: sw, height: max(0, newButton.frame.minY - listTop - 8))
        var y: CGFloat = 0
        for row in rows {
            row.frame = CGRect(x: 6, y: y, width: sw - 12, height: 46)
            y += 48
        }
        list.frame = CGRect(x: 0, y: 0, width: listScroll.contentSize.width, height: max(y, listScroll.contentSize.height))
        editorScroll.frame = CGRect(x: sw + 1, y: 0, width: max(0, b.width - sw - 1), height: b.height)
        editor.minSize = NSSize(width: 0, height: editorScroll.contentSize.height)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.frame.size.width = editorScroll.contentSize.width
        placeholder.sizeToFit()
        placeholder.frame.origin = CGPoint(x: sw + 1 + 27, y: 21)
    }

    // MARK: TileApp

    func focus() {
        // Notes may have been added or edited outside Lucent.
        let fresh = NotesStore.all()
        if fresh.map(\.url) != notes.map(\.url) {
            notes = fresh
            rebuildList()
        }
        view.window?.makeFirstResponder(editor)
    }

    func shutdown() { saveNow() }

    var sessionState: JSONValue? {
        saveNow()
        return .object(current.map { ["note": .string($0.id)] } ?? [:])
    }

    /// Mod+⇧N: new note.
    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == [c.mod, .shift], e.charactersIgnoringModifiers?.lowercased() == "n" {
            newNote()
            return true
        }
        return false
    }
}

/// The editor: a plain-text NSTextView where clicking a "[ ]" / "[x]" box toggles it.
final class NoteTextView: NSTextView {
    var onToggleTask: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let s = string as NSString
        if index <= s.length {
            let line = s.lineRange(for: NSRange(location: min(index, max(0, s.length - 1)), length: 0))
            let text = s.substring(with: line)
            if let m = MarkdownStyler.taskBox.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let box = NSRange(location: line.location + m.range(at: 1).location, length: 3) // "[ ]"
                if index >= box.location && index <= box.location + 3 {
                    let checked = (text as NSString).substring(with: NSRange(location: m.range(at: 1).location + 1, length: 1)).lowercased() == "x"
                    let mark = NSRange(location: box.location + 1, length: 1)
                    if shouldChangeText(in: mark, replacementString: checked ? " " : "x") {
                        replaceCharacters(in: mark, with: checked ? " " : "x")
                        didChangeText()
                        onToggleTask?()
                    }
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

/// Light Markdown styling for the editor (the text itself stays plain Markdown).
enum MarkdownStyler {
    static let taskBox = try! NSRegularExpression(pattern: #"^\s*[-*+]\s(\[[ xX]\])"#)

    @MainActor static var font: NSFont { Config.shared.terminalFont(size: 13.5) }

    @MainActor static var baseAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        return [.font: font, .foregroundColor: Config.shared.text, .paragraphStyle: p]
    }

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s.*$"#, options: .anchorsMatchLines)
    private static let bullet = try! NSRegularExpression(pattern: #"^\s*([-*+]|\d+\.)\s"#, options: .anchorsMatchLines)
    private static let task = try! NSRegularExpression(pattern: #"^\s*[-*+]\s\[([ xX])\].*$"#, options: .anchorsMatchLines)
    private static let quote = try! NSRegularExpression(pattern: #"^>.*$"#, options: .anchorsMatchLines)
    private static let fence = try! NSRegularExpression(pattern: #"^```[^\n]*\n[\s\S]*?(^```\s*$|\z)"#, options: .anchorsMatchLines)
    private static let code = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let bold = try! NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*"#)
    private static let link = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    @MainActor
    static func style(_ storage: NSTextStorage) {
        let c = Config.shared
        let p = c.palette
        let full = NSRange(location: 0, length: storage.length)
        let text = storage.string
        let base = font
        storage.setAttributes(baseAttributes, range: full)

        for m in heading.matches(in: text, range: full) {
            let level = m.range(at: 1).length
            let size = base.pointSize + CGFloat(max(0, 4 - level)) * 2
            storage.addAttributes([.font: NSFontManager.shared.convert(base.withSize(size), toHaveTrait: .boldFontMask),
                                   .foregroundColor: p.text], range: m.range)
            storage.addAttribute(.foregroundColor, value: c.accent, range: m.range(at: 1))
        }
        for m in bullet.matches(in: text, range: full) {
            storage.addAttribute(.foregroundColor, value: c.accent, range: m.range(at: 1))
        }
        for m in task.matches(in: text, range: full) {
            let done = (text as NSString).substring(with: m.range(at: 1)).lowercased() == "x"
            let box = NSRange(location: m.range(at: 1).location - 1, length: 3)
            storage.addAttributes([.foregroundColor: done ? p.green : c.accent,
                                   .font: NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)], range: box)
            if done {
                let rest = NSRange(location: box.location + 3, length: NSMaxRange(m.range) - box.location - 3)
                storage.addAttributes([.foregroundColor: p.overlay, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
            }
        }
        for m in quote.matches(in: text, range: full) {
            storage.addAttributes([.foregroundColor: p.subtext,
                                   .font: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)], range: m.range)
        }
        for m in bold.matches(in: text, range: full) {
            storage.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask), range: m.range)
        }
        for m in code.matches(in: text, range: full) {
            storage.addAttributes([.foregroundColor: p.green, .backgroundColor: p.surface0.withAlphaComponent(0.6)], range: m.range)
        }
        for m in fence.matches(in: text, range: full) {
            storage.addAttributes([.foregroundColor: p.teal, .backgroundColor: p.mantle, .font: base], range: m.range)
        }
        for m in link.matches(in: text, range: full) {
            if let url = m.url { storage.addAttribute(.link, value: url, range: m.range) }
        }
    }
}

/// A note in the sidebar.
final class NoteRowView: NSView {
    let note: Note
    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    var isSelected = false { didSet { applyColors() } }
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let trash = NSButton()
    private var hovering = false { didSet { applyColors() } }

    override var isFlipped: Bool { true }

    init(note: Note) {
        self.note = note
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        let c = Config.shared
        title.stringValue = note.title
        title.font = c.uiFont(12.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named // "now", "yesterday"…
        let when = Date().timeIntervalSince(note.modified) < 60 ? "now"
            : formatter.localizedString(for: min(note.modified, Date()), relativeTo: Date())
        detail.stringValue = note.preview.isEmpty ? when : "\(when) · \(note.preview)"
        detail.font = c.uiFont(11, weight: .regular)
        detail.lineBreakMode = .byTruncatingTail
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete note")
        trash.isBordered = false
        trash.toolTip = "Delete note"
        trash.target = self
        trash.action = #selector(deleteTapped)
        trash.isHidden = true
        [title, detail, trash].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyColors() {
        let c = Config.shared
        layer?.backgroundColor = (isSelected ? c.accent.withAlphaComponent(0.2)
                                  : hovering ? c.surface0.withAlphaComponent(0.6) : .clear).cgColor
        title.textColor = c.text
        detail.textColor = c.overlay0
        trash.contentTintColor = c.overlay0
        trash.isHidden = !hovering
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = CGRect(x: 10, y: 6, width: w - 40, height: 17)
        detail.frame = CGRect(x: 10, y: 24, width: w - 20, height: 15)
        trash.frame = CGRect(x: w - 26, y: 6, width: 18, height: 18)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    @objc private func deleteTapped() { onDelete?() }
}
