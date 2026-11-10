import SwiftUI

/// ⌘K: type to find a book, jump to a page, or run an action without hunting through menus.
struct QuickFind: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let title: String
        var subtitle: String = ""
        let symbol: String
        var book: Book?
        var keywords: String = ""
        let run: () -> Void
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Find a book, page or action", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { choose(results) }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == highlighted)
                                .id(index)
                                .onTapGesture {
                                    highlighted = index
                                    choose(results)
                                }
                        }
                        if results.isEmpty {
                            Text("Nothing matches “\(query)”")
                                .foregroundStyle(.secondary)
                                .padding(30)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
            }
            .frame(height: 340)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            app.showQuickFind = false
            return .handled
        }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if let book = item.book {
                CoverView(book: book, maxPixel: 96, cornerRadius: 2).frame(width: 22)
            } else {
                Image(systemName: item.symbol)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer()
            if selected { Image(systemName: "return").font(.caption) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    private func choose(_ results: [Item]) {
        guard results.indices.contains(highlighted) else { return }
        app.showQuickFind = false
        let item = results[highlighted]
        // Let the sheet close before anything else is presented.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { item.run() }
    }

    private var results: [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let commands = commands
        guard !needle.isEmpty else { return commands }
        func matches(_ item: Item) -> Bool {
            (item.title + " " + item.subtitle + " " + item.keywords).lowercased().contains(needle)
        }
        let found: [Book] = app.store.books.filter { $0.searchText.contains(needle) }
        let ranked: [Book] = found.sorted { (a: Book, b: Book) -> Bool in
            a.title.lowercased().hasPrefix(needle) && !b.title.lowercased().hasPrefix(needle)
        }
        let books: [Item] = ranked.prefix(12).map { (book: Book) -> Item in
            Item(id: book.id.uuidString, title: book.title, subtitle: book.authorText, symbol: "book", book: book) {
                app.showInLibrary(book)
            }
        }
        func named(_ names: [String], kind: String, symbol: String, item: @escaping (String) -> SidebarItem) -> [Item] {
            let matching: [String] = Set(names).filter { $0.lowercased().contains(needle) }.sorted()
            return matching.prefix(4).map { (name: String) -> Item in
                Item(id: kind + "-" + name, title: name, subtitle: kind, symbol: symbol) { go(item(name)) }
            }
        }
        let allBooks: [Book] = app.store.books
        let series: [Item] = named(allBooks.compactMap(\.series), kind: "Series", symbol: "square.stack") { .series($0) }
        let authors: [Item] = named(allBooks.flatMap(\.authors), kind: "Author", symbol: "person") { .author($0) }
        let tags: [Item] = named(allBooks.flatMap(\.tags), kind: "Tag", symbol: "tag") { .tag($0) }
        let collections: [Item] = series + authors + tags
        let actions: [Item] = commands.filter(matches)
        return actions + books + collections
    }

    private func go(_ item: SidebarItem) {
        withAnimation(.snappy) { app.sidebar = item }
    }

    private var commands: [Item] {
        var items: [Item] = [
            Item(id: "home", title: "Home", subtitle: "What you're reading and how it's going", symbol: "house") { go(.home) },
            Item(id: "discover", title: "Discover", subtitle: "Recommendations, wishlist and your taste",
                 symbol: "sparkles", keywords: "recommend next wishlist taste assistant ai") { go(.discover) },
            Item(id: "journal", title: "Journal", subtitle: "Your thoughts, notes and highlights",
                 symbol: "text.book.closed", keywords: "notes highlights quotes review") { go(.journal) },
            Item(id: "organise", title: "Organise", subtitle: "Every tool for tidying your library",
                 symbol: "wand.and.stars", keywords: "tools tidy bulk batch import") { go(.organise) },
            Item(id: "all", title: "All Books", symbol: "books.vertical", keywords: "library") { go(.all) },
            Item(id: "favourites", title: "Favourites", symbol: "heart") { go(.favourites) },
            Item(id: "cleanup", title: "Clean Up Details…",
                 subtitle: "Fix author names, long titles and series across the library", symbol: "wand.and.stars",
                 keywords: "bulk batch tidy fix metadata rename") { app.startCleanUp(wholeLibrary: true) },
            Item(id: "format", title: "Format Books…", subtitle: "Font size, spacing and layout on your e-reader",
                 symbol: "textformat.size", keywords: "convert css font margin line") { app.showFormatting = true },
            Item(id: "add", title: "Add Books…", subtitle: "Add book files or folders", symbol: "plus",
                 keywords: "import open file") { app.addBooks() },
            Item(id: "calibre", title: "Import from Calibre…", symbol: "books.vertical") { app.importCalibre() },
            Item(id: "goodreads", title: "Import Ratings from Goodreads…", symbol: "star.leadinghalf.filled") {
                app.importGoodreads()
            },
            Item(id: "settings", title: "Settings…", subtitle: "Formatting, devices and AI assistants",
                 symbol: "gearshape", keywords: "preferences assistant claude mcp connect") { openSettings() },
        ]
        if !app.selection.isEmpty {
            let count = app.selection.count
            items.insert(Item(id: "edit", title: count > 1 ? "Edit Details of \(count) Selected Books…" : "Edit Details…",
                              symbol: "pencil", keywords: "batch bulk metadata") { app.edit(app.selection) }, at: 0)
        }
        for status in ReadingStatus.allCases {
            items.append(Item(id: "status-" + status.rawValue, title: status.label, subtitle: "Books by status",
                              symbol: status.symbol) { go(.status(status)) })
        }
        for device in app.devices.devices {
            items.append(Item(id: "device-" + device.id, title: device.name, subtitle: "E-reader",
                              symbol: "ipad.landscape") { go(.device(device.id)) })
            if device.kind == .kobo {
                items.append(Item(id: "sync-" + device.id, title: "Sync Reading from \(device.name)",
                                  symbol: "arrow.triangle.2.circlepath", keywords: "kobo progress highlights") {
                    app.syncReading(from: device.id)
                })
                items.append(Item(id: "covers-" + device.id, title: "Refresh Covers on \(device.name)", symbol: "photo",
                                  keywords: "kobo cover image missing wrong") { app.refreshCovers(on: device.id) })
                items.append(Item(id: "tidy-" + device.id, title: "Tidy Up \(device.name)…", symbol: "sparkles",
                                  keywords: "kobo calibre clean") { app.startTidyUp(device.id) })
            }
        }
        return items
    }
}
