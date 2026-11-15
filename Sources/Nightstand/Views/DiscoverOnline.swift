import SwiftUI

/// Where a book found online stands: already in the library, on the wishlist, or neither.
enum Ownership: Equatable {
    case owned(Book)
    case wishlisted(Recommendation)
    case none
}

extension AppModel {
    func ownership(title: String, authors: [String]) -> Ownership {
        if let book = Insights.ownedBook(title: title, authors: authors, in: store.books) { return .owned(book) }
        let saved = store.companion.recommendations.filter { $0.state == .saved }
        let asBooks = saved.map { Book(id: $0.id, title: $0.title, authors: $0.authors, format: .epub) }
        if let match = Insights.ownedBook(title: title, authors: authors, in: asBooks),
           let entry = saved.first(where: { $0.id == match.id }) {
            return .wishlisted(entry)
        }
        return .none
    }

    /// Puts a book on the wishlist, or moves an earlier suggestion of it there.
    func addToWishlist(_ recommendation: Recommendation) {
        withAnimation(.snappy) {
            var entry = recommendation
            entry.state = .saved
            store.companion.recommendations.removeAll {
                Insights.normalize($0.title) == Insights.normalize(entry.title) && $0.state != .saved
            }
            store.companion.recommendations.insert(entry, at: 0)
        }
    }

    func removeFromWishlist(_ id: UUID) {
        withAnimation(.snappy) { store.companion.recommendations.removeAll { $0.id == id } }
    }
}

// MARK: - Search

