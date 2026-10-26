// The converter's look, taken from its icon: an indigo stage, and the red and cyan controller halves around a screen that becomes the icon's Mac
// window when a game has been converted. The colours (each with its light, dark and Increase Contrast values), the tones of state, the stage type,
// spacing, motion, the split view's column widths, the environment keys and the shared container shapes
import AppKit
import SwiftUI

// MARK: - Colour helper

/// One value of a custom colour: an sRGB hex colour and its opacity
private struct Swatch: ExpressibleByIntegerLiteral, Sendable {
    let hex: UInt32
    let alpha: CGFloat

    init(integerLiteral value: UInt32) { self.init(value, alpha: 1) }

    init(_ hex: UInt32, alpha: CGFloat) { self.hex = hex; self.alpha = alpha }

    static func white(_ alpha: CGFloat) -> Swatch { Swatch(0xFFFFFF, alpha: alpha) }
    static func black(_ alpha: CGFloat) -> Swatch { Swatch(0x000000, alpha: alpha) }
    static let clear = Swatch(0x000000, alpha: 0)

    var color: NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

private extension Color {
    /// A colour for the light and dark appearances, and their Increase Contrast variants
    init(light: Swatch, dark: Swatch, lightHigh: Swatch, darkHigh: Swatch) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: dark.color
            case .accessibilityHighContrastAqua: lightHigh.color
            case .accessibilityHighContrastDarkAqua: darkHigh.color
            default: light.color
            }
        })
    }

    /// The same in both appearances, with another value under Increase Contrast
    init(regular: Swatch, high: Swatch) { self.init(light: regular, dark: regular, lightHigh: high, darkHigh: high) }
}

// MARK: - The stage

/// The stage band's colours. The band is a picture like the icon: its gradient follows the window's appearance, and turns flat and darker under
/// Increase Contrast. The tones are brightened for the chip fill (6.2:1 or more there), so they are used in chips and segments only
enum StagePalette {
    static let top = Color(light: 0x4C4DC6, dark: 0x4344B0, lightHigh: 0x221E5C, darkHigh: 0x17143F)
    static let bottom = Color(light: 0x221E5C, dark: 0x1A1748, lightHigh: 0x221E5C, darkHigh: 0x17143F)
    static let glow = Color(light: .white(0.18), dark: .white(0.12), lightHigh: .clear, darkHigh: .clear)
    static let ink = Color.white
    static let inkSecondary = Color(regular: .white(0.85), high: .white(1))
    static let chipFill = Color(regular: .black(0.25), high: .black(0.5))
    static let chipStroke = Color(regular: .clear, high: .white(0.6))
    static let track = Color(regular: .white(0.22), high: .white(0.4))
    static let brand = Color(regular: 0xE2E0FF, high: 0xFFFFFF)
    static let info = Color(regular: 0xC9E4FF, high: 0xFFFFFF)
    static let success = Color(regular: 0xB2F7C1, high: 0xFFFFFF)
    static let warning = Color(regular: 0xFFDDA6, high: 0xFFFFFF)
    static let failure = Color(regular: 0xFFC2BD, high: 0xFFFFFF)
}

