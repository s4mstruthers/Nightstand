import SwiftUI

/// Shared look: cards, section headings, rings and the small motions used across pages.
enum Design {
    static let pageWidth: CGFloat = 980
    static let cardRadius: CGFloat = 14
    static let spring = Animation.spring(duration: 0.45, bounce: 0.25)
}

// MARK: - Page

/// A scrolling page with a large serif title, centred at a comfortable reading width.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold, design: .serif))
                    if let subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                content
            }
            .frame(maxWidth: Design.pageWidth, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 26)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { appeared = true } }
    }
}

struct SectionHeading<Trailing: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.tint).font(.headline)
            }
            Text(title).font(.system(.title2, design: .serif, weight: .semibold))
            Spacer()
            trailing
        }
    }
}

extension SectionHeading where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}

// MARK: - Cards

private struct CardModifier: ViewModifier {
    var padding: CGFloat
    var lifts: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(hovering && lifts ? 0.9 : 0.5))
            }
            .shadow(color: .black.opacity(hovering && lifts ? 0.14 : 0.05),
                    radius: hovering && lifts ? 14 : 4, y: hovering && lifts ? 7 : 2)
            .scaleEffect(hovering && lifts ? 1.012 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// A raised panel. `lifts` makes it rise slightly under the pointer, for cards that can be clicked.
    func card(padding: CGFloat = 16, lifts: Bool = false) -> some View {
        modifier(CardModifier(padding: padding, lifts: lifts))
    }

    /// Fades and slides the view in, a moment after the one before it.
    func staggered(_ index: Int) -> some View {
        modifier(Staggered(index: index))
    }
}

private struct Staggered: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.spring(duration: 0.5, bounce: 0.2).delay(Double(min(index, 12)) * 0.045)) {
                    shown = true
                }
            }
    }
}

// MARK: - Progress

/// A ring that fills as a book is read.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 4
    var tint: Color = .accentColor
    @State private var shown = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.15).delay(0.15)) { shown = progress } }
        .onChange(of: progress) { withAnimation(.spring(duration: 0.6)) { shown = progress } }
    }
}

/// A thin bar along the bottom of a cover showing how far through the book the reader is.
struct CoverProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.35))
                Capsule().fill(Color.accentColor).frame(width: max(4, proxy.size.width * progress))
            }
        }
        .frame(height: 4)
        .padding(5)
    }
}

/// A number with a caption, counting up when it first appears.
struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .contentTransition(.numericText())
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }
}

/// A heart that toggles a favourite, with a little bounce.
struct FavouriteButton: View {
    let isOn: Bool
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "heart.fill" : "heart")
                .font(.system(size: size))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.pink) : AnyShapeStyle(.tertiary))
                .symbolEffect(.bounce, value: isOn)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Remove from favourites" : "Add to favourites")
    }
}

/// A small tinted label, for counts and states.
struct Pill: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: Capsule())
    }
}
