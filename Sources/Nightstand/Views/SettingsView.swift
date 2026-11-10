import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            FormattingSettings()
                .tabItem { Label("Formatting", systemImage: "textformat.size") }
            DeviceSettings()
                .tabItem { Label("Devices", systemImage: "ipad.landscape") }
            LibrarySettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AssistantSettings()
                .tabItem { Label("AI Assistants", systemImage: "sparkles") }
        }
        .frame(width: 520)
    }
}

private struct FormattingSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let format = settings.format

        Form {
            Section {
                Toggle("Convert EPUB to KEPUB for Kobo", isOn: $settings.format.convertToKepub)
            } footer: {
                caption("KEPUB gives Kobo readers faster page turns, reading statistics and better typography controls. Other e-readers get standard EPUB.")
            }

            Section {
                Toggle("Restyle books when sending or exporting", isOn: $settings.format.applyFormatting)
            } footer: {
                caption("Applies to EPUB and KEPUB. Your library copy is never changed, so you can adjust these and send again.")
            }

            if format.applyFormatting {
                Section("Text") {
                    LabeledContent("Base font size") {
                        HStack {
                            Slider(value: $settings.format.fontScale, in: 70...160, step: 5)
                            Text("\(Int(format.fontScale))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    Toggle("Ignore fixed font sizes set by the publisher", isOn: $settings.format.normalizeFontSizes)
                    Toggle("Set line spacing", isOn: $settings.format.overrideLineHeight)
                    if format.overrideLineHeight {
                        LabeledContent("Line spacing") {
                            HStack {
                                Slider(value: $settings.format.lineHeight, in: 1...2, step: 0.05)
                                Text(String(format: "%.2f", format.lineHeight)).monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                }
                Section("Layout") {
                    Picker("Alignment", selection: $settings.format.alignment) {
                        ForEach(FormatOptions.Alignment.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Paragraphs", selection: $settings.format.paragraphStyle) {
                        ForEach(FormatOptions.ParagraphStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Remove page margins", isOn: $settings.format.removeMargins)
                    Toggle("Hyphenate", isOn: $settings.format.hyphenate)
                }
                Section("Preview") {
                    FormatPreview(format: format)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.snappy, value: format.applyFormatting)
        .animation(.snappy, value: format.overrideLineHeight)
    }
}

private func caption(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
}

/// An approximation of how the options change a page.
private struct FormatPreview: View {
    let format: FormatOptions

    private let paragraphs = [
        "It was a bright cold day in April, and the clocks were striking thirteen.",
        "The hallway smelt of boiled cabbage and old rag mats. At one end of it a coloured poster, too large for indoor display, had been tacked to the wall.",
    ]

    var body: some View {
        let size = 13 * format.fontScale / 100
        let spacing = format.overrideLineHeight ? (format.lineHeight - 1.2) * size : 2
        VStack(alignment: .leading, spacing: format.paragraphStyle == .indented ? 0 : size * 0.7) {
            ForEach(paragraphs, id: \.self) { paragraph in
                Text((format.paragraphStyle == .indented ? "     " : "") + paragraph)
                    .font(.system(size: size, design: .serif))
                    .lineSpacing(max(0, spacing))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(format.removeMargins ? 4 : 14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .animation(.snappy, value: format)
    }
}

private struct DeviceSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let manager = app.devices

        Form {
            Section {
                if manager.devices.isEmpty {
                    Text("No e-reader connected").foregroundStyle(.secondary)
                }
                ForEach(manager.devices) { device in
                    LabeledContent {
                        if device.kind == .generic {
                            Button("Forget") { manager.forget(device) }
                        } else {
                            Text("Detected automatically").foregroundStyle(.secondary)
                        }
                    } label: {
                        Text(device.name)
                        Text(device.kind.label)
                    }
                }
            } header: {
                Text("Connected")
            } footer: {
                caption("Kobo and Kindle readers are recognised when you plug them in. Kindles from 2024 onwards no longer appear as a drive on a Mac, so they can't be used over USB.")
            }

            Section {
                @Bindable var app = app
                Toggle("Sync reading from Kobo when connected", isOn: $app.syncKoboAutomatically)
            } footer: {
                caption("Reads how far you are through each book, how long you've spent reading, finished books and highlights from your Kobo. Nightstand only reads the Kobo's records; it never changes them.")
            }

            if !manager.candidates.isEmpty {
                Section {
                    ForEach(manager.candidates, id: \.self) { volume in
                        LabeledContent(volume.lastPathComponent) {
                            Button("Use as E-reader") { manager.adopt(volume) }
                        }
                    }
                } header: {
                    Text("Other Drives")
                } footer: {
                    caption("For PocketBook, Tolino, Nook and other readers that show up as a normal drive. Books are copied into a Books folder.")
                }
            }

            Section {
                LabeledContent("Calibre converter") {
                    Text(CalibreConverter.executable == nil ? "Not installed" : "Available")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                caption("Nightstand converts EPUB to KEPUB itself. For other conversions, such as EPUB to AZW3 for a Kindle, it uses Calibre's converter if Calibre is installed.")
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.refresh() }
    }
}

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var updater = app.updater

        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automatic)
                LabeledContent("Version \(updater.currentVersion)") {
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.isBusy)
                }
            } header: {
                Text("Updates")
            } footer: {
                caption("Nightstand looks for a new version on GitHub once a day and asks before installing it.")
            }
            Section {
                LabeledContent("Location") {
                    Text(app.store.root.path(percentEncoded: false))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                LabeledContent("Books") { Text("\(app.store.books.count)").foregroundStyle(.secondary) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.store.root]) }
            } footer: {
                caption("Each book has its own folder holding the original file and its cover. Ratings, notes and details live in library.json, so backing up this one folder backs up everything.")
            }
            Section {
                Button("Import from Calibre…") { app.importCalibre() }
            } footer: {
                caption("Copies your books, covers, series, tags and ratings. Your Calibre library is not changed.")
            }
            Section {
                Button("Import Ratings from Goodreads…") { app.importGoodreads() }
            } footer: {
                caption("Matches your Goodreads export to books already in your library and fills in ratings, read status, dates read, reviews and shelves. Nothing you have already set in Nightstand is overwritten.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AssistantSettings: View {
    @State private var copied: String?
    @State private var desktop = AssistantConnector.Status.notConnected
    @State private var code = AssistantConnector.Status.notConnected
    @State private var working: String?
    @State private var problem: String?
    @State private var showManual = false

    private var executable: String { AssistantConnector.executable }

    private var configuration: String {
        """
        {
          "mcpServers": {
            "nightstand": {
              "command": "\(executable)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    private var claudeCodeCommand: String { "claude mcp add nightstand -- \"\(executable)\" --mcp" }

    var body: some View {
        Form {
            Section {
                Text("Nightstand includes an MCP server, so an AI assistant such as Claude can look through your library to recommend what to read next, and tidy titles, authors, series and tags for you.")
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                caption("The assistant can read your books' details, ratings and notes, and edit details. It cannot delete books or open the book files. Before the first edit each day, your library index is copied to the Backups folder in your library.")
            }

            Section {
                assistant("Claude Desktop", status: desktop, connectedNote: "Quit and reopen Claude to finish.") { connect in
                    try AssistantConnector.setDesktop(connected: connect)
                }
                assistant("Claude Code", status: code, connectedNote: "Available in new sessions.") { connect in
                    try AssistantConnector.setCode(connected: connect)
                }
            } header: {
                Text("Connect")
            } footer: {
                if let problem { caption(problem) }
            }

            Section {
                DisclosureGroup("Set up another assistant by hand", isExpanded: $showManual) {
                    snippet("MCP configuration", text: configuration,
                            footer: "Add this to the assistant's MCP configuration.")
                    snippet("Claude Code command", text: claudeCodeCommand, footer: "Run this once in a terminal.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .animation(.snappy, value: desktop)
        .animation(.snappy, value: code)
    }

    private func refresh() {
        desktop = AssistantConnector.desktopStatus()
        code = AssistantConnector.codeStatus()
    }

    private func assistant(_ name: String, status: AssistantConnector.Status, connectedNote: String,
                           change: @escaping @Sendable (Bool) throws -> Void) -> some View {
        LabeledContent {
            if working == name {
                ProgressView().controlSize(.small)
            } else {
                switch status {
                case .notInstalled: EmptyView()
                case .notConnected: Button("Connect") { apply(name, true, change) }
                case .connectedElsewhere: Button("Reconnect") { apply(name, true, change) }
                case .connected: Button("Disconnect") { apply(name, false, change) }
                }
            }
        } label: {
            Text(name)
            switch status {
            case .notInstalled: Text("Not installed on this Mac")
            case .notConnected: Text("Not connected")
            case .connectedElsewhere: Text("Connected to a copy of Nightstand that has moved")
            case .connected: Label("Connected. \(connectedNote)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
        }
        .disabled(working != nil)
    }

    private func apply(_ name: String, _ connect: Bool, _ change: @escaping @Sendable (Bool) throws -> Void) {
        working = name
        problem = nil
        Task {
            do {
                try await Task.detached { try change(connect) }.value
            } catch {
                problem = "\(name): \(error.localizedDescription)"
            }
            working = nil
            refresh()
        }
    }

    private func snippet(_ title: String, text: String, footer: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(copied == title ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = title
                }
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
