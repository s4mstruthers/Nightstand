import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("coverSize") private var coverSize = 150.0

    var body: some View {
        let books = app.visibleBooks

        Group {
            if app.store.books.isEmpty {
                EmptyLibraryView()
            } else if books.isEmpty, app.search.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("No Books Here", systemImage: "books.vertical",
                                       description: Text(emptyText))
            } else if books.isEmpty {
                ContentUnavailableView.search(text: app.search)
            } else if app.viewMode == .grid {
                LibraryGridView(books: books, coverSize: coverSize)
            } else {
                LibraryTableView(books: books)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !app.store.books.isEmpty { statusBar(count: books.count) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .needs(let issue) = app.sidebar, !books.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: issue.symbol).foregroundStyle(.orange)
                    Text(issue.advice).font(.callout)
                    Spacer()
                    Button("Back to Organise") { withAnimation(.snappy) { app.sidebar = .organise } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .onDeleteCommand { app.requestDelete(app.selection) }
        .onExitCommand { withAnimation(.snappy) { app.selection = [] } }
    }

    private var emptyText: String {
        switch app.sidebar {
        case .favourites: "Click the heart on a book you love to keep it here."
        case .needs: "Nothing needs attention here any more."
        case .status(let status): "No books are marked \(status.label)."
        default: "Nothing matches this view."
        }
    }

    private func statusBar(count: Int) -> some View {
        HStack {
            Text(app.selection.isEmpty
                 ? "\(count) book\(count == 1 ? "" : "s")"
                 : "\(app.selection.count) of \(count) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.snappy, value: app.selection.count)
            Button(app.selection.count == count && count > 0 ? "Deselect All" : "Select All") {
                withAnimation(.snappy) {
                    if app.selection.count == count { app.selection = [] } else { app.selectAll() }
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.tint)
            Spacer()
            if app.viewMode == .grid {
                Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.tertiary)
                Slider(value: $coverSize, in: 100...240)
                    .controlSize(.mini)
                    .frame(width: 110)
                Image(systemName: "square.grid.2x2").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Grid

struct LibraryGridView: View {
    @Environment(AppModel.self) private var app
    let books: [Book]
    let coverSize: Double

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize, maximum: coverSize * 1.35), spacing: 24)],
                      spacing: 28) {
                ForEach(books) { book in
                    BookCell(book: book,
                             selected: app.selection.contains(book.id),
                             onDevice: app.devices.isOnDevice(book.id),
                             selecting: !app.selection.isEmpty) {
                        withAnimation(.snappy(duration: 0.18)) { app.toggle(book) }
                    }
                        .gesture(TapGesture(count: 2).onEnded { app.open(book) })
                        .simultaneousGesture(TapGesture().onEnded { app.click(book, in: books) })
                        .contextMenu { BookMenu(ids: app.targets(for: book)) }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .padding(24)
            .animation(.snappy(duration: 0.35), value: books.map(\.id))
            .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { app.selection = [] }
            }
        }
    }
}

struct BookCell: View {
    let book: Book
    let selected: Bool
    let onDevice: Bool
    /// True while any book is selected, so every cover shows its tick circle.
    var selecting = false
    var toggle: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(book: book)
                .overlay(alignment: .topTrailing) {
                    if onDevice {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .font(.system(size: 17))
                            .shadow(radius: 2, y: 1)
                            .padding(6)
                            .help("On your e-reader")
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hovering || selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.black.opacity(0.35)))
                            .shadow(radius: 2, y: 1)
                            .contentTransition(.symbolEffect(.replace))
                            .padding(6)
                            .contentShape(Rectangle())
                            .highPriorityGesture(TapGesture().onEnded(toggle))
                            .help(selected ? "Take out of the selection" : "Add to the selection")
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if book.isFavourite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.pink)
                            .padding(5)
                            .background(.regularMaterial, in: Circle())
                            .padding(6)
                            .padding(.bottom, book.status == .reading && (book.progress ?? 0) > 0 ? 8 : 0)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if book.status == .reading, let progress = book.progress, progress > 0 {
                        CoverProgressBar(progress: progress)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
                        .padding(-4)
                }
                .shadow(color: .black.opacity(hovering ? 0.32 : 0.2), radius: hovering ? 14 : 6, y: hovering ? 9 : 4)
                .scaleEffect(hovering ? 1.035 : 1)
                .animation(.spring(duration: 0.3, bounce: 0.35), value: hovering)
                .animation(.snappy(duration: 0.18), value: selected)
                .animation(.snappy(duration: 0.18), value: hovering || selecting)
                .animation(.spring(duration: 0.35, bounce: 0.4), value: book.isFavourite)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Text(book.authorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if book.rating > 0 { StarRating(rating: .constant(book.rating), size: 9, interactive: false) }
                    if book.status == .reading || book.status == .finished {
                        Image(systemName: book.status.symbol)
                            .font(.caption2)
                            .foregroundStyle(book.status == .finished ? Color.green : Color.accentColor)
                    }
                    if book.status == .reading, let progress = book.progress, progress > 0 {
                        Text("\(Int(progress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - List

struct LibraryTableView: View {
    @Environment(AppModel.self) private var app
    let books: [Book]
    @State private var order: [KeyPathComparator<Book>] = []

    var body: some View {
        @Bindable var app = app
        let rows = order.isEmpty ? books : books.sorted(using: order)

        Table(rows, selection: $app.selection, sortOrder: $order) {
            TableColumn("Title", value: \.title) { book in
                HStack(spacing: 10) {
                    CoverView(book: book, maxPixel: 96, cornerRadius: 2)
                        .frame(width: 24)
                    Text(book.title)
                    if app.devices.isOnDevice(book.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 200, ideal: 340)
            TableColumn("Author", value: \.authorText)
                .width(min: 100, ideal: 170)
            TableColumn("Series", value: \.seriesText)
                .width(min: 80, ideal: 150)
            TableColumn("Rating", value: \.rating) { book in
                StarRating(rating: .constant(book.rating), size: 10, interactive: false)
            }
            .width(80)
            TableColumn("Status", value: \.status.label) { book in
                Text(book.status.label).foregroundStyle(.secondary)
            }
            .width(80)
            TableColumn("Format", value: \.format.label) { book in
                Text(book.format.label).foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("Added", value: \.dateAdded) { book in
                Text(book.dateAdded, format: .dateTime.day().month().year()).foregroundStyle(.secondary)
            }
            .width(100)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty { BookMenu(ids: ids) }
        } primaryAction: { ids in
            if let id = ids.first, let book = app.store.book(id) { app.open(book) }
        }
    }
}

// MARK: - Context menu

struct BookMenu: View {
    @Environment(AppModel.self) private var app
    let ids: Set<UUID>

    var body: some View {
        let single = ids.count == 1 ? ids.first.flatMap(app.store.book) : nil

        if let single {
            Button("Open", systemImage: "book") { app.open(single) }
        }
        ForEach(app.devices.devices) { device in
            Button("Send to \(device.name)", systemImage: "arrow.up.forward.app") { app.send(ids, to: device.id) }
        }
        Divider()
        Menu("Status") {
            ForEach(ReadingStatus.allCases) { status in
                Button(status.label, systemImage: status.symbol) { app.store.setStatus(status, for: ids) }
            }
        }
        Button(ids.count == 1 && single?.isFavourite == true ? "Remove from Favourites" : "Add to Favourites",
               systemImage: "heart") {
            let remove = ids.count == 1 && single?.isFavourite == true
            app.store.modify(ids) { $0.favourite = remove ? nil : true }
        }
        Menu("Rating") {
            ForEach((1...5).reversed(), id: \.self) { stars in
                Button(String(repeating: "★", count: stars)) { app.store.modify(ids) { $0.rating = stars } }
            }
            Divider()
            Button("No Rating") { app.store.modify(ids) { $0.rating = 0 } }
        }
        Divider()
        Button(ids.count > 1 ? "Edit Details of \(ids.count) Books…" : "Edit Details…", systemImage: "pencil") {
            app.edit(ids)
        }
        if let single {
            Button("Look Up Details Online…", systemImage: "globe") { app.lookingUp = single }
            Button("Change Cover…", systemImage: "photo") { app.chooseCover(for: single.id) }
        }
        Button("Show in Finder", systemImage: "folder") { app.reveal(ids) }
        Button("Export…", systemImage: "square.and.arrow.up") { app.export(ids) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { app.requestDelete(ids) }
    }
}

// MARK: - Empty state

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: appeared)
            VStack(spacing: 6) {
                Text("Your library is empty")
                    .font(.system(.title, design: .serif, weight: .semibold))
                Text("Drop books anywhere in this window, or add them from your Mac.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Add Books…") { app.addBooks() }
                    .buttonStyle(.borderedProminent)
                Button("Import from Calibre…") { app.importCalibre() }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(40)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .onAppear { withAnimation(.spring(duration: 0.6)) { appeared = true } }
    }
}
