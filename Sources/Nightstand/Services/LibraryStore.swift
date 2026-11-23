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

    func clear() {
        dismissal?.cancel()
        current = nil
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
            do {
                try CompanionIndex.save(companion, to: root)
            } catch {
                activity.flash("Couldn't save your wishlist and shelves", detail: error.localizedDescription)
            }
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
    /// When the oldest change still waiting to be saved was made, so a run of edits can't put saving off for long.
    private var unsavedSince: Date?
    /// Each book as the index held it when this process last read or wrote it: what tells an edit made here
    /// from one made by another process when the two are merged.
    private var baseline: [UUID: Book] = [:]
    private var saveFailing = false
    /// The index exists but could not be read when the app opened. Nothing is saved over it until the reader
    /// chooses to start again; see `startEmptyLibrary`.
    private(set) var indexUnreadable = false
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
        load(initial: true)
        clearRatingsCopiedFromFiles()
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

    private func load(initial: Bool = false) {
        do {
            let loaded = try LibraryIndex.load(from: root)
            if loaded != books { withAnimation(.snappy) { books = loaded } }
            baseline = Self.byID(loaded)
        } catch {
            // Never overwrite an index we could not read without keeping it for recovery. When the app is
            // opening there is nothing in memory to save instead, so saving stops until the reader decides.
            LibraryIndex.keepUnreadableCopy(in: root)
            if initial { indexUnreadable = true }
        }
        knownModification = LibraryIndex.modificationDate(in: root)
        loadCompanion()
    }

    private static func byID(_ books: [Book]) -> [UUID: Book] {
        Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Gives up on an index that could not be read (a copy of it stays in the library folder) and starts again
    /// with no books.
    func startEmptyLibrary() {
        guard indexUnreadable else { return }
        indexUnreadable = false
        books = []
        baseline = [:]
        knownModification = LibraryIndex.modificationDate(in: root)
        saveNow()
    }

    /// Once: takes away ratings that earlier versions copied out of book files when they were added.
    private func clearRatingsCopiedFromFiles() {
        let key = "clearedRatingsFromFiles"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let books = books, folder = booksFolder
        Task {
            let ids = await Task.detached {
                Ingest.ratingsCopiedFromFiles(books) {
                    folder.appending(path: $0.id.uuidString).appending(path: $0.fileName)
                }
            }.value
            UserDefaults.standard.set(true, forKey: key)
            guard !ids.isEmpty else { return }
            modify(ids) { $0.rating = 0 }
            activity.flash("Cleared \(ids.count) rating\(ids.count == 1 ? "" : "s") you didn't give",
                           detail: "They came from inside the book files when the books were added.")
        }
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
        guard !hasUnsavedChanges, !indexUnreadable,
              LibraryIndex.modificationDate(in: root) != knownModification else { return }
        load()
    }

    /// Saves shortly after the last of a run of edits, and at most two seconds after the first.
    private func scheduleSave(after wait: TimeInterval = 0.4) {
        hasUnsavedChanges = true
        let now = Date(), since = unsavedSince ?? now
        unsavedSince = since
        let delay = max(0, min(wait, 2 - now.timeIntervalSince(since)))
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { saveNow() }
        }
    }

    /// Writes the index. If another process (an assistant) has written it since this one last looked, its
    /// changes are merged in first instead of being overwritten.
    func saveNow() {
        pendingSave?.cancel()
        guard !indexUnreadable else { return }
        do {
            if LibraryIndex.modificationDate(in: root) != knownModification {
                do {
                    let merged = LibraryIndex.merge(mine: books, theirs: try LibraryIndex.load(from: root),
                                                    baseline: baseline)
                    if merged != books { withAnimation(.snappy) { books = merged } }
                } catch {
                    // What is on disk can't be read; what is in memory is good, so it replaces it.
                    LibraryIndex.keepUnreadableCopy(in: root)
                }
            }
            try LibraryIndex.save(books, to: root)
            baseline = Self.byID(books)
            hasUnsavedChanges = false
            unsavedSince = nil
            saveFailing = false
            knownModification = LibraryIndex.modificationDate(in: root)
        } catch {
            // The changes stay in memory and are tried again; the reader is told once, not every few seconds.
            hasUnsavedChanges = true
            if !saveFailing {
                activity.flash("Couldn't save your library", detail: error.localizedDescription)
            }
            saveFailing = true
            pendingSave = Task {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { saveNow() }
            }
        }
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

    // MARK: Duplicates

    /// Keeps one book and moves to the Trash the others, after carrying over anything recorded only on them:
    /// the highest rating, the furthest status, notes, thoughts, highlights, tags and missing details.
    func merge(keeping keepID: UUID, removing others: [UUID]) {
        let extras = books.filter { others.contains($0.id) && $0.id != keepID }
        guard book(keepID) != nil, !extras.isEmpty else { return }
        let order: [ReadingStatus] = [.unread, .abandoned, .reading, .finished]
        modify([keepID]) { book in
            for other in extras {
                book.rating = max(book.rating, other.rating)
                if (order.firstIndex(of: other.status) ?? 0) > (order.firstIndex(of: book.status) ?? 0) {
                    book.status = other.status
                }
                if !other.notes.isEmpty, !book.notes.contains(other.notes) {
                    book.notes = book.notes.isEmpty ? other.notes : book.notes + "\n\n" + other.notes
                }
                if (book.liked ?? "").isEmpty { book.liked = other.liked }
                if (book.disliked ?? "").isEmpty { book.disliked = other.disliked }
                if other.isFavourite { book.favourite = true }
                book.tags += other.tags.filter { !book.tags.contains($0) }
                var highlights = book.highlights ?? []
                for highlight in other.highlights ?? [] where !highlights.contains(where: { $0.id == highlight.id }) {
                    highlights.append(highlight)
                }
                book.highlights = highlights.isEmpty ? nil : highlights
                if book.series == nil {
                    book.series = other.series
                    book.seriesIndex = other.seriesIndex
                }
                if (book.summary ?? "").isEmpty { book.summary = other.summary }
                book.publisher = book.publisher ?? other.publisher
                book.published = book.published ?? other.published
                book.isbn = book.isbn ?? other.isbn
                book.progress = [book.progress, other.progress].compactMap { $0 }.max()
                book.readingSeconds = [book.readingSeconds, other.readingSeconds].compactMap { $0 }.max()
                book.lastRead = [book.lastRead, other.lastRead].compactMap { $0 }.max()
                book.dateStarted = [book.dateStarted, other.dateStarted].compactMap { $0 }.min()
                book.dateFinished = book.dateFinished ?? other.dateFinished
                book.dateAdded = min(book.dateAdded, other.dateAdded)
                if book.goodreadsID == nil {
                    book.goodreadsID = other.goodreadsID
                    book.goodreadsRating = other.goodreadsRating
                    book.goodreadsRatings = other.goodreadsRatings
                }
            }
        }
        if let keep = book(keepID), !keep.hasCover,
           let donor = extras.first(where: \.hasCover), let data = try? Data(contentsOf: coverURL(for: donor)) {
            setCover(data, for: keepID)
        }
        delete(Set(extras.map(\.id)))
    }

    // MARK: Books without a file

    /// Adds many books without files at once, as an import does.
    func addWithoutFiles(_ added: [Book]) {
        for book in added {
            try? FileManager.default.createDirectory(at: folder(for: book), withIntermediateDirectories: true)
        }
        withAnimation(.snappy) { books.append(contentsOf: added) }
        scheduleSave()
    }

    /// Adds a book you've read but don't have a file for, with its cover when one is known. A wishlist entry
    /// for it comes off the wishlist.
    @discardableResult
    func addWithoutFile(_ book: Book, cover: URL?) async -> Book {
        var book = book
        book.noFile = true
        book.fileSize = 0
        try? FileManager.default.createDirectory(at: folder(for: book), withIntermediateDirectories: true)
        withAnimation(.snappy) {
            books.insert(book, at: 0)
            companion.recommendations.removeAll {
                Insights.ownedBook(title: $0.title, authors: $0.authors, in: [book]) != nil
            }
        }
        saveNow()
        if let cover, let data = await MetadataLookup.download(cover),
           let jpeg = ImageTools.encode(data, as: .jpeg, maxPixel: 1600),
           (try? jpeg.write(to: coverURL(for: book), options: .atomic)) != nil {
            modify([book.id]) {
                $0.hasCover = true
                $0.coverVersion += 1
            }
        }
        return self.book(book.id) ?? book
    }

    /// The book without a file that a newly added file is a copy of, if any.
    func fileless(matching book: Book) -> Book? {
        Insights.ownedBook(title: book.title, authors: book.authors, in: books.filter { !$0.hasFile })
    }

    /// Moves a newly ingested file onto the book without a file it belongs to, keeping everything recorded
    /// about the book and filling in only what it lacked.
    private func attach(_ added: Book, to existing: Book) {
        let fm = FileManager.default
        let from = folder(for: added), to = folder(for: existing)
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        let file = to.appending(path: added.fileName)
        try? fm.removeItem(at: file)
        try? fm.moveItem(at: from.appending(path: added.fileName), to: file)
        let takeCover = !existing.hasCover && added.hasCover
        if takeCover { try? fm.moveItem(at: from.appending(path: "cover.jpg"), to: coverURL(for: existing)) }
        try? fm.removeItem(at: from)
        modify([existing.id]) { book in
            book.noFile = nil
            book.format = added.format
            book.fileSize = added.fileSize
            if takeCover {
                book.hasCover = true
                book.coverVersion += 1
            }
            if (book.summary ?? "").isEmpty { book.summary = added.summary }
            book.publisher = book.publisher ?? added.publisher
            book.published = book.published ?? added.published
            book.isbn = book.isbn ?? added.isbn
            book.language = book.language ?? added.language
            if book.tags.isEmpty { book.tags = added.tags }
            if book.series == nil {
                book.series = added.series
                book.seriesIndex = added.seriesIndex
            }
            if book.authors.isEmpty { book.authors = added.authors }
        }
    }

    /// Gives a book without a file the file chosen for it.
    func attachFile(_ url: URL, to id: UUID) async {
        guard let existing = book(id) else { return }
        let destination = booksFolder
        do {
            let added = try await Task.detached(priority: .userInitiated) {
                try Ingest.ingest(file: url, booksFolder: destination)
            }.value
            attach(added, to: existing)
            saveNow()
            activity.flash("Added the file to “\(existing.title)”")
        } catch {
            activity.flash("Couldn't add that file", detail: error.localizedDescription)
        }
    }

    // MARK: Importing

    private func isDuplicate(_ book: Book) -> Bool {
        books.contains {
            $0.title.caseInsensitiveCompare(book.title) == .orderedSame
                && $0.authors == book.authors && $0.format == book.format && $0.fileSize == book.fileSize
        }
    }

    /// Bumped whenever fonts are added to My Fonts from outside the Fonts page, so it can reload.
    private(set) var fontsVersion = 0

    /// Adds books to the library. Font files among them (loose, in folders or in zips) go to My Fonts instead.
    func importFiles(_ urls: [URL]) async {
        let fontFolder = FontLibrary.folder(in: root)
        let fonts = await Task.detached { (try? FontLibrary.importFiles(urls, into: fontFolder)) ?? [] }.value
        if !fonts.isEmpty {
            fontsVersion += 1
            activity.flash(fonts.count == 1 ? "Added \(fonts[0]) to My Fonts" : "Added \(fonts.count) fonts to My Fonts",
                           detail: "Find them on the Fonts page, ready to install on your Kobo.")
        }
        let files = await Task.detached { Ingest.expand(urls) }.value
        guard !files.isEmpty else {
            if fonts.isEmpty { activity.flash("No supported books or fonts found") }
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
        var added = 0, duplicates = 0, failed = 0, attached = 0
        let destination = booksFolder
        for (index, entry) in entries.enumerated() {
            activity.set(title, detail: entry.file.lastPathComponent,
                         progress: Double(index) / Double(entries.count))
            do {
                let book = try await Task.detached(priority: .userInitiated) {
                    try Ingest.ingest(file: entry.file, booksFolder: destination,
                                      metadata: entry.metadata, cover: entry.cover)
                }.value
                if let existing = fileless(matching: book) {
                    attach(book, to: existing)
                    attached += 1
                } else if isDuplicate(book) {
                    try? FileManager.default.removeItem(at: folder(for: book))
                    duplicates += 1
                } else {
                    withAnimation(.snappy) { books.insert(book, at: 0) }
                    // Marks the library as changed, so an edit by an assistant mid-import can't replace it.
                    scheduleSave()
                    added += 1
                }
            } catch {
                failed += 1
            }
        }
        saveNow()
        var notes: [String] = []
        // Wishlist books that have just arrived come off the wishlist.
        let arrived = companion.recommendations.filter {
            $0.state == .saved && Insights.ownedBook(title: $0.title, authors: $0.authors, in: books) != nil
        }
        if !arrived.isEmpty {
            let ids = Set(arrived.map(\.id))
            withAnimation(.snappy) { companion.recommendations.removeAll { ids.contains($0.id) } }
            notes.append(arrived.count == 1 ? "“\(arrived[0].title)” came off your wishlist"
                         : "\(arrived.count) came off your wishlist")
        }
        if attached > 0 {
            notes.append(attached == 1 ? "the file was added to a book you'd read" : "\(attached) files added to books you'd read")
        }
        if duplicates > 0 { notes.append("\(duplicates) already in your library") }
        if failed > 0 { notes.append("\(failed) couldn't be read") }
        activity.flash("Added \(added) book\(added == 1 ? "" : "s")",
                       detail: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    // MARK: Exporting

    func export(_ ids: Set<UUID>, to folder: URL, options: FormatOptions) async {
        let selected = books.filter { ids.contains($0.id) && $0.hasFile }
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
