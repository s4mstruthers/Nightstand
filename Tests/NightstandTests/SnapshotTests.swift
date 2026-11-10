import SwiftUI
import XCTest
@testable import Nightstand

/// Renders the main screens to PNG files for a visual check, without needing the app on screen:
/// `NIGHTSTAND_LIBRARY=/path/to/library NIGHTSTAND_SNAPSHOTS=/output/folder swift test --filter Snapshot`
/// Nothing is written to a connected e-reader unless NIGHTSTAND_SNAPSHOT_DEVICE names its volume.
@MainActor
final class SnapshotTests: XCTestCase {
    private func render(_ view: some View, size: NSSize, to url: URL, dark: Bool = false) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        // Far off-screen, so the window is live (and renders fully) without appearing on the display.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testUpdateSnapshot() async throws {
        guard let output = ProcessInfo.processInfo.environment["NIGHTSTAND_SNAPSHOTS"] else {
            throw XCTSkip("Set NIGHTSTAND_SNAPSHOTS to an output folder to render snapshots.")
        }
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = AppModel()
        app.updater.offer(try await UpdateFeed.fetchLatest())
        try render(UpdateSheet().environment(app), size: NSSize(width: 500, height: 420),
                   to: folder.appending(path: "update.png"))
    }

    func testSnapshots() async throws {
        guard let output = ProcessInfo.processInfo.environment["NIGHTSTAND_SNAPSHOTS"] else {
            throw XCTSkip("Set NIGHTSTAND_SNAPSHOTS to an output folder to render snapshots.")
        }
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = AppModel()
        let books = app.visibleBooks
        if let first = books.first { app.selection = [first.id] }

        let main = HStack(spacing: 0) {
            SidebarView().frame(width: 220)
            Divider()
            LibraryView()
            Divider()
            InspectorView().frame(width: 350).background(Color(nsColor: .windowBackgroundColor))
        }
        .environment(app)
        try render(main, size: NSSize(width: 1280, height: 820), to: folder.appending(path: "main-light.png"))
        try render(main, size: NSSize(width: 1280, height: 820), to: folder.appending(path: "main-dark.png"), dark: true)

        // The pages, each in the same window shell.
        func shell(_ content: some View) -> some View {
            HStack(spacing: 0) {
                SidebarView().frame(width: 220)
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView().frame(width: 350).background(Color(nsColor: .windowBackgroundColor))
            }
            .environment(app)
        }
        let pages: [(String, SidebarItem, AnyView)] = [
            ("home", .home, AnyView(HomeView())), ("discover", .discover, AnyView(DiscoverView())),
            ("journal", .journal, AnyView(JournalView())), ("organise", .organise, AnyView(OrganiseView())),
        ]
        for (name, item, view) in pages {
            app.sidebar = item
            try render(shell(view), size: NSSize(width: 1280, height: 900), to: folder.appending(path: "\(name).png"))
        }
        app.sidebar = .home
        try render(shell(HomeView()), size: NSSize(width: 1280, height: 900),
                   to: folder.appending(path: "home-dark.png"), dark: true)
        app.sidebar = .all
        app.selection = Set(books.prefix(3).map(\.id))
        try render(shell(LibraryView().overlay(alignment: .bottom) { SelectionBar().padding(.bottom, 44) }),
                   size: NSSize(width: 1280, height: 820), to: folder.appending(path: "selection.png"))
        try render(QuickFind().environment(app), size: NSSize(width: 560, height: 400),
                   to: folder.appending(path: "quickfind.png"))
        try render(FormattingSheet().environment(app), size: NSSize(width: 560, height: 680),
                   to: folder.appending(path: "formatting.png"))

        app.viewMode = .list
        app.selection = Set(books.prefix(3).map(\.id))
        try render(main, size: NSSize(width: 1280, height: 820), to: folder.appending(path: "list.png"))
        app.viewMode = .grid

        if let first = books.first {
            try render(MetadataEditor(book: first).environment(app), size: NSSize(width: 640, height: 560),
                       to: folder.appending(path: "editor.png"))
        }
        if books.count > 1 {
            let ids = Array(books.prefix(6).map(\.id))
            try render(BatchEditor(bookIDs: ids, books: Array(books.prefix(6))).environment(app),
                       size: NSSize(width: 600, height: 640), to: folder.appending(path: "batch-editor.png"))
        }
        let proposals = MetadataCleaner.proposals(for: Set(books.map(\.id)), in: app.store.books)
        if !proposals.isEmpty {
            try render(CleanUpSheet(proposals: proposals).environment(app), size: NSSize(width: 620, height: 600),
                       to: folder.appending(path: "cleanup.png"))
        }
        // Live search, so this also checks the catalogues respond.
        if let first = books.first(where: { $0.title.contains("Brave New World") }) ?? books.first {
            let found = await MetadataLookup.search(title: first.title, author: "")
            print("LOOKUP: \(found.candidates.count) results, unavailable: \(found.unavailable)")
            for candidate in found.candidates.prefix(4) {
                print("LOOKUP \(candidate.source): \(candidate.title) — \(candidate.authors.joined(separator: ", ")) — cover \(candidate.coverURL != nil)")
            }
            if let key = found.candidates.first?.workKey {
                print("LOOKUP description: \((await MetadataLookup.openLibraryDescription(workKey: key) ?? "none").prefix(80))")
            }
            try render(LookupSheet(book: first).environment(app), size: NSSize(width: 780, height: 560),
                       to: folder.appending(path: "lookup.png"))
        }
        app.settings.format.applyFormatting = true
        try render(SettingsView().environment(app), size: NSSize(width: 520, height: 760),
                   to: folder.appending(path: "settings.png"))
        app.settings.format.applyFormatting = false
        // Sends two books to the volume named in NIGHTSTAND_SNAPSHOT_DEVICE and shows the device page. It writes
        // to that device, so it only ever runs against one named on purpose: use a disk image, not a real e-reader.
        try await Task.sleep(for: .seconds(1))
        let deviceName = ProcessInfo.processInfo.environment["NIGHTSTAND_SNAPSHOT_DEVICE"]
        if let deviceName, let device = app.devices.devices.first(where: { $0.name == deviceName }) {
            await app.devices.send(Array(books.prefix(2)), to: device.id, store: app.store,
                                   options: app.settings.format)
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(app.devices.device(device.id)?.manifest.count, 2)
            try render(main, size: NSSize(width: 1280, height: 820), to: folder.appending(path: "main-device.png"))
            try render(DeviceView(deviceID: device.id).environment(app), size: NSSize(width: 760, height: 600),
                       to: folder.appending(path: "device.png"))
        }
    }
}
