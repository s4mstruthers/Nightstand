import Foundation

/// Looks books up in public catalogues: Open Library, Apple Books (which has descriptions and good covers
/// for most books in print), and Google Books when its shared anonymous quota allows. Runs only when the user
/// asks, and sends only the title and author (or the book's ISBN).
enum MetadataLookup {
    struct Candidate: Identifiable, Hashable, Sendable {
        let id: String
        let source: String
        var title: String
        var subtitle: String?
        var authors: [String]
        var publisher: String?
        var published: String?
        var summary: String?
        var isbn: String?
        var coverURL: URL?
        var tags: [String] = []
        /// Open Library work key, used to fetch the description on demand.
        var workKey: String?
    }

    struct Results: Sendable {
        var candidates: [Candidate]
        /// Sources that could not be reached, for display.
        var unavailable: [String]
    }

    static func search(title: String, author: String) async -> Results {
        async let openLibrary = searchOpenLibrary(title: title, author: author)
        async let apple = searchAppleBooks(title: title, author: author)
        async let google = searchGoogleBooks(title: title, author: author)
        let (first, second, third) = await (openLibrary, apple, google)
        var unavailable: [String] = []
        if first == nil { unavailable.append("Open Library") }
        if second == nil { unavailable.append("Apple Books") }
        // Google's anonymous quota is often used up; that's not worth mentioning when the others answered.
        if third == nil, first == nil || second == nil { unavailable.append("Google Books") }
        return Results(candidates: (second ?? []) + (first ?? []) + (third ?? []), unavailable: unavailable)
    }

    // MARK: Browsing

    /// Books matching words typed on the Discover page: a title, an author or both. Apple Books comes first
    /// for its covers and descriptions; Open Library adds what Apple doesn't sell. One entry per book.
    static func browse(_ query: String) async -> Results {
        async let apple = searchAppleBooks(title: query, author: "", limit: 20)
        async let openLibrary = searchOpenLibrary(query: query)
        let (first, second) = await (apple, openLibrary)
        var unavailable: [String] = []
        if first == nil { unavailable.append("Apple Books") }
        if second == nil { unavailable.append("Open Library") }
        var seen: Set<String> = []
        var unique: [Candidate] = []
        for candidate in (first ?? []) + (second ?? []) {
            // Translations and box sets crowd the results; one per title and first author.
            let cut = candidate.title.firstIndex { $0 == ":" || $0 == "(" } ?? candidate.title.endIndex
            let key = Insights.normalize(String(candidate.title[..<cut]))
                + "|" + Insights.normalize(candidate.authors.first?.split(separator: " ").last.map(String.init) ?? "")
            if seen.insert(key).inserted { unique.append(candidate) }
        }
        return Results(candidates: unique, unavailable: unavailable)
    }

    // MARK: Filling in many books

    /// What was found for one book, merged from every source that matched it.
    struct Details: Sendable {
        var summary: String?
        var publisher: String?
        var published: String?
        var isbn: String?
        var tags: [String] = []
        var coverURL: URL?

        var isEmpty: Bool {
            summary == nil && publisher == nil && published == nil && isbn == nil && tags.isEmpty && coverURL == nil
        }
    }

    /// The candidates that are this book: the same title (ignoring subtitles) and, when known, an author
    /// sharing the surname. Nothing is taken from a result that isn't clearly the same book.
    static func matches(title: String, authors: [String], in candidates: [Candidate]) -> [Candidate] {
        func main(_ text: String) -> String {
            let cut = text.firstIndex { $0 == ":" || $0 == "(" || $0 == "[" } ?? text.endIndex
            return Insights.normalize(String(text[..<cut]))
        }
        let wanted = Set([Insights.normalize(title), main(title)].filter { !$0.isEmpty })
        let surnames = authors.compactMap { $0.split(separator: " ").last.map { Insights.normalize(String($0)) } }
            .filter { !$0.isEmpty }
        return candidates.filter { candidate in
            let found = [Insights.normalize(candidate.title), main(candidate.title)]
            guard found.contains(where: wanted.contains) else { return false }
            guard !surnames.isEmpty, !candidate.authors.isEmpty else { return true }
            let names = Insights.normalize(candidate.authors.joined(separator: " "))
            return surnames.contains { names.contains($0) }
        }
    }

