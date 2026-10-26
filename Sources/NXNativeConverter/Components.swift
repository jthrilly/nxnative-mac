// The components every page builds from: chips and their rows, notices and the page status row, the stage band and its progress bar, the milestone
// track, path rows, number fields, the log controls and Copy, and the language picker; the view helpers on model types that several pages use; and the
// file checks views run in a task instead of in body
import AppKit
import ConverterCore
import SwiftUI

// MARK: - Chips

/// A short state in a capsule. Off the stage it is outlined in its tone's text colour; on the stage band it sits on the band's dark chip fill in the
/// tone's stage colour, stroked under Increase Contrast
struct StatusChip: View {
    private let text: String
    private let symbol: String?
    private let tone: Tone
    @Environment(\.onStage) private var onStage
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ text: String, symbol: String? = nil, tone: Tone = .neutral) {
        self.text = text; self.symbol = symbol; self.tone = tone
    }

    var body: some View {
        let high = contrast == .increased
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small).accessibilityHidden(true) }
            Text(text).lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(onStage ? tone.stage : tone.text)
        .padding(.horizontal, 7)
        .frame(minHeight: 18)
        .background { if onStage { Capsule().fill(StagePalette.chipFill) } }
        .overlay {
            if onStage {
                Capsule().strokeBorder(StagePalette.chipStroke, lineWidth: 1)
            } else {
                Capsule().strokeBorder(tone.text.opacity(high ? 0.9 : 0.35), lineWidth: high ? 1 : 0.75)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Chips in rows: as many as fit on a line, then the next line. A chip wider than the row is truncated
struct ChipRow: Layout {
    private let spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(rows.map(\.width).max() ?? 0, proposal.width ?? .infinity), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified), width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified), chip = min(size.width, width)
            if let last = rows.last, last.width + spacing + chip <= width {
                rows[rows.count - 1] = (last.items + [index], last.width + spacing + chip, max(last.height, size.height))
            } else {
                rows.append(([index], chip, size.height))
            }
        }
        return rows
    }
}

// MARK: - Notices

/// A message in a tone (a failure and its hints, a warning and its fixes, a fact worth knowing) on a neutral card, with actions beside a short message
/// or under a long one. The tone is on the symbol and the title; under Increase Contrast the card is stroked in it too. `messageLines` limits the
/// message, which is then the help in full. Without its card (`onCard: false`) it is a form row, as the form's section is the card
struct Notice<Actions: View>: View {
    private let tone: Tone
    private let title: String?
    private let message: String
    private let symbol: String
    private let messageLines: Int?
    private let onCard: Bool
    private let actions: Actions
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ tone: Tone, title: String? = nil, message: String, symbol: String? = nil, messageLines: Int? = nil, onCard: Bool = true,
         @ViewBuilder actions: () -> Actions) {
        self.tone = tone; self.title = title; self.message = message; self.symbol = symbol ?? tone.symbol; self.messageLines = messageLines
        self.onCard = onCard; self.actions = actions()
    }

    var body: some View {
        ActionsBesideOrUnder(label: label, actions: actions)
            .padding(onCard ? Space.m : 0)
            .background { if onCard { ConcentricRectangle.card.fill(.fill.quaternary) } }
            .overlay { if onCard && contrast == .increased { ConcentricRectangle.card.stroke(tone.glyph, lineWidth: 1) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title ?? message.split(separator: "\n").first.map(String.init) ?? message)
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol).foregroundStyle(tone.glyph).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.headline).foregroundStyle(tone.text) }
                Text(message)
                    .foregroundStyle(title == nil ? .primary : .secondary)
                    .lineLimit(messageLines)
                    .textSelection(.enabled)
                    .help(messageLines == nil ? "" : message)
            }
        }
    }
}

extension Notice where Actions == EmptyView {
    init(_ tone: Tone, title: String? = nil, message: String, symbol: String? = nil, messageLines: Int? = nil, onCard: Bool = true) {
        self.init(tone, title: title, message: message, symbol: symbol, messageLines: messageLines, onCard: onCard) { EmptyView() }
    }
}

/// The status at the top of the nxnative and Setup pages, as in Software Update: a large symbol in its tone (a spinner when the symbol is nil), a title
/// and a subtitle, with the actions it offers beside it, or under it when they do not fit
struct PageStatusRow<Actions: View>: View {
    private let title: String
    private let subtitle: String?
    private let symbol: String?
    private let tone: Tone
    private let hasActions: Bool
    private let actions: Actions

