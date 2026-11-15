import Foundation

/// A book the reader doesn't own yet: suggested by an AI assistant, or added to the wishlist by hand.
struct Recommendation: Identifiable, Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        /// Suggested and not yet looked at.
        case new
        /// On the wishlist.
        case saved
        case dismissed
    }

    var id = UUID()
    var title: String
    var authors: [String] = []
    /// Why it was suggested, written for the reader.
    var reason: String = ""
    /// "assistant" or "you".
    var source: String = "assistant"
    var added = Date()
    var state: State = .new
    /// Filled in from Goodreads when the suggestion is shown.
    var goodreadsRating: Double?
    var goodreadsRatings: Int?
    var goodreadsID: String?
    /// Filled in when the book was found by searching online.
    var coverURL: URL?
    var summary: String?
    var published: String?
    var series: String?
    var seriesIndex: Double?

    var authorText: String { authors.joined(separator: ", ") }

    /// A wishlist entry for a book found online.
    init(_ candidate: MetadataLookup.Candidate, source: String = "you", state: State = .saved) {
        self.init(title: candidate.title, authors: candidate.authors, source: source, state: state)
        coverURL = candidate.coverURL
        summary = candidate.summary
        published = candidate.published.map { String($0.prefix(4)) }
    }

    init(title: String, authors: [String] = [], reason: String = "", source: String = "assistant",
         state: State = .new) {
        self.title = title
        self.authors = authors
        self.reason = reason
        self.source = source
        self.state = state
    }
}

/// What sits beside the books: the reader's taste in their own words, and books they might want.
/// Kept in its own file so the book index stays exactly as older versions expect it.
struct Companion: Codable, Equatable, Sendable {
    /// The reader's own description of what they love and avoid.
    var taste: String = ""
    var recommendations: [Recommendation] = []
    /// Books to finish this year; nil when no goal is set.
    var yearlyGoal: Int?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taste = try container.decodeIfPresent(String.self, forKey: .taste) ?? ""
        recommendations = try container.decodeIfPresent([Recommendation].self, forKey: .recommendations) ?? []
        yearlyGoal = try container.decodeIfPresent(Int.self, forKey: .yearlyGoal)
    }

    /// Adds suggestions, skipping ones already listed or already in the library. Returns those added.
    @discardableResult
    mutating func add(_ suggestions: [Recommendation], owned books: [Book]) -> [Recommendation] {
        func key(_ title: String) -> String { Insights.normalize(title) }
        var known = Set(recommendations.map { key($0.title) }).union(books.map { key($0.title) })
        var added: [Recommendation] = []
        for suggestion in suggestions where !key(suggestion.title).isEmpty && !known.contains(key(suggestion.title)) {
            known.insert(key(suggestion.title))
            recommendations.insert(suggestion, at: 0)
            added.append(suggestion)
        }
        return added
    }
}

/// Reads and writes `companion.json`. Shared by the app and the MCP server.
enum CompanionIndex {
    static func url(in root: URL) -> URL { root.appending(path: "companion.json") }

    static func modificationDate(in root: URL) -> Date? {
        try? url(in: root).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func load(from root: URL) -> Companion {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(in: root)),
              let companion = try? decoder.decode(Companion.self, from: data) else { return Companion() }
        return companion
    }

    static func save(_ companion: Companion, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(companion).write(to: url(in: root), options: .atomic)
    }
}

/// Things worked out from the library: reading statistics, taste, and what needs attention.
enum Insights {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    // MARK: Statistics

    struct Stats: Equatable, Sendable {
        var total = 0
        var finished = 0
        var finishedThisYear = 0
        var reading = 0
        var toRead = 0
        var secondsRead = 0
        var averageRating: Double?
        var highlights = 0
    }

