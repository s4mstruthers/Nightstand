import SwiftUI

/// Offers a newer version, with what changed, and installs it.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let updater = app.updater

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nightstand \(updater.release?.version ?? "") is available")
                        .font(.system(.title2, design: .serif, weight: .semibold))
                    Text("You have version \(updater.currentVersion).")
                        .foregroundStyle(.secondary)
                }
            }

            if let notes = updater.release.map({ UpdateFeed.formatted($0.notes) }), !notes.characters.isEmpty {
                ScrollView {
                    Text(notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 220)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }

            status(updater)

            HStack {
                if !updater.isBusy {
                    Button("Skip This Version") { updater.skip() }
                }
                Spacer()
                Button("Later") { updater.showSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(updater.phase == .installing)
                primaryButton(updater)
            }
        }
        .padding(22)
        .frame(width: 500)
        .interactiveDismissDisabled(updater.isBusy)
        .animation(.snappy, value: updater.phase)
    }

    @ViewBuilder
    private func status(_ updater: Updater) -> some View {
        switch updater.phase {
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading…").font(.callout) }
        case .installing:
            ProgressView { Text("Installing…").font(.callout) }
                .progressViewStyle(.linear)
        case .failed(let message):
            Label("The update couldn't be installed. \(message)", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .checking:
            if !updater.canInstallInPlace {
                Text("Nightstand can't update itself from where it is now. Move it to your Applications folder, or download the new version yourself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func primaryButton(_ updater: Updater) -> some View {
        if case .failed = updater.phase {
            Button("Open Download Page") { updater.openReleasePage() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else if updater.canInstallInPlace {
            Button("Install and Relaunch") { Task { await updater.install() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(updater.isBusy)
        } else {
            Button("Open Download Page") { updater.openReleasePage() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
