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

    /// Imports a folder of books into a temporary library and prints what was read and what the clean-up
    /// would change: `NIGHTSTAND_SURVEY=/path/to/folder swift test --filter FolderSurvey`
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
