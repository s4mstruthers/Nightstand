import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("sidebar.series") private var seriesExpanded = true
    @AppStorage("sidebar.authors") private var authorsExpanded = false
    @AppStorage("sidebar.tags") private var tagsExpanded = false

    var body: some View {
        @Bindable var app = app
        let books = app.store.books

        List(selection: $app.sidebar) {
            Section("Library") {
                row("All Books", symbol: "books.vertical", count: books.count, item: .all)
                ForEach(ReadingStatus.allCases) { status in
                    row(status.label, symbol: status.symbol,
                        count: books.count { $0.status == status }, item: .status(status))
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
