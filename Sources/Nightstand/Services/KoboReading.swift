import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// Reading progress, time spent and highlights as a Kobo records them in `.kobo/KoboReader.sqlite`.
/// Kobo has no public API for this; the database on the device is the source of truth.
enum KoboReading {
    struct Record: Equatable, Sendable {
        /// Kobo's id for the book: `file:///mnt/onboard/<path>` for sideloaded books, a UUID for store books.
        var contentID: String
        var title: String
        var author: String
        /// 0 unread, 1 reading, 2 finished.
        var readStatus: Int
        /// 0 to 100.
        var percentRead: Int
        var lastRead: Date?
        var secondsReading: Int?
        var highlights: [Highlight] = []
        /// Where the reader is: a chapter file in the book and a `kobo.N.N` span, e.g. `text/ch3.html#kobo.24.1`.
        var bookmark: String?
        /// How far through the current chapter, 0 to 1.
        var chapterProgress: Double?
        /// `DateLastRead` exactly as the Kobo wrote it, for writing back.
        var lastReadRaw: String?

        /// The book's path relative to the device root, for books copied onto it over USB.
        var devicePath: String? {
            let prefix = "file:///mnt/onboard/"
            guard contentID.hasPrefix(prefix) else { return nil }
            let path = String(contentID.dropFirst(prefix.count))
            return path.removingPercentEncoding ?? path
        }
    }

