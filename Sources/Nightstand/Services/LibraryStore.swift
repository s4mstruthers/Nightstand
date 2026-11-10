import SwiftUI

/// Progress and short status messages shown at the bottom of the window.
@MainActor @Observable
final class ActivityCenter {
    struct Activity: Equatable {
        var title: String
        var detail: String?
        var progress: Double?
    }

    private(set) var current: Activity?
    private var dismissal: Task<Void, Never>?

    func set(_ title: String, detail: String? = nil, progress: Double? = nil) {
        dismissal?.cancel()
        current = Activity(title: title, detail: detail, progress: progress)
    }

    /// Shows a message briefly, then clears it.
    func flash(_ title: String, detail: String? = nil) {
        dismissal?.cancel()
        current = Activity(title: title, detail: detail, progress: nil)
        dismissal = Task {
            try? await Task.sleep(for: .seconds(detail == nil ? 2.5 : 5))
            if !Task.isCancelled { current = nil }
        }
    }
}

/// The library: a folder of book files plus one JSON file describing them.
@MainActor @Observable
final class LibraryStore {
    private(set) var books: [Book] = []
    /// The reader's taste notes and wishlist; saved as soon as it changes.
    var companion = Companion() {
        didSet {
            guard companion != oldValue, !loadingCompanion else { return }
            try? CompanionIndex.save(companion, to: root)
            companionModification = CompanionIndex.modificationDate(in: root)
        }
    }
    private var loadingCompanion = false
    private var companionModification: Date?
    let root: URL
    let activity: ActivityCenter

    private var booksFolder: URL { root.appending(path: "Books") }
    private var indexURL: URL { root.appending(path: "library.json") }
    private var pendingSave: Task<Void, Never>?
    private var hasUnsavedChanges = false
    /// The index's modification date as this process last read or wrote it.
    private var knownModification: Date?
    private var watcher: Timer?

