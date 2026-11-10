import Foundation

/// Looks a book up on Goodreads for its community rating and series.
///
/// Goodreads has no public API. This uses the same title lookup its own search box does: one small request
/// per book, identified honestly as Nightstand, never logged in. Goodreads asks automated clients to stay off
/// its search and review pages, so those are never fetched. If Goodreads refuses or challenges a request, the
/// lookup stops rather than trying another way in.
enum GoodreadsLookup {
    struct Match: Equatable, Sendable {
        var id: String
        var title: String
        var author: String
        var rating: Double
        var ratings: Int
        var series: String?
        var seriesIndex: Double?

        var page: URL { URL(string: "https://www.goodreads.com/book/show/\(id)")! }
    }

    enum Failure: LocalizedError {
        case refused(Int), unreachable

        var errorDescription: String? {
            switch self {
            case .refused(let code): "Goodreads isn't accepting lookups right now (it answered \(code)). Try again later."
            case .unreachable: "Goodreads couldn't be reached. Check your internet connection."
            }
        }
    }

    /// Seconds to wait between books when looking up many, to stay a light visitor.
    static let pause = 1.5

    /// The lookup matches on titles: adding the author's name mostly brings up "Summary of…" books, so the
    /// author is left out of the question and checked in the answers instead.
    static func url(title: String, author: String = "") -> URL {
        var components = URLComponents(string: "https://www.goodreads.com/book/auto_complete")!
        let query = [mainTitle(title), author].filter { !$0.isEmpty }.joined(separator: " ")
        components.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    static func parse(_ data: Data) -> [Match] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["bookId"] as? String ?? (item["bookId"] as? NSNumber)?.stringValue,
                  let full = item["title"] as? String else { return nil }
            let rating = (item["avgRating"] as? String).flatMap(Double.init) ?? (item["avgRating"] as? NSNumber)?.doubleValue ?? 0
            let series = MetadataCleaner.seriesInParentheses(full)
            return Match(id: id, title: item["bookTitleBare"] as? String ?? series?.title ?? full,
                         author: (item["author"] as? [String: Any])?["name"] as? String ?? "",
                         rating: rating, ratings: (item["ratingsCount"] as? NSNumber)?.intValue ?? 0,
                         series: series?.series, seriesIndex: series?.index)
        }
    }

    /// The result that is this book: same title (with or without a subtitle) and author. When several
    /// editions match, the one most people have rated.
    static func best(for title: String, authors: [String], in matches: [Match]) -> Match? {
        let wanted = [Insights.normalize(title), Insights.normalize(mainTitle(title))]
        let surname = authors.first?.split(separator: " ").last.map { Insights.normalize(String($0)) } ?? ""
        return matches.filter { match in
            let found = [Insights.normalize(match.title), Insights.normalize(mainTitle(match.title))]
            guard wanted.contains(where: found.contains) else { return false }
            return surname.isEmpty || match.author.isEmpty || Insights.normalize(match.author).contains(surname)
        }
        .max { $0.ratings < $1.ratings }
    }

    private static func mainTitle(_ title: String) -> String {
        let cut = title.firstIndex { $0 == ":" || $0 == "(" || $0 == "[" } ?? title.endIndex
        return String(title[..<cut]).trimmingCharacters(in: .whitespaces)
    }

    /// Looks one book up. Nil when Goodreads has no confident match. A very short or common title that
    /// isn't found by itself is tried once more with the author's surname.
    static func find(title: String, authors: [String]) async throws -> Match? {
        if let match = try await ask(url(title: title), title: title, authors: authors) { return match }
        guard let surname = authors.first?.split(separator: " ").last else { return nil }
        try? await Task.sleep(for: .seconds(pause))
        return try await ask(url(title: title, author: String(surname)), title: title, authors: authors)
    }

    private static func ask(_ url: URL, title: String, authors: [String]) async throws -> Match? {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("Nightstand (personal e-book library app)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.refused(status) }
        // A challenge page instead of results also means "not now".
        guard data.first == UInt8(ascii: "[") else { throw Failure.refused(status) }
        return best(for: title, authors: authors, in: parse(data))
    }
}

extension Book {
    /// "4.29 · 1.7M ratings", or nil when the book hasn't been found on Goodreads.
    var goodreadsText: String? {
        guard let goodreadsRating, let count = goodreadsRatings, goodreadsRating > 0 else { return nil }
        let short: String = switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 10_000...: "\(count / 1000)K"
        case 1000...: String(format: "%.1fK", Double(count) / 1000)
        default: "\(count)"
        }
        return String(format: "%.2f", goodreadsRating) + " · \(short) rating\(count == 1 ? "" : "s")"
    }

    /// Records what Goodreads says. The series is only filled in when the book has none.
    mutating func apply(_ match: GoodreadsLookup.Match?, on date: Date = Date()) {
        goodreadsChecked = date
        guard let match else { return }
        goodreadsID = match.id
        goodreadsRating = match.rating
        goodreadsRatings = match.ratings
        if series?.isEmpty != false, let found = match.series {
            series = found
            seriesIndex = match.seriesIndex
        }
    }
}
