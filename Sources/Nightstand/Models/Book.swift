import Foundation

enum ReadingStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case unread, reading, finished, abandoned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unread: "To Read"
        case .reading: "Reading"
        case .finished: "Finished"
        case .abandoned: "Abandoned"
        }
    }

    var symbol: String {
        switch self {
        case .unread: "bookmark"
        case .reading: "book"
        case .finished: "checkmark.circle"
        case .abandoned: "xmark.circle"
        }
    }
}

enum BookFormat: String, Codable, Sendable, CaseIterable {
    case epub, kepub, pdf, mobi, azw3, azw, fb2, cbz, cbr, djvu, txt

    /// Extension used for the file stored in the library and sent to devices.
    var fileExtension: String { self == .kepub ? "kepub.epub" : rawValue }

    /// EPUB and KEPUB can have their metadata, cover and styling rewritten.
    var isEPUBBased: Bool { self == .epub || self == .kepub }

    var label: String { rawValue.uppercased() }

    init?(url: URL) {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".kepub.epub") || name.hasSuffix(".kepub") {
            self = .kepub
        } else if let format = BookFormat(rawValue: url.pathExtension.lowercased()) {
            self = format
        } else {
            return nil
        }
    }
}

struct Book: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()

    // Metadata
    var title: String
    var authors: [String] = []
    var series: String?
    var seriesIndex: Double?
    var tags: [String] = []
    var publisher: String?
    var language: String?
    var summary: String?
    var published: String?
    var isbn: String?

    // Personal tracking
    var rating: Int = 0
    var status: ReadingStatus = .unread
    var notes: String = ""
    /// What the reader liked and didn't, in their own words. Used for the journal and by AI assistants.
    var liked: String?
    var disliked: String?
    var favourite: Bool?
    /// The community's rating on Goodreads, how many people gave one, and when it was last looked up.
    var goodreadsRating: Double?
    var goodreadsRatings: Int?
    var goodreadsID: String?
    var goodreadsChecked: Date?
    /// When missing details were last filled in from Open Library and Apple Books.
    var detailsChecked: Date?
    /// True for a book you've read but have no file for. Its file can be added later.
    var noFile: Bool?
    /// Formatting used for this book instead of the usual settings, when it needs its own.
    var formatOverride: FormatOptions?
    var dateAdded = Date()
    var dateStarted: Date?
    var dateFinished: Date?
    /// How far through the book, 0 to 1, as last synced from an e-reader.
    var progress: Double?
    /// When the e-reader last opened the book.
    var lastRead: Date?
    /// Total time spent reading on the e-reader.
    var readingSeconds: Int?
    /// Highlights and notes made on the e-reader.
    var highlights: [Highlight]?

    // File
    var format: BookFormat
    var fileSize: Int64 = 0
    var hasCover = false
    /// True when the user replaced the cover, so it gets written into the file on send/export.
    var customCover = false
    /// Bumped whenever the cover image changes, to invalidate cached thumbnails.
    var coverVersion = 0

    var fileName: String { "book.\(format.fileExtension)" }

    var authorText: String { authors.isEmpty ? "Unknown Author" : authors.joined(separator: ", ") }

    var seriesText: String {
        guard let series, !series.isEmpty else { return "" }
        guard let seriesIndex else { return series }
        return "\(series) #\(Book.formatIndex(seriesIndex))"
    }

    var searchText: String {
        ([title, authorText, series ?? "", notes, liked ?? "", disliked ?? ""] + tags)
            .joined(separator: " ").lowercased()
    }

    var isFavourite: Bool { favourite == true }
    var hasFile: Bool { noFile != true }

    /// True when the reader has written anything about the book.
    var hasThoughts: Bool {
        !notes.isEmpty || liked?.isEmpty == false || disliked?.isEmpty == false || highlights?.isEmpty == false
    }

    static func formatIndex(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// A passage highlighted, or a note written, on an e-reader.
struct Highlight: Identifiable, Codable, Hashable, Sendable {
    /// The e-reader's own id for it, so syncing again updates rather than duplicates.
    var id: String
    var text: String?
    var note: String?
    var date: Date?
}

extension Book {
    /// "3 h 20 min", or nil when nothing has been recorded.
    var readingTimeText: String? {
        guard let readingSeconds, readingSeconds >= 60 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = readingSeconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: TimeInterval(readingSeconds))
    }
}

enum BookSort: String, CaseIterable, Identifiable {
    case recent, title, author, series, rating, goodreads

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: "Recently Added"
        case .title: "Title"
        case .author: "Author"
        case .series: "Series"
        case .rating: "My Rating"
        case .goodreads: "Goodreads Rating"
        }
    }

    func apply(_ books: [Book]) -> [Book] {
        func byTitle(_ a: Book, _ b: Book) -> Bool {
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        switch self {
        case .recent:
            return books.sorted { $0.dateAdded > $1.dateAdded }
        case .title:
            return books.sorted(by: byTitle)
        case .author:
            return books.sorted {
                let order = $0.authorText.localizedStandardCompare($1.authorText)
                return order == .orderedSame ? Book.seriesOrder($0, $1) : order == .orderedAscending
            }
        case .series:
            return books.sorted(by: Book.seriesOrder)
        case .rating:
            return books.sorted { $0.rating == $1.rating ? byTitle($0, $1) : $0.rating > $1.rating }
        case .goodreads:
            return books.sorted {
                let a = $0.goodreadsRating ?? -1, b = $1.goodreadsRating ?? -1
                return a == b ? byTitle($0, $1) : a > b
            }
        }
    }
}

