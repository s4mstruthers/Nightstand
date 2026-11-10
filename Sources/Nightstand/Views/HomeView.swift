import SwiftUI

/// The first thing you see: what you're reading, how the year is going, and what could use a moment.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let books = app.store.books
        let stats = Insights.stats(books)
        let reading = books.filter { $0.status == .reading }
            .sorted { ($0.lastRead ?? $0.dateStarted ?? .distantPast) > ($1.lastRead ?? $1.dateStarted ?? .distantPast) }
        let unrated = books.filter(Insights.Issue.unrated.matches)
            .sorted { ($0.dateFinished ?? .distantPast) > ($1.dateFinished ?? .distantPast) }
        let fresh = app.store.companion.recommendations.filter { $0.state == .new }
        let upNext = Insights.nextInSeries(books)

        if books.isEmpty {
            EmptyLibraryView()
        } else {
            Page(title: greeting, subtitle: summary(stats)) {
                if !reading.isEmpty {
                    section("Continue Reading", symbol: "book", index: 0) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                            ForEach(Array(reading.prefix(6).enumerated()), id: \.element.id) { index, book in
                                ReadingCard(book: book).staggered(index)
                            }
                        }
                    }
                } else if !upNext.isEmpty {
                    section("Up Next", symbol: "arrow.forward.circle", index: 0) {
                        shelf(upNext)
                    }
                }

                section("Your Reading", symbol: "chart.bar", index: 1) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                        StatTile(value: "\(stats.finishedThisYear)", label: "finished this year",
                                 symbol: "checkmark.circle", tint: .green)
                        StatTile(value: hours(stats.secondsRead), label: "spent reading",
                                 symbol: "clock", tint: .orange)
                        StatTile(value: stats.averageRating.map { String(format: "%.1f", $0) } ?? "–",
                                 label: "average rating", symbol: "star", tint: .yellow)
                        StatTile(value: "\(stats.toRead)", label: "waiting to be read",
                                 symbol: "bookmark", tint: .accentColor)
                    }
                }

                if !unrated.isEmpty {
                    section("How Was It?", symbol: "star.bubble", index: 2,
                            more: unrated.count > 3 ? ("All \(unrated.count)", .needs(.unrated)) : nil) {
                        VStack(spacing: 10) {
                            ForEach(unrated.prefix(3)) { book in RateRow(book: book) }
                        }
                    }
                }

                if !fresh.isEmpty {
                    section("From Your Assistant", symbol: "sparkles", index: 3, more: ("Discover", .discover)) {
                        VStack(spacing: 10) {
                            ForEach(fresh.prefix(3)) { RecommendationCard(recommendation: $0, compact: true) }
                        }
                    }
                }

                let quotes = recentHighlights(books)
                if !quotes.isEmpty {
                    section("Lately Highlighted", symbol: "highlighter", index: 4, more: ("Journal", .journal)) {
                        VStack(spacing: 10) {
                            ForEach(quotes, id: \.highlight.id) { entry in
                                QuoteCard(book: entry.book, highlight: entry.highlight)
                            }
                        }
                    }
                }

                if !reading.isEmpty, !upNext.isEmpty {
                    section("Next in Your Series", symbol: "arrow.forward.circle", index: 5) { shelf(upNext) }
                }

                section("Recently Added", symbol: "plus.circle", index: 6, more: ("All Books", .all)) {
                    shelf(Array(books.sorted { $0.dateAdded > $1.dateAdded }.prefix(12)))
                }

                TidyNudge()
            }
        }
    }

    // MARK: Pieces

    private func section(_ title: String, symbol: String, index: Int, more: (String, SidebarItem)? = nil,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: title, symbol: symbol) {
                if let more {
                    Button {
                        withAnimation(.snappy) { app.sidebar = more.1 }
                    } label: {
                        Label(more.0, systemImage: "chevron.right").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            content()
        }
        .staggered(index)
    }

    private func shelf(_ books: [Book]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(books) { book in
                    ShelfBook(book: book)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good Morning"
        case 12..<18: "Good Afternoon"
        default: "Good Evening"
        }
    }

    private func summary(_ stats: Insights.Stats) -> String {
        var parts: [String] = []
        if stats.reading > 0 { parts.append("You're reading \(stats.reading) book\(stats.reading == 1 ? "" : "s")") }
        parts.append("\(stats.finished) finished")
        parts.append("\(stats.total) in your library")
        return parts.joined(separator: " · ")
    }

    private func hours(_ seconds: Int) -> String {
        seconds >= 3600 ? "\(seconds / 3600) h" : "\(seconds / 60) min"
    }

    private func recentHighlights(_ books: [Book]) -> [(book: Book, highlight: Highlight)] {
        books.flatMap { book in (book.highlights ?? []).filter { $0.text != nil }.map { (book, $0) } }
            .sorted { ($0.1.date ?? .distantPast) > ($1.1.date ?? .distantPast) }
            .prefix(2).map { (book: $0.0, highlight: $0.1) }
    }
}