    init(_ title: String, subtitle: String? = nil, symbol: String?, tone: Tone, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tone: tone, hasActions: true, actions: actions)
    }

    fileprivate init(title: String, subtitle: String?, symbol: String?, tone: Tone, hasActions: Bool, actions: () -> Actions) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.tone = tone
        self.hasActions = hasActions; self.actions = actions()
    }

    var body: some View {
        if hasActions {
            ActionsBesideOrUnder(label: label, actions: actions)
        } else {
            label.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var label: some View {
        HStack(spacing: Space.m) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.title).foregroundStyle(tone.glyph)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, Space.xs)
    }
}

extension PageStatusRow where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: String?, tone: Tone) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tone: tone, hasActions: false) { EmptyView() }
    }
}

/// A label with its actions beside it, or under it and trailing when they do not fit
private struct ActionsBesideOrUnder<Label: View, Actions: View>: View {
    let label: Label
    let actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) {
                label
                Spacer(minLength: Space.m)
                HStack(spacing: Space.s) { actions }
            }
            VStack(alignment: .leading, spacing: Space.s) {
                label
                HStack(spacing: Space.s) { actions }.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

// MARK: - The stage band

/// The brand band at the top of a game's page and of the empty Convert page: the icon's indigo gradient with a soft glow at `glow`, full-bleed and
/// extended under the sidebar's glass. Its content is padded 24 × 20 and drawn in the dark scheme, with `onStage` set; the gradient keeps the window's
/// appearance, and turns flat under Increase Contrast
struct StageBand<Content: View>: View {
    private let height: CGFloat
    private let glow: UnitPoint
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(height: CGFloat, glow: UnitPoint = .center, @ViewBuilder content: () -> Content) {
        self.height = height; self.glow = glow; self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(StagePalette.ink)
            .environment(\.windowColorScheme, colorScheme)
            .environment(\.colorScheme, .dark)
            .environment(\.onStage, true)
            // Outside the forced dark scheme, so the band resolves in the window's appearance
            .background { backdrop.ignoresSafeArea(.container, edges: .leading) }
    }

    @ViewBuilder private var backdrop: some View {
        if contrast == .increased {
            StagePalette.top
        } else {
            LinearGradient(colors: [StagePalette.top, StagePalette.bottom], startPoint: .top, endPoint: .bottom)
                .overlay { RadialGradient(colors: [StagePalette.glow, .clear], center: glow, startRadius: 0, endRadius: 0.9 * height) }
        }
    }
}

/// A conversion's progress as its stages: one segment per stage (done, the running one filling, those to come), one bar beyond 24 stages. A running
/// stage that reports no fraction is tinted whole at 45 %; `failed` marks the stage that was running; `pulsesCurrent` pulses the running segment
/// (not under Reduce Motion, in an inactive window or when the system asks for less work)
struct StageProgressBar: View {
    private let segments: Int
    private let completed: Int
    private let current: Double?
    private let failed: Bool
    private let compact: Bool
    private let pulsesCurrent: Bool
    @Environment(\.onStage) private var onStage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResources

    init(segments: Int, completed: Int, current: Double?, failed: Bool = false, compact: Bool = false, pulsesCurrent: Bool = false) {
        self.segments = max(segments, 1); self.completed = min(max(completed, 0), max(segments, 1)); self.current = current.map { min(max($0, 0), 1) }
        self.failed = failed; self.compact = compact; self.pulsesCurrent = pulsesCurrent
    }

    var body: some View {
        Group {
            if segments > 24 {
                segment(fill: fraction, failed: failed, color: done)
            } else {
                HStack(spacing: compact ? 2 : 3) {
                    ForEach(0..<segments, id: \.self) { index in
                        if index == completed {
                            segment(fill: current, failed: failed, color: running)
                                .modifier(Pulse(active: pulsesCurrent && !failed && !reduceMotion && appearsActive && !reducedResources))
                        } else {
                            segment(fill: index < completed ? 1 : 0, failed: false, color: done)
                        }
                    }
                }
            }
        }
        .frame(height: compact ? 4 : 6)
        .animation(reduceMotion ? nil : Motion.fill, value: completed)
        .animation(reduceMotion ? nil : Motion.fill, value: current)
        .accessibilityRepresentation { ProgressView(value: fraction) }
    }

    private var fraction: Double { min((Double(completed) + (current ?? 0)) / Double(segments), 1) }
    private var done: Color { onStage ? StagePalette.success : .accentColor }
    private var running: Color { onStage ? StagePalette.brand : .accentColor }

    private func segment(fill: Double?, failed: Bool, color: Color) -> some View {
        Capsule()
            .fill(onStage ? StagePalette.track : Color(nsColor: .quaternaryLabelColor))
            .overlay(alignment: .leading) {
                if failed {
                    Rectangle().fill(onStage ? StagePalette.failure : Tone.failure.glyph)
                } else if let fill {
                    Rectangle().fill(color).scaleEffect(x: fill, anchor: .leading)
                } else {
                    Rectangle().fill(color.opacity(0.45))
                }
            }
            .clipShape(Capsule())
    }
}

private struct Pulse: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([1.0, 0.6]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.6) }
        } else {
            content
        }
    }
}

