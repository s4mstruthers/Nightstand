import Foundation
import UniformTypeIdentifiers

// MARK: - Shell

/// Runs the zip tools that ship with macOS. Nightstand is not sandboxed, so this needs no extra dependency.
enum Shell {
    struct Failure: LocalizedError {
        let tool: String
        let code: Int32
        var errorDescription: String? { "\((tool as NSString).lastPathComponent) failed (exit code \(code))" }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, okCodes: Set<Int32> = [0]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = cwd
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard okCodes.contains(process.terminationStatus) else {
            throw Failure(tool: tool, code: process.terminationStatus)
        }
        return data
    }
}

// MARK: - XML helpers

extension XMLNode {
    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
}

extension XMLElement {
    func child(_ localName: String) -> XMLElement? {
        elementChildren.first { $0.localName == localName }
    }

    func children(named localName: String) -> [XMLElement] {
        elementChildren.filter { $0.localName == localName }
    }

    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }

    func setAttr(_ name: String, _ value: String) {
        if let existing = attribute(forName: name) {
            existing.stringValue = value
        } else if let node = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode {
            addAttribute(node)
        }
    }

    func removeChildren(where predicate: (XMLElement) -> Bool) {
        for (index, node) in (children ?? []).enumerated().reversed() {
            if let element = node as? XMLElement, predicate(element) { removeChild(at: index) }
        }
    }
}

// MARK: - Metadata

struct EPUBMetadata: Sendable {
    var title: String?
    var authors: [String] = []
    var series: String?
    var seriesIndex: Double?
    var tags: [String] = []
    var publisher: String?
    var language: String?
    var summary: String?
    var published: String?
    var isbn: String?
    /// 0–5 stars (Calibre stores 0–10).
    var rating: Int?
    var added: Date?
    /// Path of the cover image inside the archive.
    var coverPath: String?
}

enum OPF {
    static let dcURI = "http://purl.org/dc/elements/1.1/"

