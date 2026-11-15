import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("sidebar.series") private var seriesExpanded = true
    @AppStorage("sidebar.authors") private var authorsExpanded = false
    @AppStorage("sidebar.tags") private var tagsExpanded = false

    var body: some View {
        @Bindable var app = app
        let books = app.store.books
        let fresh = app.store.companion.recommendations.count { $0.state == .new }

        List(selection: $app.sidebar) {
            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Label("Discover", systemImage: "sparkles").badge(fresh).tag(SidebarItem.discover)
                Label("Browse", systemImage: "globe").tag(SidebarItem.browse)
                Label("Journal", systemImage: "text.book.closed").tag(SidebarItem.journal)
                Label("Organise", systemImage: "wand.and.stars").tag(SidebarItem.organise)
                Label("Fonts", systemImage: "textformat").tag(SidebarItem.fonts)
            }

            Section("Library") {
                row("All Books", symbol: "books.vertical", count: books.count, item: .all)
                ForEach(ReadingStatus.allCases) { status in
                    row(status.label, symbol: status.symbol,
                        count: books.count { $0.status == status }, item: .status(status))
                }
                row("Favourites", symbol: "heart", count: books.count(where: \.isFavourite), item: .favourites)
                if case .needs(let issue) = app.sidebar {
                    row(issue.title, symbol: issue.symbol, count: books.count(where: issue.matches), item: .needs(issue))
                }
            }

            Section("Shelves") {
                ForEach(app.store.companion.shelves) { shelf in
                    row(shelf.name, symbol: "line.3.horizontal.decrease.circle", count: books.count(where: shelf.matches),
                        item: .shelf(shelf.id))
                        .contextMenu {
                            Button("Edit Shelf…") { app.editingShelf = shelf }
                            Button("Delete Shelf", role: .destructive) {
                                withAnimation(.snappy) {
                                    app.store.companion.shelves.removeAll { $0.id == shelf.id }
                                    if app.sidebar == .shelf(shelf.id) { app.sidebar = .all }
                                }
                            }
                        }
                }
                Button {
                    app.editingShelf = Shelf(name: "")
                } label: {
                    Label("New Shelf…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Save a filter, such as unread sci-fi or five-star books, as a shelf in the sidebar")
            }

            if !app.devices.devices.isEmpty {
                Section("Devices") {
                    ForEach(app.devices.devices) { device in
                        Label(device.name, systemImage: "ipad.landscape")
                            .badge(device.manifest.count)
                            .tag(SidebarItem.device(device.id))
                    }
                }
            }

            group("Series", expanded: $seriesExpanded, symbol: "square.stack",
                  values: books.compactMap { $0.series?.isEmpty == false ? $0.series : nil }) { .series($0) }
            group("Authors", expanded: $authorsExpanded, symbol: "person",
                  values: books.flatMap(\.authors)) { .author($0) }
            group("Tags", expanded: $tagsExpanded, symbol: "tag",
                  values: books.flatMap(\.tags)) { .tag($0) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
            if app.updater.updateAvailable, !app.updater.showSheet, let version = app.updater.release?.version {
                Button {
                    app.updater.showSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update to \(version)")
                        Spacer()
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .help("See what's new and install it")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button {
                app.showQuickFind = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Find Anything")
                    Spacer()
                    Text("⌘K").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("Find a book, a page or an action")
            }
            .animation(.snappy, value: app.updater.updateAvailable && !app.updater.showSheet)
        }
    }

    private func row(_ title: String, symbol: String, count: Int, item: SidebarItem) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(item)
    }

    @ViewBuilder
    private func group(_ title: String, expanded: Binding<Bool>, symbol: String, values: [String],
                       item: @escaping (String) -> SidebarItem) -> some View {
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        let names = counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if !names.isEmpty {
            Section(title, isExpanded: expanded) {
                ForEach(names, id: \.self) { name in
                    row(name, symbol: symbol, count: counts[name] ?? 0, item: item(name))
                }
            }
        }
    }
}
