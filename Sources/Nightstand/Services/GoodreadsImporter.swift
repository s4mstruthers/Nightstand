import Foundation

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
                         review: OPF.plainText(value("My Review")), shelves: shelves)
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
    func importGoodreads(from url: URL) async {
        activity.set("Reading Goodreads export…")
        let entries = await Task.detached { () -> [Goodreads.Entry] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return Goodreads.parse(String(decoding: data, as: UTF8.self))
        }.value
        guard !entries.isEmpty else {
            activity.flash("That doesn't look like a Goodreads export",
                           detail: "Choose the goodreads_library_export.csv file from Goodreads.")
            return
        }

        var summary = Goodreads.Summary(total: entries.count)
        var changes: [UUID: Goodreads.Entry] = [:]
        for entry in entries {
            guard let book = books.first(where: { changes[$0.id] == nil && Goodreads.matches(entry, $0) })
            else { continue }
            summary.matched += 1
            changes[book.id] = entry
        }
        modify(Set(changes.keys)) { book in
            if let entry = changes[book.id], Goodreads.apply(entry, to: &book) { summary.updated += 1 }
        }
        saveNow()
        let missing = summary.total - summary.matched
        activity.flash("Updated \(summary.updated) book\(summary.updated == 1 ? "" : "s") from Goodreads",
                       detail: "\(summary.matched) of \(summary.total) Goodreads books are in your library"
                           + (missing > 0 ? " · \(missing) aren't" : ""))
    }
}