    static func document(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    /// Resolves an href from the OPF against the OPF's own location inside the archive.
    static func resolve(_ href: String, relativeTo opfPath: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        var parts = opfPath.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }

    /// The manifest item holding the cover image, using the EPUB 2 and EPUB 3 conventions and then a best guess.
    static func coverItem(in package: XMLElement) -> XMLElement? {
        let items = package.child("manifest")?.children(named: "item") ?? []
        let metas = package.child("metadata")?.children(named: "meta") ?? []
        func isImage(_ item: XMLElement) -> Bool { item.attr("media-type")?.hasPrefix("image/") == true }

        if let ref = metas.first(where: { $0.attr("name") == "cover" })?.attr("content") {
            if let item = items.first(where: { $0.attr("id") == ref && isImage($0) }) { return item }
            if let item = items.first(where: { $0.attr("href") == ref && isImage($0) }) { return item }
        }
        if let item = items.first(where: {
            ($0.attr("properties") ?? "").split(separator: " ").contains("cover-image")
        }) { return item }
        return items.first {
            isImage($0) && (($0.attr("id") ?? "") + ($0.attr("href") ?? "")).lowercased().contains("cover")
        }
    }

    static func parse(_ doc: XMLDocument, opfPath: String) -> EPUBMetadata {
        var result = EPUBMetadata()
        guard let package = doc.rootElement(), let md = package.child("metadata") else { return result }

        func text(_ name: String) -> String? {
            md.children(named: name).lazy
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        func texts(_ name: String) -> [String] {
            md.children(named: name)
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        result.title = text("title")
        result.authors = texts("creator")
        result.tags = texts("subject")
        result.publisher = text("publisher")
        result.language = text("language")
        result.summary = text("description").map(plainText)
        result.published = text("date").map { String($0.prefix(10)) }

        for identifier in md.children(named: "identifier") {
            guard let value = identifier.stringValue?.trimmingCharacters(in: .whitespaces) else { continue }
            let scheme = (identifier.attr("opf:scheme") ?? identifier.attr("scheme") ?? "").lowercased()
            let lower = value.lowercased()
            if scheme == "isbn" {
                result.isbn = value
            } else if lower.hasPrefix("urn:isbn:") {
                result.isbn = String(value.dropFirst(9))
            } else if lower.hasPrefix("isbn:") {
                result.isbn = String(value.dropFirst(5))
            }
        }

        let metas = md.children(named: "meta")
        func named(_ name: String) -> String? {
            metas.first { $0.attr("name") == name }?.attr("content")
        }
        if let series = named("calibre:series"), !series.isEmpty {
            result.series = series
            result.seriesIndex = named("calibre:series_index").flatMap(Double.init)
        } else if let collection = metas.first(where: { $0.attr("property") == "belongs-to-collection" }),
                  let name = collection.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            result.series = name
            if let id = collection.attr("id") {
                result.seriesIndex = metas
                    .first { $0.attr("refines") == "#\(id)" && $0.attr("property") == "group-position" }?
                    .stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            }
        }
        if let rating = named("calibre:rating").flatMap(Double.init) {
            result.rating = min(5, max(0, Int((rating / 2).rounded())))
        }
        if let stamp = named("calibre:timestamp") {
            let precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            result.added = precise.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        }
        if let href = coverItem(in: package)?.attr("href") {
            result.coverPath = resolve(href, relativeTo: opfPath)
        }
        return result
    }

    /// Descriptions are often HTML; reduce them to readable plain text.
    static func plainText(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Reading without extracting

enum EPUBReader {
    struct Invalid: LocalizedError {
        var errorDescription: String? { "This file is not a valid EPUB." }
    }

    /// Reads one entry from the archive. `unzip` treats some characters as wildcards, so they are escaped.
    static func entry(_ path: String, in archive: URL) throws -> Data {
        var escaped = ""
        for character in path {
            if "[]*?\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return try Shell.run("/usr/bin/unzip", ["-p", archive.path, escaped], okCodes: [0, 1])
    }

    static func opfPath(in archive: URL) throws -> String {
        let container = try XMLDocument(data: entry("META-INF/container.xml", in: archive),
                                        options: [.nodeLoadExternalEntitiesNever])
        guard let path = container.rootElement()?.child("rootfiles")?.child("rootfile")?.attr("full-path"),
              !path.isEmpty else { throw Invalid() }
        return path
    }

    static func read(_ archive: URL) throws -> (metadata: EPUBMetadata, cover: Data?) {
        let path = try opfPath(in: archive)
        let metadata = OPF.parse(try OPF.document(entry(path, in: archive)), opfPath: path)
        let cover = metadata.coverPath.flatMap { try? entry($0, in: archive) }
        return (metadata, cover?.isEmpty == false ? cover : nil)
    }
}

// MARK: - Editing an extracted EPUB

/// An EPUB unpacked into a temporary folder so its metadata, cover and content can be rewritten.
final class ExtractedEPUB {
    let root: URL
    let opfPath: String
    let opf: XMLDocument

    private var opfURL: URL { root.appending(path: opfPath) }
    private var opfDirectory: URL { opfURL.deletingLastPathComponent() }
    private var package: XMLElement? { opf.rootElement() }
    private var isEPUB3: Bool { package?.attr("version")?.hasPrefix("3") == true }

    init(extracting archive: URL) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "nightstand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try Shell.run("/usr/bin/unzip", ["-q", "-o", archive.path, "-d", root.path], okCodes: [0, 1])
            // Some EPUBs store files with no permissions at all, which zip then can't read back.
            try Shell.run("/bin/chmod", ["-R", "u+rwX", root.path])
            let container = try XMLDocument(contentsOf: root.appending(path: "META-INF/container.xml"),
                                            options: [.nodeLoadExternalEntitiesNever])
            guard let path = container.rootElement()?.child("rootfiles")?.child("rootfile")?.attr("full-path")
            else { throw EPUBReader.Invalid() }
            opfPath = path
            opf = try OPF.document(Data(contentsOf: root.appending(path: path)))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// Writes the OPF back and zips the folder into a valid EPUB (uncompressed `mimetype` first).
    func pack(to destination: URL) throws {
        try opf.xmlData().write(to: opfURL)
        let mimetype = root.appending(path: "mimetype")
        if !FileManager.default.fileExists(atPath: mimetype.path) {
            try Data("application/epub+zip".utf8).write(to: mimetype)
        }
        try? FileManager.default.removeItem(at: destination)
        try Shell.run("/usr/bin/zip", ["-X0", destination.path, "mimetype"], cwd: root)
        try Shell.run("/usr/bin/zip", ["-Xr9Dq", destination.path, ".", "-x", "mimetype", "-x", "*.DS_Store"], cwd: root)
    }

    // MARK: Metadata

    func applyMetadata(_ book: Book) {
        guard let package, let md = package.child("metadata") else { return }

        let dc: String
        if let prefix = md.resolvePrefix(forNamespaceURI: OPF.dcURI), !prefix.isEmpty {
            dc = prefix
        } else {
            dc = "dc"
            if let namespace = XMLNode.namespace(withName: "dc", stringValue: OPF.dcURI) as? XMLNode {
                md.addNamespace(namespace)
            }
        }
        let metaName = (md.prefix?.isEmpty == false) ? "\(md.prefix!):meta" : "meta"

        func dcElement(_ local: String, _ value: String) -> XMLElement {
            let element = XMLElement(name: "\(dc):\(local)", uri: OPF.dcURI)
            element.stringValue = value
            return element
        }
        func setSingle(_ local: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            if let existing = md.child(local) {
                if existing.stringValue != value { existing.stringValue = value }
            } else {
                md.addChild(dcElement(local, value))
            }
        }
        var orphanedRefs = Set<String>()
        func setMultiple(_ local: String, _ values: [String]) {
            let existing = md.children(named: local)
            let current = existing.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard current != values else { return }
            for element in existing {
                if let id = element.attr("id") { orphanedRefs.insert("#\(id)") }
            }
            md.removeChildren { $0.localName == local && $0.prefix == dc }
            values.forEach { md.addChild(dcElement(local, $0)) }
        }

        setSingle("title", book.title)
        setSingle("publisher", book.publisher)
        setMultiple("creator", book.authors)
        setMultiple("subject", book.tags)

        // Series: rewrite both the Calibre convention and the EPUB 3 collection, which Kobo reads.
        for meta in md.children(named: "meta") where meta.attr("property") == "belongs-to-collection" {
            if let id = meta.attr("id") { orphanedRefs.insert("#\(id)") }
        }
        md.removeChildren { element in
            guard element.localName == "meta" else { return false }
            if let name = element.attr("name"), name == "calibre:series" || name == "calibre:series_index" { return true }
            if element.attr("property") == "belongs-to-collection" { return true }
            if let refines = element.attr("refines"), orphanedRefs.contains(refines) { return true }
            return false
        }
        if let series = book.series, !series.isEmpty {
            let index = Book.formatIndex(book.seriesIndex ?? 1)
            func meta(_ attributes: [(String, String)], _ value: String? = nil) {
                let element = XMLElement(name: metaName)
                attributes.forEach { element.setAttr($0.0, $0.1) }
                if let value { element.stringValue = value }
                md.addChild(element)
            }
            meta([("name", "calibre:series"), ("content", series)])
            meta([("name", "calibre:series_index"), ("content", index)])
            if isEPUB3 {
                meta([("property", "belongs-to-collection"), ("id", "nightstand-series")], series)
                meta([("refines", "#nightstand-series"), ("property", "collection-type")], "series")
                meta([("refines", "#nightstand-series"), ("property", "group-position")], index)
            }
        }
    }

    // MARK: Cover

    /// Replaces the cover image. Overwrites the existing image file where possible so cover pages keep working.
    func setCover(imageData: Data) throws {
        guard let package, let manifest = package.child("manifest") else { return }

        if let item = OPF.coverItem(in: package), let href = item.attr("href") {
            let url = root.appending(path: OPF.resolve(href, relativeTo: opfPath))
            let type: UTType? = switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": .jpeg
            case "png": .png
            default: nil
            }
            if let type, let encoded = ImageTools.encode(imageData, as: type) {
                try encoded.write(to: url)
                return
            }
        }

        guard let jpeg = ImageTools.encode(imageData, as: .jpeg) else { return }
        try jpeg.write(to: opfDirectory.appending(path: "nightstand-cover.jpg"))
        let itemName = (manifest.prefix?.isEmpty == false) ? "\(manifest.prefix!):item" : "item"
        manifest.removeChildren { $0.attr("id") == "nightstand-cover" }
        for item in manifest.children(named: "item") {
            guard let properties = item.attr("properties") else { continue }
            let kept = properties.split(separator: " ").filter { $0 != "cover-image" }.joined(separator: " ")
            if kept.isEmpty { item.removeAttribute(forName: "properties") } else { item.setAttr("properties", kept) }
        }
        let item = XMLElement(name: itemName)
        item.setAttr("id", "nightstand-cover")
        item.setAttr("href", "nightstand-cover.jpg")
        item.setAttr("media-type", "image/jpeg")
        item.setAttr("properties", "cover-image")
        manifest.addChild(item)
        if let md = package.child("metadata") {
            md.removeChildren { $0.localName == "meta" && $0.attr("name") == "cover" }
            let meta = XMLElement(name: (md.prefix?.isEmpty == false) ? "\(md.prefix!):meta" : "meta")
            meta.setAttr("name", "cover")
            meta.setAttr("content", "nightstand-cover")
            md.addChild(meta)
        }
    }

    // MARK: Content

    /// Every XHTML content document, with its href relative to the OPF.
    var contentDocuments: [(href: String, url: URL)] {
        let items = package?.child("manifest")?.children(named: "item") ?? []
        return items.compactMap { item in
            guard let href = item.attr("href") else { return nil }
            let lower = href.lowercased()
            let isXHTML = item.attr("media-type") == "application/xhtml+xml"
                || lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm")
            guard isXHTML else { return nil }
            return (href, root.appending(path: OPF.resolve(href, relativeTo: opfPath)))
        }
    }

    /// Adds a stylesheet that loads last in every chapter, so it overrides the publisher's styling.
    func injectStylesheet(_ css: String) throws {
        guard let manifest = package?.child("manifest") else { return }
        try Data(css.utf8).write(to: opfDirectory.appending(path: "nightstand.css"))
        manifest.removeChildren { $0.attr("id") == "nightstand-css" }
        let item = XMLElement(name: (manifest.prefix?.isEmpty == false) ? "\(manifest.prefix!):item" : "item")
        item.setAttr("id", "nightstand-css")
        item.setAttr("href", "nightstand.css")
        item.setAttr("media-type", "text/css")
        manifest.addChild(item)

        for document in contentDocuments {
            guard var html = try? String(contentsOf: document.url, encoding: .utf8),
                  !html.contains("nightstand.css"),
                  let head = html.range(of: "</head>", options: .caseInsensitive) else { continue }
            let depth = (document.href.removingPercentEncoding ?? document.href)
                .split(separator: "/").dropLast().filter { $0 != "." }.count
            let prefix = String(repeating: "../", count: depth)
            html.insert(contentsOf: "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(prefix)nightstand.css\"/>",
                        at: head.lowerBound)
            try html.write(to: document.url, atomically: true, encoding: .utf8)
        }
    }

    /// Adds Kobo's reading-position spans to every chapter. Chapters that cannot be parsed are left as they are.
    func convertToKepub() {
        for document in contentDocuments {
            guard let data = try? Data(contentsOf: document.url),
                  let converted = KepubConverter.convert(data) else { continue }
            try? converted.write(to: document.url)
        }
        // Kobo finds the cover through the EPUB 3 property, even in EPUB 2 files.
        if let package, let cover = OPF.coverItem(in: package) {
            let properties = (cover.attr("properties") ?? "").split(separator: " ").map(String.init)
            if !properties.contains("cover-image") {
                cover.setAttr("properties", (properties + ["cover-image"]).joined(separator: " "))
            }
        }
    }
}

// MARK: - Building the file that leaves the library

/// What the destination (a device or an export folder) can read.
struct OutputProfile: Sendable {
    var supported: Set<BookFormat>
    /// Whether EPUBs should become KEPUBs (Kobo).
    var kepub: Bool
    /// The format to convert to when the book's own format is not supported.
    var fallback: BookFormat

    static let export = OutputProfile(supported: Set(BookFormat.allCases).subtracting([.kepub]),
                                      kepub: false, fallback: .epub)
}

/// Optional bridge to Calibre's command-line converter, for format pairs Nightstand cannot convert itself
/// (for example EPUB to AZW3 for a Kindle). Used only when Calibre happens to be installed.
enum CalibreConverter {
    static var executable: URL? {
        let candidates = [
            "/Applications/calibre.app/Contents/MacOS/ebook-convert",
            NSHomeDirectory() + "/Applications/calibre.app/Contents/MacOS/ebook-convert",
            "/opt/homebrew/bin/ebook-convert",
            "/usr/local/bin/ebook-convert",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static func convert(_ input: URL, to output: URL) throws {
        guard let executable else { throw BookBuilder.Unsupported(format: nil, target: nil) }
        try Shell.run(executable.path, [input.path, output.path])
    }
}

enum BookBuilder {
    struct Unsupported: LocalizedError {
        let format: BookFormat?
        let target: BookFormat?
        var errorDescription: String? {
            guard let format, let target else { return "Calibre's converter is not installed." }
            return "\(format.label) needs converting to \(target.label), which requires Calibre to be installed."
        }
    }

    /// Produces the file to send or export: metadata and cover written in, formatting applied, and the
    /// format converted where the destination needs it. The result lives in its own temporary folder,
    /// which the caller removes.
    static func build(book: Book, source: URL, customCover: URL?, options: FormatOptions,
                      profile: OutputProfile) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nightstand-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            return try build(book: book, source: source, customCover: customCover, options: options,
                             profile: profile, in: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func build(book: Book, source: URL, customCover: URL?, options: FormatOptions,
                              profile: OutputProfile, in folder: URL) throws -> URL {
        let name = outputName(for: book)
        let wantsKepub = profile.kepub && options.convertToKepub
        var current = source
        var format = book.format

        if format.isEPUBBased {
            let epub = try ExtractedEPUB(extracting: source)
            defer { epub.cleanup() }
            epub.applyMetadata(book)
            if let customCover, let data = try? Data(contentsOf: customCover) {
                try epub.setCover(imageData: data)
            }
            if let css = options.css() { try epub.injectStylesheet(css) }
            if format == .epub, wantsKepub {
                epub.convertToKepub()
                format = .kepub
            }
            // A KEPUB is still a valid EPUB, so readers without KEPUB support get it under the plain extension.
            if format == .kepub, !profile.supported.contains(.kepub), profile.supported.contains(.epub) {
                format = .epub
            }
            current = folder.appending(path: "\(name).\(format.fileExtension)")
            try epub.pack(to: current)
        }

        if profile.supported.contains(format) {
            if current == source {
                current = folder.appending(path: "\(name).\(format.fileExtension)")
                try FileManager.default.copyItem(at: source, to: current)
            }
            return current
        }

        guard CalibreConverter.executable != nil else {
            throw Unsupported(format: book.format, target: profile.fallback)
        }
        var output = folder.appending(path: "\(name)-converted.\(profile.fallback.fileExtension)")
        try CalibreConverter.convert(current, to: output)
        if current != source { try? FileManager.default.removeItem(at: current) }

        if profile.fallback == .epub, wantsKepub {
            let epub = try ExtractedEPUB(extracting: output)
            defer { epub.cleanup() }
            epub.convertToKepub()
            try? FileManager.default.removeItem(at: output)
            output = folder.appending(path: "\(name).kepub.epub")
            try epub.pack(to: output)
        } else {
            let final = folder.appending(path: "\(name).\(profile.fallback.fileExtension)")
            try FileManager.default.moveItem(at: output, to: final)
            output = final
        }
        return output
    }

    static func outputName(for book: Book) -> String {
        let author = book.authors.first.map { " - \($0)" } ?? ""
        return sanitize(book.title + author)
    }

    /// Makes a string safe as a file name on the FAT file system Kobo uses.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters))
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(100))
    }
}
