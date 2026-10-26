// The icon's console as art: two controller halves around a square screen, which is a Switch screen until the game is a Mac app and then docks into
// the icon's Mac window; the small console glyph of the drop card; and the blank screen of a folder with no game on it
import SwiftUI

/// The icon's console: two controller halves around a square screen. The screen is a Switch screen (a dark bezel around the content) until the
/// game is a Mac app, then the icon's Mac window (a light frame, a title bar and its traffic lights): turning `window` on docks it. `height` is the
/// screen's; the console is 1.736 times as wide. The content fills the frame it is given (GameArtwork with `.screen`)
struct ConsoleFrame<Screen: View>: View {
    enum Halves: Equatable { case attached, detached, unplugged }

    private let height: CGFloat
    private let window: Bool
    private let halves: Halves
    private let detail: Bool
    private let screen: Screen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowColorScheme) private var windowColorScheme
    @Environment(\.colorScheme) private var colorScheme
    @State private var docked = 0

    init(height: CGFloat, window: Bool = false, halves: Halves = .attached, detail: Bool = true, @ViewBuilder screen: () -> Screen) {
        self.height = height; self.window = window; self.halves = halves; self.detail = detail; self.screen = screen()
    }

    var body: some View {
        // Under Reduce Motion the halves never move: only colours and the screen change, as crossfades
        let halves = reduceMotion && self.halves == .detached ? .attached : self.halves
        HStack(spacing: 0.033 * height) {
            half(leading: true, halves)
            ConsoleScreen(height: height, window: window, crossfade: reduceMotion, content: screen)
            half(leading: false, halves)
        }
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.25), radius: 0.04 * height, y: 0.03 * height)
        .animation(reduceMotion ? Motion.fade : Motion.respond, value: halves)
        .onChange(of: window) { _, isWindow in if isWindow && !reduceMotion { docked += 1 } }
        // On the stage band the scheme is forced dark: the art keeps the window's
        .environment(\.colorScheme, windowColorScheme ?? colorScheme)
        .accessibilityHidden(true)
    }

    private func half(leading: Bool, _ halves: Halves) -> some View {
        let side: CGFloat = leading ? -1 : 1
        return ConsoleHalf(leading: leading, height: height, unplugged: halves == .unplugged, detail: detail)
            .offset(x: halves == .detached ? side * 0.06 * height : 0)
            .keyframeAnimator(initialValue: 0.0, trigger: docked) { content, nudge in
                content.offset(x: side * nudge)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(6, duration: 0.15)
                    SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                }
            }
    }
}

private struct ConsoleHalf: View {
    let leading: Bool
    let height: CGFloat
    let unplugged: Bool
    let detail: Bool

    var body: some View {
        let width = 0.335 * height, outer = min(0.92 * width, height / 2), inner = height * 16 / 364
        let shape = UnevenRoundedRectangle(topLeadingRadius: leading ? outer : inner, bottomLeadingRadius: leading ? outer : inner,
                                           bottomTrailingRadius: leading ? inner : outer, topTrailingRadius: leading ? inner : outer, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(gradient: leading ? ConsolePalette.joyRed : ConsolePalette.joyCyan, startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(gradient: ConsolePalette.joyOff, startPoint: .top, endPoint: .bottom)).opacity(unplugged ? 1 : 0)
            if detail { controls }
        }
        .frame(width: width, height: height)
    }

    // A stick and four buttons, at the icon's places (in units of a 364-point half)
    private var controls: some View {
        Canvas { context, size in
            let unit = size.height / 364, x = size.width / 2 + (leading ? 4 : -4) * unit
            let stickY = size.height * (leading ? 0.3 : 0.62), buttonsY = size.height * (leading ? 0.62 : 0.3)
            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: cx - r * unit, y: cy - r * unit, width: 2 * r * unit, height: 2 * r * unit))
            }
            context.fill(circle(x, stickY, 37), with: .color(ConsolePalette.stick))
            context.fill(circle(x, stickY, 27), with: .color(ConsolePalette.stickCap))
            for (dx, dy) in [(0.0, -1.0), (1, 0), (0, 1), (-1, 0)] {
                context.fill(circle(x + dx * 29 * unit, buttonsY + dy * 29 * unit, 12.5), with: .color(ConsolePalette.stick))
            }
        }
    }
}

