import Foundation
import SwiftUI

/// Reads a Goodreads library export (`goodreads_library_export.csv`) and matches it to books in the library.
enum Goodreads {
    struct Entry: Sendable {
        var title: String
        var series: String?
        var seriesIndex: Double?
        var authors: [String]
        var isbns: Set<String>
        var rating: Int
        var status: ReadingStatus?
        var dateRead: Date?
        var review: String
        var shelves: [String]
        /// Goodreads' own number for the book, for its page there.
        var bookID: String?
        var publisher: String?
        /// The year it first came out.
        var published: String?
        /// What Goodreads readers rate it on average.
        var averageRating: Double?
        var dateAdded: Date?
    }

    /// What an export would do to the library, worked out before anything changes.
    struct Plan: Sendable {
        var total = 0
        /// Entries for books already in the library, by the book they match.
        var changes: [UUID: Entry] = [:]
        /// Read or being read on Goodreads, and not in the library.
        var missingRead: [Entry] = []
        /// On the to-read shelf, and not in the library.
        var missingToRead: [Entry] = []
    }

    struct Summary: Sendable {
        var total = 0
        var matched = 0
        var updated = 0
    }

    // MARK: Parsing

    static func parse(_ csv: String) -> [Entry] {
        var rows = records(in: csv)
        guard !rows.isEmpty else { return [] }
        let header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let titleColumn = column("Title") else { return [] }

        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.dateFormat = "yyyy/MM/dd"

        return rows.compactMap { row in
            func value(_ name: String) -> String {
                guard let index = column(name), index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard titleColumn < row.count else { return nil }
            let (title, series, seriesIndex) = splitSeries(value("Title"))
            guard !title.isEmpty else { return nil }

            let additional = value("Additional Authors").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let authors = ([value("Author")] + additional).filter { !$0.isEmpty }
            // ISBNs are exported as ="0123456789" so spreadsheets keep leading zeros.
            let isbns = Set([value("ISBN"), value("ISBN13")]
                .map { $0.uppercased().filter { $0.isNumber || $0 == "X" } }
                .filter { !$0.isEmpty })
            let exclusive = value("Exclusive Shelf")
            let status: ReadingStatus? = switch exclusive {
            case "read": .finished
            case "currently-reading": .reading
            case "to-read": .unread
            default: nil
            }
            let shelves = value("Bookshelves").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !["read", "currently-reading", "to-read"].contains($0) }

            return Entry(title: title, series: series, seriesIndex: seriesIndex, authors: authors,
                         isbns: isbns, rating: min(5, max(0, Int((Double(value("My Rating")) ?? 0).rounded()))),
                         status: status, dateRead: dates.date(from: value("Date Read")),
                         review: OPF.plainText(value("My Review")), shelves: shelves,
                         bookID: value("Book Id").isEmpty ? nil : value("Book Id"),
                         publisher: value("Publisher").isEmpty ? nil : value("Publisher"),
                         published: [value("Original Publication Year"), value("Year Published")]
                             .first { !$0.isEmpty },
                         averageRating: Double(value("Average Rating")).flatMap { $0 > 0 ? $0 : nil },
                         dateAdded: dates.date(from: value("Date Added")))
        }
    }

