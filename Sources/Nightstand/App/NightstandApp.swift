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

@main
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
            CommandGroup(replacing: .newItem) {
                Button("Add Books…") { app.addBooks() }
                    .keyboardShortcut("o")
                Button("Import from Calibre…") { app.importCalibre() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Export Selected…") { app.export(app.selection) }
                    .keyboardShortcut("e")
                    .disabled(app.selection.isEmpty)
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
