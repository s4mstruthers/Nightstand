import SwiftUI

/// Searches public catalogues for a book and lets the user choose which details to take.
struct LookupSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let book: Book

    @State private var title: String
    @State private var author: String
    @State private var results: [MetadataLookup.Candidate] = []
    @State private var unavailable: [String] = []
    @State private var searching = false
    @State private var searched = false
    @State private var selectedID: String?
    @State private var summaries: [String: String] = [:]
    @State private var applying = false

    @State private var useTitle = true
    @State private var useAuthors = true
    @State private var useSummary = true
    @State private var useDetails = true
    @State private var useCover: Bool

    init(book: Book) {
        self.book = book
        var query = MetadataCleaner.stripMarketingSubtitle(
            MetadataCleaner.seriesInParentheses(book.title)?.title ?? book.title)
        if let colon = query.firstIndex(of: ":") { query = String(query[..<colon]) }
        _title = State(initialValue: query)
        _author = State(initialValue: MetadataCleaner.cleanAuthors(book.authors).first ?? "")
        _useCover = State(initialValue: !book.hasCover)
    }

    private var selected: MetadataLookup.Candidate? { results.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Title", text: $title)
                TextField("Author", text: $author)
                    .frame(width: 170)
                Button("Search") { search() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            .textFieldStyle(.roundedBorder)
            .padding(14)

            Divider()
            HStack(spacing: 0) {
                resultList
                    .frame(width: 330)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use These Details") { apply() }
                    .disabled(selected == nil || applying)
            }
            .padding(14)
        }
        .frame(width: 780, height: 560)
        .task { search() }
    }

    private var footnote: String {
        unavailable.isEmpty
            ? "Searches Open Library and Google Books with the title and author above."
            : "\(unavailable.joined(separator: " and ")) couldn't be reached just now."
    }

    @ViewBuilder
    private var resultList: some View {
        if searching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView(searched ? "No Matches" : "Search for This Book",
                                   systemImage: "magnifyingglass",
                                   description: Text(searched ? "Try a shorter title, or clear the author." : ""))
        } else {
            List(results, selection: $selectedID) { candidate in
                HStack(spacing: 10) {
                    RemoteCover(url: candidate.coverURL)
                        .frame(width: 34, height: 51)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title).lineLimit(2)
                        Text(candidate.authors.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text([candidate.source, candidate.published.map { String($0.prefix(4)) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 3)
                .tag(candidate.id)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let candidate = selected {
            let summary = candidate.summary ?? summaries[candidate.id]
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Title", isOn: $useTitle, old: book.title, new: candidate.title)
                    field("Author", isOn: $useAuthors, old: book.authorText,
                          new: candidate.authors.joined(separator: ", "), available: !candidate.authors.isEmpty)
                    field("Description", isOn: $useSummary, old: nil, new: summary ?? "None available",
                          available: summary != nil, lineLimit: 6)
                    field("Publisher, date and ISBN", isOn: $useDetails, old: nil,
                          new: [candidate.publisher, candidate.published, candidate.isbn]
                            .compactMap { $0 }.joined(separator: " · "),
                          available: candidate.publisher != nil || candidate.published != nil || candidate.isbn != nil)
                    if candidate.coverURL != nil {
                        Toggle(isOn: $useCover) {
                            HStack(spacing: 10) {
                                Text("Cover").font(.callout.weight(.medium))
                                RemoteCover(url: candidate.coverURL).frame(width: 60, height: 90)
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: candidate.id) {
                guard candidate.summary == nil, summaries[candidate.id] == nil, let key = candidate.workKey,
                      let text = await MetadataLookup.openLibraryDescription(workKey: key) else { return }
                summaries[candidate.id] = text
            }
        } else {
            Text("Choose a match to see what it would change.")
                .foregroundStyle(.secondary)
        }
    }

    private func field(_ label: String, isOn: Binding<Bool>, old: String?, new: String,
                       available: Bool = true, lineLimit: Int = 3) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.medium))
                if let old, old != new {
                    Text(old).strikethrough().foregroundStyle(.secondary).lineLimit(2)
                }
                Text(new).lineLimit(lineLimit).foregroundStyle(available ? .primary : .tertiary)
            }
            .font(.callout)
        }
        .disabled(!available)
    }

    private func search() {
        let queryTitle = title.trimmingCharacters(in: .whitespaces)
        guard !queryTitle.isEmpty, !searching else { return }
        searching = true
        Task {
            let found = await MetadataLookup.search(title: queryTitle,
                                                    author: author.trimmingCharacters(in: .whitespaces))
            results = found.candidates
            unavailable = found.unavailable
            selectedID = found.candidates.first?.id
            searching = false
            searched = true
        }
    }

    private func apply() {
        guard let candidate = selected, var updated = app.store.book(book.id) else { return }
        applying = true
        if useTitle { updated.title = candidate.title }
        if useAuthors, !candidate.authors.isEmpty { updated.authors = candidate.authors }
        if useSummary, let summary = candidate.summary ?? summaries[candidate.id] { updated.summary = summary }
        if useDetails {
            updated.publisher = candidate.publisher ?? updated.publisher
            updated.published = candidate.published ?? updated.published
            updated.isbn = candidate.isbn ?? updated.isbn
        }
        app.store.update(updated)
        Task {
            if useCover, let url = candidate.coverURL, let data = await MetadataLookup.download(url) {
                app.store.setCover(data, for: book.id)
            }
            dismiss()
        }
    }
}

/// A cover image loaded from the web, with a neutral placeholder while loading or when missing.
private struct RemoteCover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "book.closed").foregroundStyle(.tertiary) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}
