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
            Group {
                if case .device(let id) = app.sidebar {
                    DeviceView(deviceID: id)
                } else {
                    LibraryView()
                }
            }
            .navigationTitle(app.title)
            .overlay(alignment: .bottom) { ActivityOverlay() }
        }
        .inspector(isPresented: $app.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 330, ideal: 350, max: 440)
        }
        .searchable(text: $app.search, placement: .toolbar, prompt: "Search title, author, notes")
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
        .sheet(item: $app.editing) { book in
            MetadataEditor(book: book)
        }
        .sheet(item: $app.batchEditing) { session in
            BatchEditor(bookIDs: session.bookIDs, books: session.bookIDs.compactMap(app.store.book))
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
        .onChange(of: app.devices.devices.map(\.id)) { _, ids in
            if case .device(let id) = app.sidebar, !ids.contains(id) { app.sidebar = .all }
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
            Button("Add Books", systemImage: "plus") { app.addBooks() }
                .help("Add books to your library")
        }
        ToolbarItemGroup(placement: .primaryAction) {
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

            SendButton()

            Button("Details", systemImage: "sidebar.trailing") {
                withAnimation(.snappy) { app.showInspector.toggle() }
            }
            .help("Show or hide book details")
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
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: app.activity.current)
    }
}
