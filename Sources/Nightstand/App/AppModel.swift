import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
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

    var sidebar: SidebarItem? = .all
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
    }

    // MARK: Derived

    var visibleBooks: [Book] {
        var books = store.books
        switch sidebar {
        case .status(let status): books = books.filter { $0.status == status }
        case .series(let name): books = books.filter { $0.series == name }
        case .author(let name): books = books.filter { $0.authors.contains(name) }
        case .tag(let name): books = books.filter { $0.tags.contains(name) }
        case .all, .device, nil: break
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
        case .all, nil: "All Books"
        }
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
    func startCleanUp() {
        let targets = selection.count > 1 ? selection : Set(store.books.map(\.id))
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
