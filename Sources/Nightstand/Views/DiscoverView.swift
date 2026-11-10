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

    var body: some View {
        let books = app.store.books
        let recommendations = app.store.companion.recommendations
        let fresh = recommendations.filter { $0.state == .new }
        let saved = recommendations.filter { $0.state == .saved }
        let taste = Insights.taste(books)
        let upNext = Insights.nextInSeries(books)

        Page(title: "Discover", subtitle: "What to read next, based on what you love.") {
            tasteSection(taste).staggered(0)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Suggested for You", symbol: "sparkles") {
                    if !fresh.isEmpty { Pill(text: "\(fresh.count) new", tint: .pink) }
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

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Wishlist", symbol: "bookmark") {
                    Button("Add a Book", systemImage: "plus") { withAnimation(.snappy) { adding.toggle() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
                if adding { addForm }
                if saved.isEmpty, !adding {
                    Text("Books you want but don't have yet. Save a suggestion, or add one yourself.")
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
                    .frame(width: 40, height: 40)
                    .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PlaceholderCover(book: Book(title: recommendation.title, authors: recommendation.authors, format: .epub))
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(width: compact ? 40 : 54)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recommendation.title).font(.system(.headline, design: .serif)).lineLimit(2)
                    if recommendation.source == "assistant" {
                        Image(systemName: "sparkles").font(.caption).foregroundStyle(.pink)
                            .help("Suggested by your assistant")
                    }
                }
                if !recommendation.authors.isEmpty {
                    Text(recommendation.authorText).font(.callout).foregroundStyle(.secondary)
                }
                if !recommendation.reason.isEmpty {
                    Text(recommendation.reason)
                        .font(.callout)
                        .lineLimit(compact ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if recommendation.state == .new {
                    Button("Save", systemImage: "bookmark") { set(.saved) }
                        .help("Add to your wishlist")
                }
                Button("Find", systemImage: "magnifyingglass") { find() }
                    .help("Search for this book online")
                Button(recommendation.state == .saved ? "Remove" : "Dismiss", systemImage: "xmark") { set(.dismissed) }
                    .labelStyle(.iconOnly)
                    .help(recommendation.state == .saved ? "Remove from your wishlist" : "Not for me")
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
        var components = URLComponents(string: "https://openlibrary.org/search")!
        components.queryItems = [URLQueryItem(name: "q", value: "\(recommendation.title) \(recommendation.authorText)")]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
