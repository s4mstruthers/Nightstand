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
                Label("Journal", systemImage: "text.book.closed").tag(SidebarItem.journal)
                Label("Organise", systemImage: "wand.and.stars").tag(SidebarItem.organise)
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
