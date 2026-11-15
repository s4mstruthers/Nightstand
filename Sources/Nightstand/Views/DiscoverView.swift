import SwiftUI

/// What to read next: your taste, suggestions from an AI assistant, and your wishlist.
struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var tasteDraft = ""
    @State private var adding = false
    @State private var newTitle = ""
    @State private var newAuthor = ""
    @State private var assistantConnected = false
    /// Suggestions already looked up on Goodreads this session, found or not.
    @State private var lookedUp: Set<UUID> = []

    var body: some View {
        let books = app.store.books
        let recommendations = app.store.companion.recommendations
        let fresh = recommendations.filter { $0.state == .new }
        let saved = recommendations.filter { $0.state == .saved }
        let taste = Insights.taste(books)
        let upNext = Insights.nextInSeries(books)

        Page(title: "Discover", subtitle: "What to read next, based on what you love.") {

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Suggested for You", symbol: "sparkles") {
                    if !fresh.isEmpty { Text("\(fresh.count) new").foregroundStyle(.secondary) }
                }
                if fresh.isEmpty {
                    askAssistant
                } else {
                    VStack(spacing: 10) {
                        ForEach(fresh) { RecommendationCard(recommendation: $0) }
                    }
                }
            }
            .staggered(1)
            .animation(.snappy, value: recommendations)

            if !upNext.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading("Next in Your Series", symbol: "arrow.forward.circle")
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(upNext) { ShelfBook(book: $0) }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.never)
                }
                .staggered(2)
            }

            SeriesGapsSection().staggered(2)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Wishlist", symbol: "bookmark") {
                    Button("Add a Book", systemImage: "plus") { withAnimation(.snappy) { adding.toggle() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
                if adding { addForm }
                if saved.isEmpty, !adding {
                    Text("Books you want but don't have yet. Save them from Browse, or add one yourself.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }
                VStack(spacing: 10) {
                    ForEach(saved) { RecommendationCard(recommendation: $0) }
                }
            }
            .staggered(3)
            .animation(.snappy, value: recommendations)

            tasteSection(taste).staggered(4)
        }
        .onAppear { tasteDraft = app.store.companion.taste }
        .onChange(of: app.store.companion.taste) { _, taste in
            if taste != tasteDraft { tasteDraft = taste }
        }
        .task(id: tasteDraft) {
            // Save a moment after typing stops.
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled, tasteDraft != app.store.companion.taste { app.store.companion.taste = tasteDraft }
        }
        .task {
            let connected = await Task.detached {
                AssistantConnector.desktopStatus() == .connected || AssistantConnector.codeStatus() == .connected
            }.value
            assistantConnected = connected
        }
        .task(id: app.store.companion.recommendations.map(\.id)) { await rateSuggestions() }
    }

    /// Fills in the cover and Goodreads rating for suggestions and wishlist books that lack either, gently.
    /// An assistant only gives a title, authors and a reason, so the cover has to be found here.
    private func rateSuggestions() async {
        let waiting = app.store.companion.recommendations.filter {
            $0.state != .dismissed && ($0.goodreadsRating == nil || $0.coverURL == nil) && !lookedUp.contains($0.id)
        }
        for suggestion in waiting.prefix(12) {
            if Task.isCancelled { return }
            lookedUp.insert(suggestion.id)
            // Refused, offline or not found on Goodreads: the cover can still come from the book catalogues.
            let match = try? await GoodreadsLookup.find(title: suggestion.title, authors: suggestion.authors)
            var cover = suggestion.coverURL ?? match?.coverURL
            if cover == nil {
                cover = await Self.catalogueCover(title: suggestion.title, authors: suggestion.authors)
            }
            if let index = app.store.companion.recommendations.firstIndex(where: { $0.id == suggestion.id }) {
                withAnimation(.snappy) {
                    var entry = app.store.companion.recommendations[index]
                    if let match {
                        entry.goodreadsRating = match.rating
                        entry.goodreadsRatings = match.ratings
                        entry.goodreadsID = match.id
                        entry.series = entry.series ?? match.series
                        entry.seriesIndex = entry.seriesIndex ?? match.seriesIndex
                        entry.summary = entry.summary ?? match.summary
                    }
                    entry.coverURL = entry.coverURL ?? cover
                    app.store.companion.recommendations[index] = entry
                }
            }
            try? await Task.sleep(for: .seconds(GoodreadsLookup.pause))
        }
    }

    /// A cover from Apple Books, Open Library or Google Books, for a result whose title is the same book.
    static func catalogueCover(title: String, authors: [String]) async -> URL? {
        let found = await MetadataLookup.search(title: title, author: authors.first ?? "")
        let wanted = Insights.normalize(title)
        let withCover = found.candidates.filter { $0.coverURL != nil }
        return (withCover.first { Insights.normalize($0.title) == wanted }
                ?? withCover.first { Insights.normalize($0.title).hasPrefix(wanted) })?.coverURL
    }

    // MARK: Taste

    private func tasteSection(_ taste: Insights.Taste) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Your Taste", symbol: "heart.text.square")
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In your own words")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $tasteDraft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 64)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if tasteDraft.isEmpty {
                                Text("What do you love in a book? What puts you off? For example: “Fast-paced sci-fi with clever problem solving. Not keen on love triangles or slow starts.”")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    Text("Your assistant reads this before recommending anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !taste.lovedAuthors.isEmpty || !taste.lovedTags.isEmpty || !taste.coolTags.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("From your ratings")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        chips("You rate highly", taste.lovedAuthors.map { ($0.name, SidebarItem.author($0.name)) }
                            + taste.lovedTags.map { ($0.name, SidebarItem.tag($0.name)) }, tint: .green)
                        chips("Less keen on", taste.coolTags.map { ($0.name, SidebarItem.tag($0.name)) }, tint: .orange)
                    }
                } else {
                    Text("Rate a few finished books and Nightstand will show which authors and genres you rate highest.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .card()
        }
    }

    @ViewBuilder
    private func chips(_ label: String, _ items: [(String, SidebarItem)], tint: Color) -> some View {
        if !items.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                FlowLayout {
                    ForEach(items, id: \.0) { item in
                        Button { withAnimation(.snappy) { app.sidebar = item.1 } } label: { Pill(text: item.0, tint: tint) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Assistant

    private var askAssistant: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.pink)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(assistantConnected ? "Ask your assistant for ideas" : "Connect an AI assistant")
                        .font(.headline)
                    Text(assistantConnected
                         ? "It knows your library, ratings, thoughts and taste. Anything it suggests appears here, with its reasons."
                         : "Connect Claude and it can read your library, ratings and thoughts, then put suggestions here with its reasons.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !assistantConnected {
                    Button("Connect…") { openSettings() }.buttonStyle(.borderedProminent)
                }
            }
            if assistantConnected {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["Recommend five books I'd love and add them to Nightstand.",
                             "What should I read next from the books I already own?",
                             "Look at what I rated low and tell me what to avoid."], id: \.self) { prompt in
                        PromptRow(prompt: prompt)
                    }
                }
            }
        }
        .card()
    }

    private var addForm: some View {
        HStack {
            TextField("Title", text: $newTitle)
            TextField("Author", text: $newAuthor)
            Button("Add") {
                let title = newTitle.trimmingCharacters(in: .whitespaces)
                app.store.companion.recommendations.insert(
                    Recommendation(title: title, authors: BatchEdit.list(newAuthor), source: "you", state: .saved), at: 0)
                newTitle = ""
                newAuthor = ""
                adding = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .card(padding: 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// An example request for the assistant, with a button to copy it.
private struct PromptRow: View {
    let prompt: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text("“\(prompt)”").font(.callout).italic()
            Spacer()
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                withAnimation(.snappy) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.snappy) { copied = false }
                }
            }
            .controlSize(.small)
            .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A book you don't own yet, with why it was suggested.
struct RecommendationCard: View {
    @Environment(AppModel.self) private var app
    let recommendation: Recommendation
    var compact = false

    /// "Author · Series #2 · 2021"
    private var byline: String {
        var parts: [String] = []
        if !recommendation.authorText.isEmpty { parts.append(recommendation.authorText) }
        if let series = recommendation.series {
            if let index = recommendation.seriesIndex {
                parts.append("\(series) #\(FormatOptions.points(index))")
            } else {
                parts.append(series)
            }
        }
        if let published = recommendation.published, !published.isEmpty { parts.append(published) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let ownership = app.ownership(title: recommendation.title, authors: recommendation.authors)
        HStack(alignment: .top, spacing: 14) {
            WebCover(url: recommendation.coverURL, title: recommendation.title, authors: recommendation.authors)
                .frame(width: compact ? 40 : 54)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recommendation.title).font(.system(.headline, design: .serif)).lineLimit(2)
                    if recommendation.source == "assistant" {
                        Image(systemName: "sparkles").font(.caption).foregroundStyle(.pink)
                            .help("Suggested by your assistant")
                    }
                }
                if !recommendation.authors.isEmpty || recommendation.series != nil {
                    Text(byline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if case .owned(let book) = ownership {
                    Button {
                        withAnimation(.snappy) { app.showInLibrary(book) }
                    } label: {
                        Label("In your library", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .help("You have this book. Click to show it.")
                }
                if let rating = recommendation.goodreadsRating, rating > 0 {
                    Label(String(format: "Goodreads %.2f", rating) + " · \((recommendation.goodreadsRatings ?? 0).formatted(.number.notation(.compactName))) ratings",
                          systemImage: "person.3.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                if !recommendation.reason.isEmpty {
                    Text(recommendation.reason)
                        .font(.callout)
                        .lineLimit(compact ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                } else if let summary = recommendation.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            // One clear action, with the rest a click away.
            HStack(spacing: 10) {
                if recommendation.state == .new {
                    Button("Save", systemImage: "bookmark") { set(.saved) }
                        .help("Add to your wishlist")
                }
                Menu {
                    if case .owned = ownership {} else {
                        Button("I've Read It", systemImage: "checkmark") { app.markRead(recommendation) }
                    }
                    Button("Open on Goodreads", systemImage: "arrow.up.right.square") { find() }
                    Divider()
                    Button(recommendation.state == .saved ? "Remove from Wishlist" : "Not for Me", systemImage: "xmark",
                           role: .destructive) { set(.dismissed) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .controlSize(.small)
        }
        .card(padding: compact ? 12 : 16)
        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.92).combined(with: .opacity)))
    }

    private func set(_ state: Recommendation.State) {
        withAnimation(.snappy) {
            guard let index = app.store.companion.recommendations.firstIndex(where: { $0.id == recommendation.id })
            else { return }
            app.store.companion.recommendations[index].state = state
        }
    }

    private func find() {
        if let id = recommendation.goodreadsID, let url = URL(string: "https://www.goodreads.com/book/show/\(id)") {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(GoodreadsLookup.link(title: recommendation.title, authors: recommendation.authors))
    }
}
