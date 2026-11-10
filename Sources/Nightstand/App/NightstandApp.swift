import SwiftUI

/// Receives books opened with Nightstand from Finder or dropped on its Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in await AppDelegate.model?.store.importFiles(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.model?.store.saveNow() }
    }
}

/// `Nightstand --mcp` runs the MCP server for AI assistants instead of opening the app.
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        } else {
            NightstandApp.main()
        }
    }
}

struct NightstandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app: AppModel

    init() {
        let model = AppModel()
        AppDelegate.model = model
        _app = State(initialValue: model)
    }

    var body: some Scene {
        Window("Nightstand", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await app.updater.check(userInitiated: true) } }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Books…") { app.addBooks() }
                    .keyboardShortcut("o")
                Button("Import from Calibre…") { app.importCalibre() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Import Ratings from Goodreads…") { app.importGoodreads() }
                Divider()
                Button("Export Selected…") { app.export(app.selection) }
                    .keyboardShortcut("e")
                    .disabled(app.selection.isEmpty)
            }
            CommandMenu("Library") {
                Button(app.selection.count > 1 ? "Edit Details of \(app.selection.count) Books…" : "Edit Details…") {
                    app.edit(app.selection)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(app.selection.isEmpty)
                Button(app.selection.count > 1 ? "Clean Up Selected Books…" : "Clean Up Details…") {
                    app.startCleanUp()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(app.store.books.isEmpty)
                Button("Look Up Details Online…") {
                    if let id = app.selection.first { app.lookingUp = app.store.book(id) }
                }
                .keyboardShortcut("l")
                .disabled(app.selection.count != 1)
            }
            CommandGroup(after: .sidebar) {
                Button(app.showInspector ? "Hide Details" : "Show Details") {
                    withAnimation(.snappy) { app.showInspector.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
