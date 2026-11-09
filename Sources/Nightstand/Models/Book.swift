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
    var dateAdded = Date()
    var dateStarted: Date?
    var dateFinished: Date?

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
        ([title, authorText, series ?? "", notes] + tags).joined(separator: " ").lowercased()
    }

    static func formatIndex(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

enum BookSort: String, CaseIterable, Identifiable {
    case recent, title, author, series, rating

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: "Recently Added"
        case .title: "Title"
        case .author: "Author"
        case .series: "Series"
        case .rating: "Rating"
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
        }
    }
}

extension Book {
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
struct FormatOptions: Codable, Equatable, Sendable {
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

    var convertToKepub = true
    var applyFormatting = false
    /// Base font size as a percentage of the device's size.
    var fontScale: Double = 100
    /// Forces body text to the base size, ignoring fixed sizes set by the publisher.
    var normalizeFontSizes = false
    var overrideLineHeight = false
    var lineHeight: Double = 1.4
    var alignment: Alignment = .publisher
    var paragraphStyle: ParagraphStyle = .publisher
    var removeMargins = false
    var hyphenate = false

    /// The stylesheet injected into every chapter, or nil when there is nothing to change.
    func css() -> String? {
        guard applyFormatting else { return nil }
        var rules: [String] = []
        if Int(fontScale) != 100 {
            rules.append("html, body { font-size: \(Int(fontScale))% !important; }")
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
        if removeMargins {
            rules.append("body { margin: 0 !important; padding: 0 !important; }")
            rules.append("@page { margin: 0; }")
        }
        if hyphenate {
            rules.append("p { -webkit-hyphens: auto !important; hyphens: auto !important; adobe-hyphenate: auto; }")
        }
        guard !rules.isEmpty else { return nil }
        return (["/* Added by Nightstand */"] + rules).joined(separator: "\n") + "\n"
    }
}
