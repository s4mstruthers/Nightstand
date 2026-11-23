import AppKit
import SwiftUI

enum DeviceKind: String, Sendable {
    case kobo, kindle, generic

    var label: String {
        switch self {
        case .kobo: "Kobo"
        case .kindle: "Kindle"
        case .generic: "E-reader"
        }
    }

    /// Where books go on the device, relative to its root.
    var booksFolder: String {
        switch self {
        case .kobo: ""
        case .kindle: "documents"
        case .generic: "Books"
        }
    }

    var profile: OutputProfile {
        switch self {
        case .kobo:
            OutputProfile(supported: [.epub, .kepub, .pdf, .mobi, .cbz, .cbr, .txt], kepub: true, fallback: .epub)
        case .kindle:
            OutputProfile(supported: [.azw3, .azw, .mobi, .pdf, .txt], kepub: false, fallback: .azw3)
        case .generic:
            // PocketBook, Tolino, Nook, Boox and similar readers all read EPUB; let everything else through.
            OutputProfile(supported: Set(BookFormat.allCases).subtracting([.kepub, .azw3, .azw]),
                          kepub: false, fallback: .epub)
        }
    }
}

/// How books are filed into folders on an e-reader.
enum FolderLayout: String, CaseIterable, Identifiable, Sendable {
    case author, authorSeries, series, flat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .author: "By Author"
        case .authorSeries: "By Author, Then Series"
        case .series: "By Series, Else Author"
        case .flat: "All in One Folder"
        }
    }

    var example: String {
        switch self {
        case .author: "Tao Wong/Rebel Star - Tao Wong.kepub.epub"
        case .authorSeries: "Tao Wong/The System Apocalypse/Rebel Star - Tao Wong.kepub.epub"
        case .series: "The System Apocalypse/Rebel Star - Tao Wong.kepub.epub"
        case .flat: "Rebel Star - Tao Wong.kepub.epub"
        }
    }

    static var current: FolderLayout {
        get { FolderLayout(rawValue: UserDefaults.standard.string(forKey: "deviceFolderLayout") ?? "") ?? .author }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "deviceFolderLayout") }
    }

    /// The folder a book goes in, relative to the device's books folder.
    func folder(for book: Book) -> String {
        let author = BookBuilder.sanitize(book.authors.first ?? "Unknown Author")
        let series = book.series.flatMap { $0.isEmpty ? nil : BookBuilder.sanitize($0) }
        switch self {
        case .author: return author
        case .authorSeries: return [author, series].compactMap { $0 }.joined(separator: "/")
        case .series: return series ?? author
        case .flat: return ""
        }
    }

    /// The full path for a book file named `fileName` on a device of this kind.
    func path(for book: Book, fileName: String, on kind: DeviceKind) -> String {
        [kind.booksFolder, folder(for: book), fileName].filter { !$0.isEmpty }.joined(separator: "/")
    }
}

struct DeviceFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    /// Path relative to the device root.
    let path: String
    let size: Int64
    var name: String { (path as NSString).lastPathComponent }
}

struct ReaderDevice: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let kind: DeviceKind
    var total: Int64
    var free: Int64
    /// Library book id → path on the device, for books Nightstand put there.
    var manifest: [UUID: String]
    /// Every book file found on the device.
    var files: [DeviceFile]

    var untrackedFiles: [DeviceFile] {
        let tracked = Set(manifest.values)
        return files.filter { !tracked.contains($0.path) }
    }
}

/// Finds e-readers among mounted volumes. Runs off the main thread.
enum DeviceScanner {
    struct Result: Sendable {
        var devices: [ReaderDevice] = []
        /// Other external drives the user could choose to treat as an e-reader.
        var candidates: [URL] = []
    }

    static let manifestName = ".nightstand.json"

