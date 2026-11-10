import Foundation

/// Replaces books another app (usually Calibre) put on a Kobo with Nightstand's own copies, removes that app's
/// leftover files, and afterwards puts each book's reading position back.
///
/// A Kobo keys reading positions on the file's path, so a replaced book starts out as a new, unread book. The
/// old position is saved when the book is replaced, moved onto the new copy by finding the same sentence in
/// the same chapter (span numbers differ between converters), and written into the Kobo's database once the
/// Kobo has imported the new file, which happens after it is ejected.
enum KoboTidy {
    /// A reading position to write onto a book once the Kobo has imported it.
    struct Position: Codable, Equatable, Sendable {
        var title: String
        var readStatus: Int
        var percentRead: Int
        var lastRead: String?
        var secondsReading: Int?
        var chapterProgress: Double?
        /// `ChapterIDBookmarked` for the new copy, or nil when the place could not be found in it.
        var bookmark: String?
    }

    /// What a tidy-up does. Remembered between tidy-ups, except which books were left out.
    struct Options: Codable, Equatable, Sendable {
        /// Replace copies put there by other apps.
        var replaceOthers = true
        /// Move Nightstand's own copies to match the folder layout.
        var refile = true
        /// Books to leave as they are.
        var skipped: Set<UUID> = []
        /// Put the reader back on the same sentence in replaced books.
        var keepPlace = true
        /// Add books that aren't in the library yet, so they can be replaced too.
        var addMissing = true
        var removeLeftovers = true
        var removeDamaged = true

        enum CodingKeys: String, CodingKey {
            case replaceOthers, refile, keepPlace, addMissing, removeLeftovers, removeDamaged
        }

