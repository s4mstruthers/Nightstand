import AppKit
import PDFKit

/// Copies a book file into the library folder and reads whatever metadata and cover its format offers.
enum Ingest {
    struct UnsupportedFile: LocalizedError {
        let name: String
        var errorDescription: String? { "\(name) is not a supported book format." }
    }

    static let supportedExtensions: Set<String> = Set(BookFormat.allCases.map(\.rawValue))

    static func isBook(_ url: URL) -> Bool { BookFormat(url: url) != nil }

    /// Expands folders into the book files they contain.
    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])
                while let file = enumerator?.nextObject() as? URL {
                    if isBook(file) { result.append(file) }
                }
            } else if isBook(url) {
                result.append(url)
            }
        }
        return result
    }

    static func ingest(file: URL, booksFolder: URL, metadata override: EPUBMetadata? = nil,
                       cover coverOverride: URL? = nil) throws -> Book {
        guard let format = BookFormat(url: file) else { throw UnsupportedFile(name: file.lastPathComponent) }

        var name = file.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".kepub") { name = String(name.dropLast(6)) }
        var book = Book(title: name, format: format)

        let folder = booksFolder.appending(path: book.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let stored = folder.appending(path: book.fileName)
            try FileManager.default.copyItem(at: file, to: stored)
            book.fileSize = Int64((try? stored.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

            var embedded = EPUBMetadata()
            var cover: Data?
            switch format {
            case .epub, .kepub:
                if let result = try? EPUBReader.read(stored) { (embedded, cover) = result }
            case .pdf:
                (embedded, cover) = readPDF(stored)
            case .mobi, .azw3, .azw:
                embedded = MobiReader.read(stored) ?? embedded
            case .cbz:
                cover = comicCover(stored)
            default:
                break
            }

            let metadata = override ?? embedded
            if let title = metadata.title, !title.isEmpty { book.title = title }
            book.authors = metadata.authors
            book.series = metadata.series
            book.seriesIndex = metadata.seriesIndex
            book.tags = metadata.tags
            book.publisher = metadata.publisher
            book.language = metadata.language
            book.summary = metadata.summary
            book.published = metadata.published
            book.isbn = metadata.isbn
            book.rating = metadata.rating ?? 0
            if let added = metadata.added { book.dateAdded = added }

            if let coverOverride, let data = try? Data(contentsOf: coverOverride) { cover = data }
            if let cover, let jpeg = ImageTools.encode(cover, as: .jpeg, maxPixel: 1600) {
                try jpeg.write(to: folder.appending(path: "cover.jpg"))
                book.hasCover = true
            }
            return book
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func readPDF(_ url: URL) -> (EPUBMetadata, Data?) {
        var metadata = EPUBMetadata()
        guard let document = PDFDocument(url: url) else { return (metadata, nil) }
        let attributes = document.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String,
           !title.trimmingCharacters(in: .whitespaces).isEmpty {
            metadata.title = title
        }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String,
           !author.trimmingCharacters(in: .whitespaces).isEmpty {
            metadata.authors = [author]
        }
        let cover = document.page(at: 0)?
            .thumbnail(of: NSSize(width: 800, height: 1200), for: .mediaBox)
            .tiffRepresentation
        return (metadata, cover)
    }

    /// The first image in a comic archive, by name, is its cover.
    private static func comicCover(_ url: URL) -> Data? {
        guard let listing = try? Shell.run("/usr/bin/unzip", ["-Z1", url.path], okCodes: [0, 1]),
              let names = String(data: listing, encoding: .utf8) else { return nil }
        let images = names.split(separator: "\n").map(String.init).filter {
            let lower = $0.lowercased()
            return !lower.contains("__macosx")
                && [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { lower.hasSuffix($0) }
        }
        guard let first = images.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).first
        else { return nil }
        return try? EPUBReader.entry(first, in: url)
    }
}

/// Reads the title and author from a MOBI / AZW / AZW3 file's headers.
enum MobiReader {
    static func read(_ url: URL) -> EPUBMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The headers live in the first record; a generous prefix avoids loading the whole book.
        guard let data = try? handle.read(upToCount: 256 * 1024), data.count > 78 else { return nil }

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            return Int(data[offset]) << 8 | Int(data[offset + 1])
        }
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return (0..<4).reduce(0) { $0 << 8 | Int(data[offset + $1]) }
        }
        func string(_ offset: Int, _ length: Int, utf8: Bool) -> String? {
            guard offset >= 0, length > 0, offset + length <= data.count else { return nil }
            let bytes = data.subdata(in: offset..<(offset + length))
            return String(data: bytes, encoding: utf8 ? .utf8 : .windowsCP1252)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let records = u16(76), records > 0, let record0 = u32(78),
              string(record0 + 16, 4, utf8: false) == "MOBI",
              let headerLength = u32(record0 + 20) else { return nil }
        let isUTF8 = u32(record0 + 28) == 65001

        var metadata = EPUBMetadata()
        if let titleOffset = u32(record0 + 84), let titleLength = u32(record0 + 88) {
            metadata.title = string(record0 + titleOffset, titleLength, utf8: isUTF8)
        }

        let exth = record0 + 16 + headerLength
        if let flags = u32(record0 + 128), flags & 0x40 != 0,
           string(exth, 4, utf8: false) == "EXTH", let count = u32(exth + 8) {
            var offset = exth + 12
            for _ in 0..<min(count, 500) {
                guard let type = u32(offset), let length = u32(offset + 4), length >= 8 else { break }
                let value = string(offset + 8, length - 8, utf8: isUTF8)
                switch type {
                case 100: if let value, !value.isEmpty { metadata.authors.append(value) }
                case 101: metadata.publisher = value
                case 103: metadata.summary = value.map(OPF.plainText)
                case 104: metadata.isbn = value
                case 105: if let value, !value.isEmpty { metadata.tags.append(value) }
                case 106: metadata.published = value.map { String($0.prefix(10)) }
                case 503: if let value, !value.isEmpty { metadata.title = value }
                default: break
                }
                offset += length
            }
        }
        return metadata
    }
}

/// Finds the books in a Calibre library folder, with the metadata Calibre keeps beside each one.
enum CalibreLibrary {
    struct Entry: Sendable {
        let file: URL
        let metadata: EPUBMetadata?
        let cover: URL?
    }

    private static let preference: [BookFormat] = [.epub, .kepub, .azw3, .mobi, .azw, .pdf, .fb2, .cbz, .cbr, .djvu, .txt]

    static func entries(in library: URL) -> [Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: library, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { return [] }
        var result: [Entry] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "metadata.opf" else { continue }
            let folder = url.deletingLastPathComponent()
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let best = files
                .compactMap { file in BookFormat(url: file).map { (file, $0) } }
                .min { (preference.firstIndex(of: $0.1) ?? 99) < (preference.firstIndex(of: $1.1) ?? 99) }
            guard let best else { continue }
            let metadata = (try? Data(contentsOf: url))
                .flatMap { try? OPF.document($0) }
                .map { OPF.parse($0, opfPath: "metadata.opf") }
            let cover = folder.appending(path: "cover.jpg")
            result.append(Entry(file: best.0, metadata: metadata,
                                cover: fm.fileExists(atPath: cover.path) ? cover : nil))
        }
        return result
    }
}
