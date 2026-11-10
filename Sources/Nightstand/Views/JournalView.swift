import SwiftUI

/// Everything you've written and highlighted, across all your books.
struct JournalView: View {
    @Environment(AppModel.self) private var app
    @State private var filter = Filter.all
    @State private var query = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Everything", thoughts = "Thoughts", highlights = "Highlights"
        var id: String { rawValue }
    }

    var body: some View {
        let books = entries
        let stats = Insights.stats(app.store.books)

        Page(title: "Journal",
             subtitle: "Your thoughts on \(app.store.books.count(where: \.hasThoughts)) books · \(stats.highlights) highlight\(stats.highlights == 1 ? "" : "s")") {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                TextField("Search your journal", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            if books.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "Nothing Written Yet" : "No Matches", systemImage: "text.book.closed")
                } description: {
                    Text(query.isEmpty
                         ? "Select a book and write what you liked, what you didn't, or any notes. Highlights you make on a Kobo appear here after it syncs."
                         : "Nothing in your journal matches “\(query)”.")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        JournalEntry(book: book, filter: filter, query: query)
                            .staggered(index)
                    }
                }
                .animation(.snappy, value: filter)
            }
        }
    }

    private var entries: [Book] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return app.store.books.filter { book in
            let thoughts = !book.notes.isEmpty || book.liked?.isEmpty == false || book.disliked?.isEmpty == false
            let highlights = book.highlights?.isEmpty == false
            switch filter {
            case .all: guard thoughts || highlights else { return false }
            case .thoughts: guard thoughts else { return false }
            case .highlights: guard highlights else { return false }
            }
            guard !needle.isEmpty else { return true }
            let text = ([book.title, book.authorText, book.notes, book.liked ?? "", book.disliked ?? ""]
                + (book.highlights ?? []).flatMap { [$0.text ?? "", $0.note ?? ""] }).joined(separator: " ")
            return text.lowercased().contains(needle)
        }
        .sorted { activity($0) > activity($1) }
    }

    private func activity(_ book: Book) -> Date {
        [book.lastRead, book.dateFinished, book.highlights?.compactMap(\.date).max(), book.dateStarted]
            .compactMap { $0 }.max() ?? book.dateAdded
    }
}

private struct JournalEntry: View {
    @Environment(AppModel.self) private var app
    let book: Book
    let filter: JournalView.Filter
    let query: String
    @State private var showAllHighlights = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                app.show(book)
            } label: {
                HStack(spacing: 12) {
                    CoverView(book: book, maxPixel: 160, cornerRadius: 3).frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).font(.system(.headline, design: .serif)).lineLimit(1)
                        Text(book.authorText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if book.isFavourite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                    if book.rating > 0 { StarRating(rating: .constant(book.rating), size: 12, interactive: false) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if filter != .highlights {
                if let liked = book.liked, !liked.isEmpty {
                    thought("Liked", symbol: "hand.thumbsup.fill", tint: .green, text: liked)
                }
                if let disliked = book.disliked, !disliked.isEmpty {
                    thought("Didn't like", symbol: "hand.thumbsdown.fill", tint: .red, text: disliked)
                }
                if !book.notes.isEmpty {
                    thought("Notes", symbol: "note.text", tint: .secondary, text: book.notes)
                }
            }
            if filter != .thoughts, let highlights = book.highlights, !highlights.isEmpty {
                let shown = showAllHighlights ? highlights : Array(highlights.prefix(3))
                ForEach(shown) { highlight in
                    VStack(alignment: .leading, spacing: 4) {
                        if let text = highlight.text {
                            Text(text)
                                .font(.system(.callout, design: .serif))
                                .italic()
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) { Capsule().fill(Color.yellow.opacity(0.75)).frame(width: 3) }
                        }
                        if let note = highlight.note {
                            Label(note, systemImage: "text.bubble").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if highlights.count > 3 {
                    Button(showAllHighlights ? "Show Fewer" : "Show All \(highlights.count) Highlights") {
                        withAnimation(.snappy) { showAllHighlights.toggle() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .font(.callout)
                }
            }
        }
        .card()
    }

    private func thought(_ label: String, symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.callout).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
