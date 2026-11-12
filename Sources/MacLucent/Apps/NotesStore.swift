import Foundation

/// One note: a plain Markdown file in ~/.config/lucent/notes.
struct Note: Equatable {
    let url: URL
    var text: String
    var modified: Date

    var id: String { url.deletingPathExtension().lastPathComponent }

    /// The first non-empty line, without Markdown heading marks.
    var title: String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(80)) }
        }
        return "Untitled"
    }

    /// The second non-empty line, for the sidebar.
    var preview: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#>")).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.dropFirst().first.map { String($0.prefix(80)) } ?? ""
    }
}

/// Reads and writes notes. Files are the source of truth, so notes can be edited, synced or backed
/// up with any tool; the list is re-read when the Scratchpad gains focus.
enum NotesStore {
    static var directory: URL {
        // Test runs point this at a scratch folder so they never touch the user's notes.
        if let dir = ProcessInfo.processInfo.environment["ML_NOTES_DIR"] { return URL(fileURLWithPath: dir) }
        return Config.directory.appendingPathComponent("notes")
    }

    static func all() -> [Note] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Note(url: url, text: text, modified: modified)
        }.sorted { $0.modified > $1.modified }
    }

    static func create(text: String = "") -> Note {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        var url = directory.appendingPathComponent("note-\(f.string(from: Date())).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("note-\(f.string(from: Date()))-\(n).md")
            n += 1
        }
        let note = Note(url: url, text: text, modified: Date())
        save(note)
        return note
    }

    static func save(_ note: Note) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? note.text.write(to: note.url, atomically: true, encoding: .utf8)
    }

    static func delete(_ note: Note) {
        // To the Trash, not gone: a deleted note can still be recovered.
        try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
    }
}