    static func stats(_ books: [Book], now: Date = Date()) -> Stats {
        let year = Calendar.current.component(.year, from: now)
        var stats = Stats(total: books.count)
        var ratings: [Int] = []
        for book in books {
            switch book.status {
            case .finished:
                stats.finished += 1
                if let date = book.dateFinished, Calendar.current.component(.year, from: date) == year {
                    stats.finishedThisYear += 1
                }
            case .reading: stats.reading += 1
            case .unread: stats.toRead += 1
            case .abandoned: break
            }
            stats.secondsRead += book.readingSeconds ?? 0
            stats.highlights += book.highlights?.count ?? 0
            if book.rating > 0 { ratings.append(book.rating) }
        }
        if !ratings.isEmpty { stats.averageRating = Double(ratings.reduce(0, +)) / Double(ratings.count) }
        return stats
    }

    // MARK: Taste

    struct Preference: Identifiable, Equatable, Sendable {
        var id: String { name }
        let name: String
        let books: Int
        let averageRating: Double
    }

    struct Taste: Equatable, Sendable {
        /// Authors and tags the reader rates highly (average of 4 or more).
        var lovedAuthors: [Preference] = []
        var lovedTags: [Preference] = []
        /// Tags the reader rates poorly or abandons.
        var coolTags: [Preference] = []
        var loved: [Book] = []
        var disliked: [Book] = []
    }

    static func taste(_ books: [Book]) -> Taste {
        func preferences(_ names: (Book) -> [String]) -> [Preference] {
            var scores: [String: [Int]] = [:]
            for book in books {
                // An abandoned book with no rating counts as a low one.
                let score = book.rating > 0 ? book.rating : (book.status == .abandoned ? 2 : 0)
                guard score > 0 else { continue }
                for name in names(book) { scores[name, default: []].append(score) }
            }
            return scores.map { Preference(name: $0.key, books: $0.value.count,
                                           averageRating: Double($0.value.reduce(0, +)) / Double($0.value.count)) }
                .sorted { ($0.averageRating, Double($0.books), $1.name) > ($1.averageRating, Double($1.books), $0.name) }
        }
        let authors = preferences(\.authors), tags = preferences(\.tags)
        return Taste(
            lovedAuthors: Array(authors.filter { $0.averageRating >= 4 }.prefix(8)),
            lovedTags: Array(tags.filter { $0.averageRating >= 4 }.prefix(8)),
            coolTags: Array(tags.filter { $0.averageRating < 3 }.suffix(6).reversed()),
            loved: books.filter { $0.rating == 5 || $0.isFavourite }
                .sorted { ($0.dateFinished ?? .distantPast) > ($1.dateFinished ?? .distantPast) },
            disliked: books.filter { ($0.rating > 0 && $0.rating <= 2) || $0.status == .abandoned })
    }

    // MARK: Owned or not

