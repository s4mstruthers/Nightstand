import Foundation

/// Looks books up in public catalogues. Open Library is the main source; Google Books is used when its
/// shared anonymous quota allows. Runs only when the user asks, and sends only the title and author typed
/// into the search fields.
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
        async let google = searchGoogleBooks(title: title, author: author)
        let (first, second) = await (openLibrary, google)
        var unavailable: [String] = []
        if first == nil { unavailable.append("Open Library") }
        if second == nil { unavailable.append("Google Books") }
        return Results(candidates: (first ?? []) + (second ?? []), unavailable: unavailable)
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
