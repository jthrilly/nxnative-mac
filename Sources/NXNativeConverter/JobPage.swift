// A game's page on Convert: its stage band, the notices under it (why a folder can't be converted, a failure, a game with no profile, each with the
// survey and port actions), its options while it waits, and its stages and log once it ran. The job's actions are in the toolbar
import AppKit
import ConverterCore
import SwiftUI

struct JobPage: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    @AppStorage(JobTab.storageKey) private var tab = JobTab.stages
    @AppStorage("logAutoScroll") private var autoScroll = true
    @State private var compact = false
    @State private var stageHeight: CGFloat = 0
    private let job: ConversionJob

    init(job: ConversionJob) { self.job = job }

    var body: some View {
        VStack(spacing: 0) {
            // StageBand pads its content 20 top and bottom: a band whose chips wrap grows to fit them instead of spilling over the notices
            StageBand(height: max(compact ? 152 : 188, stageHeight + 40)) {
                JobStage(job: job, compact: compact)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stageHeight = $0 }
            }
            JobNotices(job: job)
            if job.cannotConvert {
                Spacer(minLength: 0)
            } else if job.state == .queued {
                JobOptionsForm(job: job)
            } else {
                tabs
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < 680 || proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom < 700
        } action: { compact = $0 }
        .task(id: FileKey(state: job.state, titleID: job.titleID, generation: window.fileChecks)) { await window.checkJobFiles(job) }
        .navigationTitle(job.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem { AddGameFolderButton() }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                JobActionButton(.showInFinder, job: job)
                Menu("More", systemImage: "ellipsis") {
                    JobActionMenuItems(JobAction.more(for: job), job: job)
                }
                .menuIndicator(.hidden)
                .help("More actions")
                .accessibilityLabel("More Actions")
            }
            .visibilityPriority(.low)
            if let action = JobAction.prominent(for: job) {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    // Cancel is a symbol button, never the prominent one
                    JobActionButton(action, job: job, prominent: action != .cancel)
                }
                .visibilityPriority(.high)
            }
        }
    }

    // MARK: Stages and log

    private var tabs: some View {
        VStack(spacing: 0) {
            ZStack {
                Picker("View", selection: $tab) {
                    Text("Stages").tag(JobTab.stages)
                    Text("Log").tag(JobTab.log)
                }
                .pickerStyle(.tabs)
                .labelsHidden()
                .fixedSize()
                if tab == .log {
                    let log = job.build.log
                    Text("\(log.count) line\(log.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LogControls(autoScroll: $autoScroll, canCopy: !log.isEmpty) { log.map(\.text).joined(separator: "\n") }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 40)
            .padding(.horizontal, Space.page)
            Group {
                switch tab {
                case .stages:
                    StageListView(stages: job.build.stages, upcoming: upcoming)
                case .log:
                    // A view per run: each run numbers its lines from 0, and the view appends what it has not shown
                    LogConsoleView(lines: job.build.log, autoScroll: autoScroll).id(job.attempt)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.fill.quinary, in: .card)
            .clipShape(.card)
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.l)
        }
    }

    private var upcoming: Int { job.state.isActive ? max(job.build.plannedStages - job.build.currentPlan.count, 0) : 0 }

    // MARK: Toolbar

    /// The queue around the game: another game converting, the games waiting and those finished
    private var subtitle: String {
        var parts: [String] = []
        if let active = model.activeJob, active.id != job.id { parts.append("Converting \(active.name)") }
        let queued = model.queuedCount
        if queued > 0 { parts.append("\(queued) waiting") }
        let finished = model.jobs.filter { $0.state.isFinished && !$0.cannotConvert }.count
        if finished > 0 { parts.append("\(finished) finished") }
        return parts.joined(separator: " · ")
    }
}

/// What the check of the job's files is keyed on: its state and title ID, and the generation of checks asked for
private struct FileKey: Equatable {
    let state: JobState
    let titleID: String?
    let generation: Int
}

// MARK: - Notices

/// The first rule that applies: why the folder can't be converted (and the scan's notes), an app in the install folder that was not replaced, a
/// failure, or a game with no profile
private struct JobNotices: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general
    let job: ConversionJob

    var body: some View {
        let failed = job.state == .failed && !job.cannotConvert
        let noProfile = !job.cannotConvert && !failed && job.match == .noProfile && job.state != .installing
        if job.cannotConvert || failed || noProfile {
            VStack(spacing: Space.s) {
                if job.cannotConvert {
                    Notice(.failure, title: "Why This Folder Can't Be Converted", message: Self.bullets(job.scan.errors), symbol: "xmark.octagon.fill")
                    if !job.scan.warnings.isEmpty { Notice(.warning, title: "Notes", message: Self.bullets(job.scan.warnings)) }
                } else if failed, let foreignApp = job.foreignApp {
                    Notice(.failure, title: "The app was not installed",
                           message: job.message ?? "\(foreignApp.path) is not an nxnative app of this game, so it was left as it is.", messageLines: 4) {
                        Group {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([foreignApp]) }
                                .help(foreignApp.path)
                            Button("Settings…") {
                                settingsTab = .install
                                openSettings()
                            }
                            .help("Choose another install folder in Settings")
                            NoticePortActions(job: job)
                        }
                        .noticeActionStyle()
                    }
                } else if failed {
                    Notice(.failure, title: "The conversion failed",
                           message: job.message ?? "The conversion failed. An agent can look into it in a worktree of its own.", messageLines: 4) {
                        NoticePortActions(job: job).noticeActionStyle()
                    }
                } else {
                    Notice(.warning, title: "No profile for this game", message: "The conversion packs a provisional profile, which may not boot.",
                           symbol: "questionmark.diamond.fill") {
                        NoticePortActions(job: job).noticeActionStyle()
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.m)
        }
    }

    private static func bullets(_ lines: [String]) -> String { lines.map { "• " + $0 }.joined(separator: "\n") }
}

/// Survey Only, Open Survey, Show Provisional Profile and Port with an Agent… (or Continue Port…), each only when it applies: the survey and the
/// profile when their files exist
private struct NoticePortActions: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    let job: ConversionJob

    var body: some View {
        if JobAction.survey.applies(to: job, in: model) { JobActionButton(.survey, job: job) }
        if offers(.openSurvey) { JobActionButton(.openSurvey, job: job) }
        if offers(.showProvisionalProfile) { JobActionButton(.showProvisionalProfile, job: job) }
        if JobAction.port.applies(to: job, in: model) { JobActionButton(.port, job: job) }
    }

    private func offers(_ action: JobAction) -> Bool {
        action.applies(to: job, in: model) && action.isEnabled(for: job, in: model, files: window.jobFiles)
    }
}

private extension View {
    func noticeActionStyle() -> some View { buttonStyle(.bordered).controlSize(.small) }
}