    /// The book in the library with this title (with or without a subtitle) and, when both name one, an author
    /// sharing a surname.
    static func ownedBook(title: String, authors: [String], in books: [Book]) -> Book? {
        func main(_ text: String) -> String {
            let cut = text.firstIndex { $0 == ":" || $0 == "(" || $0 == "[" } ?? text.endIndex
            return normalize(String(text[..<cut]))
        }
        func surnames(_ names: [String]) -> Set<String> {
            Set(names.compactMap { $0.split(separator: " ").last.map { normalize(String($0)) } }.filter { !$0.isEmpty })
        }
        let wanted = Set([normalize(title), main(title)].filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        let theirs = surnames(authors)
        return books.first { book in
            guard wanted.contains(normalize(book.title)) || wanted.contains(main(book.title)) else { return false }
            let ours = surnames(book.authors)
            return theirs.isEmpty || ours.isEmpty || !theirs.isDisjoint(with: ours)
        }
    }

    // MARK: Missing from a series

    /// A place in a series the reader has started with no book in the library.
    struct SeriesGap: Identifiable, Hashable, Sendable {
        var series: String
        var index: Double
        var authors: [String]
        /// True for the number after the last one owned, which may not have been written yet.
        var isNext: Bool
        var id: String { "\(series)#\(index)" }
    }

    /// For each series with a book finished or being read: the numbers missing before the last one owned,
    /// and the one after it. Omnibus editions such as "Books 1-3" count for the numbers they hold.
    static func seriesGaps(_ books: [Book], limit: Int = 8) -> [SeriesGap] {
        let grouped = Dictionary(grouping: books.filter { $0.series?.isEmpty == false && $0.seriesIndex != nil }) {
            $0.series ?? ""
        }
        var gaps: [SeriesGap] = []
        for (series, entries) in grouped.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            guard entries.contains(where: { $0.status == .finished || $0.status == .reading }),
                  let last = entries.compactMap(\.seriesIndex).max(), last < 200 else { continue }
            var owned = Set(entries.compactMap { $0.seriesIndex.map { Int($0) } })
            // "The System Apocalypse Books 1-3" holds 1, 2 and 3.
            let name = normalize(series)
            for book in books where normalize(book.title).contains(name) {
                guard let range = book.title.range(of: #"\d+\s*[-–]\s*\d+"#, options: .regularExpression) else { continue }
                let ends = book.title[range].split { !$0.isNumber }.compactMap { Int($0) }
                if ends.count == 2, ends[0] < ends[1], ends[1] - ends[0] < 20 { owned.formUnion(ends[0]...ends[1]) }
            }
            let authors = entries.max { $0.authors.count < $1.authors.count }?.authors ?? []
            let missing = (1..<Int(last)).filter { !owned.contains($0) }
            var found = missing.prefix(limit).map {
                SeriesGap(series: series, index: Double($0), authors: authors, isNext: false)
            }
            found.append(SeriesGap(series: series, index: Double(Int(last) + 1), authors: authors, isNext: true))
            gaps += found
        }
        return gaps
    }

    // MARK: Next in series

    /// For each series the reader has started, the next unread book they already own.
    static func nextInSeries(_ books: [Book]) -> [Book] {
        let series = Dictionary(grouping: books.filter { $0.series?.isEmpty == false && $0.seriesIndex != nil }) {
            $0.series ?? ""
        }
        var next: [Book] = []
        for (_, entries) in series {
            let started = entries.filter { $0.status == .finished || $0.status == .reading }
            guard let reached = started.compactMap(\.seriesIndex).max(),
                  !entries.contains(where: { $0.status == .reading }) else { continue }
            if let book = entries.filter({ $0.status == .unread && ($0.seriesIndex ?? 0) > reached })
                .min(by: { ($0.seriesIndex ?? 0) < ($1.seriesIndex ?? 0) }) {
                next.append(book)
            }
        }
        return next.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: Needs attention

    enum Issue: String, CaseIterable, Identifiable, Hashable, Sendable {
        case unrated, noThoughts, missingCover, missingDescription, unknownAuthor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .unrated: "Finished, Not Rated"
            case .noThoughts: "Finished, No Thoughts Yet"
            case .missingCover: "Missing a Cover"
            case .missingDescription: "Missing a Description"
            case .unknownAuthor: "Missing an Author"
            }
        }

        var symbol: String {
            switch self {
            case .unrated: "star"
            case .noThoughts: "text.bubble"
            case .missingCover: "photo"
            case .missingDescription: "text.alignleft"
            case .unknownAuthor: "person.crop.circle.badge.questionmark"
            }
        }

        /// What to do about it, shown beside the count.
        var advice: String {
            switch self {
            case .unrated: "Rate them so your favourites and recommendations get better."
            case .noThoughts: "Jot down what you liked and didn't while you remember."
            case .missingCover: "Fill them in online, or drop an image on a cover."
            case .missingDescription: "Nightstand can find most of these online."
            case .unknownAuthor: "Add the author with Edit Details."
            }
        }

        func matches(_ book: Book) -> Bool {
            switch self {
            case .unrated: book.status == .finished && book.rating == 0
            case .noThoughts: book.status == .finished && !book.hasThoughts
            case .missingCover: !book.hasCover
            case .missingDescription: (book.summary ?? "").isEmpty
            case .unknownAuthor: book.authors.isEmpty
            }
        }
    }
}
