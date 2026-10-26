// A game's stage on its page: the console with the game's art on its screen (docking into a Mac window when the game becomes a Mac app, its halves
// unplugged when it fails), the name, its facts and chips, and a readout of what the conversion is doing. The actions are in the toolbar
import ConverterCore
import SwiftUI

struct JobStage: View {
    private let job: ConversionJob
    private let compact: Bool

    init(job: ConversionJob, compact: Bool = false) {
        self.job = job; self.compact = compact
    }

    var body: some View {
        let height: CGFloat = compact ? 92 : 120
        HStack(alignment: .center, spacing: 24) {
            ConsoleFrame(height: height, window: job.isMacApp, halves: job.isUnplugged ? .unplugged : .attached) {
                screen(height: height)
            }
            VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                Text(job.name)
                    .font(.stageTitle)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(job.name)
                    .accessibilityAddTraits(.isHeader)
                meta
                ChipRow {
                    ForEach(chips, id: \.text) { chip in
                        StatusChip(chip.text, symbol: chip.symbol, tone: chip.tone)
                            .help(chip.help)
                            .accessibilityHint(chip.help)
                    }
                }
                StageReadout(job: job, compact: compact)
                    .frame(height: compact ? 40 : 64, alignment: .topLeading)
                    .motion(Motion.respond, value: job.state)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: job.isMacApp) { _, isApp in
            if isApp { AccessibilityNotification.Announcement("\(job.name) is a Mac app now.").post() }
        }
        .onChange(of: job.state) { _, state in
            if state == .failed && !job.cannotConvert { AccessibilityNotification.Announcement("\(job.name) failed").post() }
        }
    }

    @ViewBuilder private func screen(height: CGFloat) -> some View {
        if job.cannotConvert {
            BlankScreen(symbol: "questionmark.folder", height: height, symbolSize: 0.3 * height)
        } else {
            let unplugged = job.isUnplugged
            GameArtwork(job.artwork, name: job.name, size: height, shape: .screen)
                .saturation(unplugged ? 0.35 : 1)
                .brightness(unplugged ? -0.05 : 0)
                .motion(.easeInOut(duration: 0.3), value: unplugged)
        }
    }

    // MARK: Facts

    private var meta: some View {
        HStack(spacing: 6) {
            if job.cannotConvert {
                let path = job.folder.path
                Text(path.abbreviatedPath)
                    .font(.mono)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
            } else {
                let titleID = job.titleID, files = !job.scan.files.isEmpty, size = job.scan.totalBytes > 0
                if let titleID { Text(titleID).font(.mono).textSelection(.enabled).layoutPriority(1) }
                if files {
                    if titleID != nil { separator }
                    Text(versionsText)
                }
                if size {
                    if titleID != nil || files { separator }
                    Text(ProgressFormat.bytes(Double(job.scan.totalBytes))).layoutPriority(1)
                }
            }
        }
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(StagePalette.inkSecondary)
    }

    private var separator: some View { Text("·").accessibilityHidden(true) }

    private var versionsText: String {
        let updates = job.scan.updates.count, dlc = job.scan.dlc.count
        var parts = [job.scan.versions.map { "v\($0)" }.joined(separator: ", ")]
        if updates > 0 { parts.append("\(updates) update\(updates == 1 ? "" : "s")") }
        if dlc > 0 { parts.append("\(dlc) DLC") }
        return parts.joined(separator: ", ")
    }

    private var chips: [Chip] {
        var chips: [Chip] = []
        if job.cannotConvert {
            chips.append(Chip("Can't be converted", symbol: "xmark.circle.fill", tone: .failure))
        } else {
            switch job.match {
            case .tested(_, let display):
                chips.append(Chip("Tested: \(display)", symbol: "checkmark.seal.fill", tone: .success,
                                  help: "This version of the game was brought up and tested with nxnative"))
            case .untestedVersion(_, let version, let tested):
                let builds = tested.isEmpty ? "none" : tested.map { "\($0.display) (\($0.version))" }.joined(separator: ", ")
                chips.append(Chip("Untested version", symbol: "exclamationmark.triangle.fill", tone: .warning,
                                  help: "\(version) was not tested; it is packed from a derived profile, and fixes for the tested builds may not apply. "
                                      + "Tested: \(builds)"))
            case .noProfile:
                chips.append(Chip("No profile — best effort", symbol: "questionmark.diamond.fill", tone: .warning,
                                  help: "nxnative has no profile for this game: the script surveys it and packs a provisional profile, which may not boot"))
            }
        }
        if job.build.game?.provisional == true { chips.append(Chip("Provisional profile", symbol: "doc.badge.gearshape", tone: .info)) }
        if job.build.game?.derived == true { chips.append(Chip("Derived profile", symbol: "arrow.triangle.branch", tone: .info)) }
        if let branch = job.portBranch {
            chips.append(Chip("nxnative: \(branch) worktree", symbol: "hammer", tone: .info,
                              help: "Built with the port's worktree: \(job.repository?.path ?? "")"))
        }
        if job.options.surveyOnly && job.state != .succeeded { chips.append(Chip("Survey only", symbol: "doc.text.magnifyingglass", tone: .neutral)) }
        return chips
    }
}

private struct Chip {
    let text: String
    let symbol: String
    let tone: Tone
    let help: String