    /// Goodreads writes series into the title: "The Final Empire (Mistborn, #1)".
    static func splitSeries(_ raw: String) -> (title: String, series: String?, index: Double?) {
        guard raw.hasSuffix(")"), let open = raw.range(of: " (", options: .backwards) else {
            return (raw, nil, nil)
        }
        let title = String(raw[..<open.lowerBound])
        let inside = raw[open.upperBound...].dropLast()
        guard let hash = inside.range(of: "#", options: .backwards) else { return (raw, nil, nil) }
        let name = inside[..<hash.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        // "#1-3" (an omnibus) keeps its first number.
        let number = inside[hash.upperBound...].prefix { $0.isNumber || $0 == "." }
        return (title, name.isEmpty ? nil : name, Double(number))
    }

    /// A CSV parser that handles quoted fields containing commas, quotes and line breaks.
    static func records(in text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending = iterator.next()
        while let character = pending {
            pending = iterator.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = iterator.next()
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field)
                field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else {
                field.append(character)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    // MARK: Matching

    /// Lowercased letters and digits of the main title, without subtitle or series suffix.
    static func titleKey(_ title: String) -> String {
        // Drop any trailing parenthetical ("(Cradle, #1)", "(King's Dark Tidings Book 7)"), then the subtitle.
        var main = title.trimmingCharacters(in: .whitespaces)
        while main.hasSuffix(")"), let open = main.range(of: " (", options: .backwards) {
            main = String(main[..<open.lowerBound])
        }
        if let colon = main.firstIndex(of: ":") { main = String(main[..<colon]) }
        return main.replacingOccurrences(of: "&", with: " and ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func nameTokens(_ names: [String]) -> Set<String> {
        Set(names.joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter }.map(String.init).filter { $0.count > 1 })
    }

    static func matches(_ entry: Entry, _ book: Book) -> Bool {
        if let isbn = book.isbn?.uppercased().filter({ $0.isNumber || $0 == "X" }), !isbn.isEmpty,
           entry.isbns.contains(isbn) { return true }
        guard titleKey(entry.title) == titleKey(book.title), !titleKey(book.title).isEmpty else { return false }
        // Same title: accept when either side has no author, or they share a name ("Clear, James" / "James Clear").
        let theirs = nameTokens(entry.authors), ours = nameTokens(book.authors)
        return theirs.isEmpty || ours.isEmpty || !theirs.isDisjoint(with: ours)
    }

    /// Sorts an export into books already in the library and books that aren't, each listed once.
    static func plan(_ entries: [Entry], books: [Book]) -> Plan {
        var plan = Plan(total: entries.count)
        var seen: Set<String> = []
        for entry in entries {
            if let book = books.first(where: { plan.changes[$0.id] == nil && matches(entry, $0) }) {
                plan.changes[book.id] = entry
                continue
            }
            // Another edition of a book that's already matched, or listed twice in the export.
            if books.contains(where: { matches(entry, $0) }) { continue }
            let key = titleKey(entry.title) + "|" + nameTokens(entry.authors.prefix(1).map { $0 }).sorted().joined()
            guard seen.insert(key).inserted else { continue }
            if entry.status == .unread { plan.missingToRead.append(entry) } else { plan.missingRead.append(entry) }
        }
        return plan
    }

    /// A book you've read but have no file for, with everything the export says about it.
    static func book(from entry: Entry) -> Book {
        var book = Book(title: entry.title, format: .epub)
        book.authors = entry.authors
        book.series = entry.series
        book.seriesIndex = entry.seriesIndex
        book.rating = entry.rating
        book.status = entry.status ?? .finished
        if book.status == .finished { book.dateFinished = entry.dateRead }
        book.notes = entry.review
        book.tags = entry.shelves
        book.publisher = entry.publisher
        book.published = entry.published
        book.isbn = entry.isbns.max { $0.count < $1.count }
        book.goodreadsID = entry.bookID
        book.goodreadsRating = entry.averageRating
        // When it went on Goodreads, so years of reading don't all show as added today.
        if let added = entry.dateAdded ?? entry.dateRead { book.dateAdded = added }
        book.noFile = true
        book.fileSize = 0
        return book
    }

    /// A book from the to-read shelf, as a wishlist entry.
    static func wish(from entry: Entry) -> Recommendation {
        var wish = Recommendation(title: entry.title, authors: entry.authors, source: "you", state: .saved)
        wish.series = entry.series
        wish.seriesIndex = entry.seriesIndex
        wish.published = entry.published
        wish.goodreadsID = entry.bookID
        return wish
    }

    /// Fills in what Goodreads knows without overwriting anything already set in Nightstand.
    /// Returns true when the book changed.
    static func apply(_ entry: Entry, to book: inout Book) -> Bool {
        let before = book
        if book.rating == 0 { book.rating = entry.rating }
        if book.status == .unread, let status = entry.status, status != .unread {
            book.status = status
            if status == .finished { book.dateFinished = entry.dateRead ?? book.dateFinished }
        }
        if book.status == .finished, book.dateFinished == nil { book.dateFinished = entry.dateRead }
        if book.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { book.notes = entry.review }
        if book.series == nil, let series = entry.series {
            book.series = series
            book.seriesIndex = entry.seriesIndex
        }
        for shelf in entry.shelves where !book.tags.contains(where: { $0.caseInsensitiveCompare(shelf) == .orderedSame }) {
            book.tags.append(shelf)
        }
        return book != before
    }
}

extension LibraryStore {
    /// Reads an export and works out what it would change. Nothing in the library changes yet.
    func planGoodreadsImport(from url: URL) async -> Goodreads.Plan? {
        activity.set("Reading Goodreads export…")
        let books = self.books
        let plan = await Task.detached { () -> Goodreads.Plan? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let entries = Goodreads.parse(String(decoding: data, as: UTF8.self))
            return entries.isEmpty ? nil : Goodreads.plan(entries, books: books)
        }.value
        if plan == nil {
            activity.flash("That doesn't look like a Goodreads export",
                           detail: "Choose the goodreads_library_export.csv file from Goodreads.")
        } else {
            activity.clear()
        }
        return plan
    }

    /// Updates the books you have from the export and, when asked, adds the ones you don't: read books
    /// without a file, and to-read books on the wishlist. Returns the books added.
    @discardableResult
    func importGoodreads(_ plan: Goodreads.Plan, addMissing: Bool) -> [Book] {
        var updated = 0
        modify(Set(plan.changes.keys)) { book in
            if let entry = plan.changes[book.id], Goodreads.apply(entry, to: &book) { updated += 1 }
        }
        var added: [Book] = []
        var wished = 0
        if addMissing {
            added = plan.missingRead.map(Goodreads.book)
            addWithoutFiles(added)
            withAnimation(.snappy) {
                wished = companion.add(plan.missingToRead.map(Goodreads.wish), owned: books).count
            }
        }
        saveNow()

        var detail = ["\(updated) updated"]
        if !added.isEmpty { detail.append("\(added.count) added without a file") }
        if wished > 0 { detail.append("\(wished) on your wishlist") }
        let skipped = plan.missingRead.count + plan.missingToRead.count
        if !addMissing, skipped > 0 { detail.append("\(skipped) not in your library left out") }
        activity.flash("Imported \(plan.total) book\(plan.total == 1 ? "" : "s") from Goodreads",
                       detail: detail.joined(separator: " · "))
        return added
    }
}