extension Book {
    /// Changes the reading status and keeps the start and finish dates in step with it.
    mutating func setStatus(_ newStatus: ReadingStatus, on date: Date = Date()) {
        guard status != newStatus else { return }
        status = newStatus
        switch newStatus {
        case .reading: if dateStarted == nil { dateStarted = date }
        case .finished: if dateFinished == nil { dateFinished = date }
        case .unread:
            dateStarted = nil
            dateFinished = nil
        case .abandoned: break
        }
    }

    /// Books in a series first (by series, then position), then everything else by title.
    static func seriesOrder(_ a: Book, _ b: Book) -> Bool {
        let sa = a.series ?? "", sb = b.series ?? ""
        if sa.isEmpty != sb.isEmpty { return !sa.isEmpty }
        if sa != sb { return sa.localizedStandardCompare(sb) == .orderedAscending }
        if !sa.isEmpty, a.seriesIndex != b.seriesIndex {
            return (a.seriesIndex ?? .greatestFiniteMagnitude) < (b.seriesIndex ?? .greatestFiniteMagnitude)
        }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}

/// Options applied to EPUBs when they are sent to a device or exported.
struct FormatOptions: Codable, Hashable, Sendable {
    enum Alignment: String, Codable, CaseIterable, Identifiable, Sendable {
        case publisher, justified, left
        var id: String { rawValue }
        var label: String {
            switch self {
            case .publisher: "Publisher Default"
            case .justified: "Justified"
            case .left: "Left Aligned"
            }
        }
    }

    enum ParagraphStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case publisher, indented, spaced
        var id: String { rawValue }
        var label: String {
            switch self {
            case .publisher: "Publisher Default"
            case .indented: "Indented"
            case .spaced: "Spaced"
            }
        }
    }

