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
            <meta name="calibre:rating" content="8.00"/>
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
        XCTAssertEqual(metadata.rating, 4)
        XCTAssertNotNil(cover)
    }

    func testIngestCopiesBookIntoLibrary() throws {
        let library = work.appending(path: "Books")
        let book = try Ingest.ingest(file: try makeEPUB(), booksFolder: library)
        XCTAssertEqual(book.title, "Original Title")
        XCTAssertEqual(book.format, .epub)
        XCTAssertTrue(book.hasCover)
        // The rating inside the file is whoever made it's, not the reader's.
        XCTAssertEqual(book.rating, 0)
        // A Calibre library's own record is the reader's, so its rating comes across.
        var calibre = EPUBMetadata()
        calibre.title = "From Calibre"
        calibre.rating = 3
        XCTAssertEqual(try Ingest.ingest(file: try makeEPUB(named: "c.epub"), booksFolder: library, metadata: calibre).rating, 3)

        // Ratings an earlier version copied from the file are found again, but never ones the reader gave.
        var copied = book
        copied.rating = 4
        var read = copied
        read.id = UUID(); read.status = .finished
        var different = copied
        different.id = UUID(); different.rating = 2
        let file = library.appending(path: book.id.uuidString).appending(path: book.fileName)
        XCTAssertEqual(Ingest.ratingsCopiedFromFiles([copied, read, different]) { _ in file }, [copied.id])
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

    func testGoodreadsImportMatchesAndFillsWithoutOverwriting() {
        let csv = """
        Book Id,Title,Author,Author l-f,Additional Authors,ISBN,ISBN13,My Rating,Date Read,Bookshelves,Exclusive Shelf,My Review
        1,"Atomic Habits: An Easy & Proven Way to Build Good Habits",James Clear,"Clear, James",,="0735211299",="9780735211292",5.0,2024/03/09,"self-help, favourites",read,"Loved it.<br/>Said ""wow"",
        twice."
        2,"The Final Empire (Mistborn, #1)",Brandon Sanderson,"Sanderson, Brandon",,="",="",4,,fantasy,currently-reading,
        3,Not In Library,Some Body,"Body, Some",,="",="",3,,,to-read,
        """
        let entries = Goodreads.parse(csv)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].review, "Loved it.\nSaid \"wow\",\ntwice.")
        XCTAssertEqual(entries[0].isbns, ["0735211299", "9780735211292"])
        XCTAssertEqual(entries[1].title, "The Final Empire")
        XCTAssertEqual(entries[1].series, "Mistborn")
        XCTAssertEqual(entries[1].seriesIndex, 1)

        // Matches a differently worded subtitle and "Last, First" author; keeps the user's own rating.
        var habits = Book(title: "Atomic Habits: Tiny Changes, Remarkable Results", format: .epub)
        habits.authors = ["Clear, James"]
        habits.rating = 3
        XCTAssertTrue(Goodreads.matches(entries[0], habits))
        XCTAssertTrue(Goodreads.apply(entries[0], to: &habits))
        XCTAssertEqual(habits.rating, 3)
        XCTAssertEqual(habits.status, .finished)
        XCTAssertNotNil(habits.dateFinished)
        XCTAssertEqual(habits.tags, ["self-help", "favourites"])
        XCTAssertTrue(habits.notes.hasPrefix("Loved it."))

        var mistborn = Book(title: "The Final Empire", format: .kepub)
        mistborn.authors = ["Brandon Sanderson"]
        XCTAssertTrue(Goodreads.matches(entries[1], mistborn))
        XCTAssertFalse(Goodreads.matches(entries[2], mistborn))
        XCTAssertTrue(Goodreads.apply(entries[1], to: &mistborn))
        XCTAssertEqual(mistborn.rating, 4)
        XCTAssertEqual(mistborn.status, .reading)
        XCTAssertEqual(mistborn.seriesText, "Mistborn #1")

        XCTAssertEqual(Goodreads.titleKey("How to Win Friends & Influence People"),
                       Goodreads.titleKey("How To Win Friends and Influence People"))
        XCTAssertEqual(Goodreads.titleKey("Ritual of Ruin (King's Dark Tidings Book 7)"), "ritualofruin")
        XCTAssertEqual(Goodreads.titleKey("Defiance of the Fall 3 (Defiance of the Fall, #3)"),
                       Goodreads.titleKey("Defiance of the Fall 3: A LitRPG Adventure"))

        // Same title by a different author is not a match.
        var other = Book(title: "The Final Empire", format: .epub)
        other.authors = ["Jane Doe"]
        XCTAssertFalse(Goodreads.matches(entries[1], other))
    }

    func testKoboReadingSync() throws {
        // A Kobo database in WAL mode, as on the device, with one sideloaded and one store book.
        let device = work.appending(path: "KOBOeReader")
        try FileManager.default.createDirectory(at: device.appending(path: ".kobo"), withIntermediateDirectories: true)
        let sql = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE content (ContentID TEXT, ContentType TEXT, Title TEXT, Attribution TEXT, ReadStatus INT,
                ___PercentRead INT, DateLastRead TEXT, TimeSpentReading INT);
            CREATE TABLE Bookmark (BookmarkID TEXT, VolumeID TEXT, ContentID TEXT, Text TEXT, Annotation TEXT,
                DateCreated TEXT, Type TEXT, Hidden TEXT);
            INSERT INTO content VALUES ('file:///mnt/onboard/Weir, Andy/Project Hail Mary.kepub.epub', '6',
                'Project Hail Mary: A Novel', 'Andy Weir', 1, 21, '2026-08-25T05:23:44Z', 13626);
            INSERT INTO content VALUES ('file:///mnt/onboard/Weir, Andy/Project Hail Mary.kepub.epub!ch1', '9',
                'Chapter 1', '', 0, 0, NULL, NULL);
            INSERT INTO content VALUES ('0a1b-store', '6', 'Dune', 'Frank Herbert', 2, 100,
                '2026-07-25T21:16:00.401', 20863);
            INSERT INTO content VALUES ('file:///mnt/onboard/Nobody/Unknown.epub', '6', 'Not in library', 'Nobody', 1, 5,
                NULL, NULL);
            INSERT INTO Bookmark VALUES ('b1', 'file:///mnt/onboard/Weir, Andy/Project Hail Mary.kepub.epub', 'x',
                '  Amaze, amaze, amaze! ', NULL, '2026-08-20T10:00:00.000', 'highlight', 'false');
            INSERT INTO Bookmark VALUES ('b2', '0a1b-store', 'x', NULL, NULL, '2026-07-01T10:00:00Z', 'dogear', 'false');
            INSERT INTO Bookmark VALUES ('b3', '0a1b-store', 'x', 'Fear is the mind-killer.', 'Litany', NULL,
                'highlight', 'false');
            ALTER TABLE content ADD COLUMN ChapterIDBookmarked TEXT;
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [KoboReading.databaseURL(on: device).path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let records = try KoboReading.read(deviceRoot: device)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].devicePath, "Weir, Andy/Project Hail Mary.kepub.epub")
        XCTAssertEqual(records[0].secondsReading, 13626)
        XCTAssertEqual(records[0].highlights.map(\Highlight.text), ["Amaze, amaze, amaze!" as String?])
        XCTAssertEqual(records[1].highlights.map(\Highlight.note), ["Litany" as String?])
        XCTAssertEqual(records[1].lastRead, KoboReading.parseDate("2026-07-25T21:16:00Z"))

        var hailMary = Book(title: "Project Hail Mary", format: .epub)
        hailMary.authors = ["Andy Weir"]
        var dune = Book(title: "Dune", format: .epub)
        dune.authors = ["Frank Herbert"]
        var other = Book(title: "Dune Messiah", format: .epub)
        other.authors = ["Frank Herbert"]
        let manifest = [hailMary.id: "Weir, Andy/Project Hail Mary.kepub.epub"]

        let (changed, summary) = KoboReading.merge(records, into: [hailMary, dune, other], manifest: manifest)
        XCTAssertEqual(summary, KoboReading.Summary(booksUpdated: 2, finished: 1, newHighlights: 2, unmatched: 1))
        let synced: [UUID: Book] = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0) })
        XCTAssertEqual(synced[hailMary.id]?.status, .reading)
        XCTAssertEqual(synced[hailMary.id]?.progress, 0.21)
        XCTAssertEqual(synced[hailMary.id]?.readingTimeText?.isEmpty, false)
        XCTAssertEqual(synced[dune.id]?.status, .finished)
        XCTAssertEqual(synced[dune.id]?.progress, 1)
        XCTAssertEqual(synced[dune.id]?.dateFinished, records[1].lastRead)
        XCTAssertNil(synced[other.id])

        // Moving a book's file carries its records along, so the Kobo still knows it; nothing is left to restore.
        let moved = try KoboTidy.carryOver([KoboTidy.Move(old: "Weir, Andy/Project Hail Mary.kepub.epub",
                                                          new: "Andy Weir/Project Hail Mary.kepub.epub",
                                                          bookmark: "ch6.xhtml#kobo.35.1")], on: device)
        XCTAssertEqual(moved, ["Andy Weir/Project Hail Mary.kepub.epub"])
        let after = try KoboReading.read(deviceRoot: device)
        let carried = try XCTUnwrap(after.first { $0.devicePath == "Andy Weir/Project Hail Mary.kepub.epub" })
        XCTAssertEqual(carried.percentRead, 21)
        XCTAssertEqual(carried.secondsReading, 13626)
        XCTAssertEqual(carried.bookmark, "ch6.xhtml#kobo.35.1")
        XCTAssertEqual(carried.highlights.map(\Highlight.text), ["Amaze, amaze, amaze!" as String?])
        XCTAssertNil(after.first { $0.devicePath == "Weir, Andy/Project Hail Mary.kepub.epub" })
        KoboTidy.savePending(["Andy Weir/Project Hail Mary.kepub.epub": KoboTidy.Position(
            title: "Project Hail Mary", readStatus: 1, percentRead: 21, lastRead: "2026-08-25T05:23:44Z",
            secondsReading: 13626, chapterProgress: nil, bookmark: "ch6.xhtml#kobo.35.1")], on: device)
        let check = try KoboTidy.restore(on: device, backupFolder: work.appending(path: "backups"))
        XCTAssertEqual(check.restored, [])
        XCTAssertEqual(check.waiting, 0)
        XCTAssertTrue(KoboTidy.pending(on: device).isEmpty)

        // Syncing again changes nothing; a book marked abandoned stays abandoned.
        let again = KoboReading.merge(records, into: changed + [other], manifest: manifest)
        XCTAssertTrue(again.changed.isEmpty)
        dune.status = .abandoned
        XCTAssertEqual(KoboReading.merge(records, into: [dune], manifest: [:]).changed.first?.status, .abandoned)
    }

    func testKoboPositionMovesToSameSentence() throws {
        func epub(_ name: String, _ chapters: [String: String]) throws -> URL {
            let folder = work.appending(path: name)
            for (path, body) in chapters {
                let url = folder.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "<html><body>\(body)</body></html>".write(to: url, atomically: true, encoding: .utf8)
            }
            let archive = work.appending(path: "\(name).epub")
            _ = try Shell.run("/usr/bin/zip", ["-rq", archive.path, "."], cwd: folder)
            return archive
        }
        func span(_ id: String, _ text: String) -> String { #"<span class="koboSpan" id="kobo.\#(id)">\#(text)</span>"# }

        // Calibre numbered differently, and put an empty span next to a picture.
        let old = try epub("old", ["text/ch1.html": span("1.1", "Intro.") + span("5.1", "Here we go.") + span("5.2", "")
                                   + span("6.1", "After the picture.")])
        let new = try epub("new", ["text/ch1.html": span("1.1", "Intro.") + span("3.1", "Here we go.")
                                   + span("4.1", "After the picture.")])
        XCTAssertEqual(KoboTidy.relocate("text/ch1.html#kobo.6.1", from: old, to: new, chapterProgress: 0.9),
                       "text/ch1.html#kobo.4.1")
        XCTAssertEqual(KoboTidy.relocate("text/ch1.html#kobo.5.2", from: old, to: new, chapterProgress: 0.5),
                       "text/ch1.html#kobo.3.1")
        // A chapter split differently is found by searching the whole book.
        let split = try epub("split", ["text/part2.html": span("9.1", "Intro."), "text/part3.html": span("2.2", "After the picture.")])
        XCTAssertEqual(KoboTidy.relocate("text/ch1.html#kobo.6.1", from: old, to: split, chapterProgress: nil),
                       "text/part3.html#kobo.2.2")
        // Without a matching sentence, the same share of the chapter.
        XCTAssertEqual(KoboTidy.relocate("text/ch1.html#kobo.9.9", from: old, to: new, chapterProgress: 0.5),
                       "text/ch1.html#kobo.3.1")
    }

    func testKoboCoverRefreshKeepsEachThumbnailSize() throws {
        func jpeg(_ width: Int, _ height: Int, _ color: NSColor) throws -> Data {
            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            image.unlockFocus()
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            return try XCTUnwrap(ImageTools.encode(try XCTUnwrap(rep.representation(using: .png, properties: [:])),
                                                   as: .jpeg, maxPixel: max(width, height)))
        }
        func size(_ url: URL) -> Int {
            NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()).map { max($0.pixelsWide, $0.pixelsHigh) } ?? 0
        }
        let path = "Arthur Koestler/Darkness at Noon - Arthur Koestler.kepub.epub"
        XCTAssertEqual(KoboCovers.imageID(for: path),
                       "file____mnt_onboard_Arthur_Koestler_Darkness_at_Noon_-_Arthur_Koestler_kepub_epub")
        let folder = work.appending(path: ".kobo-images/210/136")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let grid = folder.appending(path: KoboCovers.imageID(for: path) + " - N3_LIBRARY_GRID.parsed")
        let full = folder.appending(path: KoboCovers.imageID(for: path) + " - N3_FULL.parsed")
        let other = folder.appending(path: "file____mnt_onboard_Other_epub - N3_FULL.parsed")
        try jpeg(100, 150, .gray).write(to: grid)
        try jpeg(400, 600, .gray).write(to: full)
        try jpeg(400, 600, .gray).write(to: other)
        let untouched = try Data(contentsOf: other)
        let cover = work.appending(path: "cover.jpg")
        try jpeg(800, 1200, .red).write(to: cover)

        XCTAssertEqual(KoboCovers.refresh(for: path, cover: cover, on: work), 2)
        XCTAssertEqual(size(grid), 150)
        XCTAssertEqual(size(full), 600)
        XCTAssertEqual(try Data(contentsOf: other), untouched)
        XCTAssertEqual(KoboCovers.refresh(for: "Nobody/Unknown.epub", cover: cover, on: work), 0)
    }

    func testFonts() throws {
        let catalogue = try GoogleFonts.parseCatalogue(Data(#"""
            )]}'
            {"familyMetadataList": [
              {"family": "Lora", "category": "Serif", "popularity": 40, "fonts": {"400": {}, "400i": {}, "700": {}, "700i": {}}},
              {"family": "Open Sans", "category": "Sans Serif", "popularity": 1, "fonts": {"400": {}, "700": {}}},
              {"family": "Heavy Only", "category": "Display", "popularity": 5, "fonts": {"900": {}}}
            ]}
            """#.utf8))
        XCTAssertEqual(catalogue.map(\.name), ["Open Sans", "Lora"])
        XCTAssertEqual(catalogue[1].styles, FontStyle.allCases)
        XCTAssertEqual(GoogleFonts.stylesheetURL(for: catalogue[1], styles: FontStyle.allCases).absoluteString,
                       "https://fonts.googleapis.com/css2?family=Lora:ital,wght@0,400;0,700;1,400;1,700")
        XCTAssertEqual(GoogleFonts.stylesheetURL(for: catalogue[0], styles: FontStyle.allCases).absoluteString,
                       "https://fonts.googleapis.com/css2?family=Open+Sans:wght@400;700")
        XCTAssertEqual(GoogleFonts.stylesheetURL(for: catalogue[1], styles: [.regular]).absoluteString,
                       "https://fonts.googleapis.com/css2?family=Lora")

        let files = GoogleFonts.parseStylesheet("""
            @font-face { font-family: 'Lora'; font-style: italic; font-weight: 400;
              src: url(https://fonts.gstatic.com/s/lora/v37/italic.ttf) format('truetype'); }
            @font-face { font-family: 'Lora'; font-style: normal; font-weight: 700;
              src: url(https://fonts.gstatic.com/s/lora/v37/bold.ttf) format('truetype'); }
            @font-face { font-family: 'Lora'; font-style: normal; font-weight: 400;
              src: url(https://evil.example/regular.ttf) format('truetype'); }
            """)
        XCTAssertEqual(files[.italic]?.lastPathComponent, "italic.ttf")
        XCTAssertEqual(files[.bold]?.lastPathComponent, "bold.ttf")
        XCTAssertNil(files[.regular], "Only Google's own font host is trusted")

        XCTAssertEqual(FontLibrary.fileName(family: "Crimson Text", style: .boldItalic, extension: "ttf"),
                       "CrimsonText-BoldItalic.ttf")
        let folder = work.appending(path: "fonts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["CrimsonText-Regular.ttf", "CrimsonText-Bold.ttf", "RobotoSlab-Thin.ttf", "notes.txt"] {
            try Data("x".utf8).write(to: folder.appending(path: name))
        }
        let fonts = FontLibrary.fonts(in: folder)
        XCTAssertEqual(fonts.map(\.name), ["CrimsonText", "RobotoSlab"])
        XCTAssertEqual(fonts[0].displayName, "Crimson Text")
        XCTAssertEqual(fonts[0].regular?.lastPathComponent, "CrimsonText-Regular.ttf")
        XCTAssertEqual(fonts[0].styleNames, ["Bold", "Regular"])
        let device = work.appending(path: "device/fonts")
        try FontLibrary.copy(fonts[0], to: device)
        XCTAssertEqual(FontLibrary.fonts(in: device).map(\.name), ["CrimsonText"])
        FontLibrary.remove(FontLibrary.fonts(in: device)[0])
        XCTAssertTrue(FontLibrary.fonts(in: device).isEmpty)
    }

    /// Downloads a real family: `NIGHTSTAND_LIVE_FONTS=1 swift test --filter LiveFont`.
    func testLiveFontDownload() async throws {
        guard ProcessInfo.processInfo.environment["NIGHTSTAND_LIVE_FONTS"] != nil else {
            throw XCTSkip("Set NIGHTSTAND_LIVE_FONTS to download from Google Fonts.")
        }
        let catalogue = try await GoogleFonts.catalogue(cache: work.appending(path: "cache"))
        XCTAssertGreaterThan(catalogue.count, 1000)
        let lora = try XCTUnwrap(catalogue.first { $0.name == "Lora" })
        let files = try await GoogleFonts.download(lora, to: work.appending(path: "Fonts"))
        XCTAssertEqual(Set(files.map(\.lastPathComponent)),
                       ["Lora-Regular.ttf", "Lora-Italic.ttf", "Lora-Bold.ttf", "Lora-BoldItalic.ttf"])
        XCTAssertNotNil(FontLibrary.register(try XCTUnwrap(files.first { $0.lastPathComponent == "Lora-Regular.ttf" })))
        print("FONTS: \(catalogue.count) families; Lora files \(files.map { (try? Data(contentsOf: $0).count) ?? 0 })")
    }

    func testDiscoverKnowsWhatYouOwnAndWhatsMissing() async throws {
        func book(_ title: String, _ author: String, series: String? = nil, _ index: Double? = nil,
                  _ status: ReadingStatus = .finished) -> Book {
            var book = Book(title: title, format: .epub)
            book.authors = [author]
            book.series = series
            book.seriesIndex = index
            book.status = status
            return book
        }
        let books = [
            book("Defiance of the Fall", "TheFirstDefier", series: "Defiance of the Fall", 1),
            book("Defiance of the Fall 3", "TheFirstDefier", series: "Defiance of the Fall", 3),
            book("Defiance of the Fall 7", "TheFirstDefier", series: "Defiance of the Fall", 7),
            book("Cities in Chains", "Tao Wong", series: "The System Apocalypse", 4),
            book("The System Apocalypse Books 1-3", "Tao Wong"),
            book("Unread Saga 2", "Someone", series: "Unread Saga", 2, .unread),
            book("Piranesi", "Susanna Clarke"),
        ]

        // Owned, whatever the subtitle, as long as the author agrees.
        XCTAssertEqual(Insights.ownedBook(title: "Piranesi: A Novel", authors: ["Susanna Clarke"], in: books)?.title, "Piranesi")
        XCTAssertEqual(Insights.ownedBook(title: "Piranesi", authors: [], in: books)?.title, "Piranesi")
        XCTAssertNil(Insights.ownedBook(title: "Piranesi", authors: ["Someone Else"], in: books))
        XCTAssertNil(Insights.ownedBook(title: "Jonathan Strange", authors: ["Susanna Clarke"], in: books))

        // Gaps before the last book owned, plus the next one; omnibus editions count, unstarted series don't.
        let gaps = Insights.seriesGaps(books)
        XCTAssertEqual(gaps.filter { $0.series == "Defiance of the Fall" }.map(\.index), [2, 4, 5, 6, 8])
        XCTAssertEqual(gaps.filter { $0.series == "Defiance of the Fall" }.map(\.isNext), [false, false, false, false, true])
        XCTAssertEqual(gaps.filter { $0.series == "The System Apocalypse" }.map(\.index), [5])
        XCTAssertFalse(gaps.contains { $0.series == "Unread Saga" })

        // Goodreads names the book at a place in a series; numbers arrive as text; thumbnails come full size.
        let data = Data(#"""
            [{"bookId":"59763121","title":"Defiance of the Fall 4 (Defiance of the Fall, #4)","bookTitleBare":"Defiance of the Fall 4",
              "avgRating":"4.47","ratingsCount":"11766","author":{"name":"TheFirstDefier"},
              "imageUrl":"https://i.gr-assets.com/images/books/1i/59763121._SY75_.jpg","description":{"html":"Just as a threat&#39;s dealt with.<br/>More."}},
             {"bookId":"2","title":"Defiance (The Afflicted Saga, #4)","bookTitleBare":"Defiance","avgRating":"4.0",
              "ratingsCount":"5","author":{"name":"Katika Schneider"}}]
            """#.utf8)
        let matches = GoodreadsLookup.parse(data)
        XCTAssertEqual(matches.first?.ratings, 11766)
        XCTAssertEqual(matches.first?.coverURL?.absoluteString, "https://i.gr-assets.com/images/books/1i/59763121.jpg")
        XCTAssertEqual(matches.first?.summary, "Just as a threat's dealt with.\nMore.")
        let volume = GoodreadsLookup.volume(4, of: "Defiance of the Fall", authors: ["TheFirstDefier"], in: matches)
        XCTAssertEqual(volume?.id, "59763121")
        XCTAssertNil(GoodreadsLookup.volume(5, of: "Defiance of the Fall", authors: ["TheFirstDefier"], in: matches))

        // A wishlist book comes off the wishlist when its file is added.
        let store = await LibraryStore(root: work, activity: ActivityCenter())
        await MainActor.run {
            store.companion.recommendations = [
                Recommendation(title: "Original Title: A Novel", authors: ["Ada Writer"], source: "you", state: .saved),
                Recommendation(title: "Something Else", authors: ["Ada Writer"], source: "you", state: .saved),
            ]
        }
        let epub = try makeEPUB(named: "wanted.epub")
        await store.importFiles([epub])
        let left = await store.companion.recommendations.map(\.title)
        XCTAssertEqual(left, ["Something Else"])

        // A book read without a file: on the shelf, off the wishlist, and its file joins it later.
        var read = Book(title: "Original Title", format: .epub)
        read.authors = ["Ada Writer"]
        read.status = .finished
        read.rating = 5
        read.series = "Kept Series"
        read.seriesIndex = 3
        await MainActor.run {
            store.delete(Set(store.books.map(\.id)))
            store.companion.recommendations = [
                Recommendation(title: "Original Title", authors: ["Ada Writer"], source: "you", state: .saved)]
        }
        let added = await store.addWithoutFile(read, cover: nil)
        XCTAssertFalse(added.hasFile)
        let wishlistAfterRead = await store.companion.recommendations.count
        XCTAssertEqual(wishlistAfterRead, 0)
        await store.importFiles([try makeEPUB(named: "later.epub")])
        let shelf = await store.books
        XCTAssertEqual(shelf.count, 1)
        let joined = try XCTUnwrap(shelf.first)
        XCTAssertEqual(joined.id, added.id)
        XCTAssertTrue(joined.hasFile)
        XCTAssertEqual(joined.rating, 5)
        XCTAssertEqual(joined.status, .finished)
        XCTAssertEqual(joined.series, "Kept Series")
        XCTAssertEqual(joined.summary, "A fine book.")
        XCTAssertTrue(joined.hasCover)
        let file = await store.fileURL(for: joined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testShelves() throws {
        var a = Book(title: "Red Rising", format: .epub)
        a.authors = ["Pierce Brown"]; a.tags = ["Sci-Fi"]; a.rating = 5; a.status = .finished
        var b = Book(title: "Golden Son", format: .epub)
        b.authors = ["Pierce Brown"]; b.tags = ["Sci-Fi"]; b.status = .unread
        var c = Book(title: "Emma", format: .epub)
        c.authors = ["Jane Austen"]; c.status = .unread
        var shelf = Shelf(name: "Unread sci-fi")
        shelf.status = .unread
        shelf.tag = "Sci-Fi"
        XCTAssertEqual([a, b, c].filter(shelf.matches).map(\.title), ["Golden Son"])
        var loved = Shelf(name: "Loved Brown")
        loved.search = "brown"
        loved.minimumRating = 4
        XCTAssertEqual([a, b, c].filter(loved.matches).map(\.title), ["Red Rising"])

        // Saved with the companion, and older companion files without shelves still load.
        var companion = Companion()
        companion.shelves = [shelf]
        let data = try JSONEncoder().encode(companion)
        XCTAssertEqual(try JSONDecoder().decode(Companion.self, from: data).shelves, [shelf])
        XCTAssertEqual(try JSONDecoder().decode(Companion.self, from: Data("{}".utf8)).shelves, [])
    }

    @MainActor
    func testDuplicatesAreFoundAndMerged() throws {
        var all: [Book] = []
        func add(_ title: String, _ author: String, file: Bool = true, rating: Int = 0, status: ReadingStatus = .unread,
                 notes: String = "") -> Book {
            var book = Book(title: title, format: .epub)
            book.authors = [author]
            book.rating = rating
            book.status = status
            book.notes = notes
            book.noFile = file ? nil : true
            all.append(book)
            return book
        }
        let kept = add("Dune", "Frank Herbert")
        let other = add("Dune (Dune #1)", "Herbert, Frank", file: false, rating: 5, status: .finished, notes: "Loved it")
        _ = add("Dune", "Someone Else")
        _ = add("Emma", "Jane Austen")
        try LibraryIndex.save(all, to: work)
        let store = LibraryStore(root: work, activity: ActivityCenter())
        let groups = Insights.duplicates(store.books)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].map(\.id), [kept.id, other.id], "the copy with a file comes first")

        store.merge(keeping: kept.id, removing: [other.id])
        XCTAssertNil(store.book(other.id))
        let merged = try XCTUnwrap(store.book(kept.id))
        XCTAssertEqual(merged.rating, 5)
        XCTAssertEqual(merged.status, .finished)
        XCTAssertEqual(merged.notes, "Loved it")
        XCTAssertTrue(Insights.duplicates(store.books).isEmpty)
    }

    @MainActor
    func testGeneratedCover() throws {
        var book = Book(title: "The Cost of Survival", format: .epub)
        book.authors = ["Tao Wong"]
        book.series = "The System Apocalypse"
        book.seriesIndex = 3
        let data = try XCTUnwrap(GeneratedCover.render(book))
        let image = try XCTUnwrap(NSImage(data: data))
        XCTAssertEqual(image.representations.first?.pixelsHigh, 1800)
        if let folder = ProcessInfo.processInfo.environment["NIGHTSTAND_SNAPSHOTS"] {
            try data.write(to: URL(fileURLWithPath: folder).appending(path: "generated-cover.jpg"))
        }
    }

    func testPolishingBooks() throws {
        // Punctuation, carried across the edges of text runs.
        var previous: Character?
        XCTAssertEqual(TextTidy.smarten(#"He said "it's fine" -- then 'left'... "#, after: &previous),
                       "He said \u{201C}it\u{2019}s fine\u{201D} \u{2014} then \u{2018}left\u{2019}\u{2026} ")
        previous = "a"
        XCTAssertEqual(TextTidy.smarten(#"" end"#, after: &previous), "\u{201D} end")

        let chapter = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>
            <body><h1>Chapter&nbsp;One</h1><p>"Hi," she said.</p><p>&nbsp;</p><p><br/></p><p><img src="a.png"/></p>
            <pre>"code"</pre></body></html>
            """.utf8)
        let tidied = try XCTUnwrap(TextTidy.tidy(chapter, smartPunctuation: true, removeBlankParagraphs: true))
        let text = try XCTUnwrap(String(data: tidied, encoding: .utf8))
        XCTAssertTrue(text.contains("\u{201C}Hi,\u{201D} she said."))
        XCTAssertTrue(text.contains("\"code\""), "code is left alone")
        XCTAssertEqual(text.components(separatedBy: "<p>").count + text.components(separatedBy: "<p ").count - 2, 2,
                       "the two empty paragraphs go, the picture stays")
        XCTAssertNil(TextTidy.tidy(Data("<html><body><p>Plain.</p></body></html>".utf8), smartPunctuation: true,
                                   removeBlankParagraphs: true))

        // A book with no table of contents gets one from its headings when sent.
        let epub = try ExtractedEPUB(extracting: try makeEPUB(named: "toc.epub"))
        defer { epub.cleanup() }
        XCTAssertEqual(epub.contentsEntries, 0)
        XCTAssertFalse(epub.repairContents(title: "T"), "one chapter isn't enough for a contents")
        let second = epub.opfDirectory.appending(path: "text/ch2.xhtml")
        try Data(#"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>2</title></head><body><h2>The Second</h2><p>x</p></body></html>"#.utf8).write(to: second)
        let manifest = try XCTUnwrap(epub.package?.child("manifest"))
        let item = XMLElement(name: "item")
        item.setAttr("id", "ch2"); item.setAttr("href", "text/ch2.xhtml"); item.setAttr("media-type", "application/xhtml+xml")
        manifest.addChild(item)
        let ref = XMLElement(name: "itemref"); ref.setAttr("idref", "ch2")
        epub.package?.child("spine")?.addChild(ref)
        XCTAssertEqual(epub.headings().map(\.title), ["Chapter One", "The Second"])
        XCTAssertTrue(epub.repairContents(title: "T"))
        XCTAssertEqual(epub.contentsEntries, 2)
        XCTAssertEqual(epub.package?.child("spine")?.attr("toc"), "nightstand-ncx")

        // Big pictures shrink, keeping their name and type.
        let image = NSImage(size: NSSize(width: 3000, height: 4000))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 3000, height: 4000).fill(); image.unlockFocus()
        let big = try XCTUnwrap(ImageTools.encode(try XCTUnwrap(image.tiffRepresentation), as: .png, maxPixel: 4000))
        let cover = epub.opfDirectory.appending(path: "images/cover.png")
        try big.write(to: cover)
        XCTAssertGreaterThan(epub.shrinkImages(), 0)
        let shrunk = try XCTUnwrap(NSImage(contentsOf: cover))
        XCTAssertLessThanOrEqual(max(shrunk.representations[0].pixelsWide, shrunk.representations[0].pixelsHigh), 1600)

        // The new options load from settings saved before they existed, and old "no margins" carries over.
        let old = try JSONDecoder().decode(FormatOptions.self, from: Data(#"{"removeMargins":true}"#.utf8))
        XCTAssertEqual(old.margins, .none)
        XCTAssertFalse(old.smartenPunctuation)
        var custom = FormatOptions()
        custom.applyFormatting = true
        custom.margins = .custom
        custom.marginSize = 2
        XCTAssertTrue(custom.css()?.contains("margin: 0 2.0em") == true)

        // A book's own formatting is used instead of the usual settings.
        let library = work.appending(path: "Books")
        var book = try Ingest.ingest(file: try makeEPUB(named: "own.epub"), booksFolder: library)
        var own = FormatOptions()
        own.applyFormatting = true
        own.fontSizeMode = .fixed
        own.fontSizePoints = 15
        book.formatOverride = own
        let built = try BookBuilder.build(book: book, source: library.appending(path: book.id.uuidString).appending(path: book.fileName),
                                          customCover: nil, options: FormatOptions(), profile: .export)
        defer { try? FileManager.default.removeItem(at: built.deletingLastPathComponent()) }
        let css = try XCTUnwrap(String(data: try EPUBReader.entry("OEBPS/nightstand.css", in: built), encoding: .utf8))
        XCTAssertTrue(css.contains("15pt"))
    }

    func testPopularBooks() throws {
        let chart = Data(#"""
            {"feed":{"entry":[{"im:name":{"label":"Red Rising"},"im:artist":{"label":"Pierce Brown"},
              "summary":{"label":"NEW YORK TIMES BESTSELLER &#8226; A debut."},
              "im:image":[{"label":"https://is1-ssl.mzstatic.com/a/9780345539793.jpg/0x53bb.png"},
                          {"label":"https://is1-ssl.mzstatic.com/a/9780345539793.jpg/0x170bb.png"}],
              "id":{"label":"https://books.apple.com/us/book/red-rising/id578010311","attributes":{"im:id":"578010311"}},
              "link":{"attributes":{"href":"https://books.apple.com/us/book/red-rising/id578010311?uo=2"}},
              "category":{"attributes":{"label":"Adventure Sci-Fi"}},"im:releaseDate":{"label":"2014-01-28T00:00:00-07:00"}},
             {"im:name":{"label":"1984: The Graphic Novel"},"im:artist":{"label":"George Orwell & Fido Nesti"},
              "category":{"attributes":{"label":"Comics & Graphic Novels"}}}]}}
            """#.utf8)
        let books = try XCTUnwrap(PopularBooks.parseAppleChart(chart))
        XCTAssertEqual(books.map(\.title), ["Red Rising", "1984: The Graphic Novel"])
        XCTAssertEqual(books[0].coverURL?.absoluteString, "https://is1-ssl.mzstatic.com/a/9780345539793.jpg/600x900bb.jpg")
        XCTAssertEqual(books[0].summary, "NEW YORK TIMES BESTSELLER \u{2022} A debut.")
        XCTAssertEqual(books[0].published, "2014-01-28")
        XCTAssertEqual(books[0].tags, ["Adventure Sci-Fi"])
        XCTAssertEqual(books[0].link?.host(), "books.apple.com")
        XCTAssertEqual(books[1].authors, ["George Orwell", "Fido Nesti"])
        XCTAssertTrue(books[1].isComic)
        // A chart of one comes as a lone entry rather than a list.
        let single = Data(#"{"feed":{"entry":{"im:name":{"label":"Only"},"im:artist":{"label":"A. Writer"}}}}"#.utf8)
        XCTAssertEqual(PopularBooks.parseAppleChart(single)?.map(\.title), ["Only"])

        let trending = Data(#"{"works":[{"key":"/works/OL1W","title":"Atomic Habits","author_name":["James Clear"],"first_publish_year":2016,"cover_i":12539702}]}"#.utf8)
        let work = try XCTUnwrap(PopularBooks.parseOpenLibraryTrending(trending)?.first)
        XCTAssertEqual(work.coverURL?.absoluteString, "https://covers.openlibrary.org/b/id/12539702-L.jpg")
        XCTAssertEqual(work.link?.absoluteString, "https://openlibrary.org/works/OL1W")

        XCTAssertEqual(GoodreadsLookup.link(id: "123", title: "X", authors: []).absoluteString,
                       "https://www.goodreads.com/book/show/123")
        XCTAssertEqual(GoodreadsLookup.link(title: "Red Rising", authors: ["Pierce Brown"]).absoluteString,
                       "https://www.goodreads.com/search?q=Red%20Rising%20Pierce%20Brown")
    }

    func testGoodreadsLookupPicksTheRightBook() throws {
        let data = Data(#"""
            [{"bookId":"110","title":"The Road to Dune","bookTitleBare":"The Road to Dune","avgRating":"3.90",
              "ratingsCount":6235,"author":{"name":"Frank Herbert"}},
             {"bookId":"44767458","title":"Dune (Dune, #1)","bookTitleBare":"Dune","avgRating":"4.29",
              "ratingsCount":1726834,"author":{"name":"Frank Herbert"}},
             {"bookId":"7","title":"Dune","bookTitleBare":"Dune","avgRating":"4.10","ratingsCount":12,
              "author":{"name":"Frank Herbert"}},
             {"bookId":"9","title":"Dune","bookTitleBare":"Dune","avgRating":"2.00","ratingsCount":9000000,
              "author":{"name":"Someone Else"}}]
            """#.utf8)
        let matches = GoodreadsLookup.parse(data)
        XCTAssertEqual(matches.count, 4)
        let best = try XCTUnwrap(GoodreadsLookup.best(for: "Dune: Deluxe Edition", authors: ["Frank Herbert"], in: matches))
        XCTAssertEqual(best.id, "44767458")
        XCTAssertEqual(best.rating, 4.29)
        XCTAssertEqual(best.series, "Dune")
        XCTAssertEqual(best.seriesIndex, 1)
        XCTAssertNil(GoodreadsLookup.best(for: "Children of Dune", authors: ["Frank Herbert"], in: matches))
        XCTAssertEqual(GoodreadsLookup.url(title: "Dune: Deluxe Edition").absoluteString,
                       "https://www.goodreads.com/book/auto_complete?format=json&q=Dune")
        XCTAssertEqual(GoodreadsLookup.url(title: "We", author: "Zamyatin").absoluteString,
                       "https://www.goodreads.com/book/auto_complete?format=json&q=We%20Zamyatin")
        XCTAssertTrue(GoodreadsLookup.parse(Data("<html>challenge</html>".utf8)).isEmpty)

        var book = Book(title: "Dune", format: .epub)
        book.apply(best)
        XCTAssertEqual(book.goodreadsText, "4.29 · 1.7M ratings")
        XCTAssertEqual(book.seriesText, "Dune #1")
        // A series the reader already set is kept.
        var mine = Book(title: "Dune", format: .epub)
        mine.series = "My Dune Shelf"
        mine.apply(best)
        XCTAssertEqual(mine.series, "My Dune Shelf")
        // Not found still records that it was checked.
        var unknown = Book(title: "Obscure", format: .epub)
        unknown.apply(nil)
        XCTAssertNotNil(unknown.goodreadsChecked)
        XCTAssertNil(unknown.goodreadsText)
        XCTAssertEqual(BookSort.goodreads.apply([unknown, book]).map(\.title), ["Dune", "Obscure"])
    }

    /// Looks a few real books up: `NIGHTSTAND_LIVE_GOODREADS=1 swift test --filter LiveGoodreads`.
    func testLiveGoodreads() async throws {
        guard ProcessInfo.processInfo.environment["NIGHTSTAND_LIVE_GOODREADS"] != nil else {
            throw XCTSkip("Set NIGHTSTAND_LIVE_GOODREADS to look books up on Goodreads.")
        }
        let books = try LibraryIndex.load(from: LibraryStore.defaultRoot)
        for book in books.prefix(12) {
            let match = try await GoodreadsLookup.find(title: book.title, authors: book.authors)
            print("GOODREADS: \(book.title) | \(book.authorText) -> \(match.map { "\($0.rating) from \($0.ratings), series \($0.series ?? "-") #\($0.seriesIndex ?? 0), id \($0.id)" } ?? "no match")")
            try await Task.sleep(for: .seconds(GoodreadsLookup.pause))
        }
    }

    func testBatchEditChangesOnlyChosenFields() {
        func book(_ title: String, series: String? = nil, index: Double? = nil, tags: [String] = []) -> Book {
            var book = Book(title: title, format: .epub)
            book.authors = ["Someone"]
            book.series = series
            book.seriesIndex = index
            book.tags = tags
            book.publisher = "Old Press"
            return book
        }
        let books = [book("One", tags: ["fantasy", "Kindle"]), book("Two", series: "Saga", index: 7),
                     book("Three", tags: ["kindle"])]

        XCTAssertTrue(BatchEdit().isEmpty)
        XCTAssertTrue(BatchEdit().apply(to: books).isEmpty)

        var edit = BatchEdit()
        edit.series = "  The Saga "
        edit.numbering = .sequential(start: 1)
        edit.addTags = ["Fantasy", "owned"]
        edit.removeTags = ["KINDLE"]
        edit.publisher = ""
        edit.status = .finished
        let finished = Date(timeIntervalSince1970: 1_000_000)
        let changed = edit.apply(to: books, on: finished)
        XCTAssertEqual(changed.map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(changed.map(\.series), ["The Saga", "The Saga", "The Saga"])
        XCTAssertEqual(changed.map(\.seriesIndex), [1, 2, 3])
        XCTAssertEqual(changed[0].tags, ["fantasy", "owned"])
        XCTAssertEqual(changed[1].tags, ["Fantasy", "owned"])
        XCTAssertEqual(changed[2].tags, ["Fantasy", "owned"])
        XCTAssertTrue(changed.allSatisfy { $0.publisher == nil && $0.authors == ["Someone"] })
        XCTAssertTrue(changed.allSatisfy { $0.status == .finished && $0.dateFinished == finished })

        // Numbering only touches books in a series; removing the series removes numbers too.
        var number = BatchEdit()
        number.numbering = .sequential(start: 10)
        XCTAssertEqual(number.apply(to: books).map(\.title), ["Two"])
        XCTAssertEqual(number.apply(to: books).first?.seriesIndex, 11)
        var unseries = BatchEdit()
        unseries.series = ""
        let removed = unseries.apply(to: books)
        XCTAssertEqual(removed.map(\.title), ["Two"])
        XCTAssertNil(removed[0].series)
        XCTAssertNil(removed[0].seriesIndex)

        var clear = BatchEdit()
        clear.clearTags = true
        clear.rating = 4
        XCTAssertTrue(clear.apply(to: books).allSatisfy { $0.tags.isEmpty && $0.rating == 4 })
    }

    func testCleanerFixesAuthorsAndFindsSeries() {
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Wong, Tao"]), ["Tao Wong"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Voss, Chris", "Raz, Tahl"]), ["Chris Voss", "Tahl Raz"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Voss, Chris, Raz, Tahl"]), ["Chris Voss", "Tahl Raz"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Benjamin Graham; Jason Zweig"]), ["Benjamin Graham", "Jason Zweig"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Robert B. Cialdini, PhD"]), ["Robert B. Cialdini"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Evelyn Tribole, M.S., R.D."]), ["Evelyn Tribole"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Haleem, M. A. S. Abdel"]), ["M. A. S. Abdel Haleem"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Joe Navarro, Marvin Karlins"]), ["Joe Navarro", "Marvin Karlins"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Ursula K. Le Guin"]), ["Ursula K. Le Guin"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Le Guin, Ursula K."]), ["Ursula K. Le Guin"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Clear, James [Clear, James], chenjin5.com"]), ["James Clear"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Dave Barker-Plummer, Jon Barwise and John Etchemendy"]),
                       ["Dave Barker-Plummer", "Jon Barwise", "John Etchemendy"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Barringer, Bruce; Ireland, R.; "]), ["Bruce Barringer", "R. Ireland"])
        XCTAssertEqual(MetadataCleaner.cleanAuthors(["Simon and Schuster"]), ["Simon and Schuster"])

        func book(_ title: String, _ authors: [String], series: String? = nil, index: Double? = nil) -> Book {
            var book = Book(title: title, format: .epub)
            book.authors = authors
            book.series = series
            book.seriesIndex = index
            return book
        }
        let library = [
            book("Rebel Star: A LitRPG Post-Apocalyptic Space Opera (System Apocalypse Book 8)", ["Tao Wong"]),
            book("System Finale: An Apocalyptic Space Opera LitRPG (The System Apocalypse Book 12)", ["Tao Wong"]),
            book("World Unbound: An Apocalyptic LitRPG (System Apocalypse Book 6)", ["Wong, Tao"]),
            book("Stars Awoken", ["Tao Wong"], series: "The System Apocalypse", index: 7),
            book("Defiance of the Fall: A LitRPG Adventure", ["TheFirstDefier", "J. F. Brink"]),
            book("Defiance of the Fall 3: A LitRPG Adventure", ["TheFirstDefier", "JF Brink"]),
            book("Defiance of the Fall 16: A LitRPG Adventure", ["TheFirstDefier", "JF Brink"]),
            book("Fahrenheit 451", ["Ray Bradbury"]),
            book("1984", ["George Orwell"]),
            book("Project Hail Mary: A Novel", ["Andy Weir"]),
            book("Atomic Habits: An Easy and Proven Way to Build Good Habits", ["Clear, James"]),
        ]
        let proposals = MetadataCleaner.proposals(for: Set(library.map(\.id)), in: library)
        func after(_ index: Int) -> Book { proposals.first { $0.id == library[index].id }?.after ?? library[index] }

        // Series found in parentheses, spelled the way the library already spells it.
        XCTAssertEqual(after(0).title, "Rebel Star")
        XCTAssertEqual(after(0).seriesText, "The System Apocalypse #8")
        XCTAssertEqual(after(1).title, "System Finale")
        XCTAssertEqual(after(1).seriesText, "The System Apocalypse #12")
        XCTAssertEqual(after(2).authors, ["Tao Wong"])
        XCTAssertEqual(after(2).seriesText, "The System Apocalypse #6")

        // Numbered titles, the unnumbered first book, and one spelling for the co-author.
        XCTAssertEqual(after(4).title, "Defiance of the Fall")
        XCTAssertEqual(after(4).seriesText, "Defiance of the Fall #1")
        XCTAssertEqual(after(5).title, "Defiance of the Fall 3")
        XCTAssertEqual(after(5).seriesText, "Defiance of the Fall #3")
        XCTAssertEqual(after(6).seriesText, "Defiance of the Fall #16")
        XCTAssertEqual(after(4).authors, ["TheFirstDefier", "JF Brink"])

        // Titles that merely end in a number, and real subtitles, are left alone.
        XCTAssertEqual(after(7).series, nil)
        XCTAssertEqual(after(8).title, "1984")
        XCTAssertEqual(after(9).title, "Project Hail Mary")
        XCTAssertEqual(after(10).title, "Atomic Habits: An Easy and Proven Way to Build Good Habits")
        XCTAssertEqual(after(10).authors, ["James Clear"])
        XCTAssertNil(proposals.first { $0.id == library[7].id })
    }

    func testOpenLibraryAndGoogleParsing() throws {
        let openLibrary = Data(#"{"docs":[{"key":"/works/OL1W","title":"Brave New World","author_name":["Aldous Huxley"],"first_publish_year":1932,"isbn":["0060929871","9780060929879"],"publisher":["Harper"],"cover_i":42,"subject":["Fiction"]}]}"#.utf8)
        let first = try XCTUnwrap(MetadataLookup.parseOpenLibrary(openLibrary)?.first)
        XCTAssertEqual(first.title, "Brave New World")
        XCTAssertEqual(first.authors, ["Aldous Huxley"])
        XCTAssertEqual(first.isbn, "9780060929879")
        XCTAssertEqual(first.coverURL?.absoluteString, "https://covers.openlibrary.org/b/id/42-L.jpg")

        let google = Data(#"{"items":[{"id":"abc","volumeInfo":{"title":"1984","authors":["George Orwell"],"publishedDate":"1949","description":"<p>A novel.</p>","industryIdentifiers":[{"type":"ISBN_13","identifier":"9780452284234"}],"imageLinks":{"thumbnail":"http://books.google.com/x?id=abc&edge=curl"}}}]}"#.utf8)
        let second = try XCTUnwrap(MetadataLookup.parseGoogleBooks(google)?.first)
        XCTAssertEqual(second.summary, "A novel.")
        XCTAssertEqual(second.isbn, "9780452284234")
        XCTAssertEqual(second.coverURL?.absoluteString, "https://books.google.com/x?id=abc")
        XCTAssertEqual(MetadataLookup.parseGoogleBooks(Data(#"{"totalItems":0}"#.utf8))?.count, 0)
        XCTAssertNil(MetadataLookup.parseGoogleBooks(Data(#"{"error":{"code":429}}"#.utf8))?.first)

        let apple = Data(#"{"resultCount":1,"results":[{"trackId":7,"trackName":"Piranesi","artistName":"Susanna Clarke","description":"A &#34;miraculous&#34; novel&#x2019;s <b>start</b>.","releaseDate":"2020-09-15T07:00:00Z","genres":["Fantasy","Books"],"artworkUrl100":"https://is1.mzstatic.com/a/b.jpg/100x100bb.jpg"}]}"#.utf8)
        let third = try XCTUnwrap(MetadataLookup.parseAppleBooks(apple)?.first)
        XCTAssertEqual(third.summary, "A \"miraculous\" novel\u{2019}s start.")
        XCTAssertEqual(third.published, "2020-09-15")
        XCTAssertEqual(third.tags, ["Fantasy"])
        XCTAssertEqual(third.coverURL?.absoluteString, "https://is1.mzstatic.com/a/b.jpg/1200x1200bb.jpg")

        // Merging: one entry per book, gaps filled from later sources, comics after books unless asked for.
        var comic = MetadataLookup.Candidate(id: "c", source: "Apple Books", title: "The Saga Issue 1", authors: ["Ann Author"])
        comic.isComic = true
        let novel = MetadataLookup.Candidate(id: "g", source: "Goodreads", title: "Saga Begins", authors: ["Ann Author"], series: "The Saga", seriesIndex: 1)
        var sameNovel = MetadataLookup.Candidate(id: "a", source: "Apple Books", title: "Saga Begins: A Novel", authors: ["Ann Author"])
        sameNovel.summary = "It begins."
        let merged = MetadataLookup.merge([], [comic, sameNovel], [], query: "saga")
        XCTAssertEqual(MetadataLookup.merge([novel], [comic, sameNovel], query: "saga").map(\.id), ["g", "c"])
        XCTAssertEqual(MetadataLookup.merge([novel], [comic, sameNovel], query: "saga").first?.summary, "It begins.")
        XCTAssertEqual(merged.map(\.id), ["a", "c"])
        XCTAssertEqual(MetadataLookup.merge([comic, sameNovel], query: "saga comic").map(\.id), ["c", "a"])

        // Only results that are the same book are used: same title, ignoring a subtitle, and the author's surname.
        let candidates = [third, first, second,
                          MetadataLookup.Candidate(id: "x", source: "", title: "Piranesi: A Study Guide",
                                                   authors: ["Some Student"])]
        XCTAssertEqual(MetadataLookup.matches(title: "Piranesi", authors: ["Susanna Clarke"], in: candidates).map(\.id),
                       ["apple/7"])
        XCTAssertEqual(MetadataLookup.matches(title: "Brave New World: A Novel", authors: ["Aldous Huxley"],
                                              in: candidates).map(\.id), ["openlibrary/works/OL1W"])
    }

    /// Looks a few books up for real: `NIGHTSTAND_LIVE=1 swift test --filter LiveDetails`
    func testLiveDetails() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NIGHTSTAND_LIVE"] != nil)
        for (title, author) in [("Piranesi", "Susanna Clarke"), ("Project Hail Mary", "Andy Weir"),
                                ("The Way of Kings", "Brandon Sanderson")] {
            let found = await MetadataLookup.details(title: title, authors: [author])
            let details = try XCTUnwrap(found)
            print("DETAILS: \(title) | cover \(details.coverURL?.absoluteString ?? "-") | \(details.publisher ?? "-") | \(details.published ?? "-") | \(details.isbn ?? "-") | \(details.tags) | \(details.summary?.prefix(80) ?? "-")")
            XCTAssertNotNil(details.summary)
            XCTAssertNotNil(details.coverURL)
        }
        let series = await MetadataLookup.browse("System apocalypse")
        print("SERIES: " + series.candidates.prefix(8).map { "\($0.title) #\($0.seriesIndex ?? 0) [\($0.source)]\($0.isComic ? " comic" : "")" }.joined(separator: " | "))
        XCTAssertEqual(series.candidates.first?.title, "Life in the North")
        for chart in PopularBooks.charts {
            let list = await PopularBooks.load(chart, store: "gb", limit: 5)
            print("CHART \(chart.title): " + (list?.map { "\($0.title) (\($0.coverURL != nil ? "cover" : "no cover"))" }.joined(separator: " | ") ?? "FAILED"))
            XCTAssertFalse(list?.isEmpty ?? true, chart.title)
        }
        let browsed = await MetadataLookup.browse("brandon sanderson mistborn")
        print("BROWSE: " + browsed.candidates.prefix(8).map { "\($0.title) [\($0.source)]" }.joined(separator: " | "))
        XCTAssertFalse(browsed.candidates.isEmpty)
        if let books = try? LibraryIndex.load(from: LibraryStore.defaultRoot) {
            for gap in Insights.seriesGaps(books) {
                let match = try await GoodreadsLookup.volume(gap.index, of: gap.series, authors: gap.authors)
                print("GAP: \(gap.series) #\(gap.index)\(gap.isNext ? " (next)" : "") -> \(match.map { "\($0.title), cover \($0.coverURL != nil)" } ?? "not found")")
                try await Task.sleep(for: .seconds(GoodreadsLookup.pause))
            }
        }
    }

    /// Prints what the clean-up would do to a real library: `NIGHTSTAND_LIBRARY_INDEX=library.json swift test --filter RealCleanUp`
    @MainActor
    func testRealCleanUp() throws {
        guard let index = ProcessInfo.processInfo.environment["NIGHTSTAND_LIBRARY_INDEX"] else {
            throw XCTSkip("Set NIGHTSTAND_LIBRARY_INDEX to run this test.")
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: index), to: work.appending(path: "library.json"))
        let store = LibraryStore(root: work, activity: ActivityCenter())
        let proposals = MetadataCleaner.proposals(for: Set(store.books.map(\.id)), in: store.books)
        print("CLEANUP: \(proposals.count) of \(store.books.count) books")
        for proposal in proposals {
            for change in proposal.changes { print("CLEANUP \(change.label): \(change.old)  →  \(change.new)") }
        }
    }

    func testSeriesFoundInDescription() {
        let known = ["systemapocalypse": "The System Apocalypse", "cradle": "Cradle"]
        let first = MetadataCleaner.seriesInDescription(
            "Stars collide. Stars Asunder is book 9 of the System Apocalypse, the bestselling series.", known: known)
        XCTAssertEqual(first?.series, "The System Apocalypse")
        XCTAssertEqual(first?.index, 9)
        XCTAssertEqual(MetadataCleaner.seriesInDescription("Book three in the Cradle series.", known: known)?.index, 3)
        XCTAssertEqual(MetadataCleaner.seriesInDescription("System Apocalypse, Book 11.", known: known)?.index, 11)
        XCTAssertNil(MetadataCleaner.seriesInDescription("Book 2 of the Wheel of Time.", known: known))
        XCTAssertNil(MetadataCleaner.seriesInDescription("A fine standalone novel.", known: known))
    }

    func testMCPServerReadsAndUpdatesLibrary() throws {
        var dune = Book(title: "Dune", format: .epub)
        dune.authors = ["Frank Herbert"]
        dune.rating = 5
        dune.status = .finished
        dune.notes = "Loved the ecology."
        var zone = Book(title: "Forbidden Zone", format: .epub)
        zone.authors = ["Wong, Tao"]
        try LibraryIndex.save([dune, zone], to: work)

        func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
            let response = try XCTUnwrap(MCPServer.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params],
                                                          root: work))
            return try XCTUnwrap(response["result"] as? [String: Any], "\(response)")
        }
        func call(_ tool: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
            let result = try request("tools/call", ["name": tool, "arguments": arguments])
            XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
            let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }

        XCTAssertEqual(try request("initialize", ["protocolVersion": "2025-06-18"])["protocolVersion"] as? String,
                       "2025-06-18")
        XCTAssertNil(MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], root: work))
        XCTAssertEqual((try request("tools/list")["tools"] as? [[String: Any]])?.count, 11)
        XCTAssertNotNil(MCPServer.handle(["jsonrpc": "2.0", "id": 2, "method": "nope"], root: work)?["error"])

        XCTAssertEqual(try call("library_summary")["total_books"] as? Int, 2)
        let finished = try call("list_books", ["status": "finished"])
        XCTAssertEqual(finished["total"] as? Int, 1)
        XCTAssertEqual((finished["books"] as? [[String: Any]])?.first?["title"] as? String, "Dune")
        let details = try call("get_books", ["ids": [dune.id.uuidString.lowercased()]])
        XCTAssertEqual((details["books"] as? [[String: Any]])?.first?["notes"] as? String, "Loved the ecology.")

        let updated = try call("update_books", ["updates": [
            ["id": zone.id.uuidString, "authors": ["Tao Wong"], "series": "The System Apocalypse",
             "series_index": 11, "add_tags": ["LitRPG"], "status": "reading", "append_note": "Set by assistant."],
            ["id": "not-a-book", "rating": 3],
        ]])
        XCTAssertEqual(updated["books_changed"] as? Int, 1)

        let saved = try XCTUnwrap(try LibraryIndex.load(from: work).first { $0.id == zone.id })
        XCTAssertEqual(saved.authors, ["Tao Wong"])
        XCTAssertEqual(saved.seriesText, "The System Apocalypse #11")
        XCTAssertEqual(saved.tags, ["LitRPG"])
        XCTAssertEqual(saved.status, .reading)
        XCTAssertNotNil(saved.dateStarted)
        XCTAssertEqual(saved.notes, "Set by assistant.")
        let untouched = try XCTUnwrap(try LibraryIndex.load(from: work).first { $0.id == dune.id })
        XCTAssertEqual(untouched.notes, dune.notes)
        XCTAssertEqual(untouched.rating, 5)
        let backups = try FileManager.default.contentsOfDirectory(atPath: work.appending(path: "Backups").path)
        XCTAssertEqual(backups.count, 1)

        // A bad status is reported per book and changes nothing.
        let rejected = try call("update_books", ["updates": [["id": dune.id.uuidString, "status": "burned"]]])
        XCTAssertEqual(rejected["books_changed"] as? Int, 0)

        // Thoughts, taste and recommendations.
        _ = try call("update_books", ["updates": [["id": dune.id.uuidString, "liked": "The worldbuilding.",
                                                   "favourite": true]]])
        _ = try call("update_taste", ["append": "Loves big ideas."])
        _ = try call("update_taste", ["append": "Avoids love triangles."])
        let profile = try call("reading_profile")
        XCTAssertEqual(profile["taste_in_their_words"] as? String, "Loves big ideas.\nAvoids love triangles.")
        let loved = try XCTUnwrap((profile["loved"] as? [[String: Any]])?.first)
        XCTAssertEqual(loved["liked"] as? String, "The worldbuilding.")
        XCTAssertEqual(loved["favourite"] as? Bool, true)
        XCTAssertEqual((profile["authors_rated_highest"] as? [[String: Any]])?.first?["name"] as? String, "Frank Herbert")

        let suggested = try call("recommend_books", ["recommendations": [
            ["title": "Hyperion", "authors": ["Dan Simmons"], "reason": "Big ideas, like Dune."],
            ["title": "dune", "reason": "You own this."],
        ]])
        XCTAssertEqual(suggested["added"] as? [String], ["Hyperion"])
        XCTAssertEqual(suggested["skipped_already_known"] as? [String], ["dune"])
        var companion = CompanionIndex.load(from: work)
        XCTAssertEqual(companion.recommendations.map(\.title), ["Hyperion"])
        XCTAssertEqual(companion.recommendations.first?.state, .new)
        // A dismissed suggestion isn't offered again.
        companion.recommendations[0].state = .dismissed
        try CompanionIndex.save(companion, to: work)
        let again = try call("recommend_books", ["recommendations": [["title": "Hyperion", "reason": "Again."]]])
        XCTAssertEqual(again["added"] as? [String], [])
        XCTAssertEqual((try call("reading_profile")["dismissed_suggestions"] as? [String]), ["Hyperion"])

        // Straight onto the wishlist: new books go on, owned ones don't, and asking twice adds nothing.
        let wished = try call("add_to_wishlist", ["books": [
            ["title": "The Fall of Hyperion", "authors": ["Dan Simmons"], "note": "The sequel."],
            ["title": "Hyperion"], ["title": "Dune"],
        ]])
        XCTAssertEqual(wished["added"] as? [String], ["The Fall of Hyperion", "Hyperion"])
        XCTAssertEqual(wished["skipped_in_library"] as? [String], ["Dune"])
        companion = CompanionIndex.load(from: work)
        XCTAssertEqual(companion.recommendations.filter { $0.state == .saved }.map(\.title).sorted(),
                       ["Hyperion", "The Fall of Hyperion"])
        XCTAssertEqual(companion.recommendations.count, 2)
        let twice = try call("add_to_wishlist", ["books": [["title": "hyperion"]]])
        XCTAssertEqual(twice["added"] as? [String], [])
        XCTAssertEqual(twice["skipped_already_on_wishlist"] as? [String], ["hyperion"])

        // Off the wishlist again, and not offered afterwards.
        let unwished = try call("remove_from_wishlist", ["titles": ["HYPERION", "Nothing Like It"]])
        XCTAssertEqual(unwished["removed"] as? [String], ["Hyperion"])
        XCTAssertEqual(unwished["not_on_wishlist"] as? [String], ["Nothing Like It"])
        companion = CompanionIndex.load(from: work)
        XCTAssertEqual(companion.recommendations.filter { $0.state == .saved }.map(\.title), ["The Fall of Hyperion"])
        XCTAssertEqual(companion.recommendations.first { $0.title == "Hyperion" }?.state, .dismissed)

        // Shelves: made, listed with their count, changed, renamed and removed. One with no rules is refused.
        let made = try call("save_shelf", ["name": "Loved", "min_rating": 5, "favourites_only": true])
        XCTAssertEqual(made["result"] as? String, "created")
        let all = try XCTUnwrap(MCPServer.call("library_summary", [:], root: work)["shelves"] as? [[String: Any]])
        XCTAssertEqual(all.first?["name"] as? String, "Loved")
        XCTAssertEqual(all.first?["books"] as? Int, made["books"] as? Int)
        let changed = try call("save_shelf", ["name": "loved", "rename_to": "Finished", "status": "finished"])
        XCTAssertEqual(changed["result"] as? String, "updated")
        companion = CompanionIndex.load(from: work)
        XCTAssertEqual(companion.shelves.map(\.name), ["Finished"])
        XCTAssertEqual(companion.shelves.first?.status, .finished)
        XCTAssertEqual(companion.shelves.first?.minimumRating, 0)
        XCTAssertEqual(companion.shelves.first?.favouritesOnly, false)
        XCTAssertThrowsError(try MCPServer.call("save_shelf", ["name": "Everything"], root: work))
        XCTAssertThrowsError(try MCPServer.call("delete_shelf", ["name": "Nope"], root: work))
        XCTAssertEqual(try call("delete_shelf", ["name": "finished"])["deleted"] as? String, "Finished")
        XCTAssertTrue(CompanionIndex.load(from: work).shelves.isEmpty)
    }

    func testInsights() throws {
        func book(_ title: String, _ author: String, rating: Int = 0, status: ReadingStatus = .unread,
                  series: String? = nil, index: Double? = nil, tags: [String] = []) -> Book {
            var book = Book(title: title, format: .epub)
            book.authors = [author]
            book.rating = rating
            book.status = status
            book.series = series
            book.seriesIndex = index
            book.tags = tags
            if status == .finished { book.dateFinished = Date() }
            return book
        }
        var first = book("One", "A. Writer", rating: 5, status: .finished, series: "Saga", index: 1, tags: ["Sci-Fi"])
        first.readingSeconds = 7200
        let books = [first, book("Two", "A. Writer", series: "Saga", index: 2),
                     book("Three", "A. Writer", series: "Saga", index: 3),
                     book("Slog", "B. Other", status: .abandoned, tags: ["Romance"]),
                     book("Fine", "C. Third", rating: 4, status: .finished, tags: ["Sci-Fi"])]

        let stats = Insights.stats(books)
        XCTAssertEqual(stats.finishedThisYear, 2)
        XCTAssertEqual(stats.secondsRead, 7200)
        XCTAssertEqual(stats.averageRating, 4.5)
        XCTAssertEqual(Insights.nextInSeries(books).map(\.title), ["Two"])
        let taste = Insights.taste(books)
        XCTAssertEqual(taste.lovedAuthors.first?.name, "A. Writer")
        XCTAssertEqual(taste.lovedTags.map(\.name), ["Sci-Fi"])
        XCTAssertEqual(taste.coolTags.map(\.name), ["Romance"])
        XCTAssertEqual(taste.disliked.map(\.title), ["Slog"])
        XCTAssertTrue(Insights.Issue.unrated.matches(books[0]) == false)
        XCTAssertEqual(books.filter(Insights.Issue.noThoughts.matches).map(\.title), ["One", "Fine"])

        // Formatting options saved before newer keys existed still load.
        let old = Data(#"{"applyFormatting":true,"fontScale":120,"convertToKepub":true}"#.utf8)
        let options = try? JSONDecoder().decode(FormatOptions.self, from: old)
        XCTAssertEqual(options?.fontScale, 120)
        XCTAssertEqual(options?.fontSizeMode, .relative)
        XCTAssertEqual(options?.fontSizePoints, 12)

        // An exact base size replaces the percentage.
        var fixed = FormatOptions()
        fixed.applyFormatting = true
        fixed.fontScale = 130
        fixed.fontSizeMode = .fixed
        fixed.fontSizePoints = 11.5
        let css = try XCTUnwrap(fixed.css())
        XCTAssertTrue(css.contains("html, body { font-size: 11.5pt !important; }"))
        XCTAssertFalse(css.contains("130%"))
        fixed.fontSizePoints = 14
        XCTAssertTrue(try XCTUnwrap(fixed.css()).contains("font-size: 14pt"))
        XCTAssertEqual(options?.useReaderFont, false)
        var styled = FormatOptions()
        styled.applyFormatting = true
        styled.useReaderFont = true
        styled.extraCSS = "h2 { text-align: center; }"
        XCTAssertTrue(styled.css()?.contains("font-family: inherit") == true)
        XCTAssertTrue(styled.css()?.hasSuffix("h2 { text-align: center; }\n") == true)
    }

    @MainActor
    func testAppPicksUpEditsMadeByAnotherProcess() throws {
        let book = Book(title: "Before", format: .epub)
        try LibraryIndex.save([book], to: work)
        let store = LibraryStore(root: work, activity: ActivityCenter())
        XCTAssertEqual(store.books.first?.title, "Before")

        // The MCP server rewrites the index while the app is open.
        var edited = book
        edited.title = "After"
        edited.rating = 4
        Thread.sleep(forTimeInterval: 0.05)
        try LibraryIndex.save([edited], to: work)
        store.reloadIfChanged()
        XCTAssertEqual(store.books.first?.title, "After")

        // A local edit made straight afterwards builds on the outside change instead of undoing it.
        store.modify([book.id]) { $0.notes = "Mine" }
        store.saveNow()
        let saved = try XCTUnwrap(try LibraryIndex.load(from: work).first)
        XCTAssertEqual(saved.title, "After")
        XCTAssertEqual(saved.rating, 4)
        XCTAssertEqual(saved.notes, "Mine")
    }

    /// Imports a folder of books into a temporary library and prints what was read and what the clean-up
    /// would change: `NIGHTSTAND_SURVEY=/path/to/folder swift test --filter FolderSurvey`
    // MARK: Updates

    func testUpdateFeed() throws {
        let json = """
        {"tag_name": "v0.10.0", "html_url": "https://github.com/s4mstruthers/Nightstand/releases/tag/v0.10.0",
         "body": "## New\\n- **Bold** thing\\n\\n**Full Changelog**: https://example.com",
         "assets": [
           {"browser_download_url": "https://evil.example.com/Nightstand-0.10.0.dmg"},
           {"browser_download_url": "https://github.com/s4mstruthers/Nightstand/releases/download/v0.10.0/notes.txt"},
           {"browser_download_url": "https://github.com/s4mstruthers/Nightstand/releases/download/v0.10.0/Nightstand-0.10.0.dmg"}]}
        """
        let release = try UpdateFeed.parse(Data(json.utf8))
        XCTAssertEqual(release.version, "0.10.0")
        XCTAssertEqual(release.download?.host, "github.com")
        XCTAssertEqual(release.download?.lastPathComponent, "Nightstand-0.10.0.dmg")
        XCTAssertEqual(String(UpdateFeed.formatted(release.notes).characters), "New\n•  Bold thing")

        XCTAssertTrue(UpdateFeed.isNewer("0.10.0", than: "0.9.2"))
        XCTAssertTrue(UpdateFeed.isNewer("v1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateFeed.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateFeed.isNewer("0.1.1", than: "0.2.0"))
        XCTAssertThrowsError(try UpdateFeed.parse(Data("{}".utf8)))
    }

    /// A signed stand-in for the app, so the installer can be tested without the real one.
    private func makeApp(version: String, bundleID: String = "test.nightstand", in folder: URL) throws -> URL {
        let app = folder.appending(path: "Nightstand.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: app.appending(path: "Contents/MacOS/Nightstand"))
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Nightstand",
                                  "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try info.write(to: app.appending(path: "Contents/Info.plist"))
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    private func makeImage(of folder: URL, named name: String) throws -> URL {
        let image = work.appending(path: name)
        try Shell.run("/usr/bin/hdiutil", ["create", "-volname", "Nightstand", "-srcfolder", folder.path,
                                           "-format", "UDZO", "-quiet", image.path])
        return image
    }

    private func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    func testUpdateReplacesInstalledApp() throws {
        let fm = FileManager.default
        let installedFolder = work.appending(path: "Applications"), newFolder = work.appending(path: "new")
        let installed = try makeApp(version: "1.0.0", in: installedFolder)
        let image = try makeImage(of: try makeApp(version: "1.1.0", in: newFolder).deletingLastPathComponent(),
                                  named: "update.dmg")
        XCTAssertTrue(UpdateInstaller.canReplace(installed))
        XCTAssertFalse(UpdateInstaller.canReplace(URL(fileURLWithPath: "/Volumes/Nightstand/Nightstand.app")))

        // The wrong version, a different app and a tampered app all leave the installed copy alone.
        XCTAssertThrowsError(try UpdateInstaller.install(image: image, version: "1.2.0", bundleID: "test.nightstand",
                                                         over: installed))
        XCTAssertThrowsError(try UpdateInstaller.install(image: image, version: "1.1.0", bundleID: "other.app",
                                                         over: installed))
        let tamperedFolder = work.appending(path: "tampered")
        let tampered = try makeApp(version: "1.1.0", in: tamperedFolder)
        try Data("changed after signing".utf8).write(to: tampered.appending(path: "Contents/MacOS/Nightstand"))
        let tamperedImage = try makeImage(of: tamperedFolder, named: "tampered.dmg")
        XCTAssertThrowsError(try UpdateInstaller.install(image: tamperedImage, version: "1.1.0",
                                                         bundleID: "test.nightstand", over: installed))
        XCTAssertEqual(version(of: installed), "1.0.0")

        try UpdateInstaller.install(image: image, version: "1.1.0", bundleID: "test.nightstand", over: installed)
        XCTAssertEqual(version(of: installed), "1.1.0")
        XCTAssertNoThrow(try Shell.run("/usr/bin/codesign", ["--verify", "--strict", installed.path]))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: installedFolder.path), ["Nightstand.app"])
    }

    /// Downloads the real latest release and installs it over a stand-in for an older copy.
    func testLiveUpdate() async throws {
        guard ProcessInfo.processInfo.environment["NIGHTSTAND_LIVE_UPDATE"] != nil else {
            throw XCTSkip("Set NIGHTSTAND_LIVE_UPDATE to download the latest release")
        }
        let release = try await UpdateFeed.fetchLatest()
        let url = try XCTUnwrap(release.download)
        let bundleID = "io.github.s4mstruthers.Nightstand"
        let installed = try makeApp(version: "0.0.1", bundleID: bundleID, in: work.appending(path: "Applications"))
        let (file, _) = try await URLSession.shared.download(from: url)
        let image = work.appending(path: "live.dmg")
        try FileManager.default.moveItem(at: file, to: image)
        try UpdateInstaller.install(image: image, version: release.version, bundleID: bundleID, over: installed)
        XCTAssertEqual(version(of: installed), release.version)
        print("Installed \(release.version) from \(url.absoluteString)")
    }

    // MARK: Connecting assistants

    func testConnectingClaudeDesktopKeepsOtherSettings() throws {
        let config = work.appending(path: "Claude/claude_desktop_config.json")
        let exe = "/Applications/Nightstand.app/Contents/MacOS/Nightstand"
        func root() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        }

        // No file yet: one is created.
        XCTAssertEqual(AssistantConnector.status(in: config, executable: exe), .notConnected)
        try AssistantConnector.setDesktop(connected: true, config: config, executable: exe)
        XCTAssertEqual(AssistantConnector.status(in: config, executable: exe), .connected)

        // An existing file keeps its other servers and settings.
        try Data(#"{"theme": "dark", "mcpServers": {"other": {"command": "/bin/other"}}}"#.utf8).write(to: config)
        try AssistantConnector.setDesktop(connected: true, config: config, executable: "/old/Nightstand")
        XCTAssertEqual(AssistantConnector.status(in: config, executable: exe), .connectedElsewhere)
        try AssistantConnector.setDesktop(connected: true, config: config, executable: exe)
        XCTAssertEqual(AssistantConnector.status(in: config, executable: exe), .connected)
        XCTAssertEqual(try root()["theme"] as? String, "dark")
        var servers = try XCTUnwrap(try root()["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["other"] as? [String: Any])?["command"] as? String, "/bin/other")
        XCTAssertEqual((servers["nightstand"] as? [String: Any])?["args"] as? [String], ["--mcp"])

        try AssistantConnector.setDesktop(connected: false, config: config, executable: exe)
        servers = try XCTUnwrap(try root()["mcpServers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["other"])

        // A file that can't be understood is never overwritten.
        try Data("{ not json".utf8).write(to: config)
        XCTAssertThrowsError(try AssistantConnector.setDesktop(connected: true, config: config, executable: exe))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{ not json")
    }

    /// Runs the real Claude Code command against a throwaway settings folder.
    func testConnectingClaudeCode() throws {
        guard ProcessInfo.processInfo.environment["NIGHTSTAND_CLAUDE_CODE"] != nil,
              let cli = AssistantConnector.codeCLI else {
            throw XCTSkip("Set NIGHTSTAND_CLAUDE_CODE to run the installed claude command")
        }
        let exe = "/Applications/Nightstand.app/Contents/MacOS/Nightstand"
        let environment = ["CLAUDE_CONFIG_DIR": work.path]
        let config = work.appending(path: ".claude.json")
        try AssistantConnector.setCode(connected: true, cli: cli, executable: "/old/Nightstand", environment: environment)
        XCTAssertEqual(AssistantConnector.status(in: config, executable: exe), .connectedElsewhere)
        try AssistantConnector.setCode(connected: true, cli: cli, executable: exe, environment: environment)
        XCTAssertEqual(AssistantConnector.status(in: config, executable: exe), .connected)
        try AssistantConnector.setCode(connected: false, cli: cli, executable: exe, environment: environment)
        XCTAssertEqual(AssistantConnector.status(in: config, executable: exe), .notConnected)
    }

    func testFolderSurvey() throws {
        guard let path = ProcessInfo.processInfo.environment["NIGHTSTAND_SURVEY"] else {
            throw XCTSkip("Set NIGHTSTAND_SURVEY to a folder of books to run this test.")
        }
        var books: [(file: String, book: Book)] = []
        for file in Ingest.expand([URL(fileURLWithPath: path)]).sorted(by: { $0.path < $1.path }) {
            do {
                books.append((file.lastPathComponent, try Ingest.ingest(file: file, booksFolder: work.appending(path: "Books"))))
            } catch {
                print("SURVEY FAILED: \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for (file, book) in books {
            print("SURVEY \(book.format.label) | \(file) | \(book.title) | \(book.authorText) | \(book.seriesText) | cover \(book.hasCover)")
        }
        let library = books.map(\.book)
        for proposal in MetadataCleaner.proposals(for: Set(library.map(\.id)), in: library) {
            for change in proposal.changes { print("SURVEY-CLEAN \(change.label): \(change.old)  →  \(change.new)") }
        }
    }

    /// Dry run against a real export and a copy of a library index:
    /// `NIGHTSTAND_GOODREADS=export.csv NIGHTSTAND_LIBRARY_INDEX=library.json swift test --filter RealGoodreads`
    @MainActor
    func testRealGoodreadsExport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let export = environment["NIGHTSTAND_GOODREADS"], let index = environment["NIGHTSTAND_LIBRARY_INDEX"] else {
            throw XCTSkip("Set NIGHTSTAND_GOODREADS and NIGHTSTAND_LIBRARY_INDEX to run this test.")
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: index), to: work.appending(path: "library.json"))
        let store = LibraryStore(root: work, activity: ActivityCenter())
        let before = store.books
        await store.importGoodreads(from: URL(fileURLWithPath: export))
        print("SUMMARY: \(store.activity.current?.title ?? "") — \(store.activity.current?.detail ?? "")")
        for (old, new) in zip(before, store.books) where old != new {
            print("UPDATED: \(new.title) | \(new.rating)★ | \(new.status.label) | \(new.seriesText)")
        }
        for book in store.books where !zip(before, store.books).contains(where: { $0.1.id == book.id && $0.0 != $0.1 }) {
            print("UNTOUCHED: \(book.title) — \(book.authorText)")
        }
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

/// Dry run against a real Kobo: `NIGHTSTAND_KOBO=/Volumes/KOBOeReader swift test --filter KoboDryRun`.
/// Reads a copy of the device's database and the library, prints what would change, saves nothing.
final class KoboDryRunTests: XCTestCase {
    func testKoboDryRun() throws {
        guard let path = ProcessInfo.processInfo.environment["NIGHTSTAND_KOBO"] else {
            throw XCTSkip("Set NIGHTSTAND_KOBO to a mounted Kobo.")
        }
        let root = URL(fileURLWithPath: path)
        let records = try KoboReading.read(deviceRoot: root)
        let books = try LibraryIndex.load(from: LibraryStore.defaultRoot)
        let (changed, summary) = KoboReading.merge(records, into: books, manifest: DeviceScanner.readManifest(on: root))
        print("KOBO: \(records.count) books on device, \(summary)")
        for book in changed {
            print("KOBO CHANGE: \(book.title) — \(book.status.rawValue) \(Int((book.progress ?? 0) * 100))% \(book.readingTimeText ?? "-") highlights \(book.highlights?.count ?? 0)")
        }
        let matched = Set(changed.map(\.title))
        for record in records where record.readStatus > 0 || record.percentRead > 0 {
            print("KOBO RECORD: \(record.title) | \(record.author) | \(record.readStatus) \(record.percentRead)%")
        }
        XCTAssertFalse(records.isEmpty)
        _ = matched
    }
}
