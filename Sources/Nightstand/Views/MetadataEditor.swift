import SwiftUI

struct MetadataEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// The book as it was when the sheet opened.
    private let original: Book
    @State private var draft: Book
    @State private var authors: String
    @State private var tags: String
    @State private var seriesIndex: String

    init(book: Book) {
        original = book
        _draft = State(initialValue: book)
        _authors = State(initialValue: book.authors.joined(separator: ", "))
        _tags = State(initialValue: book.tags.joined(separator: ", "))
        _seriesIndex = State(initialValue: book.seriesIndex.map(Book.formatIndex) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    // Read the live book so a cover change shows immediately.
                    CoverView(book: app.store.book(draft.id) ?? draft, maxPixel: 700, cornerRadius: 6)
                        .frame(width: 130)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                    Button("Change Cover…") { app.chooseCover(for: draft.id) }
                        .controlSize(.small)
                }
                .padding(.top, 20)
                .padding(.leading, 20)

                Form {
                    Section {
                        TextField("Title", text: $draft.title)
                        TextField("Authors", text: $authors, prompt: Text("Separate with commas"))
                    }
                    Section {
                        TextField("Series", text: optional(\.series))
                        TextField("Number in Series", text: $seriesIndex)
                        TextField("Tags", text: $tags, prompt: Text("Separate with commas"))
                    }
                    Section {
                        TextField("Publisher", text: optional(\.publisher))
                        TextField("Published", text: optional(\.published), prompt: Text("YYYY-MM-DD"))
                        TextField("Language", text: optional(\.language))
                        TextField("ISBN", text: optional(\.isbn))
                    }
                    Section("Description") {
                        TextEditor(text: optional(\.summary))
                            .frame(height: 90)
                            .labelsHidden()
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }

            Divider()
            HStack {
                if !draft.format.isEPUBBased {
                    Text("Details are kept in Nightstand; \(draft.format.label) files are sent unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 640, height: 560)
    }

    private func optional(_ keyPath: WritableKeyPath<Book, String?>) -> Binding<String> {
        Binding {
            draft[keyPath: keyPath] ?? ""
        } set: { value in
            draft[keyPath: keyPath] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
    }

    private func save() {
        func list(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var edited = draft
        edited.title = edited.title.trimmingCharacters(in: .whitespaces)
        edited.authors = list(authors)
        edited.tags = list(tags)
        edited.series = edited.series?.trimmingCharacters(in: .whitespaces)
        edited.seriesIndex = Double(seriesIndex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        // Only what was changed here goes onto the book as it is now, so a rating, reading progress, cover or
        // an assistant's edit made while the sheet was open is kept.
        guard var book = app.store.book(draft.id) else { return dismiss() }
        func apply<Value: Equatable>(_ field: WritableKeyPath<Book, Value>) {
            if edited[keyPath: field] != original[keyPath: field] { book[keyPath: field] = edited[keyPath: field] }
        }
        apply(\.title)
        apply(\.authors)
        apply(\.tags)
        apply(\.series)
        apply(\.seriesIndex)
        apply(\.publisher)
        apply(\.published)
        apply(\.language)
        apply(\.isbn)
        apply(\.summary)
        app.store.update(book)
        dismiss()
    }
}