        static var saved: Options {
            get {
                UserDefaults.standard.data(forKey: "koboTidyOptions")
                    .flatMap { try? JSONDecoder().decode(Options.self, from: $0) } ?? Options()
            }
            set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "koboTidyOptions") }
        }

        func includes(_ replacement: Replacement) -> Bool {
            guard !skipped.contains(replacement.bookID) else { return false }
            return replacement.isRefile ? refile : replaceOthers
        }
    }

    struct Replacement: Identifiable, Sendable {
        var id: UUID { bookID }
        let bookID: UUID
        let title: String
        /// True for a book Nightstand sent that is only in the wrong folder for the layout.
        var isRefile = false
        /// The other app's copy, relative to the device root.
        let oldPath: String
        /// What the Kobo recorded for the old copy, if the book was opened.
        let record: KoboReading.Record?

        var hasPosition: Bool { (record?.readStatus ?? 0) > 0 || (record?.percentRead ?? 0) > 0 }
    }

    struct Plan: Sendable {
        var replacements: [Replacement] = []
        /// Books on the device that aren't in the library yet; they are added to it, then replaced.
        var imports: [String] = []
        /// Leftover files from Calibre and macOS.
        var junk: [String] = []
        /// Book files that can't be opened (an interrupted copy, for example). They are removed.
        var damaged: [String] = []

        var isEmpty: Bool { replacements.isEmpty && imports.isEmpty && junk.isEmpty && damaged.isEmpty }
    }

    static let pendingName = ".nightstand-restore.json"

    /// Folders that belong to the Kobo or macOS and are never touched.
    private static let protectedFolders: Set<String> = [
        ".kobo", ".kobo-images", ".adobe-digital-editions", ".Trashes", ".Spotlight-V100", ".fseventsd",
        "Digital Editions", "fonts",
    ]

    // MARK: Planning

    static func plan(deviceRoot: URL, books: [Book], layout: FolderLayout = .current) -> Plan {
        let manifest = DeviceScanner.readManifest(on: deviceRoot)
        let tracked = Set(manifest.values.map { $0.lowercased() })
        let records = (try? KoboReading.read(deviceRoot: deviceRoot)) ?? []
        let byPath = Dictionary(records.compactMap { record in record.devicePath.map { ($0.lowercased(), record) } },
                                uniquingKeysWith: { a, _ in a })
        let alreadyThere = Set(manifest.keys)

        var plan = Plan()
        var claimed: Set<UUID> = []
        for file in DeviceScanner.bookFiles(on: deviceRoot) where !tracked.contains(file.path.lowercased()) {
            guard !protectedFolders.contains(String(file.path.split(separator: "/").first ?? "")) else { continue }
            let url = deviceRoot.appending(path: file.path)
            if BookFormat(url: url)?.isEPUBBased == true, (try? EPUBReader.opfPath(in: url)) == nil {
                plan.damaged.append(file.path)
                continue
            }
            let record = byPath[file.path.lowercased()]
            var title = record?.title ?? ""
            var author = record?.author ?? ""
            if title.isEmpty, let metadata = try? EPUBReader.read(deviceRoot.appending(path: file.path)).metadata {
                title = metadata.title ?? ""
                author = metadata.authors.joined(separator: ", ")
            }
            if let id = KoboReading.match(title: title, author: author, in: books),
               !claimed.contains(id), !alreadyThere.contains(id), let book = books.first(where: { $0.id == id }) {
                claimed.insert(id)
                plan.replacements.append(Replacement(bookID: id, title: book.title, oldPath: file.path, record: record))
            } else if Ingest.isBook(deviceRoot.appending(path: file.path)) {
                plan.imports.append(file.path)
            }
        }
        // Nightstand's own copies that aren't where the folder layout would put them.
        for (id, path) in manifest.sorted(by: { $0.value < $1.value }) {
            guard let book = books.first(where: { $0.id == id }) else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            guard folder.lowercased() != layout.folder(for: book).lowercased() else { continue }
            let record = byPath[path.lowercased()]
            plan.replacements.append(Replacement(bookID: id, title: book.title, isRefile: true, oldPath: path,
                                                 record: record))
        }
        plan.junk = junkFiles(on: deviceRoot)
        return plan
    }

    /// Calibre's device files and macOS "._" files outside the Kobo's own folders.
    static func junkFiles(on root: URL) -> [String] {
        let fm = FileManager.default
        var junk = ["metadata.calibre", "driveinfo.calibre"].filter { fm.fileExists(atPath: root.appending(path: $0).path) }
        func walk(_ relative: String) {
            let url = relative.isEmpty ? root : root.appending(path: relative)
            for name in rawEntries(of: url.path) {
                let path = relative.isEmpty ? name : relative + "/" + name
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: url.appending(path: name).path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    if !protectedFolders.contains(name) { walk(path) }
                } else if name.hasPrefix("._") {
                    junk.append(path)
                }
            }
        }
        walk("")
        return junk.sorted()
    }

    /// Every name in a folder. FileManager hides "._" files on FAT drives, so this reads the folder directly.
    static func rawEntries(of path: String) -> [String] {
        guard let directory = opendir(path) else { return [] }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            var name = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: name)
            let string = withUnsafePointer(to: &name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if string != ".", string != ".." { names.append(string) }
        }
        return names
    }

    // MARK: Moving the reading position

    /// The `kobo.N.N` spans in a chapter with their plain text.
    static func spans(in html: String) -> [(id: String, text: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<span[^>]*\bid="(kobo\.\d+\.\d+)"[^>]*>(.*?)</span>"#, options: [.dotMatchesLineSeparators])
        else { return [] }
        let source = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: source.length)).map { match in
            let id = source.substring(with: match.range(at: 1))
            let inner = source.substring(with: match.range(at: 2))
            return (id, normalize(OPF.plainText(inner)))
        }
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds the place `bookmark` points to in `old` within `new`: the same chapter file, and the span with
    /// the same sentence (the one nearest the same spot, if the sentence repeats). Falls back to the same
    /// proportion through the chapter, then to the chapter's start. Nil when the chapter isn't in the new copy.
    static func relocate(_ bookmark: String, from old: URL, to new: URL, chapterProgress: Double?) -> String? {
        let parts = bookmark.split(separator: "#", maxSplits: 1).map(String.init)
        let chapter = parts[0]
        func html(_ entry: String, in archive: URL) -> String? {
            guard let data = try? EPUBReader.entry(entry, in: archive), !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        }

        // The sentence the reader was on, and how far through its chapter it is.
        var sentence: (text: String, share: Double)?
        if parts.count == 2, let oldHTML = html(chapter, in: old) {
            let oldSpans = spans(in: oldHTML)
            if let marked = oldSpans.firstIndex(where: { $0.id == parts[1] }) {
                // The marked span can be empty (beside a picture, say): use the nearest sentence before it,
                // or failing that after it.
                let order = Array((0...marked).reversed()) + Array((marked + 1)..<oldSpans.count)
                if let index = order.first(where: { !oldSpans[$0].text.isEmpty && abs($0 - marked) <= 20 }) {
                    sentence = (oldSpans[index].text, Double(index) / Double(max(oldSpans.count - 1, 1)))
                }
            }
        }
        func find(in newSpans: [(id: String, text: String)]) -> String? {
            guard let sentence else { return nil }
            let hits = newSpans.indices.filter { newSpans[$0].text == sentence.text }
            let near = hits.isEmpty ? newSpans.indices.filter { newSpans[$0].text.hasPrefix(sentence.text) } : hits
            let count = Double(max(newSpans.count - 1, 1))
            return near.min { abs(Double($0) / count - sentence.share) < abs(Double($1) / count - sentence.share) }
                .map { newSpans[$0].id }
        }

        if let newHTML = html(chapter, in: new) {
            let newSpans = spans(in: newHTML)
            guard !newSpans.isEmpty else { return chapter }
            if let id = find(in: newSpans) { return chapter + "#" + id }
            if let chapterProgress, chapterProgress > 0 {
                return chapter + "#" + newSpans[min(Int(chapterProgress * Double(newSpans.count)), newSpans.count - 1)].id
            }
            return chapter
        }

        // The chapter was renamed or split differently: look for the sentence anywhere in the book.
        guard sentence != nil, let listing = try? Shell.run("/usr/bin/unzip", ["-Z1", new.path]) else { return nil }
        let documents = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { [".html", ".xhtml", ".htm"].contains(where: $0.lowercased().hasSuffix) }
        for document in documents {
            guard let newHTML = html(document, in: new), newHTML.contains("koboSpan") else { continue }
            if let id = find(in: spans(in: newHTML)) { return document + "#" + id }
        }
        return nil
    }

    // MARK: Pending restores

    static func pending(on root: URL) -> [String: Position] {
        guard let data = try? Data(contentsOf: root.appending(path: pendingName)) else { return [:] }
        return (try? JSONDecoder().decode([String: Position].self, from: data)) ?? [:]
    }

    static func savePending(_ pending: [String: Position], on root: URL) {
        let url = root.appending(path: pendingName)
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Copies the Kobo's database (and its write-ahead log) to `folder`, named with the date.
    @discardableResult
    static func backUpDatabase(on root: URL, to folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let destination = folder.appending(path: "KoboReader \(formatter.string(from: Date())).sqlite")
        let source = KoboReading.databaseURL(on: root)
        try fm.copyContents(of: source, to: destination)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        if fm.fileExists(atPath: wal.path) {
            try fm.copyContents(of: wal, to: URL(fileURLWithPath: destination.path + "-wal"))
        }
        return destination
    }

    /// Writes saved positions onto books the Kobo has imported since they were replaced. Positions for books
    /// not imported yet are kept for next time. Runs in one transaction. Returns how many were restored.
    static func restore(on root: URL, backupFolder: URL) throws -> (restored: [String], waiting: Int) {
        var pending = pending(on: root)
        guard !pending.isEmpty else { return ([], 0) }
        try backUpDatabase(on: root, to: backupFolder)
        let db = try KoboDatabase(KoboReading.databaseURL(on: root))
        let columns = try db.columns(of: "content")

        var restored: [String] = []
        try db.execute("BEGIN IMMEDIATE")
        do {
            for (path, position) in pending.sorted(by: { $0.key < $1.key }) {
                var sets: [(String, KoboDatabase.Value)] = [
                    ("ReadStatus", .int(position.readStatus)),
                    ("___PercentRead", .int(position.percentRead)),
                ]
                if let lastRead = position.lastRead { sets.append(("DateLastRead", .text(lastRead))) }
                if let seconds = position.secondsReading { sets.append(("TimeSpentReading", .int(seconds))) }
                if let bookmark = position.bookmark { sets.append(("ChapterIDBookmarked", .text(bookmark))) }
                if let progress = position.chapterProgress { sets.append(("CurrentChapterProgress", .double(progress))) }
                if position.readStatus > 0 { sets.append(("FirstTimeReading", .text("false"))) }
                sets = sets.filter { columns.contains($0.0) }
                let sql = "UPDATE content SET " + sets.map { "\($0.0) = ?" }.joined(separator: ", ")
                    + " WHERE ContentID = ? AND ContentType = 6"
                let changed = try db.execute(sql, sets.map(\.1) + [.text("file:///mnt/onboard/" + path)])
                if changed > 0 {
                    restored.append(position.title)
                    pending[path] = nil
                }
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        savePending(pending, on: root)
        return (restored, pending.count)
    }
}

/// The tidy-up sheet being shown for a device.
struct KoboTidySession: Identifiable {
    let id = UUID()
    let deviceID: String
    let deviceName: String
}