// MARK: - Ports

/// A port's milestones as four steps (Profile, Frame Loop, First Frame, Playable), filled up to the highest one its agent reported
struct MilestoneTrack: View {
    private let milestone: PortMilestone?
    private static let steps: [(milestone: PortMilestone, label: String)] = [(.profile, "Profile"), (.frameLoop, "Frame Loop"),
                                                                            (.firstFrame, "First Frame"), (.playable, "Playable")]

    init(milestone: PortMilestone?) { self.milestone = milestone }

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            ForEach(Self.steps.indices, id: \.self) { index in
                let step = Self.steps[index]
                if index > 0 {
                    Rectangle()
                        .fill(reached(step.milestone) ? AnyShapeStyle(step.milestone.tone.glyph) : AnyShapeStyle(.tertiary))
                        .frame(height: 1)
                        .frame(minWidth: Space.m, maxWidth: .infinity)
                        .padding(.top, 4.5)
                        .accessibilityHidden(true)
                }
                VStack(spacing: Space.xs) {
                    Group {
                        if reached(step.milestone) {
                            Circle().fill(step.milestone.tone.glyph)
                        } else {
                            Circle().strokeBorder(.tertiary, lineWidth: 1)
                        }
                    }
                    .frame(width: 10, height: 10)
                    Text(step.label).font(.footnote).foregroundStyle(reached(step.milestone) ? .primary : .secondary).lineLimit(1).fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.label): \(reached(step.milestone) ? "reached" : "not reached")")
            }
        }
    }

    private func reached(_ step: PortMilestone) -> Bool { milestone.map { $0 >= step } ?? false }
}

extension AgentRunStatus {
    var title: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Finished"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .timedOut: "Time limit"
        case .interactive: "In Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .running: "bolt.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle"
        case .timedOut: "clock.badge.exclamationmark"
        case .interactive: "apple.terminal"
        }
    }

    var tone: Tone {
        switch self {
        case .running: .info
        case .succeeded: .success
        case .failed: .failure
        case .cancelled: .neutral
        case .timedOut: .warning
        case .interactive: .brand
        }
    }
}

extension PortMilestone {
    var tone: Tone {
        switch self {
        case .blocked: .failure
        case .inProgress: .neutral
        case .profile, .frameLoop, .firstFrame: .brand
        case .playable: .success
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.octagon.fill"
        case .inProgress: "hourglass"
        case .profile: "doc.badge.gearshape"
        case .frameLoop: "arrow.triangle.2.circlepath"
        case .firstFrame: "photo"
        case .playable: "gamecontroller.fill"
        }
    }
}

// MARK: - Forms and logs

/// A path setting: the path (abbreviated, in mono) or a placeholder, Choose…, and a button that shows the path in Finder
struct PathRow: View {
    private let title: String
    private let path: String
    private let placeholder: String
    private let chooseDisabled: Bool
    private let choose: () -> Void

    init(_ title: String, path: String, placeholder: String, chooseDisabled: Bool = false, choose: @escaping () -> Void) {
        self.title = title; self.path = path; self.placeholder = placeholder; self.chooseDisabled = chooseDisabled; self.choose = choose
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path.isEmpty ? placeholder : path.abbreviatedPath)
                    .font(path.isEmpty ? .body : .mono)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
                Button("Choose…", action: choose).disabled(chooseDisabled)
                if !path.isEmpty {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .accessibilityLabel("Show \(title) in Finder")
                }
            }
        }
    }
}

