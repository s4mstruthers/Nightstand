import Foundation

/// Changes applied to several books at once. Every field left as nil (or empty) is left alone, so only what
/// the user chose to change is written.
struct BatchEdit: Equatable, Sendable {
    enum Numbering: Equatable, Sendable {
        /// Leave each book's number in its series as it is.
        case keep
        /// Remove the number from every book.
        case clear
        /// Number the books in the order given, starting from `start`.
        case sequential(start: Double)
    }

    var authors: [String]?
    /// An empty string removes the series (and its numbers).
    var series: String?
    var numbering: Numbering = .keep
    /// Removes every existing tag before `addTags` are added.
    var clearTags = false
    var addTags: [String] = []
    var removeTags: [String] = []
    /// For the optional text fields, an empty string clears the value.
    var publisher: String?
    var published: String?
    var language: String?
    var rating: Int?
    var status: ReadingStatus?

    var isEmpty: Bool { self == BatchEdit() }

    /// Splits a comma-separated field into trimmed, non-empty items.
    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Applies the edit to `books`, numbering them in the order given. Returns the books that changed.
    func apply(to books: [Book], on date: Date = Date()) -> [Book] {
        var changed: [Book] = []
        for (position, original) in books.enumerated() {
            var book = original
            if let authors { book.authors = authors }
            if let series {
                let trimmed = series.trimmingCharacters(in: .whitespaces)
                book.series = trimmed.isEmpty ? nil : trimmed
                if trimmed.isEmpty { book.seriesIndex = nil }
            }
            switch numbering {
            case .keep: break
            case .clear: book.seriesIndex = nil
            case .sequential(let start):
                if book.series != nil { book.seriesIndex = start + Double(position) }
            }
            if clearTags { book.tags = [] }
            let removing = Set(removeTags.map { $0.lowercased() })
            book.tags.removeAll { removing.contains($0.lowercased()) }
            for tag in addTags where !book.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                book.tags.append(tag)
            }
            Self.set(publisher, \.publisher, on: &book)
            Self.set(published, \.published, on: &book)
            Self.set(language, \.language, on: &book)
            if let rating { book.rating = min(max(rating, 0), 5) }
            if let status { book.setStatus(status, on: date) }
            if book != original { changed.append(book) }
        }
        return changed
    }

    private static func set(_ value: String?, _ keyPath: WritableKeyPath<Book, String?>, on book: inout Book) {
        guard let value else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        book[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
    }
}
