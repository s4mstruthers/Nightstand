import SwiftUI

/// Every tool for keeping the library in order, each with a plain explanation of what it does.
struct OrganiseView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var suggestions: Int?
    @State private var assistantConnected = false

    var body: some View {
        let books = app.store.books
        let issues = Insights.Issue.allCases.map { issue in (issue, books.count(where: issue.matches)) }
            .filter { $0.1 > 0 }

        Page(title: "Organise", subtitle: "Everything for keeping your library tidy, in one place.") {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("Needs Attention", symbol: "exclamationmark.circle")
                if issues.isEmpty {
                    Label("Nothing needs attention. Every book has a cover, an author and a description.",
                          systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(issues.enumerated()), id: \.element.0) { index, entry in
                            if index > 0 { Divider().padding(.leading, 50) }
                            issueRow(entry.0, count: entry.1)
                        }
                    }
                    .card(padding: 6)
                }
            }
            .staggered(0)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("Tidy Up", symbol: "wand.and.stars")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 14)], spacing: 14) {
                    ToolCard(symbol: "wand.and.stars", tint: .purple, title: "Clean Up Details",
                             text: "Fixes backwards author names, long titles and missed series. You approve every change.",
                             status: suggestions.map { $0 == 0 ? "Nothing to clean up" : "\($0) suggestion\($0 == 1 ? "" : "s")" },
                             button: "Review Suggestions", disabled: suggestions == 0) {
                        app.startCleanUp(wholeLibrary: true)
                    }
                    let duplicates = Insights.duplicates(books).count
                    ToolCard(symbol: "plus.square.on.square", tint: .pink, title: "Duplicates",
                             text: "Books added more than once, merged into one copy without losing ratings or notes.",
                             status: duplicates == 0 ? "None found" : "\(duplicates) found",
                             button: "Review Duplicates", disabled: duplicates == 0) {
                        app.showDuplicates = true
                    }
                    ToolCard(symbol: "globe", tint: .teal, title: "Fill In Details Online",
                             text: "Missing descriptions, covers and dates, from Open Library and Apple Books. Only fills gaps.",
                             status: "\(books.count(where: AppModel.lacksDetails)) to fill in",
                             button: app.isFetchingDetails ? "Stop" : "Fill In",
                             disabled: !app.isFetchingDetails && !books.contains(where: AppModel.lacksDetails)) {
                        if app.isFetchingDetails { app.cancelDetails() } else { app.fetchDetails(for: Set(books.map(\.id))) }
                    }
                    ToolCard(symbol: "person.3", tint: .brown, title: "Goodreads Ratings",
                             text: "What Goodreads readers rate each book, and any missing series.",
                             status: "\(books.count { $0.goodreadsRating != nil }) of \(books.count)",
                             button: app.isFetchingGoodreads ? "Stop" : "Get Ratings") {
                        if app.isFetchingGoodreads { app.cancelGoodreads() } else { app.fetchGoodreads(for: Set(books.map(\.id))) }
                    }
                    ToolCard(symbol: "textformat.size", tint: .indigo, title: "Format Books",
                             text: "Font size, spacing, margins and tidying for books sent to your e-reader.",
                             status: app.settings.format.applyFormatting ? "On" : "Off", button: "Formatting Options…") {
                        app.showFormatting = true
                    }
                }
            }
            .staggered(1)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("Bring Books In", symbol: "tray.and.arrow.down")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 14)], spacing: 14) {
                    ToolCard(symbol: "plus", tint: .green, title: "Add Books",
                             text: "EPUB, PDF, MOBI and more, or whole folders. You can also drop them on the window.",
                             status: nil, button: "Add Books…") { app.addBooks() }
                    ToolCard(symbol: "books.vertical", tint: .brown, title: "Import from Calibre",
                             text: "Copies your Calibre books with their details and covers. Calibre is left untouched.",
                             status: nil, button: "Choose Calibre Library…") { app.importCalibre() }
                    ToolCard(symbol: "star.leadinghalf.filled", tint: .orange, title: "Import from Goodreads",
                             text: "Your ratings, shelves and dates read, matched to the books you have.",
                             status: nil, button: "Choose Export File…") { app.importGoodreads() }
                }
            }
            .staggered(2)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("E-reader", symbol: "ipad.landscape")
                if app.devices.devices.isEmpty {
                    Label("Plug in a Kobo or Kindle to send books, sync your reading progress and tidy the device.",
                          systemImage: "cable.connector")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }
                ForEach(app.devices.devices) { device in
                    HStack(spacing: 14) {
                        icon("ipad.landscape", .indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.headline)
                            Text("\(device.manifest.count) from your library · \(ByteCountFormatter.string(fromByteCount: device.free, countStyle: .file)) free")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.kind == .kobo {
                            Button("Refresh Covers") { app.refreshCovers(on: device.id) }
                            Button("Sync Reading") { app.syncReading(from: device.id) }
                            Button("Tidy Up…") { app.startTidyUp(device.id) }
                        }
                        Button("Open") { withAnimation(.snappy) { app.sidebar = .device(device.id) } }
                    }
                    .card()
                }
            }
            .staggered(3)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("AI Assistant", symbol: "sparkles")
                HStack(spacing: 14) {
                    icon("sparkles", .pink)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Let an assistant help").font(.headline)
                            Pill(text: assistantConnected ? "Connected" : "Not connected",
                                 tint: assistantConnected ? .green : .secondary)
                        }
                        Text("Connected to Claude, an assistant can tidy details for you, tag and sort books, and put recommendations on your Discover page. Try: “Sort my unread books into series and fix their titles.”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(assistantConnected ? "Settings…" : "Connect…") { openSettings() }
                }
                .card()
            }
            .staggered(4)
        }
        .task(id: books) {
            let count = await Task.detached {
                MetadataCleaner.proposals(for: Set(books.map(\.id)), in: books).count
            }.value
            withAnimation(.snappy) { suggestions = count }
        }
        .task {
            let connected = await Task.detached {
                AssistantConnector.desktopStatus() == .connected || AssistantConnector.codeStatus() == .connected
            }.value
            assistantConnected = connected
        }
    }

    private func issueRow(_ issue: Insights.Issue, count: Int) -> some View {
        Button {
            withAnimation(.snappy) { app.sidebar = .needs(issue) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: issue.symbol)
                    .foregroundStyle(.orange)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(issue.title).font(.callout.weight(.medium))
                    Text(issue.advice).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Pill(text: "\(count) book\(count == 1 ? "" : "s")", tint: .orange)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One tool: what it is, what it does in a sentence or two, and the button that starts it.
private struct ToolCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    let status: String?
    let button: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.headline)
                Spacer(minLength: 0)
                if let status { Pill(text: status, tint: tint) }
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button, action: action)
                .disabled(disabled)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .card(lifts: true)
    }
}
