// The Library's games: a grid of the game apps and Xcode projects (their icons, names and how their nxnative compares with the checkout's HEAD), driven
// by the mouse, the keyboard and VoiceOver; an Xcode project's art carries an iPhone badge
import ConverterCore
import SwiftUI

struct LibraryGrid: View {
    @Environment(AppModel.self) private var model
    let entries: [LibraryEntry]
    @Binding var selection: URL?
    @State private var columns = 1
    @FocusState private var focused: Bool

    private static let spacing: CGFloat = 20
    private static let minimumTile: CGFloat = 148

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimumTile, maximum: 188), spacing: Self.spacing, alignment: .top)],
                          spacing: Self.spacing) {
                    ForEach(entries) { entry in
                        LibraryTile(entry: entry, selected: entry.id == selection, emphasized: focused) {
                            selection = entry.id
                            focused = true
                        }
                        .id(entry.id)
                    }
                }
                .padding(Space.page)
            }
            // The adaptive grid's column count, for the up and down arrows
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                columns = max(1, Int((width - 2 * Space.page + Self.spacing) / (Self.minimumTile + Self.spacing)))
            }
            // The system focus ring shows while no tile is selected; once one is, its emphasized selection shows the focus, as in Finder
            .focusable()
            .focusEffectDisabled(selection != nil)
            .focused($focused)
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in key(press.key, proxy: proxy) }
        }
    }

    private func key(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let first = entries.first else { return .ignored }
        guard let current = entries.firstIndex(where: { $0.id == selection }) else {
            if key == .return { return .ignored }
            selection = first.id
            proxy.scrollTo(first.id)
            return .handled
        }
        let next: Int
        switch key {
        case .return:
            LibraryAction.play.perform(on: entries[current], in: model)
            return .handled
        case .leftArrow: next = current - 1
        case .rightArrow: next = current + 1
        case .upArrow: next = current - columns
        case .downArrow: next = current + columns
        default: return .ignored
        }
        guard entries.indices.contains(next) else { return .handled }
        selection = entries[next].id
        proxy.scrollTo(entries[next].id)
        return .handled
    }
}

/// How a game app's nxnative compares with the checkout's HEAD, in words
private struct BuildStatus {
    let text: String
    let color: Color
    let help: String?

    init(entry: LibraryEntry, behind: Int?) {
        if entry.commit == nil {
            (text, color, help) = ("Unknown nxnative version", Tone.warning.text, nil)
        } else if let behind, behind > 0 {
            (text, color) = ("\(behind) commit\(behind == 1 ? "" : "s") behind", Tone.info.text)
            help = "nxnative has changed since this game was built: Rebuild makes it again with the current version"
        } else if behind == 0 {
            (text, color, help) = ("Up to date", .secondary, nil)
        } else {
            (text, color, help) = ("nxnative \(entry.commit?.prefix(9) ?? "")", .secondary, nil)
        }
    }
}

private struct LibraryTile: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    let entry: LibraryEntry
    let selected: Bool
    /// The grid has keyboard focus: the selected name takes the accent colour
    let emphasized: Bool
    let select: () -> Void
    @State private var hovering = false

    private static let icon: CGFloat = 96
    /// The selection backdrop's inset around the icon: its radius is the icon's plus this, so the two stay concentric
    private static let inset: CGFloat = 6

    var body: some View {
        let status = BuildStatus(entry: entry, behind: entry.commit.flatMap { model.commitsBehind[$0] })
        VStack(spacing: Space.xs) {
            GameArtwork(entry.artwork, name: entry.app.name, size: Self.icon, shape: entry.artworkShape)
                .overlay(alignment: .bottomTrailing) { if entry.isXcodeProject { badge } }
                .overlay { if hovering { play } }
                .padding(Self.inset)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: entry.artworkShape.radius(for: Self.icon) + Self.inset, style: .continuous)
                            .fill(.quaternary)
                    }
                }
            Text(entry.app.name)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(selected && emphasized ? Color.white : Color.primary)
                .padding(.horizontal, Space.xs)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    }
                }
                .frame(maxWidth: Self.icon + 2 * Self.inset)
                .help(entry.app.name)
            Text(status.text)
                .font(.subheadline)
                .foregroundStyle(status.color)
                .lineLimit(1)
                .help(status.help ?? "")
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .simultaneousGesture(TapGesture().onEnded { select() })
        .onTapGesture(count: 2) { LibraryAction.play.perform(on: entry, in: model) }
        .contextMenu { LibraryEntryMenuItems(entry: entry) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isXcodeProject ? "\(entry.app.name), \(entry.kindText), \(status.text)" : "\(entry.app.name), \(status.text)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityActions {
            ForEach(Self.voiceOverActions.filter { $0.applies(to: entry) && $0.isEnabled(for: entry, files: window.libraryFiles) }, id: \.self) { action in
                Button(action.title(for: entry)) { action.perform(on: entry, in: model) }
            }
        }
    }

    private static let voiceOverActions: [LibraryAction] = [.play, .showInFinder, .rebuild]

    /// An Xcode project's mark: it runs on an iPhone or iPad, from Xcode
    private var badge: some View {
        Image(systemName: "iphone")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.tint, in: .circle)
            .offset(x: 4, y: 4)
            .help("An iOS Xcode project: Open in Xcode builds and installs it on your iPhone or iPad")
            .accessibilityHidden(true)
    }

    /// The hover Play button: glass floating over the icon, which exists only while the pointer is on the tile
    private var play: some View {
        GlassEffectContainer {
            Button(LibraryAction.play.title(for: entry), systemImage: LibraryAction.play.symbol(for: entry)) { LibraryAction.play.perform(on: entry, in: model) }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help(LibraryAction.play.help(for: entry, files: window.libraryFiles))
        }
        .accessibilityHidden(true)
    }
}
