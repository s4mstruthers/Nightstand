import SwiftUI

/// Every tool for keeping the library in order, each with a plain explanation of what it does.
struct OrganiseView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var suggestions: Int?
    @State private var assistantConnected = false

    var body: some View {
        let books = app.store.books
        let companion = app.store.companion
        let issues = Insights.Issue.allCases.map { issue in (issue, books.count { companion.needs(issue, $0) }) }
            .filter { $0.1 > 0 }
        // Lists with skipped books that would otherwise still be on them, so they can be brought back.
        let skipped = Insights.Issue.allCases.map { issue in
            (issue, books.count { issue.matches($0) && !companion.needs(issue, $0) })
        }.filter { $0.1 > 0 }
        let skippedTotal = skipped.reduce(0) { $0 + $1.1 }

        Page(title: "Organise", subtitle: "Keep your library tidy.") {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("Needs Attention", symbol: "exclamationmark.circle")
                if issues.isEmpty {
                    Label(skippedTotal > 0 ? "Nothing else needs attention."
                          : "Nothing needs attention. Every book has a cover, an author and a description.",
                          systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(issues.enumerated()), id: \.element.0) { index, entry in
                            if index > 0 { Divider().padding(.leading, 52) }
                            issueRow(entry.0, count: entry.1)
                        }
                    }
                    .card(padding: 6)
                }
                if skippedTotal > 0 {
                    HStack(spacing: 6) {
                        Text("\(skippedTotal) skipped")
                        Menu("Bring Back") {
                            ForEach(skipped, id: \.0) { entry in
                                Button("\(entry.0.title) (\(entry.1))") { app.restoreSkipped(for: entry.0) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .transition(.opacity)
                }
            }
            .staggered(0)
            .animation(.snappy, value: companion.skipped)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("Tidy Up", symbol: "wand.and.stars")
                VStack(spacing: 0) {
                    ToolCard(symbol: "wand.and.stars", tint: .purple, title: "Clean Up Details",
                             text: "Backwards author names, long titles and missed series. You approve every change.",
                             status: suggestions.map { $0 == 0 ? "Nothing to clean up" : "\($0) suggestion\($0 == 1 ? "" : "s")" },
                             button: "Review", disabled: suggestions == 0) {
                        app.startCleanUp(wholeLibrary: true)
                    }
                    let duplicates = Insights.duplicates(books).count
                    ToolCard(symbol: "plus.square.on.square", tint: .pink, title: "Duplicates",
                             text: "Merge books added more than once, keeping ratings and notes.",
                             status: duplicates == 0 ? "None found" : "\(duplicates) found",
                             button: "Review", disabled: duplicates == 0) {
                        app.showDuplicates = true
                    }
                    ToolCard(symbol: "globe", tint: .teal, title: "Fill In Details Online",
                             text: "Missing descriptions, covers and dates. Only fills gaps.",
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
                             status: app.settings.format.applyFormatting ? "On" : "Off", button: "Options…", last: true) {
                        app.showFormatting = true
                    }
                }
                .card(padding: 6)
            }
            .staggered(1)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("Bring Books In", symbol: "tray.and.arrow.down")
                VStack(spacing: 0) {
                    ToolCard(symbol: "plus", tint: .green, title: "Add Books",
                             text: "Files or whole folders. You can also drop them on the window.",
                             status: nil, button: "Add Books…") { app.addBooks() }
                    ToolCard(symbol: "books.vertical", tint: .brown, title: "Import from Calibre",
                             text: "Books, details and covers. Calibre is left untouched.",
                             status: nil, button: "Choose Library…") { app.importCalibre() }
                    ToolCard(symbol: "star.leadinghalf.filled", tint: .orange, title: "Import from Goodreads",
                             text: "Your ratings, shelves and dates read, matched to the books you have.",
                             status: nil, button: "Choose File…", last: true) { app.importGoodreads() }
                }
                .card(padding: 6)
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
                            Button("Sync Reading") { app.syncReading(from: device.id) }
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
                        Text("Claude can tidy details, tag and sort books, and suggest what to read next.")
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
        let skip = {
            app.skip(Set(app.store.books.filter { app.store.companion.needs(issue, $0) }.map(\.id)), for: issue)
        }
        let open = { withAnimation(.snappy) { app.sidebar = .needs(issue) } }
        return HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: issue.symbol)
                        .foregroundStyle(.orange)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.title).font(.callout.weight(.medium))
                        Text(issue.advice).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.leading, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            // Beside the row, not inside it, so skipping never opens the list by mistake.
            Button("Skip", action: skip)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help("Take \(count == 1 ? "this book" : "these \(count) books") off the list without changing \(count == 1 ? "it" : "them"). You can bring \(count == 1 ? "it" : "them") back below.")
            // The count and arrow stay at the far edge, and open the list like the rest of the row.
            Button(action: open) {
                HStack(spacing: 8) {
                    Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(minWidth: 44, alignment: .trailing)
                .padding(.leading, 6)
                .padding(.trailing, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .rowHover()
        .contextMenu {
            Button("Skip \(count == 1 ? "This Book" : "All \(count) Books")", systemImage: "eye.slash", action: skip)
        }
    }

    private func icon(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(tint)
            .frame(width: 32)
    }
}

/// One tool as a row: what it is, what it does in a line, where it stands, and the button that starts it.
private struct ToolCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    let status: String?
    let button: String
    var disabled = false
    var last = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                if let status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Button(button, action: action)
                    .disabled(disabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            if !last { Divider().padding(.leading, 52) }
        }
    }
}
