import SwiftUI

/// Makes or changes a shelf: a saved set of rules, with a live count of the books it would hold.
struct ShelfEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var shelf: Shelf

    private var isNew: Bool { !app.store.companion.shelves.contains { $0.id == shelf.id } }

    var body: some View {
        let books = app.store.books
        let count = books.count(where: shelf.matches)
        let tags = Array(Set(books.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $shelf.name, prompt: Text("For example: Unread sci-fi"))
                Section {
                    TextField("Words", text: $shelf.search, prompt: Text("Title, author, series, tag or note"))
                    Picker("Status", selection: $shelf.status) {
                        Text("Any").tag(ReadingStatus?.none)
                        ForEach(ReadingStatus.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    Picker("Rating", selection: $shelf.minimumRating) {
                        Text("Any").tag(0)
                        ForEach(1...5, id: \.self) { stars in
                            Text(String(repeating: "★", count: stars) + (stars < 5 ? " or more" : "")).tag(stars)
                        }
                    }
                    if !tags.isEmpty {
                        Picker("Tag", selection: $shelf.tag) {
                            Text("Any").tag(String?.none)
                            ForEach(tags, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    }
                    Toggle("Favourites only", isOn: $shelf.favouritesOnly)
                } header: {
                    Text("Books on this shelf")
                } footer: {
                    Text("\(count) book\(count == 1 ? "" : "s") match. Books join and leave the shelf by themselves as they change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: count)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !isNew {
                    Button("Delete Shelf", role: .destructive) {
                        withAnimation(.snappy) {
                            app.store.companion.shelves.removeAll { $0.id == shelf.id }
                            if app.sidebar == .shelf(shelf.id) { app.sidebar = .all }
                        }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Shelf" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(shelf.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 440, height: 420)
    }

    private func save() {
        shelf.name = shelf.name.trimmingCharacters(in: .whitespaces)
        withAnimation(.snappy) {
            if let index = app.store.companion.shelves.firstIndex(where: { $0.id == shelf.id }) {
                app.store.companion.shelves[index] = shelf
            } else {
                app.store.companion.shelves.append(shelf)
            }
            app.search = ""
            app.sidebar = .shelf(shelf.id)
        }
        dismiss()
    }
}