    enum FontSizeMode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A percentage of the size chosen on the e-reader.
        case relative
        /// An exact size in points, as Calibre's "Base font size" sets.
        case fixed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .relative: "Relative"
            case .fixed: "Exact Size"
            }
        }
    }

    var convertToKepub = true
    var applyFormatting = false
    var fontSizeMode: FontSizeMode = .relative
    /// Base font size as a percentage of the device's size.
    var fontScale: Double = 100
    /// Base font size in points, used when `fontSizeMode` is `.fixed`.
    var fontSizePoints: Double = 12
    /// Forces body text to the base size, ignoring fixed sizes set by the publisher.
    var normalizeFontSizes = false
    var overrideLineHeight = false
    var lineHeight: Double = 1.4
    var alignment: Alignment = .publisher
    var paragraphStyle: ParagraphStyle = .publisher
    /// Takes the page margins away entirely. Kept for settings saved by earlier versions; see `margins`.
    var removeMargins = false
    enum Margins: String, Codable, CaseIterable, Identifiable, Sendable {
        case publisher, none, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .publisher: "Publisher Default"
            case .none: "None"
            case .custom: "Choose"
            }
        }
    }
    var margins: Margins = .publisher
    /// Side margins in em when `margins` is `.custom`.
    var marginSize: Double = 1.5
    /// Curly quotes, real dashes and ellipses, like Calibre's "Smarten punctuation".
    var smartenPunctuation = false
    /// Takes out empty paragraphs used as spacing.
    var removeBlankParagraphs = false
    /// Scales down big images and, with the e-reader's font chosen, drops embedded fonts.
    var shrinkImages = false
    /// Builds a table of contents from the chapter headings when a book has none.
    var fixContents = false
    var hyphenate = false
    /// Drops the publisher's fonts, so the font chosen on the e-reader is used throughout.
    var useReaderFont = false
    /// Extra rules added after everything else, for anything the options above don't cover.
    var extraCSS = ""

    init() {}

    /// Options saved by an earlier version lack the newer keys; those take their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        convertToKepub = value(.convertToKepub, true)
        applyFormatting = value(.applyFormatting, false)
        fontSizeMode = value(.fontSizeMode, .relative)
        fontScale = value(.fontScale, 100)
        fontSizePoints = value(.fontSizePoints, 12)
        normalizeFontSizes = value(.normalizeFontSizes, false)
        overrideLineHeight = value(.overrideLineHeight, false)
        lineHeight = value(.lineHeight, 1.4)
        alignment = value(.alignment, .publisher)
        paragraphStyle = value(.paragraphStyle, .publisher)
        removeMargins = value(.removeMargins, false)
        margins = value(.margins, removeMargins ? .none : .publisher)
        marginSize = value(.marginSize, 1.5)
        smartenPunctuation = value(.smartenPunctuation, false)
        removeBlankParagraphs = value(.removeBlankParagraphs, false)
        shrinkImages = value(.shrinkImages, false)
        fixContents = value(.fixContents, false)
        hyphenate = value(.hyphenate, false)
        useReaderFont = value(.useReaderFont, false)
        extraCSS = value(.extraCSS, "")
    }

    /// "12" or "11.5": whole sizes without a decimal point.
    static func points(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// The stylesheet injected into every chapter, or nil when there is nothing to change.
    func css() -> String? {
        guard applyFormatting else { return nil }
        var rules: [String] = []
        switch fontSizeMode {
        case .relative where Int(fontScale) != 100:
            rules.append("html, body { font-size: \(Int(fontScale))% !important; }")
        case .fixed:
            // Headings and other sizes set in em or % then scale from this, as they do in Calibre.
            rules.append("html, body { font-size: \(Self.points(fontSizePoints))pt !important; }")
        default: break
        }
        if normalizeFontSizes {
            rules.append("p, li, blockquote, dd, td { font-size: 1em !important; }")
        }
        if overrideLineHeight {
            rules.append("p, li, blockquote, dd { line-height: \(String(format: "%.2f", lineHeight)) !important; }")
        }
        switch alignment {
        case .publisher: break
        case .justified: rules.append("p, li, dd { text-align: justify !important; }")
        case .left: rules.append("p, li, dd { text-align: left !important; }")
        }
        switch paragraphStyle {
        case .publisher: break
        case .indented:
            rules.append("p { margin-top: 0 !important; margin-bottom: 0 !important; text-indent: 1.2em !important; }")
            rules.append("h1 + p, h2 + p, h3 + p, h4 + p { text-indent: 0 !important; }")
        case .spaced:
            rules.append("p { margin-top: 0 !important; margin-bottom: 0.7em !important; text-indent: 0 !important; }")
        }
        switch margins {
        case .publisher: break
        case .none:
            rules.append("body { margin: 0 !important; padding: 0 !important; }")
            rules.append("@page { margin: 0; }")
        case .custom:
            let size = String(format: "%.1f", marginSize)
            rules.append("body { margin: 0 \(size)em !important; padding: 0 !important; }")
            rules.append("@page { margin: 0; }")
        }
        if hyphenate {
            rules.append("p { -webkit-hyphens: auto !important; hyphens: auto !important; adobe-hyphenate: auto; }")
        }
        if useReaderFont {
            rules.append("body, p, div, span, li, blockquote, dd, td, a { font-family: inherit !important; }")
        }
        let extra = extraCSS.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { rules.append(extra) }
        guard !rules.isEmpty else { return nil }
        return (["/* Added by Nightstand */"] + rules).joined(separator: "\n") + "\n"
    }
}

/// Reads and writes `library.json`. Shared by the app and the MCP server, which run as separate processes.
enum LibraryIndex {
    private struct File: Codable {
        var version = 1
        var books: [Book]
    }

    static func url(in root: URL) -> URL { root.appending(path: "library.json") }

    static func modificationDate(in root: URL) -> Date? {
        try? url(in: root).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// An empty library when there is no index yet; throws when the index exists but cannot be read.
    static func load(from root: URL) throws -> [Book] {
        guard FileManager.default.fileExists(atPath: url(in: root).path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(File.self, from: Data(contentsOf: url(in: root))).books
    }

    static func save(_ books: [Book], to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(books: books)).write(to: url(in: root), options: .atomic)
    }

    /// Brings together the books in memory and those another process has since written to the index.
    /// `baseline` is each book as this process last read or wrote it. A book changed only on one side takes
    /// that side's version, a book changed on both keeps the one in memory, and a book added or removed on
    /// either side is added or removed.
    static func merge(mine: [Book], theirs: [Book], baseline: [UUID: Book]) -> [Book] {
        let theirsByID = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [Book] = []
        for book in mine {
            let unchangedHere = baseline[book.id] == book
            if let other = theirsByID[book.id] {
                merged.append(unchangedHere ? other : book)
            } else if !unchangedHere {
                merged.append(book)
            }
        }
        let mineIDs = Set(mine.map(\.id))
        return merged + theirs.filter { !mineIDs.contains($0.id) && baseline[$0.id] == nil }
    }

    /// Copies an index that cannot be read to a file beside it, named for when it was last changed, so that
    /// whatever is written next does not destroy it.
    static func keepUnreadableCopy(in root: URL) {
        KeptCopy.keep(url(in: root), as: "library-unreadable")
    }
}

/// Keeps a copy of a file that could not be read, once for each version of it.
enum KeptCopy {
    static func keep(_ file: URL, as name: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let copy = file.deletingLastPathComponent()
            .appending(path: "\(name)-\(Int(modified.timeIntervalSince1970)).\(file.pathExtension)")
        if !fm.fileExists(atPath: copy.path) { try? fm.copyItem(at: file, to: copy) }
    }
}
