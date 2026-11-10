import SwiftUI

/// Shows what tidying a Kobo will do, lets the user choose, then runs it. Nothing changes until Tidy Up.
struct KoboTidySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let session: KoboTidySession

    @State private var plan: KoboTidy.Plan?
    @State private var options = KoboTidy.Options.saved
    @State private var layout = FolderLayout.current
    @State private var running = false
    @State private var finished = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tidy Up \(session.deviceName)")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                Text("Choose what to tidy. Nothing on the Kobo changes until you click Tidy Up.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()

            Group {
                if finished {
                    done
                } else if let plan {
                    form(plan)
                } else {
                    ProgressView("Looking at your Kobo…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text(app.activity.current?.title ?? "Working…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let plan, !finished {
                    Text(summary(plan))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if finished {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(running)
                    Button("Tidy Up") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || plan.map { !hasWork($0) } ?? true)
                }
            }
            .padding(14)
        }
        .frame(width: 640, height: 680)
        .interactiveDismissDisabled(running)
        .task { await replan() }
        .onChange(of: layout) {
            FolderLayout.current = layout
            Task { await replan() }
        }
        .onChange(of: options) { KoboTidy.Options.saved = options }
    }

    private func replan() async {
        plan = await app.planTidyUp(session.deviceID)
    }

    // MARK: Choices

    private func form(_ plan: KoboTidy.Plan) -> some View {
        let others = plan.replacements.filter { !$0.isRefile }
        let refiles = plan.replacements.filter(\.isRefile)

        return Form {
            Section {
                Picker("Folders", selection: $layout) {
                    ForEach(FolderLayout.allCases) { Text($0.label).tag($0) }
                }
                Text(layout.example)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } header: {
                Text("Organise")
            } footer: {
                caption("Also used whenever Nightstand sends a book.")
            }

            Section {
                Toggle(isOn: $options.replaceOthers) {
                    Text("Replace copies from other apps (\(others.count))")
                    Text("Swaps Calibre's copies for Nightstand's, with your details, cover and formatting.")
                }
                .disabled(others.isEmpty)
                if options.replaceOthers { bookRows(others) }

                Toggle(isOn: $options.refile) {
                    Text("Move Nightstand's copies into these folders (\(refiles.count))")
                    Text(refiles.isEmpty ? "They're already in the right place." : "Re-sends books that are filed differently.")
                }
                .disabled(refiles.isEmpty)
                if options.refile { bookRows(refiles) }

                Toggle(isOn: $options.keepPlace) {
                    Text("Keep my place in replaced books")
                    Text("After you eject and reconnect the Kobo, puts you back on the same sentence, with your progress and reading time.")
                }
            } header: {
                Text("Books")
            } footer: {
                if !options.keepPlace {
                    caption("Without this, replaced books open at the beginning on the Kobo. Your progress is still kept in Nightstand.")
                }
            }

            Section("Clean Up") {
                if !plan.imports.isEmpty {
                    Toggle(isOn: $options.addMissing) {
                        Text("Add books that aren't in my library (\(plan.imports.count))")
                        Text(plan.imports.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                            .lineLimit(2)
                    }
                }
                Toggle(isOn: $options.removeLeftovers) {
                    Text("Remove leftover files (\(plan.junk.count))")
                    Text(junkSummary(plan.junk))
                }
                .disabled(plan.junk.isEmpty)
                if !plan.damaged.isEmpty {
                    Toggle(isOn: $options.removeDamaged) {
                        Text("Remove damaged files (\(plan.damaged.count))")
                        Text(plan.damaged.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + " can't be opened, probably from a copy that didn't finish.")
                            .lineLimit(3)
                    }
                }
            }

            Section {
                caption("Kobo store books, fonts and the Kobo's own files are never touched. Before anything changes, your reading progress is saved in Nightstand and the Kobo's database is backed up to Nightstand Library › Kobo Backups.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func bookRows(_ replacements: [KoboTidy.Replacement]) -> some View {
        let included = replacements.filter { !options.skipped.contains($0.bookID) }.count
        DisclosureGroup("Choose books (\(included) of \(replacements.count))") {
            bookList(replacements)
        }
        .padding(.leading, 20)
    }

    @ViewBuilder
    private func bookList(_ replacements: [KoboTidy.Replacement]) -> some View {
        ForEach(replacements) { replacement in
            HStack(spacing: 10) {
                Toggle("", isOn: Binding {
                    !options.skipped.contains(replacement.bookID)
                } set: { on in
                    if on { options.skipped.remove(replacement.bookID) } else { options.skipped.insert(replacement.bookID) }
                })
                .toggleStyle(.checkbox)
                .labelsHidden()
                if let book = app.store.book(replacement.bookID) {
                    CoverView(book: book, maxPixel: 100, cornerRadius: 2).frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(replacement.title).lineLimit(1)
                    Text(replacement.oldPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let record = replacement.record, replacement.hasPosition {
                    Text(record.readStatus == 2 ? "Finished" : "\(record.percentRead)%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(options.skipped.contains(replacement.bookID) ? 0.45 : 1)
        }
    }

    // MARK: Finished

    private var done: some View {
        let waiting = app.pendingRestores[session.deviceID] ?? 0
        return ContentUnavailableView {
            Label("Tidied Up", systemImage: "checkmark.circle")
        } description: {
            Text(waiting > 0
                 ? "Now eject your Kobo and wait for it to finish importing. Then plug it back in, and Nightstand will restore your place in \(waiting) book\(waiting == 1 ? "" : "s")."
                 : "Your Kobo is tidy.")
        } actions: {
            if let device = app.devices.device(session.deviceID) {
                Button("Eject \(device.name)") {
                    app.devices.eject(device)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Helpers

    private func chosen(_ plan: KoboTidy.Plan) -> [KoboTidy.Replacement] {
        plan.replacements.filter(options.includes)
    }

    private func hasWork(_ plan: KoboTidy.Plan) -> Bool {
        !chosen(plan).isEmpty
            || (options.addMissing && !plan.imports.isEmpty)
            || (options.removeLeftovers && !plan.junk.isEmpty)
            || (options.removeDamaged && !plan.damaged.isEmpty)
    }

    private func summary(_ plan: KoboTidy.Plan) -> String {
        guard hasWork(plan) else { return plan.isEmpty ? "Already tidy." : "Nothing chosen." }
        let books = chosen(plan).count
        var parts: [String] = []
        if books > 0 { parts.append("\(books) book\(books == 1 ? "" : "s") to replace") }
        if options.removeLeftovers, !plan.junk.isEmpty { parts.append("\(plan.junk.count) files to remove") }
        return parts.joined(separator: " · ")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func junkSummary(_ junk: [String]) -> String {
        let calibre = junk.filter { $0.hasSuffix(".calibre") }.count
        let apple = junk.filter { ($0 as NSString).lastPathComponent.hasPrefix("._") }.count
        var parts: [String] = []
        if calibre > 0 { parts.append("Calibre's device files") }
        if apple > 0 { parts.append("\(apple) hidden “._” files macOS left behind") }
        return parts.isEmpty ? "None found." : parts.joined(separator: " and ") + "."
    }

    private func run() {
        running = true
        let options = options
        Task {
            await app.tidyUp(session.deviceID, options: options)
            running = false
            finished = true
        }
    }
}