    enum ReadError: LocalizedError {
        case missing, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .missing: "This Kobo has no reading database yet."
            case .unreadable(let message): "Couldn't read the Kobo's reading database (\(message))."
            }
        }
    }

    static func databaseURL(on root: URL) -> URL { root.appending(path: ".kobo/KoboReader.sqlite") }

    /// Reads every book the Kobo knows about. Works on a private copy, so the device's database is never touched.
    static func read(deviceRoot: URL) throws -> [Record] {
        let source = databaseURL(on: deviceRoot)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw ReadError.missing }
        let folder = fm.temporaryDirectory.appending(path: "nightstand-kobo-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let copy = folder.appending(path: "KoboReader.sqlite")
        try fm.copyContents(of: source, to: copy)
        // Recent changes may still be in the write-ahead log.
        for suffix in ["-wal", "-shm"] {
            let extra = URL(fileURLWithPath: source.path + suffix)
            if fm.fileExists(atPath: extra.path) {
                try? fm.copyContents(of: extra, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        return try read(database: copy)
    }

    static func read(database url: URL) throws -> [Record] {
        let db = try KoboDatabase(url)
        let columns = try db.columns(of: "content")
        func column(_ name: String, or fallback: String) -> String { columns.contains(name) ? name : fallback }

        let sql = """
            SELECT ContentID, \(column("Title", or: "''")), \(column("Attribution", or: "''")),
                   \(column("ReadStatus", or: "0")), \(column("___PercentRead", or: "0")),
                   \(column("DateLastRead", or: "NULL")), \(column("TimeSpentReading", or: "NULL")),
                   \(column("ChapterIDBookmarked", or: "NULL")), \(column("CurrentChapterProgress", or: "NULL"))
            FROM content WHERE ContentType = 6
            """
        var records: [String: Record] = [:]
        var order: [String] = []
        try db.query(sql) { row in
            guard let id = row.text(0) else { return }
            records[id] = Record(contentID: id, title: row.text(1) ?? "", author: row.text(2) ?? "",
                                 readStatus: row.int(3) ?? 0, percentRead: min(max(row.int(4) ?? 0, 0), 100),
                                 lastRead: row.text(5).flatMap(parseDate), secondsReading: row.int(6),
                                 bookmark: row.text(7).flatMap { $0.isEmpty ? nil : $0 },
                                 chapterProgress: row.double(8), lastReadRaw: row.text(5))
            order.append(id)
        }

        if try db.tableExists("Bookmark") {
            let bookmarkColumns = try db.columns(of: "Bookmark")
            func bookmark(_ name: String) -> String { bookmarkColumns.contains(name) ? name : "NULL" }
            let sql = """
                SELECT BookmarkID, VolumeID, \(bookmark("Text")), \(bookmark("Annotation")),
                       \(bookmark("DateCreated")), \(bookmark("Type")), \(bookmark("Hidden"))
                FROM Bookmark ORDER BY \(bookmarkColumns.contains("DateCreated") ? "DateCreated" : "rowid")
                """
            try db.query(sql) { row in
                guard let id = row.text(0), let volume = row.text(1), records[volume] != nil else { return }
                let hidden = row.text(6).map { $0 == "true" || $0 == "1" } ?? false
                let text = row.text(2)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let note = row.text(3)?.trimmingCharacters(in: .whitespacesAndNewlines)
                // Dog-ears (page bookmarks) have no text worth keeping.
                guard !hidden, row.text(5) != "dogear", !(text ?? "").isEmpty || !(note ?? "").isEmpty else { return }
                records[volume]?.highlights.append(Highlight(
                    id: id, text: text.flatMap { $0.isEmpty ? nil : $0 },
                    note: note.flatMap { $0.isEmpty ? nil : $0 }, date: row.text(4).flatMap(parseDate)))
            }
        }
        return order.compactMap { records[$0] }
    }

    /// Kobo writes dates as `2024-03-01T21:04:11Z`, sometimes with fractions or an offset. Always UTC.
    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(trimmed.prefix(19)))
    }

    // MARK: Merging

    struct Summary: Equatable, Sendable {
        var booksUpdated = 0
        var finished = 0
        var newHighlights = 0
        var unmatched = 0
    }

    /// Applies what the Kobo recorded to the library. Books are matched by where Nightstand put them on the
    /// device, then by title and author. Status only moves forward (unread → reading → finished), and
    /// highlights are added, never removed.
    static func merge(_ records: [Record], into books: [Book], manifest: [UUID: String])
        -> (changed: [Book], summary: Summary) {
        var summary = Summary()
        var byID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        let byPath = Dictionary(manifest.map { ($0.value.lowercased(), $0.key) }, uniquingKeysWith: { a, _ in a })
        var changedIDs: [UUID] = []

        for record in records where record.readStatus > 0 || record.percentRead > 0 || !record.highlights.isEmpty {
            guard let id = match(record, books: books, byPath: byPath), var book = byID[id] else {
                summary.unmatched += 1
                continue
            }
            let original = book
            let newer = book.lastRead == nil || (record.lastRead ?? .distantPast) >= (book.lastRead ?? .distantPast)
            if newer {
                book.progress = record.readStatus == 2 ? 1 : Double(record.percentRead) / 100
                if let lastRead = record.lastRead { book.lastRead = lastRead }
                if let seconds = record.secondsReading, seconds > 0 { book.readingSeconds = seconds }
            }
            let when = record.lastRead ?? Date()
            if record.readStatus == 2, book.status != .finished, book.status != .abandoned {
                book.setStatus(.finished, on: when)
                summary.finished += 1
            } else if record.readStatus == 1 || record.percentRead > 0, book.status == .unread {
                book.setStatus(.reading, on: when)
            }

            var highlights = book.highlights ?? []
            for highlight in record.highlights {
                if let index = highlights.firstIndex(where: { $0.id == highlight.id }) {
                    highlights[index] = highlight
                } else {
                    highlights.append(highlight)
                    summary.newHighlights += 1
                }
            }
            if !highlights.isEmpty { book.highlights = highlights }

            if book != original {
                byID[id] = book
                if !changedIDs.contains(id) { changedIDs.append(id) }
            }
        }
        summary.booksUpdated = changedIDs.count
        return (changedIDs.compactMap { byID[$0] }, summary)
    }

    private static func match(_ record: Record, books: [Book], byPath: [String: UUID]) -> UUID? {
        if let path = record.devicePath?.lowercased(), let id = byPath[path] { return id }
        return match(title: record.title, author: record.author, in: books)
    }

    /// Finds the one library book with this title (with or without its subtitle) and author, if there is one.
    static func match(title rawTitle: String, author rawAuthor: String, in books: [Book]) -> UUID? {
        let record = (title: rawTitle, author: rawAuthor)
        let author = normalize(record.author + " " + record.title)
        func byAuthor(_ book: Book) -> Bool {
            guard let surname = book.authors.first?.split(separator: " ").last else { return true }
            return author.contains(normalize(String(surname)))
        }
        // The full title first, then without subtitles ("Project Hail Mary: A Novel" → "Project Hail Mary").
        for key in [normalize(record.title), normalize(mainTitle(record.title))] where !key.isEmpty {
            let exact = books.filter { normalize($0.title) == key && byAuthor($0) }
            if exact.count == 1 { return exact[0].id }
            let loose = books.filter { normalize(mainTitle($0.title)) == key && byAuthor($0) }
            if loose.count == 1 { return loose[0].id }
        }
        return nil
    }

    /// The title before any subtitle or bracketed series note.
    private static func mainTitle(_ title: String) -> String {
        let cut = title.firstIndex { $0 == ":" || $0 == "(" || $0 == "[" } ?? title.endIndex
        return String(title[..<cut])
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}

/// A small SQLite wrapper. Reading is always done on a private copy (a WAL database like Kobo's can't be
/// opened read-only when its side files are missing, so copies are opened read-write too). Writing to the
/// device's own database is done only by `KoboTidy.restore`, after a backup.
final class KoboDatabase {
    struct Row {
        let statement: OpaquePointer
        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }
        func int(_ index: Int32) -> Int? {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_NULL: nil
            case SQLITE_INTEGER, SQLITE_FLOAT: Int(sqlite3_column_int64(statement, index))
            default: text(index).flatMap { Int($0) ?? Double($0).map { Int($0) } }
            }
        }
        func double(_ index: Int32) -> Double? {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_NULL: nil
            case SQLITE_INTEGER, SQLITE_FLOAT: sqlite3_column_double(statement, index)
            default: text(index).flatMap(Double.init)
            }
        }
    }

    enum Value {
        case text(String?), int(Int?), double(Double?)
    }

    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw KoboReading.ReadError.unreadable(message)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(handle) }

    private var error: KoboReading.ReadError { .unreadable(String(cString: sqlite3_errmsg(handle))) }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text?): sqlite3_bind_text(statement, index, text, -1, transient)
            case .int(let int?): sqlite3_bind_int64(statement, index, Int64(int))
            case .double(let double?): sqlite3_bind_double(statement, index, double)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    func query(_ sql: String, _ values: [Value] = [], _ each: (Row) throws -> Void) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error }
            try each(Row(statement: statement))
        }
    }

    /// Runs a statement and returns how many rows it changed.
    @discardableResult
    func execute(_ sql: String, _ values: [Value] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else { throw error }
        return Int(sqlite3_changes(handle))
    }

    func columns(of table: String) throws -> Set<String> {
        var names: Set<String> = []
        try query("PRAGMA table_info(\(table))") { row in if let name = row.text(1) { names.insert(name) } }
        return names
    }

    func tableExists(_ table: String) throws -> Bool {
        var found = false
        try query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]) { _ in found = true }
        return found
    }
}

