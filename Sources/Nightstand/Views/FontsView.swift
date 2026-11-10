import SwiftUI

/// Browse free fonts, see them on an e-reader page, keep the ones you like and put them on your Kobo.
struct FontsView: View {
    @Environment(AppModel.self) private var app

    enum Source: String, CaseIterable, Identifiable {
        case mine = "My Fonts", device = "On Kobo", browse = "Browse"
        var id: String { rawValue }
    }

    /// The font being looked at, wherever it comes from.
    enum Choice: Hashable {
        case google(GoogleFont)
        case local(LocalFont)

        var title: String {
            switch self {
            case .google(let font): font.name
            case .local(let font): font.displayName
            }
        }
    }

    @State private var source = Source.browse
    @State private var catalogue: [GoogleFont] = []
    @State private var catalogueError: String?
    @State private var category = "Serif"
    @State private var query = ""
    @State private var mine: [LocalFont] = []
    @State private var onDevice: [LocalFont] = []
    @State private var choice: Choice?
    @State private var previewFont: String?
    @State private var loadingPreview = false
    @State private var busy = false
    @State private var fontSize = 17.0
    @State private var lineSpacing = 1.35
    @State private var justified = true

    private var libraryFolder: URL { FontLibrary.folder(in: app.store.root) }
    private var kobo: ReaderDevice? { app.devices.devices.first { $0.kind == .kobo } }
    private var previewCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Nightstand/FontPreviews")
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 300)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .task { await load() }
        .onChange(of: app.devices.devices.map(\.id)) { reloadLocal() }
        .onChange(of: app.store.fontsVersion) {
            reloadLocal()
            source = .mine
        }
        .task(id: choice) { await loadPreview() }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Picker("Show", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if source == .browse {
                    TextField("Search 1,900 free fonts", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Picker("Kind", selection: $category) {
                        Text("All Kinds").tag("")
                        ForEach(["Serif", "Sans Serif", "Display", "Handwriting", "Monospace"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            .padding(12)
            Divider()

            List(selection: $choice) {
                switch source {
                case .browse:
                    if let catalogueError {
                        Text(catalogueError).foregroundStyle(.secondary)
                    } else if catalogue.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(filtered) { font in
                        row(font.name, detail: font.category, sample: .google(font), saved: isMine(font.name),
                            installed: isOnDevice(font.name))
                            .tag(Choice.google(font))
                    }
                case .mine:
                    if mine.isEmpty {
                        Text("Fonts you add are kept here, ready to put on your e-reader. Browse to find some, or add font files you already have.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(mine) { font in
                        row(font.displayName, detail: font.styleNames.joined(separator: ", "), sample: .local(font),
                            saved: false, installed: isOnDevice(font.name))
                            .tag(Choice.local(font))
                    }
                case .device:
                    if kobo == nil {
                        Text("Plug in your Kobo to see and manage the fonts on it.").foregroundStyle(.secondary)
                    } else if onDevice.isEmpty {
                        Text("No extra fonts are on your Kobo yet.").foregroundStyle(.secondary)
                    }
                    ForEach(onDevice) { font in
                        row(font.displayName, detail: font.styleNames.joined(separator: ", "), sample: .local(font),
                            saved: false, installed: false)
                            .tag(Choice.local(font))
                    }
                }
            }
            .listStyle(.inset)

            if source == .mine {
                Divider()
                Button("Add Fonts…", systemImage: "plus") { addFiles() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background)
    }

    private func row(_ name: String, detail: String, sample: Choice, saved: Bool, installed: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                FontNameLabel(name: name, sample: sample, cache: previewCache.appending(path: "Names"))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("In My Fonts") }
            if installed { Image(systemName: "ipad.landscape").foregroundStyle(.tint).help("On your Kobo") }
        }
        .padding(.vertical, 2)
    }

    private var filtered: [GoogleFont] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return Array(catalogue.lazy.filter { font in
            (needle.isEmpty ? (category.isEmpty || font.category == category) : font.name.lowercased().contains(needle))
        }.prefix(250))
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let choice {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 4) {
                        Text(choice.title)
                            .font(previewFont.map { .custom($0, size: 34) } ?? .system(size: 34, weight: .bold, design: .serif))
                            .contentTransition(.opacity)
                        Text(subtitle(choice)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 26)

                    EReaderPreview(fontName: previewFont, fontSize: fontSize, lineSpacing: lineSpacing,
                                   justified: justified, loading: loadingPreview)

                    VStack(spacing: 8) {
                        slider("Size", value: $fontSize, range: 12...26, step: 1, shown: "\(Int(fontSize))")
                        slider("Line spacing", value: $lineSpacing, range: 1...1.8, step: 0.05,
                               shown: String(format: "%.2f", lineSpacing))
                        Toggle("Justified", isOn: $justified).frame(maxWidth: 380, alignment: .leading)
                    }
                    .controlSize(.small)

                    actions(choice)

                    Text("To use a font on a Kobo: open a book, tap the middle of the page, then Aa and choose it under Font Face. The size and spacing here are only for previewing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .animation(.snappy, value: previewFont)
        } else {
            ContentUnavailableView("Choose a Font", systemImage: "textformat",
                                   description: Text("Pick a font to see how a page looks in it on an e-reader."))
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        shown: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(shown).monospacedDigit().frame(width: 36, alignment: .trailing)
        }
        .frame(maxWidth: 380)
    }

    @ViewBuilder
    private func actions(_ choice: Choice) -> some View {
        let name = familyName(choice)
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            switch (choice, source) {
            case (.google(let font), _):
                if isMine(font.name) {
                    Label("In My Fonts", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Add to My Fonts", systemImage: "plus") { run { try await save(font) } }
                }
                if let kobo {
                    if isOnDevice(font.name) {
                        removeFromKoboButton(font.name, kobo: kobo)
                    } else {
                        Button("Install on \(kobo.name)", systemImage: "arrow.down.to.line") {
                            run { try await install(font, on: kobo) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case (.local(let font), .device):
                if !isMine(font.name) {
                    Button("Copy to My Fonts", systemImage: "plus") {
                        run { try FontLibrary.copy(font, to: libraryFolder) }
                    }
                }
                Button("Remove from Kobo", systemImage: "trash", role: .destructive) {
                    run {
                        FontLibrary.remove(font)
                        self.choice = nil
                    }
                }
            case (.local(let font), _):
                if let kobo {
                    if isOnDevice(font.name) {
                        removeFromKoboButton(font.name, kobo: kobo)
                    } else {
                        Button("Install on \(kobo.name)", systemImage: "arrow.down.to.line") {
                            run { try FontLibrary.copy(font, to: FontLibrary.deviceFolder(on: kobo.url)) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    run {
                        FontLibrary.remove(font)
                        self.choice = nil
                    }
                }
            }
        }
        .disabled(busy)
        .animation(.snappy, value: isMine(name))
        .animation(.snappy, value: isOnDevice(name))
        if kobo == nil, source != .device {
            Text("Plug in your Kobo to install fonts on it.").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Takes a family off the Kobo. Its copy in My Fonts, if any, stays.
    private func removeFromKoboButton(_ name: String, kobo: ReaderDevice) -> some View {
        Button("Remove from \(kobo.name)", systemImage: "trash", role: .destructive) {
            run {
                guard let installed = onDevice.first(where: { key($0.name) == key(name) }) else { return }
                FontLibrary.remove(installed)
                app.activity.flash("Removed \(installed.displayName) from \(kobo.name)",
                                   detail: "Books set in it will use the Kobo's default font.")
            }
        }
        .help("Installed on \(kobo.name). Removing it keeps any copy in My Fonts.")
    }

    private func subtitle(_ choice: Choice) -> String {
        switch choice {
        case .google(let font):
            "\(font.category) · \(font.styles.count) style\(font.styles.count == 1 ? "" : "s") · free from Google Fonts"
        case .local(let font):
            font.styleNames.joined(separator: " · ")
        }
    }

    // MARK: Data

    private func familyName(_ choice: Choice) -> String {
        switch choice {
        case .google(let font): font.name
        case .local(let font): font.name
        }
    }

    private func key(_ name: String) -> String { name.filter { !$0.isWhitespace && $0 != "_" }.lowercased() }
    private func isMine(_ name: String) -> Bool { mine.contains { key($0.name) == key(name) } }
    private func isOnDevice(_ name: String) -> Bool { onDevice.contains { key($0.name) == key(name) } }

    private func reloadLocal() {
        mine = FontLibrary.fonts(in: libraryFolder)
        onDevice = kobo.map { FontLibrary.fonts(in: FontLibrary.deviceFolder(on: $0.url)) } ?? []
    }

    private func load() async {
        reloadLocal()
        if !mine.isEmpty { source = .mine }
        do {
            catalogue = try await GoogleFonts.catalogue(cache: previewCache)
            if choice == nil, source == .browse { choice = filtered.first.map(Choice.google) }
        } catch {
            catalogueError = error.localizedDescription
        }
    }

    /// Fetches the regular style (for a Google font not yet saved) and makes it drawable.
    private func loadPreview() async {
        guard let choice else {
            previewFont = nil
            return
        }
        loadingPreview = true
        defer { loadingPreview = false }
        var file: URL?
        switch choice {
        case .local(let font):
            file = font.regular
        case .google(let font):
            if let saved = mine.first(where: { key($0.name) == key(font.name) }) {
                file = saved.regular
            } else {
                let cached = previewCache.appending(path: FontLibrary.fileName(family: font.name, style: .regular, extension: "ttf"))
                if !FileManager.default.fileExists(atPath: cached.path) {
                    _ = try? await GoogleFonts.download(font, styles: [.regular], to: previewCache)
                }
                file = FileManager.default.fileExists(atPath: cached.path) ? cached : nil
            }
        }
        guard !Task.isCancelled else { return }
        let name = file.flatMap(FontLibrary.register)
        withAnimation(.snappy) { previewFont = name }
    }

    private func save(_ font: GoogleFont) async throws {
        try await GoogleFonts.download(font, to: libraryFolder)
    }

    private func install(_ font: GoogleFont, on device: ReaderDevice) async throws {
        if !isMine(font.name) { try await save(font) }
        reloadLocal()
        guard let saved = mine.first(where: { key($0.name) == key(font.name) }) else { return }
        try FontLibrary.copy(saved, to: FontLibrary.deviceFolder(on: device.url))
        app.activity.flash("Installed \(font.name) on \(device.name)", detail: "Choose it on the Kobo under Aa › Font Face.")
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await work()
            } catch {
                app.activity.flash("That didn't work", detail: error.localizedDescription)
            }
            reloadLocal()
            busy = false
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.font, .zip, .folder]
        panel.message = "Choose font files (TTF or OTF), or a zip or folder of them, to keep in My Fonts"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await app.store.importFiles(urls) }
    }
}

/// A font's name written in that font, fetched when its row scrolls into view. Shows the name in the
/// system font until the sample arrives, or if it can't be had.
private struct FontNameLabel: View {
    let name: String
    let sample: FontsView.Choice
    let cache: URL

    @State private var font: Font?
    private static let size: CGFloat = 17
    @MainActor private static var loaded: [String: Font] = [:]

    private var key: String {
        switch sample {
        case .google(let font): "g:" + font.name
        case .local(let font): "l:" + (font.regular?.path ?? font.name)
        }
    }

    var body: some View {
        Text(name)
            .font(font ?? Self.loaded[key] ?? .body)
            .lineLimit(1)
            .task(id: key) { await load() }
    }

    private func load() async {
        if let known = Self.loaded[key] {
            font = known
            return
        }
        var data: Data?
        switch sample {
        case .google(let google):
            // A short pause so flicking fast past a row doesn't fetch it.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            data = try? await GoogleFonts.nameSample(google, cache: cache)
        case .local(let local):
            data = local.regular.flatMap { try? Data(contentsOf: $0) }
        }
        guard !Task.isCancelled, let data, let ctFont = FontLibrary.font(from: data, size: Self.size) else { return }
        let made = Font(ctFont)
        Self.loaded[key] = made
        withAnimation(.easeOut(duration: 0.15)) { font = made }
    }
}

/// A page of a book as an e-reader would show it: grey paper, black text, in the chosen font.
struct EReaderPreview: View {
    let fontName: String?
    let fontSize: Double
    let lineSpacing: Double
    let justified: Bool
    var loading = false

    private let paragraphs = [
        "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.",
        "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered as the rightful property of some one or other of their daughters.",
        "“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?” Mr. Bennet replied that he had not.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            PageText(heading: "Chapter One", paragraphs: paragraphs, fontName: fontName, fontSize: fontSize,
                     lineSpacing: lineSpacing, justified: justified)
            Text("1 of 432").font(.system(size: 10))
        }
        .foregroundStyle(Color(white: 0.08))
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .frame(width: 380, height: 500)
        .background(Color(white: 0.91))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay { if loading { ProgressView().controlSize(.small) } }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 46)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        .animation(.snappy, value: fontSize)
        .animation(.snappy, value: lineSpacing)
    }
}

/// Lays a page out with AppKit, which can justify text and indent first lines the way an e-reader does.
private struct PageText: NSViewRepresentable {
    let heading: String
    let paragraphs: [String]
    let fontName: String?
    let fontSize: Double
    let lineSpacing: Double
    let justified: Bool

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        func font(_ size: Double) -> NSFont {
            fontName.flatMap { NSFont(name: $0, size: size) }
                ?? NSFont(descriptor: NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) ?? .init(), size: size)
                ?? .systemFont(ofSize: size)
        }
        let colour = NSColor(white: 0.08, alpha: 1)
        let title = NSMutableParagraphStyle()
        title.alignment = .center
        title.paragraphSpacing = fontSize
        let body = NSMutableParagraphStyle()
        body.alignment = justified ? .justified : .left
        body.lineHeightMultiple = lineSpacing / 1.2
        body.firstLineHeadIndent = fontSize * 1.2
        body.hyphenationFactor = justified ? 0.9 : 0

        let text = NSMutableAttributedString(string: heading + "\n", attributes: [
            .font: font(fontSize * 1.35), .paragraphStyle: title, .foregroundColor: colour,
        ])
        text.append(NSAttributedString(string: paragraphs.joined(separator: "\n"), attributes: [
            .font: font(fontSize), .paragraphStyle: body, .foregroundColor: colour,
        ]))
        view.textStorage?.setAttributedString(text)
    }
}
