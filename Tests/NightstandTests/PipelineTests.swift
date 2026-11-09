import XCTest
@testable import Nightstand

final class PipelineTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appending(path: "nightstand-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: work)
    }

    /// Builds a small EPUB 2 with a cover, a series and a chapter in a subfolder.
    private func makeEPUB(named name: String = "sample.epub") throws -> URL {
        let root = work.appending(path: "src-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "OEBPS/text"), withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: root.appending(path: "mimetype"))
        try Data("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8).write(to: root.appending(path: "META-INF/container.xml"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>Original Title</dc:title>
            <dc:creator opf:role="aut">Ada Writer</dc:creator>
            <dc:language>en</dc:language>
            <dc:subject>Fiction</dc:subject>
            <dc:description>&lt;p&gt;A &lt;b&gt;fine&lt;/b&gt; book.&lt;/p&gt;</dc:description>
            <dc:identifier id="id" opf:scheme="ISBN">9780000000001</dc:identifier>
            <meta name="calibre:series" content="The Saga"/>
            <meta name="calibre:series_index" content="2"/>
            <meta name="cover" content="cover-img"/>
          </metadata>
          <manifest>
            <item id="cover-img" href="images/cover.png" media-type="image/png"/>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """.utf8).write(to: root.appending(path: "OEBPS/content.opf"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>
        <body class="chapter"><h1>Chapter&nbsp;One</h1>
        <p>First sentence. Second <em>emphasised</em> sentence! Third?</p>
        <p>Caf&eacute; &amp; bar &mdash; open.</p></body></html>
        """.utf8).write(to: root.appending(path: "OEBPS/text/ch1.xhtml"))

        // A 2×3 PNG as the cover.
        let image = NSImage(size: NSSize(width: 20, height: 30))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 30).fill()
        image.unlockFocus()
        try fm.createDirectory(at: root.appending(path: "OEBPS/images"), withIntermediateDirectories: true)
        let png = try XCTUnwrap(ImageTools.encode(try XCTUnwrap(image.tiffRepresentation), as: .png))
        try png.write(to: root.appending(path: "OEBPS/images/cover.png"))

        let epub = work.appending(path: name)
        try Shell.run("/usr/bin/zip", ["-X0", epub.path, "mimetype"], cwd: root)
        try Shell.run("/usr/bin/zip", ["-Xr9Dq", epub.path, ".", "-x", "mimetype"], cwd: root)
        return epub
    }

    func testReadsMetadataAndCover() throws {
        let (metadata, cover) = try EPUBReader.read(try makeEPUB())
        XCTAssertEqual(metadata.title, "Original Title")
        XCTAssertEqual(metadata.authors, ["Ada Writer"])
        XCTAssertEqual(metadata.series, "The Saga")
        XCTAssertEqual(metadata.seriesIndex, 2)
        XCTAssertEqual(metadata.tags, ["Fiction"])
        XCTAssertEqual(metadata.isbn, "9780000000001")
        XCTAssertEqual(metadata.summary, "A fine book.")
        XCTAssertEqual(metadata.coverPath, "OEBPS/images/cover.png")
        XCTAssertNotNil(cover)
    }

    func testIngestCopiesBookIntoLibrary() throws {
        let library = work.appending(path: "Books")
        let book = try Ingest.ingest(file: try makeEPUB(), booksFolder: library)
        XCTAssertEqual(book.title, "Original Title")
        XCTAssertEqual(book.format, .epub)
        XCTAssertTrue(book.hasCover)
        let folder = library.appending(path: book.id.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "book.epub").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "cover.jpg").path))
    }

    func testSentenceSplittingKeepsAllText() {
        let text = "One. Two!  Three? “Four.” Five"
        let parts = KepubConverter.sentences(in: text)
        XCTAssertEqual(parts.joined(), text)
        XCTAssertEqual(parts.count, 5)
    }

    func testBuildForKoboProducesKepubWithEditedMetadata() throws {
        let source = try makeEPUB()
        var book = Book(title: "New Title", format: .epub)
        book.authors = ["Grace Author", "Second Author"]
        book.series = "Renamed Saga"
        book.seriesIndex = 3.5
        book.tags = ["Fantasy"]

        var options = FormatOptions()
        options.applyFormatting = true
        options.fontScale = 120
        options.alignment = .justified

        let output = try BookBuilder.build(book: book, source: source, customCover: nil, options: options,
                                           profile: DeviceKind.kobo.profile)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        XCTAssertEqual(output.lastPathComponent, "New Title - Grace Author.kepub.epub")

        // The archive must start with an uncompressed mimetype entry to be a valid EPUB.
        let listing = String(decoding: try Shell.run("/usr/bin/unzip", ["-Z1", output.path]), as: UTF8.self)
        XCTAssertEqual(listing.split(separator: "\n").first, "mimetype")

        let (metadata, cover) = try EPUBReader.read(output)
        XCTAssertEqual(metadata.title, "New Title")
        XCTAssertEqual(metadata.authors, ["Grace Author", "Second Author"])
        XCTAssertEqual(metadata.series, "Renamed Saga")
        XCTAssertEqual(metadata.seriesIndex, 3.5)
        XCTAssertEqual(metadata.tags, ["Fantasy"])
        XCTAssertNotNil(cover)

        let chapter = String(decoding: try EPUBReader.entry("OEBPS/text/ch1.xhtml", in: output), as: UTF8.self)
        XCTAssertTrue(chapter.contains("<div id=\"book-columns\"><div id=\"book-inner\">"))
        XCTAssertTrue(chapter.contains("<span class=\"koboSpan\" id=\"kobo.2.1\">First sentence. </span>"))
        XCTAssertTrue(chapter.contains("<em><span class=\"koboSpan\" id=\"kobo.2.3\">emphasised</span></em>"))
        XCTAssertTrue(chapter.contains("href=\"../nightstand.css\""))
        XCTAssertTrue(chapter.contains("Café &amp; bar — open."))
        // The result must still be well-formed XML.
        XCTAssertNoThrow(try XMLDocument(xmlString: chapter, options: [.nodeLoadExternalEntitiesNever]))

        let css = String(decoding: try EPUBReader.entry("OEBPS/nightstand.css", in: output), as: UTF8.self)
        XCTAssertTrue(css.contains("font-size: 120%"))
        XCTAssertTrue(css.contains("text-align: justify"))
    }

    func testBuildForGenericReaderStaysEPUB() throws {
        let book = Book(title: "Plain", format: .epub)
        let output = try BookBuilder.build(book: book, source: try makeEPUB(), customCover: nil,
                                           options: FormatOptions(), profile: DeviceKind.generic.profile)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        XCTAssertEqual(output.pathExtension, "epub")
        XCTAssertFalse(output.lastPathComponent.contains("kepub"))
        let chapter = String(decoding: try EPUBReader.entry("OEBPS/text/ch1.xhtml", in: output), as: UTF8.self)
        XCTAssertFalse(chapter.contains("koboSpan"))
    }

    func testCustomCoverReplacesImageInPlace() throws {
        let source = try makeEPUB()
        let original = try XCTUnwrap(try EPUBReader.read(source).cover)

        let image = NSImage(size: NSSize(width: 200, height: 300))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 300).fill()
        image.unlockFocus()
        let coverURL = work.appending(path: "new-cover.jpg")
        try XCTUnwrap(ImageTools.encode(try XCTUnwrap(image.tiffRepresentation), as: .jpeg)).write(to: coverURL)

        let output = try BookBuilder.build(book: Book(title: "Covered", format: .epub), source: source,
                                           customCover: coverURL, options: FormatOptions(), profile: .export)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let (metadata, cover) = try EPUBReader.read(output)
        XCTAssertEqual(metadata.coverPath, "OEBPS/images/cover.png")
        XCTAssertNotEqual(cover, original)
        // Still a PNG, because the file keeps its .png name.
        XCTAssertEqual(try XCTUnwrap(cover).prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    /// Runs the whole pipeline over real books: `NIGHTSTAND_TEST_BOOKS=/path/to/folder swift test`.
    func testRealBooks() throws {
        guard let path = ProcessInfo.processInfo.environment["NIGHTSTAND_TEST_BOOKS"] else {
            throw XCTSkip("Set NIGHTSTAND_TEST_BOOKS to a folder of EPUBs to run this test.")
        }
        let files = Ingest.expand([URL(fileURLWithPath: path)]).filter { $0.pathExtension.lowercased() == "epub" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let book = try Ingest.ingest(file: file, booksFolder: work.appending(path: "Books"))
            var options = FormatOptions()
            options.applyFormatting = true
            options.fontScale = 110
            let source = work.appending(path: "Books/\(book.id.uuidString)/\(book.fileName)")
            let output = try BookBuilder.build(book: book, source: source, customCover: nil, options: options,
                                               profile: DeviceKind.kobo.profile)
            defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }

            let rebuilt = try ExtractedEPUB(extracting: output)
            defer { rebuilt.cleanup() }
            var converted = 0
            for document in rebuilt.contentDocuments {
                let text = try String(contentsOf: document.url, encoding: .utf8)
                if text.contains("koboSpan") { converted += 1 }
                XCTAssertNoThrow(try XMLDocument(xmlString: KepubConverter.replaceNamedEntities(text),
                                                 options: [.nodeLoadExternalEntitiesNever]),
                                 "\(file.lastPathComponent): \(document.href)")
            }
            print("✓ \(book.title) — \(book.authorText) — \(converted)/\(rebuilt.contentDocuments.count) chapters converted, cover: \(book.hasCover)")
            XCTAssertGreaterThan(converted, 0, file.lastPathComponent)
            XCTAssertEqual(try EPUBReader.read(output).metadata.title, book.title)
        }
    }
}