/// The cover thumbnails a Kobo keeps for its library screens, in `.kobo-images`.
///
/// A Kobo makes these from the cover inside the book when it first imports it, and keeps using them even if
/// the book file is later replaced. They are plain JPEGs named after the book's id.
enum KoboCovers {
    /// The name a Kobo gives a sideloaded book's images: its id with punctuation turned into underscores.
    static func imageID(for path: String) -> String {
        String(("file:///mnt/onboard/" + path).map { "/:. ".contains($0) ? "_" : $0 })
    }

    /// Replaces the thumbnails the Kobo already has for the book at `path` with the given cover, each at the
    /// size it was. Nothing is created: a book the Kobo hasn't imported gets its cover from the file.
    /// Returns how many images were replaced.
    @discardableResult
    static func refresh(for path: String, cover: URL, on root: URL) -> Int {
        guard let data = try? Data(contentsOf: cover) else { return 0 }
        let prefix = imageID(for: path) + " - "
        let folder = root.appending(path: ".kobo-images")
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var replaced = 0
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix(prefix) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  let image = ImageTools.encode(data, as: .jpeg, maxPixel: max(width, height)) else { continue }
            if (try? image.write(to: url, options: .atomic)) != nil { replaced += 1 }
        }
        return replaced
    }
}