    /// Looks one book up in every source and merges what the matching results say.
    static func details(title: String, authors: [String]) async -> Details? {
        let query = MetadataCleaner.stripMarketingSubtitle(MetadataCleaner.seriesInParentheses(title)?.title ?? title)
        let author = MetadataCleaner.cleanAuthors(authors).first ?? ""
        let results = await search(title: query, author: author)
        guard results.unavailable.count < 3 else { return nil }
        let found = matches(title: query, authors: authors, in: results.candidates)
        var details = Details()
        details.summary = found.lazy.compactMap(\.summary).first { $0.count > 80 }
        // Open Library's publisher and ISBN belong to whichever edition it lists first (often a large-print or
        // translated one), so those only come from a source that describes one edition, with both together.
        if let edition = found.first(where: { $0.source == "Google Books" && ($0.publisher != nil || $0.isbn != nil) }) {
            details.publisher = edition.publisher
            details.isbn = edition.isbn
        }
        details.published = found.lazy.compactMap(\.published).min()
        details.tags = found.first { !$0.tags.isEmpty }?.tags ?? []
        details.coverURL = found.lazy.compactMap(\.coverURL).first
        if details.summary == nil, let key = found.lazy.compactMap(\.workKey).first {
            details.summary = await openLibraryDescription(workKey: key)
        }
        return details
    }