/// A number above 0 typed as text, with its unit after it. The text is bound, and read with `positive`, because a value-bound field commits only on
/// Return or when it loses focus
struct NumberField: View {
    private let title: String
    private let unit: String
    @Binding private var text: String

    init(_ title: String, unit: String, text: Binding<String>) {
        self.title = title; self.unit = unit; _text = text
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: Space.s) {
                TextField(title, text: $text).labelsHidden().frame(width: 80)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    /// The text's number, when it is one above 0
    static func positive(_ text: String) -> Double? {
        guard let value = try? Double(text.trimmingCharacters(in: .whitespaces), format: .number), value.isFinite, value > 0 else { return nil }
        return value
    }
}

/// The controls of a log: Auto-scroll and Copy, small
struct LogControls: View {
    @Binding private var autoScroll: Bool
    private let autoScrollHelp: String
    private let canCopy: Bool
    private let copyHelp: String
    private let copyLabel: String
    private let text: () -> String

    init(autoScroll: Binding<Bool>, autoScrollHelp: String = "Scroll to new lines as they arrive", canCopy: Bool = true,
         copyHelp: String = "Copy the whole log", copyLabel: String = "Copy Log", text: @escaping () -> String) {
        _autoScroll = autoScroll; self.autoScrollHelp = autoScrollHelp; self.canCopy = canCopy; self.copyHelp = copyHelp; self.copyLabel = copyLabel
        self.text = text
    }

    var body: some View {
        HStack(spacing: Space.m) {
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .help(autoScrollHelp)
            CopyButton(help: copyHelp, label: copyLabel, text: text)
                .disabled(!canCopy)
        }
        .controlSize(.small)
    }
}

/// Copy, which puts the text on the pasteboard; the text is made when it is clicked
struct CopyButton: View {
    private let help: String
    private let label: String
    private let text: () -> String

    init(help: String, label: String = "Copy", text: @escaping () -> String) {
        self.help = help; self.label = label; self.text = text
    }

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
        }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The game's language: the default (English), or one of the script's languages. The job options and Settings share it
struct LanguagePicker: View {
    private let title: String
    @Binding private var selection: String

    init(_ title: String, selection: Binding<String>) {
        self.title = title; _selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Default (English)").tag("")
            Divider()
            ForEach(ConversionCommand.languages.indices, id: \.self) { index in
                Text(ConversionCommand.languages[index].name).tag(ConversionCommand.languages[index].code)
            }
        }
    }
}

// MARK: - Model helpers for views

extension String {
    /// The path with the home folder written as ~
    var abbreviatedPath: String { NSString(string: self).abbreviatingWithTildeInPath }
}

extension ConversionJob {
    /// Failed or cancelled: the console's halves unplug and the art desaturates
    var isUnplugged: Bool { state == .failed || state == .cancelled }

    /// A game with no profile, or a conversion that failed: the survey actions and "Port with an Agent…" apply
    var showsPortActions: Bool { !cannotConvert && (match == .noProfile || state == .failed) }

    /// The conversion's overall progress, the number the stage, the sidebar and the toolbar show: 0 until it runs, 1 from the install on
    var progressFraction: Double {
        switch state {
        case .running: build.overallFraction
        case .installing, .succeeded: 1
        case .queued, .preparing, .failed, .cancelled: 0
        }
    }
}

extension ConversionRecord {
    /// The game folder, without asking the disk whether it is one
    var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }
}

extension PortRecord {
    var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }
    var workspaceURL: URL { URL(fileURLWithPath: workspace, isDirectory: true) }
}

extension LibraryEntry {
    var logFile: URL { InstalledAppScanner.logFile(titleID: app.titleID) }
    var saveFolder: URL { InstalledAppScanner.saveFolder(titleID: app.titleID) }
}

extension NXNativeVersion {
    /// The branch of a build from a port's worktree ("port/<TID>")
    var portBranch: String? { branch.flatMap { $0.hasPrefix("port/") ? $0 : nil } }
}

// MARK: - Files

/// File checks for views: run in `.task` (never in body) and kept in state
enum FileCheck {
    static func existing(_ urls: [URL]) async -> Set<URL> {
        await Task.detached(priority: .utility) { Set(urls.filter { FileManager.default.fileExists(atPath: $0.path) }) }.value
    }
}
