import SwiftUI

/// Popular books from the web: bestseller charts by genre and what's trending, with search, Goodreads ratings
/// and links, and a way to put any of them on the wishlist.
struct BrowseView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("browse.chart") private var chartID = PopularBooks.charts[0].id
    @AppStorage("browse.store") private var store = "us"
    @State private var books: [String: [MetadataLookup.Candidate]] = [:]
    @State private var failed: Set<String> = []
    @State private var ratings: [String: GoodreadsLookup.Match] = [:]
    @State private var rated: Set<String> = []
    @State private var goodreadsStopped = false
    @State private var showing: MetadataLookup.Candidate?

    private var chart: PopularBooks.Chart {
        PopularBooks.charts.first { $0.id == chartID } ?? PopularBooks.charts[0]
    }

    var body: some View {
        Page(title: "Browse", subtitle: "Popular books right now, and any book you can think of.") {
            OnlineSearchSection().staggered(0)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Popular", symbol: "chart.line.uptrend.xyaxis") {
                    if case .apple = chart.source {
                        Picker("Store", selection: $store) {
                            ForEach(PopularBooks.stores, id: \.self) { Text(PopularBooks.storeName($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("Which country's Apple Books charts to show")
                    }
                    Link(destination: GoodreadsLookup.popularThisMonth) {
                        Label("Popular on Goodreads", systemImage: "arrow.up.right.square")
                    }
                    .font(.callout)
                    .help("Open Goodreads' most popular books this month in your browser")
                }
                FlowLayout {
                    ForEach(PopularBooks.charts) { item in
                        Button {
                            withAnimation(.snappy) { chartID = item.id }
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .font(.callout.weight(item.id == chartID ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(item.id == chartID ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                            : AnyShapeStyle(.quaternary.opacity(0.5)),
                                            in: Capsule())
                                .foregroundStyle(item.id == chartID ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        }
                        .buttonStyle(.plain)
                    }
                }
                chartGrid
                Text(chartFootnote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .staggered(1)
        }
        .task(id: key(chart)) { await load(chart) }
        .sheet(item: $showing) { candidate in
            PopularBookSheet(candidate: candidate, goodreads: ratings[candidate.id])
        }
    }

    /// Charts are kept per store, so switching back and forth doesn't reload them.
    private func key(_ chart: PopularBooks.Chart) -> String {
        if case .apple = chart.source { return "\(chart.id)-\(store)" }
        return chart.id
    }

    private var chartFootnote: String {
        switch chart.source {
        case .apple: "Apple Books' bestsellers in \(PopularBooks.storeName(store)), updated through the day. Goodreads ratings fill in as you look."
        case .openLibrary: "What Open Library's readers are looking at most. Goodreads ratings fill in as you look."
        }
    }

    @ViewBuilder
    private var chartGrid: some View {
        if let list = books[key(chart)] {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 170), spacing: 20)], spacing: 22) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, candidate in
                    PopularTile(rank: index + 1, candidate: candidate, goodreads: ratings[candidate.id]) {
                        showing = candidate
                    }
                }
            }
            .padding(.top, 4)
            .task(id: key(chart)) { await rate(list) }
        } else if failed.contains(key(chart)) {
            HStack {
                Text("This list couldn't be loaded. Check your internet connection.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Try Again") {
                    failed.remove(key(chart))
                    Task { await load(chart) }
                }
            }
            .card()
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func load(_ chart: PopularBooks.Chart) async {
        guard books[key(chart)] == nil else { return }
        if let list = await PopularBooks.load(chart, store: store) {
            withAnimation(.snappy) { books[key(chart)] = list.filter { !$0.isComic || chart.id == "top" } }
        } else {
            failed.insert(key(chart))
        }
    }

    /// Looks the books up on Goodreads one at a time, gently, for their rating and page.
    private func rate(_ list: [MetadataLookup.Candidate]) async {
        for candidate in list.prefix(40) where !rated.contains(candidate.id) && !goodreadsStopped {
            if Task.isCancelled { return }
            rated.insert(candidate.id)
            do {
                if let match = try await GoodreadsLookup.find(title: candidate.title, authors: candidate.authors) {
                    withAnimation(.snappy) { ratings[candidate.id] = match }
                }
            } catch {
                goodreadsStopped = true
                return
            }
            try? await Task.sleep(for: .seconds(GoodreadsLookup.pause))
        }
    }
}

/// One book in a chart: its place, cover, title and Goodreads rating, and whether you have it.
private struct PopularTile: View {
    @Environment(AppModel.self) private var app
    let rank: Int
    let candidate: MetadataLookup.Candidate
    let goodreads: GoodreadsLookup.Match?
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        let ownership = app.ownership(title: candidate.title, authors: candidate.authors)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                WebCover(url: candidate.coverURL, title: candidate.title, authors: candidate.authors)
                    .overlay(alignment: .topLeading) {
                        Text("\(rank)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                    }
                    .overlay(alignment: .topTrailing) {
                        switch ownership {
                        case .owned:
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .green)
                                .font(.system(size: 18))
                                .padding(6)
                                .help("In your library")
                        case .wishlisted:
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.tint)
                                .font(.system(size: 15))
                                .padding(6)
                                .background(.regularMaterial, in: Circle())
                                .padding(4)
                                .help("On your wishlist")
                        case .none:
                            EmptyView()
                        }
                    }
                    .scaleEffect(hovering ? 1.03 : 1)
                    .animation(.spring(duration: 0.3, bounce: 0.35), value: hovering)
                Text(candidate.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(candidate.authors.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let goodreads, goodreads.rating > 0 {
                    Text("Goodreads " + String(format: "%.2f", goodreads.rating))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Link("Open on Goodreads", destination: GoodreadsLookup.link(id: goodreads?.id, title: candidate.title,
                                                                        authors: candidate.authors))
            if let link = candidate.link {
                Link("Open on \(candidate.source)", destination: link)
            }
        }
    }
}

/// The details of a popular book, with its Goodreads page and a way to keep it.
private struct PopularBookSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let candidate: MetadataLookup.Candidate
    let goodreads: GoodreadsLookup.Match?

    var body: some View {
        let ownership = app.ownership(title: candidate.title, authors: candidate.authors)
        let summary = candidate.summary ?? goodreads?.summary
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                WebCover(url: candidate.coverURL ?? goodreads?.coverURL, title: candidate.title,
                         authors: candidate.authors)
                    .frame(width: 150)
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.title)
                        .font(.system(.title2, design: .serif, weight: .semibold))
                        .textSelection(.enabled)
                    Text(candidate.authors.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                    Text([goodreads?.series.map { name in
                              goodreads?.seriesIndex.map { "\(name) #\(FormatOptions.points($0))" } ?? name
                          },
                          candidate.tags.first,
                          candidate.published.map { String($0.prefix(4)) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let goodreads, let text = goodreadsText(goodreads) {
                        Label(text, systemImage: "person.3.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(summary ?? "No description available.")
                            .font(.callout)
                            .foregroundStyle(summary == nil ? .tertiary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(22)
            Divider()
            HStack(spacing: 10) {
                Link(destination: GoodreadsLookup.link(id: goodreads?.id, title: candidate.title,
                                                       authors: candidate.authors)) {
                    Label("Goodreads", systemImage: "arrow.up.right.square")
                }
                .help(goodreads == nil ? "Search for this book on Goodreads" : "Open this book's Goodreads page")
                if let link = candidate.link {
                    Link(destination: link) {
                        Label(candidate.source, systemImage: "arrow.up.right.square")
                    }
                }
                Spacer()
                switch ownership {
                case .owned(let book):
                    Button("Show in Library") {
                        dismiss()
                        withAnimation(.snappy) { app.showInLibrary(book) }
                    }
                case .wishlisted(let entry):
                    Button("Remove from Wishlist") { app.removeFromWishlist(entry.id) }
                    Button("I've Read It", systemImage: "checkmark") {
                        app.markRead(entry)
                        dismiss()
                    }
                    .help("Add it to your library as read. You don't need the file.")
                case .none:
                    Button("I've Read It", systemImage: "checkmark") {
                        app.markRead(self.entry)
                        dismiss()
                    }
                    .help("Add it to your library as read. You don't need the file.")
                    Button("Add to Wishlist", systemImage: "bookmark") { app.addToWishlist(self.entry) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 440)
    }

    /// The book as a wishlist entry, with what Goodreads knows about it.
    private var entry: Recommendation {
        var entry = Recommendation(candidate)
        if let goodreads {
            entry.goodreadsID = goodreads.id
            entry.goodreadsRating = goodreads.rating > 0 ? goodreads.rating : nil
            entry.goodreadsRatings = goodreads.ratings
            entry.series = entry.series ?? goodreads.series
            entry.seriesIndex = entry.seriesIndex ?? goodreads.seriesIndex
            entry.summary = entry.summary ?? goodreads.summary
            entry.coverURL = entry.coverURL ?? goodreads.coverURL
        }
        return entry
    }

    private func goodreadsText(_ match: GoodreadsLookup.Match) -> String? {
        guard match.rating > 0 else { return nil }
        let count = match.ratings.formatted(.number.notation(.compactName))
        return String(format: "Goodreads %.2f", match.rating) + " · \(count) ratings"
    }
}
