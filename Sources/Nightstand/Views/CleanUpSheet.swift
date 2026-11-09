import SwiftUI

/// Shows what the clean-up would change, so nothing is rewritten without being seen first.
struct CleanUpSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let proposals: [MetadataCleaner.Proposal]
    @State private var accepted: Set<UUID>

    init(proposals: [MetadataCleaner.Proposal]) {
        self.proposals = proposals
        _accepted = State(initialValue: Set(proposals.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean Up Details")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                Text("Nightstand found tidier titles, author names and series for \(proposals.count) book\(proposals.count == 1 ? "" : "s"). Untick any you want to leave alone.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()
            List(proposals) { proposal in
                HStack(alignment: .top, spacing: 12) {
                    Toggle("", isOn: Binding {
                        accepted.contains(proposal.id)
                    } set: { on in
                        if on { accepted.insert(proposal.id) } else { accepted.remove(proposal.id) }
                    })
                    .labelsHidden()
                    CoverView(book: proposal.before, maxPixel: 120, cornerRadius: 3)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(proposal.changes) { change in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(change.label.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                Text(change.old)
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                Text(change.new)
                            }
                            .font(.callout)
                        }
                    }
                    .opacity(accepted.contains(proposal.id) ? 1 : 0.4)
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button(accepted.count == proposals.count ? "Deselect All" : "Select All") {
                    accepted = accepted.count == proposals.count ? [] : Set(proposals.map(\.id))
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply to \(accepted.count) Book\(accepted.count == 1 ? "" : "s")") {
                    for proposal in proposals where accepted.contains(proposal.id) {
                        app.store.update(proposal.after)
                    }
                    app.activity.flash("Cleaned up \(accepted.count) book\(accepted.count == 1 ? "" : "s")")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(accepted.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 620, height: 600)
    }
}