    nonisolated static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["NIGHTSTAND_LIBRARY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Nightstand Library")
    }

    init(root: URL = LibraryStore.defaultRoot, activity: ActivityCenter) {
        self.root = root
        self.activity = activity
        try? FileManager.default.createDirectory(at: booksFolder, withIntermediateDirectories: true)
        load()
        // The MCP server (an AI assistant) may edit the index while the app is open.
        watcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfChanged() }
        }
    }

    // MARK: Paths

    /// Cover location in the default library. Static so cover views work without the environment, which
    /// lazily created table cells do not always receive.
    nonisolated static func coverURL(for id: UUID) -> URL {
        defaultRoot.appending(path: "Books/\(id.uuidString)/cover.jpg")
    }

    func folder(for book: Book) -> URL { booksFolder.appending(path: book.id.uuidString) }
    func fileURL(for book: Book) -> URL { folder(for: book).appending(path: book.fileName) }
    func coverURL(for book: Book) -> URL { folder(for: book).appending(path: "cover.jpg") }

    // MARK: Persistence

    private func load() {
        do {
            let loaded = try LibraryIndex.load(from: root)
            if loaded != books { withAnimation(.snappy) { books = loaded } }
        } catch {
            // Never overwrite an index we could not read; keep it for recovery.
            let backup = root.appending(path: "library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: indexURL, to: backup)
        }
        knownModification = LibraryIndex.modificationDate(in: root)
        loadCompanion()
    }

    private func loadCompanion() {
        loadingCompanion = true
        let loaded = CompanionIndex.load(from: root)
        if loaded != companion { withAnimation(.snappy) { companion = loaded } }
        loadingCompanion = false
        companionModification = CompanionIndex.modificationDate(in: root)
    }

    /// Picks up edits made by another process, unless there are local edits still waiting to be saved.
    func reloadIfChanged() {
        // An assistant may have added recommendations.
        if CompanionIndex.modificationDate(in: root) != companionModification { loadCompanion() }
        guard !hasUnsavedChanges, LibraryIndex.modificationDate(in: root) != knownModification else { return }
        load()
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { saveNow() }
        }
    }

    func saveNow() {
        pendingSave?.cancel()
        try? LibraryIndex.save(books, to: root)
        hasUnsavedChanges = false
        knownModification = LibraryIndex.modificationDate(in: root)
    }

    // MARK: Editing

    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }

    func update(_ book: Book) {
        reloadIfChanged()
        guard let index = books.firstIndex(where: { $0.id == book.id }), books[index] != book else { return }
        books[index] = book
        scheduleSave()
    }

    func modify(_ ids: Set<UUID>, _ change: (inout Book) -> Void) {
        reloadIfChanged()
        for index in books.indices where ids.contains(books[index].id) {
            change(&books[index])
        }
        scheduleSave()
    }

    func setStatus(_ status: ReadingStatus, for ids: Set<UUID>) {
        modify(ids) { $0.setStatus(status) }
    }

    func setCover(_ imageData: Data, for id: UUID) {
        guard let book = book(id), let jpeg = ImageTools.encode(imageData, as: .jpeg, maxPixel: 1600) else {
            activity.flash("That file isn't an image Nightstand can use")
            return
        }
        do {
            try jpeg.write(to: coverURL(for: book), options: .atomic)
            modify([id]) {
                $0.hasCover = true
                $0.customCover = true
                $0.coverVersion += 1
            }
        } catch {
            activity.flash("Couldn't save the cover", detail: error.localizedDescription)
        }
    }

    /// Goes back to the cover embedded in the book file.
    func restoreCover(for id: UUID) {
        guard let book = book(id), book.format.isEPUBBased else { return }
        let original = (try? EPUBReader.read(fileURL(for: book)))?.cover
            .flatMap { ImageTools.encode($0, as: .jpeg, maxPixel: 1600) }
        if let original {
            try? original.write(to: coverURL(for: book), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: coverURL(for: book))
        }
        modify([id]) {
            $0.hasCover = original != nil
            $0.customCover = false
            $0.coverVersion += 1
        }
    }

    func delete(_ ids: Set<UUID>) {
        for book in books where ids.contains(book.id) {
            try? FileManager.default.trashItem(at: folder(for: book), resultingItemURL: nil)
        }
        withAnimation(.snappy) { books.removeAll { ids.contains($0.id) } }
        saveNow()
    }

    // MARK: Importing

    private func isDuplicate(_ book: Book) -> Bool {
        books.contains {
            $0.title.caseInsensitiveCompare(book.title) == .orderedSame
                && $0.authors == book.authors && $0.format == book.format && $0.fileSize == book.fileSize
        }
    }

    func importFiles(_ urls: [URL]) async {
        let files = await Task.detached { Ingest.expand(urls) }.value
        guard !files.isEmpty else {
            activity.flash("No supported books found")
            return
        }
        await ingest(files.map { CalibreLibrary.Entry(file: $0, metadata: nil, cover: nil) }, title: "Adding books…")
    }

    func importCalibre(from library: URL) async {
        activity.set("Reading Calibre library…")
        let entries = await Task.detached { CalibreLibrary.entries(in: library) }.value
        guard !entries.isEmpty else {
            activity.flash("No Calibre books found in that folder")
            return
        }
        await ingest(entries, title: "Importing from Calibre…")
    }

    private func ingest(_ entries: [CalibreLibrary.Entry], title: String) async {
        var added = 0, duplicates = 0, failed = 0
        let destination = booksFolder
        for (index, entry) in entries.enumerated() {
            activity.set(title, detail: entry.file.lastPathComponent,
                         progress: Double(index) / Double(entries.count))
            do {
                let book = try await Task.detached(priority: .userInitiated) {
                    try Ingest.ingest(file: entry.file, booksFolder: destination,
                                      metadata: entry.metadata, cover: entry.cover)
                }.value
                if isDuplicate(book) {
                    try? FileManager.default.removeItem(at: folder(for: book))
                    duplicates += 1
                } else {
                    withAnimation(.snappy) { books.insert(book, at: 0) }
                    added += 1
                }
            } catch {
                failed += 1
            }
        }
        saveNow()
        var notes: [String] = []
        if duplicates > 0 { notes.append("\(duplicates) already in your library") }
        if failed > 0 { notes.append("\(failed) couldn't be read") }
        activity.flash("Added \(added) book\(added == 1 ? "" : "s")",
                       detail: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    // MARK: Exporting

    func export(_ ids: Set<UUID>, to folder: URL, options: FormatOptions) async {
        let selected = books.filter { ids.contains($0.id) }
        var failed = 0
        for (index, book) in selected.enumerated() {
            activity.set("Exporting…", detail: book.title, progress: Double(index) / Double(selected.count))
            let source = fileURL(for: book)
            // The library's cover always goes into the file: it can be better than the one embedded in it.
            let cover = book.hasCover ? coverURL(for: book) : nil
            do {
                try await Task.detached {
                    let built = try BookBuilder.build(book: book, source: source, customCover: cover,
                                                      options: options, profile: .export)
                    defer { try? FileManager.default.removeItem(at: built.deletingLastPathComponent()) }
                    let destination = folder.appending(path: built.lastPathComponent)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: built, to: destination)
                }.value
            } catch {
                failed += 1
            }
        }
        let done = selected.count - failed
        activity.flash("Exported \(done) book\(done == 1 ? "" : "s")",
                       detail: failed > 0 ? "\(failed) failed" : nil)
    }
}
