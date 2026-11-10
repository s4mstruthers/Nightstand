import SwiftUI
import XCTest
@testable import Nightstand

/// Renders the main screens to PNG files for a visual check, without needing the app on screen:
/// `NIGHTSTAND_LIBRARY=/path/to/library NIGHTSTAND_SNAPSHOTS=/output/folder swift test --filter Snapshot`
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

        app.viewMode = .list
        app.selection = Set(books.prefix(3).map(\.id))
        try render(main, size: NSSize(width: 1280, height: 820), to: folder.appending(path: "list.png"))
        app.viewMode = .grid

        if let first = books.first {
            try render(MetadataEditor(book: first).environment(app), size: NSSize(width: 640, height: 560),
                       to: folder.appending(path: "editor.png"))
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
        // With an e-reader (or a disk image posing as one) connected, send two books and show the device page.
        try await Task.sleep(for: .seconds(1))
        if let device = app.devices.devices.first {
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
