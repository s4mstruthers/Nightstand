import SwiftUI

/// How books look when they're sent to an e-reader, with a way to re-send what's already there.
struct FormattingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Format Books")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                Text("Set the font size, spacing and layout applied when books are sent or exported. The copies in your library are never changed, so you can adjust and send again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            FormattingSettings()
            Divider()
            HStack {
                ForEach(app.devices.devices.prefix(1)) { device in
                    let ids = Set(device.manifest.keys)
                    Button("Re-send \(ids.count) Book\(ids.count == 1 ? "" : "s") on \(device.name)") {
                        app.send(ids, to: device.id)
                        dismiss()
                    }
                    .disabled(ids.isEmpty)
                    .help("Replace Nightstand's books on the device with freshly formatted copies.")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 680)
    }
}

/// Formatting for one book, used instead of the usual settings when it's sent or exported.
struct BookFormattingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID

    var body: some View {
        let book = app.store.book(bookID)
        let custom = book?.formatOverride != nil
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Formatting for “\(book?.title ?? "")”")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .lineLimit(2)
                Picker("", selection: Binding {
                    custom
                } set: { own in
                    app.store.modify([bookID]) { $0.formatOverride = own ? app.settings.format : nil }
                }) {
                    Text("Same as Other Books").tag(false)
                    Text("Its Own Formatting").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(custom
                     ? "This book is sent and exported with the settings below. Your other books keep the usual ones."
                     : "Choose Its Own Formatting for a book with tiny text, cramped lines or odd styling.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            if custom {
                FormattingSettings(options: Binding {
                    app.store.book(bookID)?.formatOverride ?? app.settings.format
                } set: { options in
                    app.store.modify([bookID]) { $0.formatOverride = options }
                }, showsConversion: false)
            } else {
                Spacer()
            }
            Divider()
            HStack {
                ForEach(app.devices.devices.prefix(1)) { device in
                    if device.manifest[bookID] != nil {
                        Button("Send Again to \(device.name)") {
                            app.send([bookID], to: device.id)
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: custom ? 680 : 260)
        .animation(.snappy, value: custom)
    }
}
