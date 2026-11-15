import Foundation

/// Lists of popular books: Apple Books' bestseller charts, by genre, and what's trending on Open Library.
/// Both are free public feeds; nothing about the reader is sent.
enum PopularBooks {
    struct Chart: Identifiable, Hashable, Sendable {
        enum Source: Hashable, Sendable {
            /// Apple Books' top paid chart, overall or for one genre.
            case apple(genre: Int?)
            /// Open Library's trending works: "daily", "weekly", "monthly" or "forever".
            case openLibrary(period: String)
        }

        let id: String
        let title: String
        let symbol: String
        let source: Source
    }

    static let charts: [Chart] = [
        Chart(id: "top", title: "Bestsellers", symbol: "chart.line.uptrend.xyaxis", source: .apple(genre: nil)),
        Chart(id: "scifi", title: "Sci-Fi & Fantasy", symbol: "sparkles", source: .apple(genre: 9020)),
        Chart(id: "fiction", title: "Fiction", symbol: "book", source: .apple(genre: 9031)),
        Chart(id: "mystery", title: "Thrillers", symbol: "magnifyingglass", source: .apple(genre: 9032)),
        Chart(id: "romance", title: "Romance", symbol: "heart", source: .apple(genre: 9003)),
        Chart(id: "nonfiction", title: "Nonfiction", symbol: "lightbulb", source: .apple(genre: 9002)),
        Chart(id: "business", title: "Business", symbol: "briefcase", source: .apple(genre: 9009)),
        Chart(id: "trending", title: "Trending", symbol: "flame", source: .openLibrary(period: "weekly")),
    ]

    /// Apple's charts are per country store. English-language stores come first; the Mac's own region is
    /// offered too, for books in its language.
    static var stores: [String] {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        let english = ["us", "gb", "ca", "au"]
        return english + (region.count == 2 && !english.contains(region) ? [region] : [])
    }

    static func storeName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    static func load(_ chart: Chart, store country: String = "us", limit: Int = 40) async -> [MetadataLookup.Candidate]? {
        switch chart.source {
        case .apple(let genre):
            let path = "https://itunes.apple.com/\(country)/rss/toppaidebooks/limit=\(limit)"
                + (genre.map { "/genre=\($0)" } ?? "") + "/json"
            guard let url = URL(string: path), let data = await MetadataLookup.download(url) else { return nil }
            return parseAppleChart(data)
        case .openLibrary(let period):
            guard let url = URL(string: "https://openlibrary.org/trending/\(period).json?limit=\(limit)"),
                  let data = await MetadataLookup.download(url) else { return nil }
            return parseOpenLibraryTrending(data)
        }
    }

    /// Apple's chart feed. An entry is a list, or a lone object when there is only one.
    static func parseAppleChart(_ data: Data) -> [MetadataLookup.Candidate]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = object["feed"] as? [String: Any] else { return nil }
        let entries = (feed["entry"] as? [[String: Any]]) ?? (feed["entry"] as? [String: Any]).map { [$0] } ?? []
        func label(_ entry: [String: Any], _ key: String) -> String? {
            (entry[key] as? [String: Any])?["label"] as? String
        }
        return entries.compactMap { entry in
            guard let title = label(entry, "im:name") else { return nil }
            let id = ((entry["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String ?? title
            // The feed's images are 170px tall; the same address gives any size.
            let image = (entry["im:image"] as? [[String: Any]])?.last?["label"] as? String
            let cover = image?.replacingOccurrences(of: #"\d+x\d+bb\.(png|jpg)$"#, with: "600x900bb.jpg",
                                                    options: .regularExpression)
            let genre = ((entry["category"] as? [String: Any])?["attributes"] as? [String: Any])?["label"] as? String
            let link = ((entry["link"] as? [String: Any])?["attributes"] as? [String: Any])?["href"] as? String
                ?? label(entry, "id")
            var candidate = MetadataLookup.Candidate(
                id: "apple/\(id)", source: "Apple Books", title: title, subtitle: nil,
                authors: label(entry, "im:artist").map { $0.components(separatedBy: " & ") } ?? [],
                published: label(entry, "im:releaseDate").map { String($0.prefix(10)) },
                summary: label(entry, "summary").map(OPF.plainText),
                coverURL: cover.flatMap(URL.init(string:)),
                tags: genre.map { [$0] } ?? [])
            candidate.link = link.flatMap(URL.init(string:))
            candidate.isComic = genre == "Comics & Graphic Novels"
            return candidate
        }
    }

    private struct Trending: Decodable {
        struct Work: Decodable {
            var key: String
            var title: String
            var author_name: [String]?
            var first_publish_year: Int?
            var cover_i: Int?
        }
        var works: [Work]
    }

    static func parseOpenLibraryTrending(_ data: Data) -> [MetadataLookup.Candidate]? {
        guard let trending = try? JSONDecoder().decode(Trending.self, from: data) else { return nil }
        return trending.works.map { work in
            var candidate = MetadataLookup.Candidate(
                id: "openlibrary\(work.key)", source: "Open Library", title: work.title, subtitle: nil,
                authors: work.author_name ?? [], published: work.first_publish_year.map(String.init),
                coverURL: work.cover_i.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") },
                workKey: work.key)
            candidate.link = URL(string: "https://openlibrary.org\(work.key)")
            return candidate
        }
    }
}

extension GoodreadsLookup {
    /// The book's Goodreads page when its id is known, otherwise a Goodreads search for it. Opened in the
    /// reader's own browser.
    static func link(id: String? = nil, title: String, authors: [String]) -> URL {
        if let id, let url = URL(string: "https://www.goodreads.com/book/show/\(id)") { return url }
        var components = URLComponents(string: "https://www.goodreads.com/search")!
        let author = authors.first ?? ""
        components.queryItems = [URLQueryItem(name: "q", value: [title, author].filter { !$0.isEmpty }.joined(separator: " "))]
        return components.url!
    }

    /// Goodreads' own popular lists, opened in the reader's browser.
    static var popularThisMonth: URL {
        let date = Calendar.current.dateComponents([.year, .month], from: Date())
        return URL(string: "https://www.goodreads.com/book/popular_by_date/\(date.year ?? 2026)/\(date.month ?? 1)")!
    }
}
