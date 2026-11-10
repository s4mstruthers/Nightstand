import SwiftUI

/// The books being edited together, in the order they appear in the library (used for series numbers).
struct BatchEditSession: Identifiable {
    let id = UUID()
    let bookIDs: [UUID]
}

/// Edits details shared by several books. Only ticked fields are written; typing in a field ticks it.
struct BatchEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let bookIDs: [UUID]

    @State private var authors = Field()
    @State private var series = Field()
    @State private var publisher = Field()
    @State private var published = Field()
    @State private var language = Field()
    @State private var numbering = NumberingChoice.keep
    @State private var startNumber = "1"
    @State private var addTags = ""
    @State private var removeTags: Set<String> = []
    @State private var clearTags = false
    @State private var rating: Int?
    @State private var status: ReadingStatus?

    struct Field {
        var text = ""
        var isOn = false
        var mixed = false
    }

    enum NumberingChoice: Hashable { case keep, sequential, clear }

    init(bookIDs: [UUID], books: [Book]) {
        self.bookIDs = bookIDs
        func common(_ value: (Book) -> String) -> Field {
            let values = Set(books.map(value))
            return values.count == 1 ? Field(text: values.first ?? "") : Field(mixed: true)
        }
        _authors = State(initialValue: common { $0.authors.joined(separator: ", ") })
        _series = State(initialValue: common { $0.series ?? "" })
        _publisher = State(initialValue: common { $0.publisher ?? "" })
        _published = State(initialValue: common { $0.published ?? "" })
        _language = State(initialValue: common { $0.language ?? "" })
    }

    private var books: [Book] { bookIDs.compactMap(app.store.book) }

    private var existingTags: [String] {
        Array(Set(books.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var edit: BatchEdit {
        var edit = BatchEdit()
        if authors.isOn { edit.authors = BatchEdit.list(authors.text) }
        if series.isOn { edit.series = series.text }
        switch numbering {
        case .keep: break
        case .clear: edit.numbering = .clear
        case .sequential:
            if let start = startValue { edit.numbering = .sequential(start: start) }
        }
        edit.clearTags = clearTags
        edit.addTags = BatchEdit.list(addTags)
        edit.removeTags = clearTags ? [] : Array(removeTags)
        if publisher.isOn { edit.publisher = publisher.text }
        if published.isOn { edit.published = published.text }
        if language.isOn { edit.language = language.text }
        edit.rating = rating
        edit.status = status
        return edit
    }

    private var startValue: Double? {
        Double(startNumber.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        let books = books
        let changes = edit.apply(to: books)

        VStack(spacing: 0) {
            header(books)
            Divider()
            Form {
                Section {
                    TextRow(label: "Authors", field: $authors, prompt: "Separate with commas")
                }
                Section {
                    TextRow(label: "Series", field: $series, prompt: "")
                    Picker("Number in Series", selection: $numbering) {
                        Text("Keep As Is").tag(NumberingChoice.keep)
                        Text("Number in Order").tag(NumberingChoice.sequential)
                        Text("Remove Numbers").tag(NumberingChoice.clear)
                    }
                    if numbering == .sequential {
                        TextField("Start At", text: $startNumber)
                        numberingPreview(books)
                    }
                } footer: {
                    if numbering == .sequential {
                        Text("Books are numbered in the order they appear in the library. Change the sort order to change it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Tags") {
                    if !existingTags.isEmpty {
                        LabeledContent("Current") {
                            FlowLayout {
                                ForEach(existingTags, id: \.self) { tag in
                                    tagChip(tag)
                                }
                            }
                        }
                        Toggle("Remove all current tags", isOn: $clearTags)
                    }
                    TextField("Add Tags", text: $addTags, prompt: Text("Separate with commas"))
                }
                Section {
                    TextRow(label: "Publisher", field: $publisher, prompt: "")
                    TextRow(label: "Published", field: $published, prompt: "YYYY-MM-DD")
                    TextRow(label: "Language", field: $language, prompt: "")
                }
                Section {
                    Picker("Rating", selection: $rating) {
                        Text("Keep As Is").tag(Int?.none)
                        Divider()
                        ForEach((1...5).reversed(), id: \.self) { stars in
                            Text(String(repeating: "★", count: stars)).tag(Int?.some(stars))
                        }
                        Text("No Rating").tag(Int?.some(0))
                    }
                    Picker("Status", selection: $status) {
                        Text("Keep As Is").tag(ReadingStatus?.none)
                        Divider()
                        ForEach(ReadingStatus.allCases) { Text($0.label).tag(ReadingStatus?.some($0)) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Text(summary(changes.count, of: books.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(changes.isEmpty ? "Save" : "Save \(changes.count) Book\(changes.count == 1 ? "" : "s")") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 600, height: 640)
    }

    private func header(_ books: [Book]) -> some View {
        HStack(spacing: 16) {
            ZStack {
                ForEach(Array(books.prefix(3).enumerated().reversed()), id: \.element.id) { index, book in
                    CoverView(book: book, maxPixel: 200, cornerRadius: 3)
                        .frame(width: 40)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .rotationEffect(.degrees(Double(index) * 6 - 6))
                        .offset(x: CGFloat(index) * 8)
                }
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit \(books.count) Books")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                Text("Tick a field to change it on every book. Leave a ticked field empty to remove it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func tagChip(_ tag: String) -> some View {
        let removing = clearTags || removeTags.contains(tag)
        return Button {
            if removeTags.contains(tag) { removeTags.remove(tag) } else { removeTags.insert(tag) }
        } label: {
            HStack(spacing: 3) {
                Text(tag).strikethrough(removing)
                Image(systemName: removing ? "arrow.uturn.backward" : "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(removing ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .background(removing ? AnyShapeStyle(Color.red.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(clearTags)
        .help(removing ? "Keep this tag" : "Remove this tag from every book")
    }

    private func numberingPreview(_ books: [Book]) -> some View {
        let start = startValue ?? 1
        let seriesName = series.isOn ? series.text.trimmingCharacters(in: .whitespaces) : nil
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(books.prefix(4).enumerated()), id: \.element.id) { position, book in
                let inSeries = seriesName.map { !$0.isEmpty } ?? (book.series != nil)
                HStack(spacing: 8) {
                    Text(inSeries ? "#\(Book.formatIndex(start + Double(position)))" : "–")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Text(book.title).lineLimit(1)
                }
            }
            if books.count > 4 {
                Text("and \(books.count - 4) more")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 44)
            }
        }
        .font(.callout)
    }

    private func summary(_ changed: Int, of total: Int) -> String {
        if changed == 0 { return "No changes yet." }
        let unchanged = total - changed
        return unchanged == 0 ? "Every selected book will change."
            : "\(changed) will change; \(unchanged) already match\(unchanged == 1 ? "es" : "")."
    }

    private func save() {
        let changed = edit.apply(to: books)
        for book in changed { app.store.update(book) }
        app.activity.flash("Updated \(changed.count) book\(changed.count == 1 ? "" : "s")")
        dismiss()
    }
}

/// A text field with a tick box: ticked fields are written to every book.
private struct TextRow: View {
    let label: String
    @Binding var field: BatchEditor.Field
    let prompt: String

    var body: some View {
        LabeledContent {
            TextField(label, text: $field.text,
                      prompt: Text(field.isOn && field.text.isEmpty ? "Will be removed" : field.mixed ? "Mixed" : prompt))
                .labelsHidden()
                .opacity(field.isOn ? 1 : 0.6)
                .onChange(of: field.text) { field.isOn = true }
        } label: {
            HStack(spacing: 8) {
                Toggle(label, isOn: $field.isOn)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Text(label)
            }
        }
    }
}
