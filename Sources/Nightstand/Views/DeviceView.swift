import SwiftUI

struct DeviceView: View {
    @Environment(AppModel.self) private var app
    let deviceID: String
    @State private var fileToDelete: DeviceFile?

    var body: some View {
        if let device = app.devices.device(deviceID) {
            content(device)
        } else {
            ContentUnavailableView("Device Disconnected", systemImage: "cable.connector.slash")
        }
    }

    private func content(_ device: ReaderDevice) -> some View {
        let tracked = app.store.books
            .filter { device.manifest[$0.id] != nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let untracked = device.untrackedFiles

        return List {
            Section {
                header(device)
                    .listRowSeparator(.hidden)
                if let waiting = app.pendingRestores[device.id], waiting > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "bookmark.circle").font(.title2).foregroundStyle(.tint)
                        Text("Your place in \(waiting) book\(waiting == 1 ? "" : "s") will be restored once the Kobo has imported them. Eject it, let it finish importing, then plug it back in.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Restore Now") { Task { await app.restorePositions(on: device.id) } }
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    .listRowSeparator(.hidden)
                }
            }

            Section("From Your Library (\(tracked.count))") {
                if tracked.isEmpty {
                    Text("Select books in your library and choose Send to Device.")
                        .foregroundStyle(.secondary)
                }
                ForEach(tracked) { book in
                    HStack(spacing: 12) {
                        CoverView(book: book, maxPixel: 120, cornerRadius: 3).frame(width: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(book.title)
                            Text(book.authorText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if book.status == .finished {
                            Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Finished")
                        } else if let progress = book.progress, progress > 0 {
                            Text("\(Int(progress * 100))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Button("Remove", systemImage: "minus.circle") {
                            withAnimation(.snappy) { app.devices.remove(bookIDs: [book.id], from: device.id) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove from \(device.name). The book stays in your library.")
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Show in Library") {
                            app.sidebar = .all
                            app.selection = [book.id]
                        }
                        Button("Send Again") { app.send([book.id], to: device.id) }
                    }
                }
            }

            if !untracked.isEmpty {
                Section("Other Books on This Device (\(untracked.count))") {
                    ForEach(untracked) { file in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name).lineLimit(1).truncationMode(.middle)
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add to Library", systemImage: "plus.circle") {
                                let url = device.url.appending(path: file.path)
                                Task { await app.store.importFiles([url]) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Copy this book into your library")
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Delete from Device…", role: .destructive) { fileToDelete = file }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .confirmationDialog("Delete “\(fileToDelete?.name ?? "")” from \(device.name)?",
                            isPresented: Binding { fileToDelete != nil } set: { if !$0 { fileToDelete = nil } }) {
            Button("Delete", role: .destructive) {
                if let fileToDelete { app.devices.remove(file: fileToDelete, from: device.id) }
                fileToDelete = nil
            }
        } message: {
            Text("This book isn't in your Nightstand library, so this can't be undone.")
        }
    }

    private func header(_ device: ReaderDevice) -> some View {
        let used = Double(device.total - device.free) / Double(max(device.total, 1))
        return HStack(spacing: 18) {
            Image(systemName: "ipad.landscape")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(device.name).font(.system(.title2, design: .serif, weight: .semibold))
                    Text(device.kind.label).font(.callout).foregroundStyle(.secondary)
                }
                ProgressView(value: used)
                    .tint(used > 0.9 ? .red : .accentColor)
                Text("\(ByteCountFormatter.string(fromByteCount: device.free, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: device.total, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if device.kind == .kobo {
                Button("Sync Reading", systemImage: "arrow.triangle.2.circlepath") {
                    app.syncReading(from: device.id)
                }
                .controlSize(.large)
                .disabled(app.syncingDevice != nil)
                .help("Read progress, reading time and highlights from \(device.name)")
                Button("Refresh Covers", systemImage: "photo") { app.refreshCovers(on: device.id) }
                    .controlSize(.large)
                    .labelStyle(.iconOnly)
                    .help("Show your library's covers on the Kobo, for books whose cover is missing or wrong there")
                Button("Format…", systemImage: "textformat.size") { app.showFormatting = true }
                    .controlSize(.large)
                    .help("Choose how books look on the device, and re-send them")
                Button("Tidy Up…", systemImage: "sparkles") { app.startTidyUp(device.id) }
                    .controlSize(.large)
                    .disabled(app.syncingDevice != nil)
                    .help("Replace books put on the Kobo by Calibre or other apps with Nightstand's copies")
            }
            Button("Eject", systemImage: "eject") { app.devices.eject(device) }
                .controlSize(.large)
        }
        .padding(.vertical, 10)
    }
}