    private static func fetch(_ components: URLComponents) async -> Data? {
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Nightstand (https://github.com/s4mstruthers/Nightstand)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func download(_ url: URL) async -> Data? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return await fetch(components)
    }

    // MARK: Open Library

    private struct OpenLibrarySearch: Decodable {
        struct Doc: Decodable {
            var key: String
            var title: String
            var subtitle: String?
            var author_name: [String]?
            var first_publish_year: Int?
            var isbn: [String]?
            var publisher: [String]?
            var cover_i: Int?
            var subject: [String]?
        }
        var docs: [Doc]
    }

    static func parseOpenLibrary(_ data: Data) -> [Candidate]? {
        guard let search = try? JSONDecoder().decode(OpenLibrarySearch.self, from: data) else { return nil }
        return search.docs.map { doc in
            Candidate(
                id: "openlibrary\(doc.key)", source: "Open Library", title: doc.title, subtitle: doc.subtitle,
                authors: doc.author_name ?? [], publisher: doc.publisher?.first,
                published: doc.first_publish_year.map(String.init),
                isbn: doc.isbn?.first { $0.count == 13 } ?? doc.isbn?.first,
                coverURL: doc.cover_i.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") },
                tags: Array((doc.subject ?? []).prefix(6)), workKey: doc.key)
        }
    }

    private static func searchOpenLibrary(query: String) async -> [Candidate]? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "fields",
                         value: "key,title,subtitle,author_name,first_publish_year,isbn,publisher,cover_i,subject"),
        ]
        guard let data = await fetch(components) else { return nil }
        return parseOpenLibrary(data)
    }

    private static func searchOpenLibrary(title: String, author: String) async -> [Candidate]? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "fields",
                         value: "key,title,subtitle,author_name,first_publish_year,isbn,publisher,cover_i,subject"),
        ] + (author.isEmpty ? [] : [URLQueryItem(name: "author", value: author)])
        guard let data = await fetch(components) else { return nil }
        return parseOpenLibrary(data)
    }

    /// Open Library keeps descriptions on the work record, as either a string or `{"value": …}`.
    static func openLibraryDescription(workKey: String) async -> String? {
        guard let components = URLComponents(string: "https://openlibrary.org\(workKey).json"),
              let data = await fetch(components),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = (object["description"] as? String)
            ?? ((object["description"] as? [String: Any])?["value"] as? String)
        return text.map(OPF.plainText)
    }

    // MARK: Apple Books

    private struct AppleSearch: Decodable {
        struct Item: Decodable {
            var trackId: Int
            var trackName: String?
            var artistName: String?
            var description: String?
            var releaseDate: String?
            var genres: [String]?
            var artworkUrl100: String?
        }
        var results: [Item]
    }

    static func parseAppleBooks(_ data: Data) -> [Candidate]? {
        guard let search = try? JSONDecoder().decode(AppleSearch.self, from: data) else { return nil }
        return search.results.compactMap { item in
            guard let title = item.trackName else { return nil }
            // Artwork comes at any size: ask for a large one instead of the 100px thumbnail.
            let cover = item.artworkUrl100?.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")
            return Candidate(
                id: "apple/\(item.trackId)", source: "Apple Books", title: title, subtitle: nil,
                authors: item.artistName.map { $0.components(separatedBy: " & ") } ?? [],
                publisher: nil, published: item.releaseDate.map { String($0.prefix(10)) },
                summary: item.description.map(OPF.plainText), isbn: nil,
                coverURL: cover.flatMap(URL.init(string:)),
                tags: (item.genres ?? []).filter { $0 != "Books" })
        }
    }

    private static func searchAppleBooks(title: String, author: String, limit: Int = 8) async -> [Candidate]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: [title, author].filter { !$0.isEmpty }.joined(separator: " ")),
            URLQueryItem(name: "media", value: "ebook"),
            URLQueryItem(name: "entity", value: "ebook"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let data = await fetch(components) else { return nil }
        return parseAppleBooks(data)
    }

    // MARK: Google Books

    private struct GoogleSearch: Decodable {
        struct Item: Decodable {
            struct Info: Decodable {
                struct Identifier: Decodable {
                    var type: String?
                    var identifier: String?
                }
                struct Images: Decodable {
                    var thumbnail: String?
                }
                var title: String?
                var subtitle: String?
                var authors: [String]?
                var publisher: String?
                var publishedDate: String?
                var description: String?
                var industryIdentifiers: [Identifier]?
                var categories: [String]?
                var imageLinks: Images?
            }
            var id: String
            var volumeInfo: Info
        }
        var items: [Item]?
    }

    static func parseGoogleBooks(_ data: Data) -> [Candidate]? {
        guard let search = try? JSONDecoder().decode(GoogleSearch.self, from: data) else { return nil }
        return (search.items ?? []).compactMap { item in
            let info = item.volumeInfo
            guard let title = info.title else { return nil }
            let identifiers = info.industryIdentifiers ?? []
            let isbn = identifiers.first { $0.type == "ISBN_13" }?.identifier
                ?? identifiers.first { $0.type == "ISBN_10" }?.identifier
            let cover = info.imageLinks?.thumbnail?
                .replacingOccurrences(of: "http://", with: "https://")
                .replacingOccurrences(of: "&edge=curl", with: "")
            return Candidate(
                id: "google/\(item.id)", source: "Google Books", title: title, subtitle: info.subtitle,
                authors: info.authors ?? [], publisher: info.publisher, published: info.publishedDate,
                summary: info.description.map(OPF.plainText), isbn: isbn,
                coverURL: cover.flatMap(URL.init(string:)), tags: info.categories ?? [])
        }
    }

    private static func searchGoogleBooks(title: String, author: String) async -> [Candidate]? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "intitle:\(title)" + (author.isEmpty ? "" : " inauthor:\(author)")),
            URLQueryItem(name: "maxResults", value: "8"),
            URLQueryItem(name: "printType", value: "books"),
        ]
        guard let data = await fetch(components) else { return nil }
        return parseGoogleBooks(data)
    }
}