private struct ConsoleScreen<Content: View>: View {
    let height: CGFloat
    let window: Bool
    let crossfade: Bool
    let content: Content

    var body: some View {
        if crossfade {
            ZStack {
                face(window: false).opacity(window ? 0 : 1)
                face(window: true).opacity(window ? 1 : 0)
            }
            .animation(Motion.fade, value: window)
        } else {
            face(window: window).animation(Motion.dock, value: window)
        }
    }

    private func face(window: Bool) -> some View {
        let h = height, bar = 0.15 * height, inset = window ? 0 : 0.05 * height
        let shape = RoundedRectangle(cornerRadius: (window ? 34 : 22) / 364 * h, style: .continuous)
        return ZStack(alignment: .top) {
            Rectangle().fill(window ? ConsolePalette.macWindowFill : ConsolePalette.bezel)
            content
                .frame(width: h - 2 * inset, height: window ? h - bar : h - 2 * inset)
                .clipShape(RoundedRectangle(cornerRadius: window ? 0 : 0.025 * h, style: .continuous))
                .offset(y: window ? bar : inset)
            TitleBar(height: bar, shown: window, pops: !crossfade)
        }
        .frame(width: h, height: h)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.black.opacity(0.18), lineWidth: 1) }
    }
}

private struct TitleBar: View {
    let height: CGFloat
    let shown: Bool
    let pops: Bool

    var body: some View {
        let h = height / 0.15, light = 0.058 * h
        HStack(spacing: 0.03 * h) {
            ForEach(ConsolePalette.trafficLights.indices, id: \.self) { index in
                Circle().fill(ConsolePalette.trafficLights[index])
                    .overlay { Circle().strokeBorder(ConsolePalette.trafficLightStroke, lineWidth: 0.5) }
                    .frame(width: light, height: light)
                    .scaleEffect(shown || !pops ? 1 : 0.3)
                    .opacity(shown ? 1 : 0)
                    .animation(pops ? .spring(duration: 0.35, bounce: 0.5).delay(0.25 + 0.045 * Double(index)) : nil, value: shown)
            }
        }
        .padding(.leading, 0.065 * h)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(LinearGradient(gradient: ConsolePalette.titleBar, startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.1)).frame(height: 0.5) }
        .offset(y: shown ? 0 : -height)
    }
}

/// The console drawn small, without sticks and buttons, with a symbol on its dark screen: the drop card's picture
struct ConsoleGlyph: View {
    let symbol: String
    private static let height: CGFloat = 60

    var body: some View {
        ConsoleFrame(height: Self.height, detail: false) {
            ZStack {
                ConsolePalette.screenOff
                Image(systemName: symbol)
                    .font(.system(size: Self.height * 0.34, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
    }
}

/// A console screen with no game on it: a dashed outline and a symbol on the dark screen, or, `lit`, a solid outline on the icon's sky (a drop
/// target answering a drag). The symbol bounces when it lights, unless Reduce Motion is on
struct BlankScreen: View {
    private let symbol: String
    private let height: CGFloat
    private let symbolSize: CGFloat
    private let lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounces = 0

    init(symbol: String, height: CGFloat, symbolSize: CGFloat, lit: Bool = false) {
        self.symbol = symbol; self.height = height; self.symbolSize = symbolSize; self.lit = lit
    }

    var body: some View {
        let scale = height / 140, ink = lit ? ConsolePalette.stageInk.opacity(0.6) : Color.white.opacity(0.45)
        ZStack {
            ConsolePalette.screenOff
            LinearGradient(gradient: ConsolePalette.sky, startPoint: .top, endPoint: .bottom).opacity(lit ? 1 : 0)
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .strokeBorder(ink, style: StrokeStyle(lineWidth: 2, dash: lit ? [] : [7, 5]))
                .padding(14 * scale)
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(lit ? ConsolePalette.stageInk : Color.white.opacity(0.9))
                .symbolEffect(.bounce, value: bounces)
        }
        .onChange(of: lit) { _, now in if now && !reduceMotion { bounces += 1 } }
    }
}
