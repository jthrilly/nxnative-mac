// ConversionJob: one game folder in the Convert queue, from its scan to the installed app or the prepared Xcode project, or to the survey of a game with no
// profile (the run itself is ConversionRunner). A job built from a port runs the script of the port's worktree instead of the nxnative folder
import ConverterCore
import Foundation
import Observation

enum JobState: Equatable {
    case queued, preparing, running, installing, succeeded, failed, cancelled

    var isActive: Bool { self == .preparing || self == .running || self == .installing }
    var isFinished: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

@MainActor @Observable final class ConversionJob: Identifiable {
    let id = UUID()
    let folder: URL
    let scan: NSPFolderScan
    private(set) var profiles: [GameProfile]   // its repository's: the match follows the version chosen to pack
    let cannotConvert: Bool          // the scan found no convertible game: the job shows its errors and never starts
    var options: ConversionOptions
    private(set) var repository: URL?   // a port's worktree: its script, profiles and version build this job instead of the nxnative folder's
    private(set) var state: JobState
    // Kept outside observation and mutated in place (a batch must not copy a 5,000-line log); revision tells the views
    @ObservationIgnored private var buildStorage = BuildState()
    private var revision = 0
    var build: BuildState { _ = revision; return buildStorage }
    private(set) var message: String?
    var nxnative: NXNativeVersion?
    var builtApp: URL?
    var installedApp: URL?
    var surveyWritten: URL?          // a survey-only run's survey.md
    var xcodeProject: URL?           // an Xcode project run's DmIOS.xcodeproj, and the workspace it is a scheme of
    var xcodeWorkspace: URL?
    var foreignApp: URL?             // the app in the install folder that the new one did not replace: it is not an nxnative app of this game
    private(set) var attempt = 0     // counts the runs: a view of one run's output takes it as its identity, since each run numbers its log lines from 0
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    @ObservationIgnored var process: Subprocess?
    private(set) var cancelRequested = false
    @ObservationIgnored private var failure = FailureTracker()

    init(folder: URL, scan: NSPFolderScan, profiles: [GameProfile], options: ConversionOptions, repository: URL? = nil) {
        self.folder = folder
        self.scan = scan
        self.profiles = profiles
        self.options = options
        self.repository = repository
        cannotConvert = !scan.isConvertible
        state = cannotConvert ? .failed : .queued
        message = cannotConvert ? scan.errors.joined(separator: "\n") : nil
    }

    var match: ProfileMatch { GameProfiles.match(scan, in: profiles, package: options.package) }

    var name: String { scan.displayName }
    var titleID: String? { scan.titleIDString }
    var isEditable: Bool { state == .queued }
    var canRetry: Bool { !cannotConvert && (state == .failed || state == .cancelled) }
    var canSurvey: Bool { !cannotConvert && match == .noProfile && (state == .queued || state.isFinished) }
    var portBranch: String? { repository != nil ? titleID.map(PortWorkspace.branchName(titleID:)) : nil }
    var app: URL? { installedApp ?? builtApp }
    /// Prepared as an Xcode project: there is no app, Xcode builds and installs it
    var isXcodeProject: Bool { state == .succeeded && !options.surveyOnly && xcodeProject != nil }

    /// The game's art: the newest icon a run of this folder extracted
    var artwork: ArtworkSource? { titleID.map { .gameFolder(folder, titleID: $0) } }

    /// Where the Mac app is made (the script's -o): named after the App name option, else the game
    var appOutput: URL { ConversionCommand.appOutput(folder: folder, name: options.appName.isEmpty ? name : options.appName) }

    /// Converted into a Mac app: the console docks
    var isMacApp: Bool { state == .succeeded && !options.surveyOnly && app != nil }

    /// The stage bar: a segment per stage of the latest plan, the stages that succeeded, and the running stage's fraction (nil when it reports none)
    var stageBar: (segments: Int, completed: Int, current: Double?) {
        let plan = build.currentPlan
        let segments = max(build.plannedStages, build.currentStage?.n ?? 0, plan.count, 1)
        let completed = plan.filter { $0.status == .succeeded }.count
        switch state {
        case .queued: return (segments, 0, 0)
        case .preparing: return (1, 0, nil)
        case .running:
            guard let stage = build.currentStage else { return (segments, completed, 0) }
            return (segments, completed, stage.progress?.fraction)
        case .installing, .succeeded: return (segments, segments, nil)
        case .failed, .cancelled: return (segments, completed, 0)
        }
    }

    var statusText: String {
        switch state {
        case .queued: return "Waiting"
        case .preparing: return "Preparing…"
        case .running:
            guard let stage = build.currentStage else { return "Starting…" }
            return "\(stage.name) · \(ProgressFormat.percent(build.overallFraction))"
        case .installing: return "Installing…"
        case .succeeded: return options.surveyOnly ? "Survey written" : xcodeProject != nil ? "Xcode project ready" : installedApp != nil ? "Installed" : "Done"
        case .failed: return cannotConvert ? "Cannot convert" : "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    func begin() {
        buildStorage = BuildState(); failure = FailureTracker(); revision += 1; message = nil; builtApp = nil; installedApp = nil; surveyWritten = nil; nxnative = nil
        xcodeProject = nil; xcodeWorkspace = nil
        foreignApp = nil; attempt += 1; cancelRequested = false; startedAt = Date(); finishedAt = nil; state = .preparing
    }

    /// Back into the queue after it finished (a retry, or another kind of run: a survey only, or a conversion after a survey)
    func requeue() {
        guard !cannotConvert, state.isFinished else { return }
        buildStorage = BuildState(); failure = FailureTracker(); revision += 1; message = nil; foreignApp = nil
        startedAt = nil; finishedAt = nil; state = .queued
    }

    func markRunning() { state = .running }
    func markInstalling() { state = .installing }

    func finish(_ state: JobState, message: String? = nil) {
        self.state = state; self.message = message; finishedAt = Date(); process = nil
    }

    func requestCancel() { cancelRequested = true }

    /// A queued job moves to another repository (a port's worktree, or back to the nxnative folder), with that repository's profiles
    func use(repository: URL?, profiles: [GameProfile]) {
        guard isEditable else { return }
        self.repository = repository; self.profiles = profiles
    }

    /// Why a run that ended with a non-zero exit status failed
    func failureMessage(status: Int32) -> String { failure.message(status: status, lastError: build.log.last { $0.kind == .error }?.text) }

    func note(_ text: String) { buildStorage.appendNote(text, at: Date()); revision += 1 }

    func buildFinished() { buildStorage.finish(); revision += 1 }

    func ingest(_ lines: [OutputLine]) {
        for line in lines {
            switch line.stream {
            case .stdout:
                if let event = BuildEvent.decode(line.text) {
                    buildStorage.apply(event, at: line.date); failure.observe(event)
                } else { buildStorage.appendNote(line.text, at: line.date) }
            case .stderr: buildStorage.appendStderr(line.text, at: line.date)
            }
        }
        revision += 1
    }
}