// MARK: - Cards

/// A book in progress: cover, how far along, and when it was last open.
struct ReadingCard: View {
    @Environment(AppModel.self) private var app
    let book: Book

    var body: some View {
        let progress = book.progress ?? 0
        Button {
            app.show(book)
        } label: {
            HStack(spacing: 14) {
                CoverView(book: book, maxPixel: 300, cornerRadius: 4)
                    .frame(width: 62)
                    .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.system(.headline, design: .serif))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(book.authorText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                ZStack {
                    ProgressRing(progress: progress, lineWidth: 5)
                    Text(progress > 0 ? "\(Int(progress * 100))%" : "–")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                }
                .frame(width: 46, height: 46)
            }
            .frame(height: 93)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 14, lifts: true)
        .contextMenu { BookMenu(ids: [book.id]) }
    }

    private var detail: String {
        let parts = [book.readingTimeText.map { "\($0) read" },
                     book.lastRead.map { "Last read \($0.formatted(.relative(presentation: .named)))" }]
            .compactMap { $0 }
        return parts.isEmpty ? "Not synced from an e-reader yet" : parts.joined(separator: "\n")
    }
}

/// A cover on a horizontal shelf.
struct ShelfBook: View {
    @Environment(AppModel.self) private var app
    let book: Book
    @State private var hovering = false

    var body: some View {
        Button {
            app.show(book)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(book: book, maxPixel: 360)
                    .frame(width: 104)
                    .shadow(color: .black.opacity(hovering ? 0.3 : 0.18), radius: hovering ? 12 : 5, y: hovering ? 8 : 3)
                    .offset(y: hovering ? -4 : 0)
                Text(book.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 104, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3, bounce: 0.35), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu { BookMenu(ids: [book.id]) }
    }
}

/// A finished book waiting for a rating, rated right here.
private struct RateRow: View {
    @Environment(AppModel.self) private var app
    let book: Book

    var body: some View {
        HStack(spacing: 14) {
            CoverView(book: book, maxPixel: 160, cornerRadius: 3).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(book.authorText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            StarRating(rating: Binding { book.rating } set: { stars in
                withAnimation(.snappy) { app.store.modify([book.id]) { $0.rating = stars } }
            }, size: 20)
            Button("Add Thoughts") { app.show(book) }
                .controlSize(.small)
        }
        .card(padding: 12)
        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.9).combined(with: .opacity)))
    }
}

struct QuoteCard: View {
    @Environment(AppModel.self) private var app
    let book: Book
    let highlight: Highlight

    var body: some View {
        Button {
            app.show(book)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "quote.opening")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 6) {
                    Text(highlight.text ?? "")
                        .font(.system(.body, design: .serif))
                        .italic()
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                    if let note = highlight.note {
                        Label(note, systemImage: "text.bubble").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("\(book.title) · \(book.authorText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(lifts: true)
    }
}

/// Points at Organise when the library could use tidying, so the tools are found when they're useful.
private struct TidyNudge: View {
    @Environment(AppModel.self) private var app
    @State private var suggestions = 0

    var body: some View {
        let books = app.store.books
        Group {
            if suggestions > 0 {
                HStack(spacing: 14) {
                    Image(systemName: "wand.and.stars")
                        .font(.title2)
                        .foregroundStyle(.purple)
                        .frame(width: 40, height: 40)
                        .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(suggestions) book\(suggestions == 1 ? "" : "s") could have tidier details")
                            .font(.callout.weight(.medium))
                        Text("Nightstand can fix author names, trim long titles and spot series. You check every change first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review") { app.startCleanUp(wholeLibrary: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Organise") { withAnimation(.snappy) { app.sidebar = .organise } }
                }
                .card()
                .transition(.opacity)
            }
        }
        .task(id: books) {
            let count = await Task.detached {
                MetadataCleaner.proposals(for: Set(books.map(\.id)), in: books).count
            }.value
            withAnimation(.snappy) { suggestions = count }
        }
    }
}