    static func scan(adopted: Set<String>) -> Result {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeIsReadOnlyKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        var result = Result()
        for url in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard url.path != "/", let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = values.volumeName ?? url.lastPathComponent
            func exists(_ path: String) -> Bool { fm.fileExists(atPath: url.appending(path: path).path) }

            let kind: DeviceKind
            if exists(".kobo") {
                kind = .kobo
            } else if exists("documents"), exists("system") || name.lowercased().contains("kindle") {
                kind = .kindle
            } else {
                let external = (values.volumeIsEjectable == true || values.volumeIsRemovable == true)
                    && values.volumeIsInternal != true && values.volumeIsReadOnly != true
                guard external else { continue }
                guard adopted.contains(name) else {
                    result.candidates.append(url)
                    continue
                }
                kind = .generic
            }

            let files = bookFiles(on: url)
            let present = Set(files.map(\.path))
            let manifest = readManifest(on: url).filter { present.contains($0.value) }
            result.devices.append(ReaderDevice(
                url: url, name: name, kind: kind,
                total: Int64(values.volumeTotalCapacity ?? 0),
                free: Int64(values.volumeAvailableCapacity ?? 0),
                manifest: manifest, files: files))
        }
        return result
    }

    static func bookFiles(on root: URL) -> [DeviceFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let base = root.standardizedFileURL.path
        var files: [DeviceFile] = []
        while let url = enumerator.nextObject() as? URL {
            // Kindle keeps per-book sidecar folders; they are not books.
            if url.pathExtension == "sdr" {
                enumerator.skipDescendants()
                continue
            }
            guard Ingest.isBook(url) else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            files.append(DeviceFile(path: path, size: Int64(size)))
        }
        return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func readManifest(on root: URL) -> [UUID: String] {
        guard let data = try? Data(contentsOf: root.appending(path: manifestName)),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var manifest: [UUID: String] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { manifest[id] = value }
        }
        return manifest
    }

    /// False when the manifest could not be written, as when the device is full or has been unplugged.
    @discardableResult
    static func writeManifest(_ manifest: [UUID: String], on root: URL) -> Bool {
        var raw: [String: String] = [:]
        for (key, value) in manifest { raw[key.uuidString] = value }
        guard let data = try? JSONEncoder().encode(raw) else { return false }
        return (try? data.write(to: root.appending(path: manifestName), options: .atomic)) != nil
    }

    enum PlacementError: LocalizedError {
        case noSpace(needed: Int64, free: Int64)

        var errorDescription: String? {
            switch self {
            case .noSpace(let needed, let free):
                let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                return "Not enough space on the device: the book needs \(format(needed)) and \(format(free)) is free."
            }
        }
    }

    /// Whether two paths on a device name the same file. E-readers' file systems ignore case.
    static func samePath(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive]) == .orderedSame
    }

    /// Puts a built book at `path` on the device. The copy the device already has, whether at `path` or at
    /// `previous`, is only removed once the new one has been copied over whole, so a full device or a pulled
    /// cable never leaves the reader without the book.
    static func place(_ built: URL, at path: String, replacing previous: String?, on root: URL) throws {
        let fm = FileManager.default
        let destination = root.appending(path: path)
        let folder = destination.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let size = Int64((try? built.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
            .map(Int64.init), free < size + 1_000_000 {
            throw PlacementError.noSpace(needed: size, free: free)
        }

        // Named so that neither the e-reader nor a scan of the device takes it for a book.
        let incoming = folder.appending(path: ".nightstand-incoming-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: built, to: incoming)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: incoming, to: destination)
        } catch {
            try? fm.removeItem(at: incoming)
            throw error
        }

        if let previous, !samePath(previous, path) {
            let old = root.appending(path: previous)
            try? fm.removeItem(at: old)
            // Don't leave the old folder behind empty.
            let oldFolder = old.deletingLastPathComponent()
            if oldFolder.standardizedFileURL.path != root.standardizedFileURL.path,
               ((try? fm.contentsOfDirectory(atPath: oldFolder.path)) ?? ["?"]).allSatisfy({ $0.hasPrefix(".") }) {
                try? fm.removeItem(at: oldFolder)
            }
        }
    }
}

@MainActor @Observable
final class DeviceManager {
    private(set) var devices: [ReaderDevice] = []
    private(set) var candidates: [URL] = []
    private let activity: ActivityCenter
    private var observers: [NSObjectProtocol] = []
    /// Called once for each e-reader that appears, including those already plugged in at launch.
    var onConnect: ((ReaderDevice) -> Void)?

    /// Names of generic volumes the user chose to treat as e-readers.
    private var adopted: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "adoptedVolumes") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "adoptedVolumes") }
    }

    init(activity: ActivityCenter) {
        self.activity = activity
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let adopted = adopted
        Task {
            let result = await Task.detached { DeviceScanner.scan(adopted: adopted) }.value
            let known = Set(devices.map(\.id))
            defer {
                for device in result.devices where !known.contains(device.id) { onConnect?(device) }
            }
            withAnimation(.snappy) {
                devices = result.devices
                candidates = result.candidates
            }
        }
    }

    func device(_ id: String) -> ReaderDevice? { devices.first { $0.id == id } }

    func isOnDevice(_ bookID: UUID) -> Bool { devices.contains { $0.manifest[bookID] != nil } }

    func adopt(_ volume: URL) {
        adopted.insert(volume.lastPathComponent)
        refresh()
    }

    func forget(_ device: ReaderDevice) {
        adopted.remove(device.name)
        refresh()
    }

    func eject(_ device: ReaderDevice) {
        let url = device.url
        Task {
            do {
                try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }.value
                activity.flash("\(device.name) is safe to unplug")
            } catch {
                activity.flash("Couldn't eject \(device.name)", detail: error.localizedDescription)
            }
            refresh()
        }
    }

    // MARK: Sending

    /// The last send started for each device. Sends to one device run one after another, so two of them
    /// never write its manifest at once.
    private var sendQueue: [String: Task<Void, Never>] = [:]

    func send(_ books: [Book], to deviceID: String, store: LibraryStore, options: FormatOptions) async {
        let earlier = sendQueue[deviceID]
        let task = Task {
            await earlier?.value
            await sendNow(books, to: deviceID, store: store, options: options)
        }
        sendQueue[deviceID] = task
        await task.value
    }

    private func sendNow(_ books: [Book], to deviceID: String, store: LibraryStore, options: FormatOptions) async {
        // Books you've read without a file have nothing to send.
        let books = books.filter(\.hasFile)
        guard let device = device(deviceID), !books.isEmpty else { return }
        var sent = 0
        var problems: [String] = []
        let profile = device.kind.profile
        let kind = device.kind
        let layout = FolderLayout.current
        let root = device.url

        for (index, book) in books.enumerated() {
            activity.set("Sending to \(device.name)…", detail: book.title,
                         progress: Double(index) / Double(books.count))
            let source = store.fileURL(for: book)
            // The library's cover always goes into the file: the one embedded in it can be a placeholder.
            let cover = book.hasCover ? store.coverURL(for: book) : nil
            do {
                let recorded = try await Task.detached(priority: .userInitiated) {
                    let built = try BookBuilder.build(book: book, source: source, customCover: cover,
                                                      options: options, profile: profile)
                    defer { try? FileManager.default.removeItem(at: built.deletingLastPathComponent()) }
                    let path = layout.path(for: book, fileName: built.lastPathComponent, on: kind)
                    // Read afresh for every book, and written straight after it, so the device's record is right
                    // however far a send gets and whatever else has changed it meanwhile.
                    var manifest = DeviceScanner.readManifest(on: root)
                    try DeviceScanner.place(built, at: path, replacing: manifest[book.id], on: root)
                    if kind == .kobo, let cover {
                        KoboCovers.refresh(for: path, cover: cover, on: root)
                    }
                    manifest[book.id] = path
                    return DeviceScanner.writeManifest(manifest, on: root)
                }.value
                sent += 1
                if !recorded {
                    problems.append("\(book.title) was copied, but \(device.name) couldn't be updated to show it as sent.")
                }
            } catch {
                problems.append("\(book.title): \(error.localizedDescription)")
            }
        }

        refresh()
        let summary = "Sent \(sent) of \(books.count) to \(device.name)"
        activity.flash(sent == books.count ? "Sent \(sent) book\(sent == 1 ? "" : "s") to \(device.name)" : summary,
                       detail: problems.first)
    }

    // MARK: Removing

    func remove(bookIDs: Set<UUID>, from deviceID: String) {
        guard let device = device(deviceID) else { return }
        // From the device itself: the copy in memory can be behind a send that is still going.
        var manifest = DeviceScanner.readManifest(on: device.url)
        for id in bookIDs {
            guard let path = manifest.removeValue(forKey: id) else { continue }
            try? FileManager.default.removeItem(at: device.url.appending(path: path))
        }
        DeviceScanner.writeManifest(manifest, on: device.url)
        refresh()
    }

    func remove(file: DeviceFile, from deviceID: String) {
        guard let device = device(deviceID) else { return }
        try? FileManager.default.removeItem(at: device.url.appending(path: file.path))
        refresh()
    }
}