/// The console's colours (make_icon.swift), drawn as art in the window's appearance
enum ConsolePalette {
    // Each half is a gradient from its colour to a darker copy, as on the icon
    static let joyRed = Gradient(colors: [Color(light: 0xFF5D4B, dark: 0xE5301F, lightHigh: 0xD1200F, darkHigh: 0xFF6E5E),
                                          Color(light: 0xE5301F, dark: 0xB5220F, lightHigh: 0xD1200F, darkHigh: 0xFF6E5E)])
    static let joyCyan = Gradient(colors: [Color(light: 0x34CBF2, dark: 0x0796C8, lightHigh: 0x0077A8, darkHigh: 0x5AD6F7),
                                           Color(light: 0x0796C8, dark: 0x05729A, lightHigh: 0x0077A8, darkHigh: 0x5AD6F7)])
    static let joyOff = Gradient(colors: [Color(light: 0x9A98C4, dark: 0x6E6C9C, lightHigh: 0x6E6C9C, darkHigh: 0x9A98C4),
                                          Color(light: 0x6E6C9C, dark: 0x4F4D78, lightHigh: 0x6E6C9C, darkHigh: 0x9A98C4)])
    static let stick = Color(regular: Swatch(0x1E2128, alpha: 0.9), high: 0x000000)
    static let stickCap = Color(light: 0x3A3F49, dark: 0x3A3F49, lightHigh: 0x000000, darkHigh: 0x1C1C1E)
    static let bezel = Color(regular: 0x16151F, high: 0x000000)
    static let screenOff = Color(regular: 0x262538, high: 0x000000)   // a Switch screen with nothing on it
    static let sky = Gradient(colors: [Color(light: 0x58B8FF, dark: 0x3E9BE8, lightHigh: 0x1F7FD6, darkHigh: 0x3E9BE8),
                                       Color(light: 0xBFE7FF, dark: 0x8FCDF5, lightHigh: 0x9AD2F7, darkHigh: 0x8FCDF5)])
    static let macWindowFill = Color(light: 0xF4F5F7, dark: 0x2B2B2F, lightHigh: 0xFFFFFF, darkHigh: 0x1C1C1E)
    static let titleBar = Gradient(colors: [Color(light: 0xF7F7F9, dark: 0x3A3A3E, lightHigh: 0xFFFFFF, darkHigh: 0x000000),
                                            Color(light: 0xE3E4E8, dark: 0x2E2E32, lightHigh: 0xE0E0E0, darkHigh: 0x1C1C1E)])
    static let trafficLights = [Color(red: 1, green: 0x5F / 255, blue: 0x57 / 255), Color(red: 0xFE / 255, green: 0xBC / 255, blue: 0x2E / 255),
                                Color(red: 0x28 / 255, green: 0xC8 / 255, blue: 0x40 / 255)]
    static let trafficLightStroke = Color(light: .clear, dark: .clear, lightHigh: .black(0.5), darkHigh: .white(0.5))
    static let stageInk = Color(red: 0x22 / 255, green: 0x1E / 255, blue: 0x5C / 255)   // a symbol on the sky
}

// MARK: - Tones

/// What a piece of state means. `text` is for words and small marks (5.5:1 or more on windows), `glyph` for state symbols, `stage` for marks on
/// the stage band
enum Tone: Sendable {
    case neutral, brand, info, success, warning, failure

    var text: Color {
        switch self {
        case .neutral: ToneText.neutral
        case .brand: ToneText.brand
        case .info: ToneText.info
        case .success: ToneText.success
        case .warning: ToneText.warning
        case .failure: ToneText.failure
        }
    }