    init(_ text: String, symbol: String, tone: Tone, help: String = "") {
        self.text = text; self.symbol = symbol; self.tone = tone; self.help = help
    }
}

// MARK: - Readout

/// What the conversion is doing, in words and its stage bar, at a fixed height so the band keeps its size from state to state. Compact, it keeps to
/// two lines: the running stage's time left moves beside the timer (its step, count and note are left to the Stages tab), and the result's lines
/// are joined
private struct StageReadout: View {
    @Environment(AppModel.self) private var model
    let job: ConversionJob
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if job.cannotConvert {
                label("This folder can't be converted")
            } else {
                switch job.state {
                case .queued:
                    label(startHint).lineLimit(2)
                case .preparing:
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        label("Preparing…")
                        Spacer(minLength: Space.s)
                        timer
                    }
                    bar(pulses: true)
                case .running:
                    running
                case .installing:
                    let folder = installFolder
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        label("Installing into \(folder.path.abbreviatedPath)").truncationMode(.middle).help(folder.path)
                        Spacer(minLength: Space.s)
                        timer
                    }
                    bar()
                case .succeeded where job.options.surveyOnly:
                    label("Survey written")
                    if let survey = job.surveyWritten {
                        Text(survey.path.abbreviatedPath)
                            .font(.monoSmall)
                            .foregroundStyle(StagePalette.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(survey.path)
                    }
                case .succeeded:
                    if let app = job.app {
                        let folder = app.deletingLastPathComponent()
                        let place = (job.installedApp != nil ? "Installed in " : "Built in ") + folder.path.abbreviatedPath
                        let made = "Converted in \(duration)" + commit
                        label("It's a Mac app now")
                        if compact {
                            note(place + " · " + made).truncationMode(.middle).help(folder.path)
                        } else {
                            note(place).truncationMode(.middle).help(folder.path)
                            note(made)
                        }
                    } else {
                        label("Converted")
                        note("In \(duration)" + commit)
                    }
                case .failed:
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        label(failedText)
                        Spacer(minLength: Space.s)
                        Text("After \(duration)").font(.mono).foregroundStyle(StagePalette.inkSecondary).lineLimit(1)
                    }
                    bar()
                case .cancelled:
                    label("Cancelled after \(duration)")
                    bar()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var running: some View {
        let fraction = job.build.overallFraction
        return Group {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ProgressFormat.percent(fraction))
                    .font(.stageFigure)
                    .contentTransition(.numericText(value: fraction))
                    .motion(Motion.fill, value: fraction, fades: false)
                label(stageText)
                Spacer(minLength: Space.s)
                if compact, let left = timeLeft {
                    Text("about " + left).font(.mono).foregroundStyle(StagePalette.inkSecondary).lineLimit(1).layoutPriority(1)
                }
                timer
            }
            bar()
            if !compact, let text = noteText { note(text) }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.callout.weight(.semibold)).lineLimit(1)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(StagePalette.inkSecondary).lineLimit(1).textSelection(.enabled)
    }

    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(ProgressFormat.duration(job.duration ?? 0)).font(.mono).foregroundStyle(StagePalette.inkSecondary).lineLimit(1)
        }
    }

    private func bar(pulses: Bool = false) -> some View {
        let bar = job.stageBar
        return StageProgressBar(segments: bar.segments, completed: bar.completed, current: bar.current, failed: job.state == .failed, compact: compact,
                                pulsesCurrent: pulses)
            .accessibilityLabel(barLabel)
    }

    private var barLabel: String {
        guard job.state == .running, let stage = job.build.currentStage else { return "Overall progress" }
        return "Stage \(stage.k) of \(max(job.build.plannedStages, stage.n)), \(stage.name)"
    }

    private var duration: String { ProgressFormat.duration(job.duration ?? 0) }

    private var commit: String { job.nxnative.map { " with nxnative \($0.shortCommit)" } ?? "" }

    private var startHint: String {
        let settings = model.settings
        if settings.startAutomatically && model.isConverting { return "Starts when the current conversion has finished" }
        if let reason = model.startBlockReason(job) { return reason }
        return settings.startAutomatically ? "Starts in a moment" : "Starts when you click Start"
    }

    private var stageText: String {
        guard let stage = job.build.currentStage else { return "Starting…" }
        return "Stage \(stage.k) of \(max(job.build.plannedStages, stage.n)) · \(stage.name)"
    }

    /// The running stage's step, count and note, and the time left
    private var noteText: String? {
        guard let stage = job.build.currentStage else { return nil }
        let progress = stage.progress
        var text = [stage.step, progress.map(ProgressFormat.count) ?? "", progress?.note ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        if let left = timeLeft { text = text.isEmpty ? "About " + left : text + " · about " + left }
        return text.isEmpty ? nil : text
    }

    /// The running stage's time left, when the script estimates it
    private var timeLeft: String? {
        guard let eta = job.build.currentStage?.progress?.eta, eta > 0 else { return nil }
        return "\(ProgressFormat.duration(eta)) left"
    }

    private var failedText: String {
        guard let stage = job.build.currentPlan.last(where: { $0.status != .succeeded }) else { return "Failed" }
        return "Failed at stage \(stage.k) of \(max(job.build.plannedStages, stage.n)) · \(stage.name)"
    }

    private var installFolder: URL { model.settings.installMode == .none ? job.folder : model.settings.installDirectoryURL }
}
