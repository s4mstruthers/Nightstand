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