/// Search Apple Books and Open Library from the Discover page, and put what you find on the wishlist.
struct OnlineSearchSection: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var results: [MetadataLookup.Candidate] = []
    @State private var unavailable: [String] = []
    @State private var searching = false
    @State private var searched = ""
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Find Books Online", symbol: "globe")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by title or author", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(search)
                if searching {
                    ProgressView().controlSize(.small)
                } else if !searched.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") {
                        withAnimation(.snappy) {
                            query = ""
                            searched = ""
                            results = []
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            .card(padding: 12)

            if !searched.isEmpty, !searching {
                if results.isEmpty {
                    Text(unavailable.count == 2 ? "Apple Books and Open Library couldn't be reached. Check your internet connection."
                         : "Nothing found for “\(searched)”. Try fewer words, or just the author.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                } else {
                    let shown = showAll ? results : Array(results.prefix(6))
                    VStack(spacing: 10) {
                        ForEach(shown) { OnlineBookCard(candidate: $0) }
                    }
                    if results.count > 6 {
                        Button(showAll ? "Show Fewer" : "Show All \(results.count) Results") {
                            withAnimation(.snappy) { showAll.toggle() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                    Text("From Apple Books and Open Library. Only the words you typed are sent.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .animation(.snappy, value: results.map(\.id))
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !searching else { return }
        searching = true
        Task {
            let found = await MetadataLookup.browse(text)
            results = found.candidates
            unavailable = found.unavailable
            showAll = false
            searched = text
            searching = false
        }
    }
}

/// A book found online, with whether you have it.
private struct OnlineBookCard: View {
    @Environment(AppModel.self) private var app
    let candidate: MetadataLookup.Candidate
    @State private var expanded = false

    var body: some View {
        let ownership = app.ownership(title: candidate.title, authors: candidate.authors)
        HStack(alignment: .top, spacing: 14) {
            WebCover(url: candidate.coverURL, title: candidate.title, authors: candidate.authors)
                .frame(width: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title).font(.system(.headline, design: .serif)).lineLimit(2)
                Text([candidate.authors.joined(separator: ", "), candidate.published.map { String($0.prefix(4)) }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let summary = candidate.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .lineLimit(expanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                        .help(expanded ? "Show less" : "Show the whole description")
                }
            }
            Spacer(minLength: 8)
            OwnershipControl(ownership: ownership) {
                app.addToWishlist(Recommendation(candidate))
            }
        }
        .card(padding: 14)
        .transition(.opacity)
    }
}

/// "In Your Library", "On Wishlist" or an Add button, at the side of a book you might not have.
struct OwnershipControl: View {
    @Environment(AppModel.self) private var app
    let ownership: Ownership
    var add: () -> Void

    var body: some View {
        Group {
            switch ownership {
            case .owned(let book):
                VStack(alignment: .trailing, spacing: 4) {
                    Label("In Your Library", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                    Button("Show") { withAnimation(.snappy) { app.showInLibrary(book) } }
                        .controlSize(.small)
                }
            case .wishlisted(let entry):
                VStack(alignment: .trailing, spacing: 4) {
                    Label("On Your Wishlist", systemImage: "bookmark.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.tint)
                    Button("Remove") { app.removeFromWishlist(entry.id) }
                        .controlSize(.small)
                }
            case .none:
                Button("Add to Wishlist", systemImage: "bookmark", action: add)
                    .controlSize(.small)
            }
        }
        .fixedSize()
    }
}

// MARK: - Missing from your series

/// The books missing from series you're reading, named from Goodreads, ready to put on the wishlist.
struct SeriesGapsSection: View {
    @Environment(AppModel.self) private var app
    @State private var found: [String: GoodreadsLookup.Match] = [:]
    @State private var checked: Set<String> = []
    @State private var stopped = false

    var body: some View {
        let gaps = Insights.seriesGaps(app.store.books)
        // The next number only shows once Goodreads confirms the book exists.
        let shown = gaps.filter { !$0.isNext || found[$0.id] != nil }
        let bySeries = Dictionary(grouping: shown, by: \.series)
        let names = bySeries.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("Missing From Your Series", symbol: "books.vertical")
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(names, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 8) {
                            Button(name) { withAnimation(.snappy) { app.sidebar = .series(name) } }
                                .buttonStyle(.plain)
                                .font(.subheadline.weight(.semibold))
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(bySeries[name] ?? []) { gap in
                                        GapCard(gap: gap, match: found[gap.id])
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 2)
                            }
                            .scrollIndicators(.never)
                        }
                    }
                    Text(stopped ? "Goodreads isn't answering just now, so some titles are missing. They'll fill in another time."
                         : "Titles and covers from Goodreads. Books you add to the library come off the wishlist by themselves.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .card()
            }
            .task(id: gaps.map(\.id)) { await name(gaps) }
        } else {
            Color.clear.frame(height: 0)
                .task(id: gaps.map(\.id)) { await name(gaps) }
        }
    }

    /// Looks the gaps up one at a time, gently, and stops if Goodreads refuses.
    private func name(_ gaps: [Insights.SeriesGap]) async {
        for gap in gaps.prefix(30) where !checked.contains(gap.id) && !stopped {
            if Task.isCancelled { return }
            checked.insert(gap.id)
            do {
                if let match = try await GoodreadsLookup.volume(gap.index, of: gap.series, authors: gap.authors) {
                    withAnimation(.snappy) { found[gap.id] = match }
                }
            } catch {
                stopped = true
                return
            }
            try? await Task.sleep(for: .seconds(GoodreadsLookup.pause))
        }
    }
}

private struct GapCard: View {
    @Environment(AppModel.self) private var app
    let gap: Insights.SeriesGap
    let match: GoodreadsLookup.Match?

    private var number: String {
        gap.index.rounded() == gap.index ? String(Int(gap.index)) : String(gap.index)
    }

    var body: some View {
        let title = match?.title ?? "\(gap.series) \(number)"
        let ownership = app.ownership(title: title, authors: gap.authors)
        VStack(alignment: .leading, spacing: 6) {
            WebCover(url: match?.coverURL, title: title, authors: gap.authors)
                .frame(width: 92)
                .overlay(alignment: .topLeading) {
                    Text("#\(number)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .padding(5)
                }
            Text(match?.title ?? "Book \(number)")
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .frame(width: 92, alignment: .leading)
            if gap.isNext {
                Text("Next after yours").font(.caption2).foregroundStyle(.secondary)
            }
            switch ownership {
            case .wishlisted(let entry):
                Button("On Wishlist", systemImage: "bookmark.fill") { app.removeFromWishlist(entry.id) }
                    .help("Remove from your wishlist")
                    .controlSize(.mini)
            case .owned:
                Label("Owned", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
            case .none:
                Button("Wishlist", systemImage: "bookmark") {
                    var entry = Recommendation(title: title, authors: gap.authors, source: "you", state: .saved)
                    entry.series = gap.series
                    entry.seriesIndex = gap.index
                    entry.coverURL = match?.coverURL
                    entry.summary = match?.summary
                    entry.goodreadsID = match?.id
                    if let match, match.rating > 0 {
                        entry.goodreadsRating = match.rating
                        entry.goodreadsRatings = match.ratings
                    }
                    app.addToWishlist(entry)
                }
                .help("Add to your wishlist")
                .controlSize(.mini)
            }
        }
        .frame(width: 92, alignment: .leading)
    }
}

// MARK: - Covers

/// A cover from the web, or a made-up one while it loads or when there is none.
struct WebCover: View {
    let url: URL?
    let title: String
    let authors: [String]

    var body: some View {
        let placeholder = PlaceholderCover(book: Book(title: title, authors: authors, format: .epub))
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}
