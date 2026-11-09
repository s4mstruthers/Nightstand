import SwiftUI

// MARK: - Cover

struct CoverView: View {
    @Environment(AppModel.self) private var app
    let book: Book
    var maxPixel = 520
    var cornerRadius: CGFloat = 5
    @State private var image: NSImage?

    private var key: String { "\(book.id)-\(book.coverVersion)-\(maxPixel)" }

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image = image ?? CoverCache.shared.cached(key) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    PlaceholderCover(book: book)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
            }
            .task(id: key) {
                guard book.hasCover else {
                    image = nil
                    return
                }
                let loaded = await CoverCache.shared.image(at: app.store.coverURL(for: book), key: key,
                                                           maxPixel: maxPixel)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

/// A generated cover for books that have none: a colour derived from the title, with the title set on it.
struct PlaceholderCover: View {
    let book: Book

    private var hue: Double {
        Double(book.title.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55),
                                        Color(hue: hue, saturation: 0.6, brightness: 0.3)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(.black.opacity(0.18)).frame(width: max(2, width * 0.045))
                VStack(alignment: .leading, spacing: width * 0.05) {
                    Text(book.title)
                        .font(.system(size: max(6, width * 0.115), weight: .semibold, design: .serif))
                        .lineLimit(5)
                    Spacer(minLength: 0)
                    Text(book.authorText)
                        .font(.system(size: max(5, width * 0.07), weight: .medium))
                        .opacity(0.8)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.leading, width * 0.13)
                .padding([.trailing, .vertical], width * 0.1)
                .opacity(width < 40 ? 0 : 1)
            }
        }
    }
}

// MARK: - Rating

struct StarRating: View {
    @Binding var rating: Int
    var size: CGFloat = 18
    var interactive = true
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: size * 0.18) {
            ForEach(1...5, id: \.self) { star in
                let filled = star <= (hovered ?? rating)
                Image(systemName: filled ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(filled ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.quaternary))
                    .scaleEffect(interactive && hovered == star ? 1.2 : 1)
                    .symbolEffect(.bounce, value: interactive && rating == star)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard interactive else { return }
                        hovered = inside ? star : (hovered == star ? nil : hovered)
                    }
                    .onTapGesture {
                        guard interactive else { return }
                        rating = rating == star ? 0 : star
                    }
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0.4), value: hovered)
        .animation(.spring(duration: 0.25, bounce: 0.4), value: rating)
        .allowsHitTesting(interactive)
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) of 5 stars")
    }
}

// MARK: - Flow layout

/// Lays children out in rows, wrapping when a row is full. Used for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = arrange(subviews, in: width)
        return CGSize(width: proposal.width ?? (frames.map(\.maxX).max() ?? 0),
                      height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, in: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