    var glyph: Color {
        switch self {
        case .neutral: .secondary
        case .brand: ToneText.brandGlyph
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }

    var stage: Color {
        switch self {
        case .neutral: .white
        case .brand: StagePalette.brand
        case .info: StagePalette.info
        case .success: StagePalette.success
        case .warning: StagePalette.warning
        case .failure: StagePalette.failure
        }
    }

    var symbol: String {
        switch self {
        case .neutral, .info: "info.circle.fill"
        case .brand: "sparkles"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }
}

private enum ToneText {
    static let neutral = Color(light: 0x55555E, dark: 0xB8B8C2, lightHigh: 0x2E2E35, darkHigh: 0xE2E2E8)
    static let brand = Color(light: 0x4740BE, dark: 0xABA7FF, lightHigh: 0x2F2A8F, darkHigh: 0xCFCCFF)
    static let brandGlyph = Color(light: 0x5D5ED8, dark: 0x8F8CF5, lightHigh: 0x3B37A8, darkHigh: 0xB5B2FF)
    static let info = Color(light: 0x0A58B8, dark: 0x71B7FF, lightHigh: 0x073F85, darkHigh: 0xA6D1FF)
    static let success = Color(light: 0x136C2E, dark: 0x5DD87A, lightHigh: 0x0B4F20, darkHigh: 0x8AF0A0)
    static let warning = Color(light: 0x924700, dark: 0xF5A742, lightHigh: 0x6B3300, darkHigh: 0xFFC97A)
    static let failure = Color(light: 0xB01F17, dark: 0xFF8C82, lightHigh: 0x8A140E, darkHigh: 0xFFB3AD)
}

// MARK: - Type, spacing, motion

extension Font {
    static let stageTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let stageFigure = Font.system(.title, design: .rounded, weight: .semibold).monospacedDigit()
    static let mono = Font.system(.callout, design: .monospaced)
    static let monoSmall = Font.system(.subheadline, design: .monospaced)
}

enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 28
    static let page: CGFloat = 20
}

/// The app's animations. Under Reduce Motion views use `fade` (or none) in place of the others: `motion(_:value:fades:)` does that
enum Motion {
    static let dock = Animation.spring(duration: 0.5, bounce: 0.25)
    static let respond = Animation.spring(duration: 0.35, bounce: 0.3)
    static let fill = Animation.linear(duration: 0.3)
    static let hover = Animation.easeOut(duration: 0.12)
    static let fade = Animation.easeInOut(duration: 0.2)
}

extension View {
    /// `animation` when `value` changes; under Reduce Motion a fade instead, or nothing when `fades` is false
    func motion<V: Equatable>(_ animation: Animation, value: V, fades: Bool = true) -> some View {
        modifier(MotionModifier(animation: animation, value: value, fades: fades))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    let fades: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? (fades ? Motion.fade : nil) : animation, value: value)
    }
}

// MARK: - Columns

/// The widest sidebar and inspector, and the narrowest window: room for twice the widest sidebar and the widest inspector beside a column whose
/// content has no minimum width (`splitColumnContent()`), with 20 points to spare for the dividers and rounding
enum ColumnWidth {
    static let sidebarMax: CGFloat = 260
    static let inspectorMax: CGFloat = 340
    static let windowMin: CGFloat = 2 * sidebarMax + inspectorMax + 20
}

extension View {
    /// The content of a split view's column, with an explicit zero minimum width (`maxWidth: .infinity` alone keeps the content's own minimum).
    /// SwiftUI (macOS 27) adds the floating sidebar's and inspector's widths to the minimum width of the column under them, while the split view
    /// gives that column only the width beside the sidebar. Once the content's minimum, twice the sidebar and the inspector add up to more than the
    /// window's width, the split views resize each other within one layout pass until AppKit raises "more Update Constraints in Window passes than
    /// there are views" and the app ends
    func splitColumnContent() -> some View { frame(minWidth: 0, maxWidth: .infinity) }
}

// MARK: - Environment

extension EnvironmentValues {
    /// Game folders are being dragged over the window (MainWindow's drop target)
    var dropTargeted: Bool {
        get { self[DropTargetedKey.self] }
        set { self[DropTargetedKey.self] = newValue }
    }

    /// The view is on the stage band: chips and bars draw light on indigo
    var onStage: Bool {
        get { self[OnStageKey.self] }
        set { self[OnStageKey.self] = newValue }
    }

    /// The window's own colour scheme inside the stage band, which forces the dark scheme on its contents: the console art resolves its colours
    /// against the window instead
    var windowColorScheme: ColorScheme? {
        get { self[WindowColorSchemeKey.self] }
        set { self[WindowColorSchemeKey.self] = newValue }
    }
}

// Written out instead of @Entry, whose macro plugin only Xcode's toolchain has (the open-source toolchains build this package too)
private struct DropTargetedKey: EnvironmentKey { static let defaultValue = false }
private struct OnStageKey: EnvironmentKey { static let defaultValue = false }
private struct WindowColorSchemeKey: EnvironmentKey { static let defaultValue: ColorScheme? = nil }

// MARK: - Shapes

extension Shape where Self == ConcentricRectangle {
    /// Notices, the folder guide, the stages and log containers, the transcript container
    static var card: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true) }

    /// The diff container and the notices in sheets
    static var sheetCard: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: 10), isUniform: true) }
}
