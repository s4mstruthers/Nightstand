import SwiftUI

/// Books added more than once, a group at a time: pick the copy to keep and the rest are merged into it.
struct DuplicatesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The copy to keep in each group, by the id of the group's first book.
    @State private var keep: [UUID: UUID] = [:]
    @State private var merged = 0

    var body: some View {
        let groups = Insights.duplicates(app.store.books)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicates")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                Text(groups.isEmpty
                     ? (merged > 0 ? "All merged. Each book is in your library once." : "No book is in your library twice.")
                     : "These look like the same book added more than once. Choose the copy to keep: its file stays, and ratings, notes, highlights and details from the others are carried over before they go to the Trash.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(groups, id: \.[0].id) { group in
                        groupCard(group)
                            .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.95).combined(with: .opacity)))
                    }
                }
                .padding(20)
                .animation(.snappy, value: groups.map { $0.map(\.id) })
            }
            Divider()
            HStack {
                if groups.count > 1 {
                    Button("Merge All \(groups.count)") {
                        for group in groups { merge(group) }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 640, height: 560)
    }

    private func chosen(in group: [Book]) -> UUID {
        keep[group[0].id] ?? group[0].id
    }

    private func merge(_ group: [Book]) {
        let keepID = chosen(in: group)
        withAnimation(.snappy) {
            app.store.merge(keeping: keepID, removing: group.map(\.id).filter { $0 != keepID })
            merged += 1
        }
    }

    private func groupCard(_ group: [Book]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(group) { book in
                let selected = chosen(in: group) == book.id
                Button {
                    withAnimation(.snappy(duration: 0.2)) { keep[group[0].id] = book.id }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            .contentTransition(.symbolEffect(.replace))
                        CoverView(book: book, maxPixel: 120, cornerRadius: 3)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title).lineLimit(1)
                            Text(details(book))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if selected {
                            Text("Keep").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Merge Into the Chosen One") { merge(group) }
                    .controlSize(.small)
            }
        }
        .card(padding: 14)
    }

    private func details(_ book: Book) -> String {
        var parts = [book.authorText]
        parts.append(book.hasFile
                     ? "\(book.format.label), \(ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))"
                     : "No file")
        if book.status != .unread { parts.append(book.status.label) }
        if book.rating > 0 { parts.append(String(repeating: "★", count: book.rating)) }
        parts.append("added \(book.dateAdded.formatted(date: .abbreviated, time: .omitted))")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
