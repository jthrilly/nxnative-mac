// What a drag of game folders over the window shows: an accent outline concentric with the window's corners, and a glass card over the page that
// says what the drop does. Neither takes the drop: the window's drop destination does
import SwiftUI

struct DropOverlay: View {
    var body: some View {
        ZStack {
            ConcentricRectangle().fill(Color.accentColor.opacity(0.06))
            ConcentricRectangle().stroke(Color.accentColor, lineWidth: 3).padding(6)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}

struct DropCard: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Space.m) {
            ConsoleGlyph(symbol: "square.and.arrow.down")
            Text("Drop to Add Game Folders").font(.title2.weight(.semibold))
            Text("Each folder becomes a game on the Convert page.").foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.xl)
        .modifier(CardSurface(reduceTransparency: reduceTransparency, reduceMotion: reduceMotion))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

private struct CardSurface: ViewModifier {
    let reduceTransparency: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 24))
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.separator) }
                .transition(.identity)
        } else {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                // Under Reduce Motion the glass does not materialize: the glass card only fades, by its default transition
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
        }
    }
}
