import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var app = app
        @Bindable var updater = app.updater

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            ZStack {
                switch app.sidebar {
                case .home: HomeView().transition(pageTransition)
                case .discover: DiscoverView().transition(pageTransition)
                case .journal: JournalView().transition(pageTransition)
                case .organise: OrganiseView().transition(pageTransition)
                case .fonts: FontsView().transition(pageTransition)
                case .device(let id): DeviceView(deviceID: id).transition(pageTransition)
                default: LibraryView().transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.22), value: app.showsBooks)
            .animation(.easeOut(duration: 0.22), value: pageKey)
            .navigationTitle(app.title)
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    ActivityOverlay()
                    if app.showsBooks, app.selection.count > 1 {
                        SelectionBar()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.bottom, app.showsBooks ? 44 : 18)
                .animation(.spring(duration: 0.4, bounce: 0.25), value: app.selection.count > 1)
            }
        }
        .inspector(isPresented: Binding {
            app.showInspector && app.detailsRelevant
        } set: { shown in
            // Closing it on a page such as Home just puts the book away.
            if !shown, !app.showsBooks { app.selection = [] } else { app.showInspector = shown }
        }) {
            InspectorView()
                .inspectorColumnWidth(min: 330, ideal: 350, max: 440)
        }
        .searchable(text: $app.search, placement: .toolbar, prompt: "Search your books")
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            app.handleDrop(urls)
        } isTargeted: { targeted in
            withAnimation(.snappy(duration: 0.2)) { dropTargeted = targeted }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $app.showFormatting) {
            FormattingSheet()
        }
        .sheet(isPresented: $app.showQuickFind) {
            QuickFind()
        }
        .onChange(of: app.search) { _, text in
            // Searching from a page such as Home searches the whole library.
            if !text.isEmpty, !app.showsBooks { app.sidebar = .all }
        }
        .sheet(item: $app.editing) { book in
            MetadataEditor(book: book)
        }
        .sheet(item: $app.batchEditing) { session in
            BatchEditor(bookIDs: session.bookIDs, books: session.bookIDs.compactMap(app.store.book))
        }
        .sheet(item: $app.tidyingUp) { session in
            KoboTidySheet(session: session)
        }
        .sheet(item: $app.lookingUp) { book in
            LookupSheet(book: book)
        }
        .sheet(item: $app.cleanUp) { session in
            CleanUpSheet(proposals: session.proposals)
        }
        .sheet(isPresented: $updater.showSheet) {
            UpdateSheet()
        }
        .task { app.updater.checkOnLaunch() }
        .confirmationDialog(deleteTitle, isPresented: $app.showDeleteConfirmation) {
            Button("Move to Trash", role: .destructive) { app.confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The book file, your rating and your notes are moved to the Trash.")
        }
        .onChange(of: app.sidebar) { old, new in
            // A book picked on Home, Discover or Journal doesn't follow you to another page.
            let pages: [SidebarItem?] = [.home, .discover, .journal, .organise, .fonts]
            if pages.contains(old), pages.contains(new) { app.selection = [] }
        }
        .onChange(of: app.devices.devices.map(\.id)) { _, ids in
            if case .device(let id) = app.sidebar, !ids.contains(id) { app.sidebar = .all }
        }
    }

    private var pageTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity)
    }

    /// Changes when the page does, but not when moving between lists of books.
    private var pageKey: String {
        switch app.sidebar {
        case .home: "home"
        case .discover: "discover"
        case .journal: "journal"
        case .organise: "organise"
        case .fonts: "fonts"
        case .device(let id): id
        default: "books"
        }
    }

    private var deleteTitle: String {
        let count = app.pendingDelete.count
        if count == 1, let id = app.pendingDelete.first, let book = app.store.book(id) {
            return "Delete “\(book.title)”?"
        }
        return "Delete \(count) books?"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var app = app

        ToolbarItem(placement: .navigation) {
            Button(app.sidebar == .fonts ? "Add Fonts" : "Add Books", systemImage: "plus") { app.addBooks() }
                .help(app.sidebar == .fonts ? "Add font files, or a zip of them, to My Fonts" : "Add books to your library")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Find Anything", systemImage: "command") { app.showQuickFind = true }
                .help("Find a book, page or action (⌘K)")

            if app.showsBooks {
            Picker("View", selection: $app.viewMode) {
                Label("Covers", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .help("Show as covers or a list")

            Menu {
                Picker("Sort By", selection: $app.sort) {
                    ForEach(BookSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort books")
            }

            if app.showsBooks {
                SendButton()
            }
            if app.detailsRelevant {
                Button("Details", systemImage: "sidebar.trailing") {
                    withAnimation(.snappy) {
                        if app.showsBooks { app.showInspector.toggle() } else { app.selection = [] }
                    }
                }
                .help(app.showsBooks ? "Show or hide book details" : "Close book details")
            }
        }
    }
}

/// Sends the selection to a connected e-reader; a menu when more than one is connected.
private struct SendButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let devices = app.devices.devices
        Group {
            if devices.count > 1 {
                Menu {
                    ForEach(devices) { device in
                        Button(device.name) { app.send(app.selection, to: device.id) }
                    }
                } label: {
                    Label("Send to Device", systemImage: "arrow.up.forward.app")
                }
            } else {
                Button("Send to Device", systemImage: "arrow.up.forward.app") {
                    if let device = devices.first { app.send(app.selection, to: device.id) }
                }
            }
        }
        .disabled(devices.isEmpty || app.selection.isEmpty)
        .help(devices.isEmpty ? "Connect an e-reader to send books"
              : app.selection.isEmpty ? "Select books to send"
              : "Send the selected books to \(devices.count == 1 ? devices[0].name : "a device")")
    }
}

struct ActivityOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            if let activity = app.activity.current {
                HStack(spacing: 12) {
                    if let progress = activity.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.title).font(.callout.weight(.medium))
                        if let detail = activity.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: true, vertical: false)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: app.activity.current)
    }
}

/// Appears when several books are selected, so the things you can do to all of them are in plain sight.
struct SelectionBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let ids = app.selection
        HStack(spacing: 12) {
            Text("\(ids.count) selected")
                .font(.callout.weight(.semibold))
                .contentTransition(.numericText())
                .padding(.trailing, 2)
            Button("Edit Details", systemImage: "pencil") { app.edit(ids) }
                .help("Change the author, series, tags and more for all of them")
            Menu {
                ForEach(ReadingStatus.allCases) { status in
                    Button(status.label, systemImage: status.symbol) { app.store.setStatus(status, for: ids) }
                }
            } label: {
                Label("Status", systemImage: "bookmark")
            }
            .fixedSize()
            Menu {
                ForEach((1...5).reversed(), id: \.self) { stars in
                    Button(String(repeating: "★", count: stars)) { app.store.modify(ids) { $0.rating = stars } }
                }
                Divider()
                Button("No Rating") { app.store.modify(ids) { $0.rating = 0 } }
            } label: {
                Label("Rate", systemImage: "star")
            }
            .fixedSize()
            Button("Clean Up", systemImage: "wand.and.stars") { app.startCleanUp() }
                .help("Suggest tidier titles, authors and series for these books")
            if let device = app.devices.devices.first {
                Button("Send", systemImage: "arrow.up.forward.app") { app.send(ids, to: device.id) }
                    .help("Send to \(device.name)")
            }
            Menu {
                BookMenu(ids: ids)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            Divider().frame(height: 18)
            Button("Deselect", systemImage: "xmark") { withAnimation(.snappy) { app.selection = [] } }
                .labelStyle(.iconOnly)
                .help("Clear the selection")
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }
}
