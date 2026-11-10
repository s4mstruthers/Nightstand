import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case home, discover, journal, organise, fonts
    case favourites
    case needs(Insights.Issue)
    case all
    case status(ReadingStatus)
    case series(String)
    case author(String)
    case tag(String)
    case device(String)
}

/// The proposals being reviewed in the clean-up sheet.
struct CleanUpSession: Identifiable {
    let id = UUID()
    let proposals: [MetadataCleaner.Proposal]
}

enum ViewMode: String {
    case grid, list
}

@MainActor @Observable
final class AppSettings {
    var format: FormatOptions {
        didSet {
            if let data = try? JSONEncoder().encode(format) {
                UserDefaults.standard.set(data, forKey: "formatOptions")
            }
        }
    }

    init() {
        let stored = UserDefaults.standard.data(forKey: "formatOptions")
            .flatMap { try? JSONDecoder().decode(FormatOptions.self, from: $0) }
        format = stored ?? FormatOptions()
    }
}

/// Window state and the actions shared by menus, toolbars and context menus.
@MainActor @Observable
final class AppModel {
    let activity: ActivityCenter
    let store: LibraryStore
    let devices: DeviceManager
    let settings = AppSettings()
    let updater: Updater

    var sidebar: SidebarItem? = .home
    var showQuickFind = false
    var selection: Set<UUID> = []
    var search = ""
    var editing: Book?
    var batchEditing: BatchEditSession?
    var lookingUp: Book?
    var cleanUp: CleanUpSession?
    var pendingDelete: Set<UUID> = []
    var showDeleteConfirmation = false
    var showInspector = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    var sort = BookSort(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .recent {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sort") }
    }
    var viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .grid {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }

    private var anchor: UUID?

    init() {
        let activity = ActivityCenter()
        self.activity = activity
        store = LibraryStore(activity: activity)
        devices = DeviceManager(activity: activity)
        updater = Updater(activity: activity)
        devices.onConnect = { [weak self] device in
            guard let self, device.kind == .kobo else { return }
            Task {
                await self.restorePositions(on: device.id, automatic: true)
                if self.syncKoboAutomatically { self.syncReading(from: device.id, automatic: true) }
            }
        }
    }

    /// Whether reading progress and highlights are read from a Kobo as soon as it is plugged in.
    var syncKoboAutomatically = UserDefaults.standard.object(forKey: "syncKoboReading") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncKoboAutomatically, forKey: "syncKoboReading") }
    }
    private(set) var syncingDevice: String?
    /// Books replaced on each Kobo whose reading positions are still to be written back, by device id.
    private(set) var pendingRestores: [String: Int] = [:]
    var tidyingUp: KoboTidySession?
    var showFormatting = false

    var koboBackupFolder: URL { store.root.appending(path: "Kobo Backups") }

    // MARK: Derived

    var visibleBooks: [Book] {
        var books = store.books
        switch sidebar {
        case .status(let status): books = books.filter { $0.status == status }
        case .series(let name): books = books.filter { $0.series == name }
        case .author(let name): books = books.filter { $0.authors.contains(name) }
        case .tag(let name): books = books.filter { $0.tags.contains(name) }
        case .favourites: books = books.filter(\.isFavourite)
        case .needs(let issue): books = books.filter(issue.matches)
        case .all, .device, .home, .discover, .journal, .organise, .fonts, nil: break
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { books = books.filter { $0.searchText.contains(query) } }
        if case .series = sidebar { return BookSort.series.apply(books) }
        return sort.apply(books)
    }

    var title: String {
        switch sidebar {
        case .status(let status): status.label
        case .series(let name), .author(let name), .tag(let name): name
        case .device(let id): devices.device(id)?.name ?? "Device"
        case .home: "Home"
        case .discover: "Discover"
        case .journal: "Journal"
        case .organise: "Organise"
        case .fonts: "Fonts"
        case .favourites: "Favourites"
        case .needs(let issue): issue.title
        case .all, nil: "All Books"
        }
    }

    /// True when the main area shows a list of books, as opposed to a page such as Home or a device.
    var showsBooks: Bool {
        switch sidebar {
        case .home, .discover, .journal, .organise, .fonts, .device: false
        default: true
        }
    }

    /// Selects a book and makes sure its details are showing.
    func show(_ book: Book) {
        selection = [book.id]
        if !showInspector { showInspector = true }
    }

    /// Goes to the book in the full library.
    func showInLibrary(_ book: Book) {
        search = ""
        sidebar = .all
        show(book)
    }

    /// The books an action on `book` applies to: the whole selection if the book is part of it.
    func targets(for book: Book) -> Set<UUID> {
        selection.contains(book.id) ? selection : [book.id]
    }

    // MARK: Selection

    func click(_ book: Book, in books: [Book]) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            selection.formSymmetricDifference([book.id])
            anchor = book.id
        } else if modifiers.contains(.shift), let anchor,
                  let from = books.firstIndex(where: { $0.id == anchor }),
                  let to = books.firstIndex(where: { $0.id == book.id }) {
            selection.formUnion(books[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [book.id]
            anchor = book.id
        }
    }

    /// Adds a book to the selection, or takes it out, without needing a modifier key.
    func toggle(_ book: Book) {
        selection.formSymmetricDifference([book.id])
        anchor = book.id
    }

    func selectAll() {
        selection = Set(visibleBooks.map(\.id))
    }

    // MARK: Actions

    func addBooks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose books, or folders of books, to add to your library"
        panel.prompt = "Add"
        panel.allowedContentTypes = Ingest.supportedExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await store.importFiles(urls) }
    }

    func importCalibre() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your Calibre Library folder. Nightstand copies the books and leaves Calibre untouched."
        panel.prompt = "Import"
        let usual = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Calibre Library")
        if FileManager.default.fileExists(atPath: usual.path) { panel.directoryURL = usual }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.importCalibre(from: url) }
    }

    func importGoodreads() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose your Goodreads export. On goodreads.com: My Books → Tools → Import and export → Export Library."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.importGoodreads(from: url) }
    }

    /// Proposes tidier details for the selected books, or for the whole library when fewer than two are selected.
    func startCleanUp(wholeLibrary: Bool = false) {
        let targets = selection.count > 1 && !wholeLibrary ? selection : Set(store.books.map(\.id))
        let proposals = MetadataCleaner.proposals(for: targets, in: store.books)
        if proposals.isEmpty {
            activity.flash("Nothing to clean up", detail: "Titles, authors and series already look consistent.")
        } else {
            cleanUp = CleanUpSession(proposals: proposals)
        }
    }

    /// Opens the editor for one book, or the batch editor when several are given.
    func edit(_ ids: Set<UUID>) {
        if ids.count == 1, let id = ids.first {
            editing = store.book(id)
        } else if ids.count > 1 {
            // Keep the order shown in the library, so series numbers follow it.
            var ordered = visibleBooks.map(\.id).filter { ids.contains($0) }
            ordered += store.books.map(\.id).filter { ids.contains($0) && !ordered.contains($0) }
            batchEditing = BatchEditSession(bookIDs: ordered)
        }
    }

    /// Reads progress, reading time and highlights from a Kobo into the library. The device is not changed.
    func syncReading(from deviceID: String, automatic: Bool = false) {
        guard let device = devices.device(deviceID), device.kind == .kobo, syncingDevice == nil else { return }
        syncingDevice = deviceID
        activity.set("Reading progress from \(device.name)…")
        let root = device.url
        Task {
            defer { syncingDevice = nil }
            do {
                let records = try await Task.detached { try KoboReading.read(deviceRoot: root) }.value
                let (changed, summary) = KoboReading.merge(records, into: store.books, manifest: device.manifest)
                for book in changed { store.update(book) }
                if changed.isEmpty {
                    activity.flash("Reading progress is up to date", detail: automatic ? device.name : nil)
                } else {
                    var detail: [String] = []
                    if summary.finished > 0 { detail.append("\(summary.finished) finished") }
                    if summary.newHighlights > 0 {
                        detail.append("\(summary.newHighlights) new highlight\(summary.newHighlights == 1 ? "" : "s")")
                    }
                    activity.flash("Synced reading for \(changed.count) book\(changed.count == 1 ? "" : "s") from \(device.name)",
                                   detail: detail.isEmpty ? nil : detail.joined(separator: " · "))
                }
            } catch KoboReading.ReadError.missing where automatic {
                activity.flash("Connected \(device.name)")
            } catch {
                activity.flash("Couldn't sync reading from \(device.name)", detail: error.localizedDescription)
            }
        }
    }

    /// Replaces the cover thumbnails a Kobo shows with the library's covers, for books Nightstand sent.
    /// Book files aren't touched, so reading positions are unaffected.
    func refreshCovers(on deviceID: String) {
        guard let device = devices.device(deviceID), device.kind == .kobo else { return }
        let root = device.url
        let jobs = device.manifest.compactMap { id, path in
            store.book(id).flatMap { $0.hasCover ? (path, store.coverURL(for: $0)) : nil }
        }
        activity.set("Refreshing covers on \(device.name)…")
        Task {
            let books = await Task.detached {
                jobs.count { KoboCovers.refresh(for: $0.0, cover: $0.1, on: root) > 0 }
            }.value
            activity.flash(books == 0 ? "No covers needed refreshing"
                           : "Refreshed covers for \(books) book\(books == 1 ? "" : "s") on \(device.name)",
                           detail: books == 0 ? nil : "Eject the Kobo to see them.")
        }
    }

    // MARK: Tidying a Kobo

    func startTidyUp(_ deviceID: String) {
        guard let device = devices.device(deviceID), device.kind == .kobo else { return }
        tidyingUp = KoboTidySession(deviceID: deviceID, deviceName: device.name)
    }

    func planTidyUp(_ deviceID: String) async -> KoboTidy.Plan? {
        guard let device = devices.device(deviceID) else { return nil }
        let root = device.url, books = store.books
        return await Task.detached { KoboTidy.plan(deviceRoot: root, books: books) }.value
    }

    /// Replaces other apps' copies with Nightstand's, removes leftovers, and saves each reading position to be
    /// written back once the Kobo has imported the new copies.
    func tidyUp(_ deviceID: String, options: KoboTidy.Options = .saved) async {
        guard let device = devices.device(deviceID), device.kind == .kobo, syncingDevice == nil else { return }
        syncingDevice = deviceID
        defer { syncingDevice = nil }
        let root = device.url
        let backups = koboBackupFolder
        let fm = FileManager.default

        do {
            // 1. Keep what the Kobo knows, and a copy of its database, before changing anything.
            activity.set("Saving reading progress from \(device.name)…")
            let records = try await Task.detached { try KoboReading.read(deviceRoot: root) }.value
            let synced = KoboReading.merge(records, into: store.books, manifest: device.manifest)
            for book in synced.changed { store.update(book) }
            try await Task.detached { try KoboTidy.backUpDatabase(on: root, to: backups) }.value

            // 2. Books not in the library yet are added to it first.
            var plan = await planTidyUp(deviceID) ?? KoboTidy.Plan()
            if options.addMissing, !plan.imports.isEmpty {
                await store.importFiles(plan.imports.map { root.appending(path: $0) })
                plan = await planTidyUp(deviceID) ?? plan
            }
            // Finished books come off the device first, so they aren't replaced only to be removed.
            var removedFinished = 0
            if !options.removeDamaged { plan.damaged = [] }
            if options.removeFinished {
                let finished = plan.finished.filter { !options.skipped.contains($0.bookID) }
                let gone = Set(finished.map(\.bookID))
                for book in finished {
                    try? fm.removeItem(at: root.appending(path: book.path))
                    plan.damaged.append(book.path)  // its folder is checked for emptiness with the others
                }
                var manifest = DeviceScanner.readManifest(on: root)
                for id in gone { manifest[id] = nil }
                DeviceScanner.writeManifest(manifest, on: root)
                plan.replacements.removeAll { gone.contains($0.bookID) }
                removedFinished = finished.count
            }
            plan.replacements = plan.replacements.filter(options.includes)
            let removeLeftovers = options.removeLeftovers, keepPlace = options.keepPlace

            // 3. Keep the old copies of books that were opened, to find the reading position in them.
            let scratch = fm.temporaryDirectory.appending(path: "nightstand-tidy-\(UUID().uuidString)")
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            var oldCopies: [UUID: URL] = [:]
            // Places saved by an earlier tidy-up that the Kobo hasn't picked up yet move with their books.
            let earlier = KoboTidy.pending(on: root)
            for replacement in plan.replacements
            where keepPlace && (replacement.hasPosition || earlier[replacement.oldPath] != nil) {
                let copy = scratch.appending(path: "\(replacement.bookID.uuidString).epub")
                try? fm.copyContents(of: root.appending(path: replacement.oldPath), to: copy)
                oldCopies[replacement.bookID] = copy
            }

            // 4. Send Nightstand's copies.
            let books = plan.replacements.compactMap { store.book($0.bookID) }
            await devices.send(books, to: deviceID, store: store, options: settings.format)

            // 5. Save positions, then remove the old copies and leftovers.
            let manifest = DeviceScanner.readManifest(on: root)
            var pending = KoboTidy.pending(on: root)
            var replaced = 0
            let result: (Int, [String: KoboTidy.Position], Int) = await Task.detached {
                var pending = pending
                var replaced = 0
                var folders: Set<String> = []
                var moves: [KoboTidy.Move] = []
                for replacement in plan.replacements {
                    // A book that failed to send keeps its old copy.
                    guard let newPath = manifest[replacement.bookID] else { continue }
                    replaced += 1
                    let carried = pending.removeValue(forKey: replacement.oldPath)
                    if keepPlace, let record = replacement.record, replacement.hasPosition {
                        let bookmark = record.bookmark.flatMap { bookmark in
                            oldCopies[replacement.bookID].flatMap {
                                KoboTidy.relocate(bookmark, from: $0, to: root.appending(path: newPath),
                                                  chapterProgress: record.chapterProgress)
                            }
                        }
                        moves.append(KoboTidy.Move(old: replacement.oldPath, new: newPath, bookmark: bookmark))
                        pending[newPath] = KoboTidy.Position(
                            title: replacement.title, readStatus: record.readStatus,
                            percentRead: record.percentRead, lastRead: record.lastReadRaw,
                            secondsReading: record.secondsReading, chapterProgress: record.chapterProgress,
                            bookmark: bookmark)
                    } else if keepPlace, var carried {
                        carried.bookmark = carried.bookmark.flatMap { bookmark in
                            oldCopies[replacement.bookID].flatMap {
                                KoboTidy.relocate(bookmark, from: $0, to: root.appending(path: newPath),
                                                  chapterProgress: carried.chapterProgress)
                            }
                        }
                        pending[newPath] = carried
                    }
                    if replacement.oldPath.lowercased() != newPath.lowercased() {
                        try? fm.removeItem(at: root.appending(path: replacement.oldPath))
                        folders.insert((replacement.oldPath as NSString).deletingLastPathComponent)
                    }
                }
                for path in plan.damaged {
                    try? fm.removeItem(at: root.appending(path: path))
                    folders.insert((path as NSString).deletingLastPathComponent)
                }
                // Remove folders the old copies leave empty, and their parents if those empty too.
                for start in folders {
                    var folder = start
                    while !folder.isEmpty {
                        let url = root.appending(path: folder)
                        let left = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? ["?"]).filter { !$0.hasPrefix(".") }
                        guard left.isEmpty else { break }
                        try? fm.removeItem(at: url)
                        folder = (folder as NSString).deletingLastPathComponent
                    }
                }
                // Point the Kobo's own records at the new files, so it never sees them as new books. What it
                // can't carry over waits in `pending` until the Kobo has imported the book.
                let carried = keepPlace ? ((try? KoboTidy.carryOver(moves, on: root)) ?? []) : []
                let waiting = pending.keys.filter { !carried.contains($0) }.count
                KoboTidy.savePending(pending, on: root)
                // Last, so "._" files made by the writes above go too.
                for junk in removeLeftovers ? KoboTidy.junkFiles(on: root) : [] {
                    try? fm.removeItem(at: root.appending(path: junk))
                }
                return (replaced, pending, waiting)
            }.value
            replaced = result.0
            pending = result.1
            let waiting = result.2
            pendingRestores[deviceID] = waiting == 0 ? nil : waiting
            devices.refresh()
            var summary = ["\(replaced) book\(replaced == 1 ? "" : "s") replaced"]
            if removedFinished > 0 { summary.append("\(removedFinished) finished removed") }
            activity.flash("Tidied \(device.name): " + summary.joined(separator: ", "),
                           detail: waiting > 0
                               ? "Eject the Kobo and let it finish importing, then plug it back in to restore your places in \(waiting) book\(waiting == 1 ? "" : "s")."
                               : pending.isEmpty ? nil : "Your reading progress moved with them.")
        } catch {
            activity.flash("Couldn't tidy \(device.name)", detail: error.localizedDescription)
        }
    }

    /// Writes saved reading positions onto books the Kobo has imported since they were replaced.
    func restorePositions(on deviceID: String, automatic: Bool = false) async {
        guard let device = devices.device(deviceID), device.kind == .kobo else { return }
        let root = device.url, backups = koboBackupFolder
        guard !KoboTidy.pending(on: root).isEmpty else {
            pendingRestores[deviceID] = nil
            return
        }
        do {
            let (restored, waiting) = try await Task.detached {
                try KoboTidy.restore(on: root, backupFolder: backups)
            }.value
            pendingRestores[deviceID] = waiting == 0 ? nil : waiting
            if !restored.isEmpty {
                activity.flash("Restored your place in \(restored.count) book\(restored.count == 1 ? "" : "s") on \(device.name)",
                               detail: waiting > 0 ? "\(waiting) still waiting for the Kobo to import them" : nil)
            } else if !automatic, waiting > 0 {
                activity.flash("The Kobo hasn't imported the new copies yet",
                               detail: "Eject it, wait for it to finish importing, then plug it back in.")
            } else if !automatic {
                activity.flash("Your reading positions are all in place")
            }
        } catch {
            activity.flash("Couldn't restore reading positions", detail: error.localizedDescription)
        }
    }

    func open(_ book: Book) {
        NSWorkspace.shared.open(store.fileURL(for: book))
    }

    func reveal(_ ids: Set<UUID>) {
        let urls = store.books.filter { ids.contains($0.id) }.map { store.fileURL(for: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func send(_ ids: Set<UUID>, to deviceID: String) {
        let books = store.books.filter { ids.contains($0.id) }
        Task { await devices.send(books, to: deviceID, store: store, options: settings.format) }
    }

    func export(_ ids: Set<UUID>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to export. Your metadata, cover and formatting are written into each file."
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await store.export(ids, to: folder, options: settings.format) }
    }

    func chooseCover(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a cover image"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        store.setCover(data, for: id)
    }

    func requestDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
        showDeleteConfirmation = true
    }

    func confirmDelete() {
        store.delete(pendingDelete)
        selection.subtract(pendingDelete)
        pendingDelete = []
    }

    /// Handles files dropped on the window: images set the cover of a single selected book, the rest are imported.
    func handleDrop(_ urls: [URL]) -> Bool {
        let books = urls.filter { url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return isDirectory.boolValue || Ingest.isBook(url)
        }
        guard !books.isEmpty else { return false }
        Task { await store.importFiles(books) }
        return true
    }
}
