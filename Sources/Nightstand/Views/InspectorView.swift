import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let selected = app.selection
        Group {
            if selected.count == 1, let id = selected.first, app.store.book(id) != nil {
                BookInspector(id: id)
                    .id(id)
                    .transition(.opacity)
            } else if selected.count > 1 {
                MultipleSelectionInspector(ids: selected)
            } else {
                ContentUnavailableView("No Book Selected", systemImage: "book.closed",
                                       description: Text("Select a book to rate it, write notes and edit its details."))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selected)
    }
}

private struct BookInspector: View {
    @Environment(AppModel.self) private var app
    let id: UUID
    @State private var coverTargeted = false
    @State private var summaryExpanded = false

    private var book: Binding<Book> {
        Binding {
            app.store.book(id) ?? Book(title: "", format: .epub)
        } set: {
            app.store.update($0)
        }
    }

    var body: some View {
        let book = book.wrappedValue

        ScrollView {
            VStack(spacing: 18) {
                cover(book)

                VStack(spacing: 4) {
                    Text(book.title)
                        .font(.system(.title2, design: .serif, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text(book.authorText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !book.seriesText.isEmpty {
                        Button(book.seriesText) {
                            if let series = book.series { app.sidebar = .series(series) }
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .padding(.top, 2)
                    }
                }
                .textSelection(.enabled)

                StarRating(rating: self.book.rating, size: 22)

                Picker("Status", selection: Binding {
                    book.status
                } set: { status in
                    app.store.setStatus(status, for: [id])
                }) {
                    ForEach(ReadingStatus.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if book.status == .finished {
                    DatePicker("Finished", selection: Binding {
                        book.dateFinished ?? Date()
                    } set: { date in
                        app.store.modify([id]) { $0.dateFinished = date }
                    }, displayedComponents: .date)
                    .font(.callout)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if book.progress != nil || book.readingTimeText != nil {
                    readingProgress(book)
                }

                actions(book)

                section("Notes") {
                    NotesEditor(text: self.book.notes)
                }

                if let summary = book.summary, !summary.isEmpty {
                    section("Description") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(summaryExpanded ? nil : 5)
                                .textSelection(.enabled)
                            Button(summaryExpanded ? "Less" : "More") {
                                withAnimation(.snappy) { summaryExpanded.toggle() }
                            }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(.tint)
                        }
                    }
                }

                if let highlights = book.highlights, !highlights.isEmpty {
                    section("Highlights (\(highlights.count))") {
                        HighlightList(highlights: highlights)
                    }
                }

                if !book.tags.isEmpty {
                    section("Tags") {
                        FlowLayout {
                            ForEach(book.tags, id: \.self) { tag in
                                Button { app.sidebar = .tag(tag) } label: { Chip(text: tag) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                section("Details") { details(book) }
            }
            .padding(18)
            .animation(.snappy, value: book.status)
        }
    }

    private func readingProgress(_ book: Book) -> some View {
        let progress = book.status == .finished ? 1 : (book.progress ?? 0)
        let parts = [book.readingTimeText.map { "\($0) read" },
                     book.lastRead.map { "last read \($0.formatted(.relative(presentation: .named)))" }]
            .compactMap { $0 }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(book.status == .finished ? "Finished" : "\(Int(progress * 100))% read")
                    .font(.callout.weight(.medium).monospacedDigit())
                Spacer()
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .tint(book.status == .finished ? .green : .accentColor)
        }
        .help("From your e-reader")
    }

    private func cover(_ book: Book) -> some View {
        CoverView(book: book, maxPixel: 900, cornerRadius: 7)
            .frame(maxWidth: 170)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
            .overlay {
                if coverTargeted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay {
                            Image(systemName: "photo.badge.plus").font(.largeTitle).foregroundStyle(.white)
                        }
                }
            }
            .scaleEffect(coverTargeted ? 1.04 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: coverTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, let data = try? Data(contentsOf: url) else { return false }
                app.store.setCover(data, for: id)
                return true
            } isTargeted: {
                coverTargeted = $0
            }
            .contextMenu {
                Button("Change Cover…") { app.chooseCover(for: id) }
                if book.customCover, book.format.isEPUBBased {
                    Button("Restore Original Cover") { app.store.restoreCover(for: id) }
                }
            }
            .help("Drop an image here to change the cover")
            .padding(.top, 6)
    }

    private func actions(_ book: Book) -> some View {
        HStack(spacing: 8) {
            ForEach(app.devices.devices.prefix(1)) { device in
                Button {
                    app.send([id], to: device.id)
                } label: {
                    Label(device.manifest[id] == nil ? "Send to \(device.kind.label)" : "Send Again",
                          systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                app.editing = book
            } label: {
                Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity)
            }
            Menu {
                BookMenu(ids: [id])
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.large)
    }

    private func details(_ book: Book) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            detail("Format", book.format.label)
            detail("Size", ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))
            detail("Added", book.dateAdded.formatted(date: .abbreviated, time: .omitted))
            if let started = book.dateStarted {
                detail("Started", started.formatted(date: .abbreviated, time: .omitted))
            }
            if let publisher = book.publisher { detail("Publisher", publisher) }
            if let published = book.published { detail("Published", published) }
            if let language = book.language { detail("Language", language) }
            if let isbn = book.isbn { detail("ISBN", isbn) }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HighlightList: View {
    let highlights: [Highlight]
    @State private var expanded = false

    var body: some View {
        let shown = expanded ? highlights : Array(highlights.prefix(3))
        VStack(alignment: .leading, spacing: 12) {
            ForEach(shown) { highlight in
                VStack(alignment: .leading, spacing: 4) {
                    if let text = highlight.text {
                        Text(text)
                            .font(.system(.callout, design: .serif))
                            .italic()
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.yellow.opacity(0.7)).frame(width: 3)
                            }
                    }
                    if let note = highlight.note {
                        Label(note, systemImage: "text.bubble")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if highlights.count > 3 {
                Button(expanded ? "Show Fewer" : "Show All \(highlights.count)") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.tint)
            }
        }
    }
}

private struct NotesEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(minHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Your thoughts, favourite quotes, who recommended it…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct MultipleSelectionInspector: View {
    @Environment(AppModel.self) private var app
    let ids: Set<UUID>

    var body: some View {
        let books = app.store.books.filter { ids.contains($0.id) }

        VStack(spacing: 22) {
            ZStack {
                ForEach(Array(books.prefix(4).enumerated().reversed()), id: \.element.id) { index, book in
                    CoverView(book: book, maxPixel: 400)
                        .frame(width: 110)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                        .rotationEffect(.degrees(Double(index) * 5 - 6))
                        .offset(x: CGFloat(index) * 12 - 16)
                }
            }
            .frame(height: 190)

            Text("\(ids.count) books selected")
                .font(.system(.title3, design: .serif, weight: .semibold))

            VStack(spacing: 8) {
                ForEach(app.devices.devices) { device in
                    Button {
                        app.send(ids, to: device.id)
                    } label: {
                        Label("Send to \(device.name)", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    app.edit(ids)
                } label: {
                    Label("Edit Details…", systemImage: "pencil").frame(maxWidth: .infinity)
                }
                Menu {
                    ForEach(ReadingStatus.allCases) { status in
                        Button(status.label, systemImage: status.symbol) { app.store.setStatus(status, for: ids) }
                    }
                } label: {
                    Label("Set Status", systemImage: "bookmark").frame(maxWidth: .infinity)
                }
                Button {
                    app.export(ids)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    app.requestDelete(ids)
                } label: {
                    Label("Delete…", systemImage: "trash").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(18)
        .padding(.top, 20)
    }
}
