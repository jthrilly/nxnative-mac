// What can be done to a game in the Convert queue, in one place: the job page's toolbar and More menu, the sidebar row's context menu and the
// Conversion menu all take their titles, enablement, help and work from JobAction, so they cannot drift apart
import AppKit
import ConverterCore
import SwiftUI

enum JobAction: Hashable {
    case start, cancel, retry, convert, play, chooseAnotherFolder, survey, port, openSurvey, showProvisionalProfile, showInFinder, showLogs, remove,
         removeFinished

    var title: String {
        switch self {
        case .start: "Start"
        case .cancel: "Cancel Conversion"
        case .retry: "Retry"
        case .convert: "Convert"
        case .play: "Play"
        case .chooseAnotherFolder: "Choose Another Folder…"
        case .survey: "Survey Only"
        case .port: "Port with an Agent…"
        case .openSurvey: "Open Survey"
        case .showProvisionalProfile: "Show Provisional Profile"
        case .showInFinder: "Show in Finder"
        case .showLogs: "Show Logs"
        case .remove: "Remove"
        case .removeFinished: "Remove Finished"
        }
    }

    /// The toolbar's symbol; menus are text only
    fileprivate var symbol: String {
        switch self {
        case .start, .play: "play.fill"
        case .cancel: "stop.fill"
        case .retry: "arrow.clockwise"
        case .convert: "arrow.down.app"
        case .chooseAnotherFolder: "folder.badge.plus"
        case .survey: "doc.text.magnifyingglass"
        case .port: "hammer"
        case .openSurvey: "doc.text"
        case .showProvisionalProfile: "doc.badge.gearshape"
        case .showInFinder: "folder"
        case .showLogs: "doc.plaintext"
        case .remove, .removeFinished: "trash"
        }
    }

    fileprivate var isDestructive: Bool { self == .remove || self == .removeFinished }

    @MainActor func title(for job: ConversionJob, in model: AppModel) -> String {
        switch self {
        case .port: job.titleID.flatMap(model.port) != nil ? "Continue Port…" : title
        case .cancel: job.cancelRequested ? "Cancelling…" : title
        default: title
        }
    }

    /// Whether the action is offered for the job at all (a menu leaves out the rest)
    @MainActor func applies(to job: ConversionJob, in model: AppModel) -> Bool {
        switch self {
        case .start: job.state == .queued && !job.cannotConvert
        case .cancel: job.state == .preparing || job.state == .running
        case .retry: job.canRetry
        case .convert: job.state == .succeeded && job.options.surveyOnly
        case .play: job.app != nil
        case .chooseAnotherFolder: job.cannotConvert
        case .survey: job.canSurvey && !job.state.isActive
        case .port: job.showsPortActions && job.titleID != nil && !job.state.isActive
        case .openSurvey, .showProvisionalProfile: job.titleID != nil && (job.state == .succeeded && job.options.surveyOnly || job.showsPortActions)
        case .showInFinder, .remove, .removeFinished: true
        case .showLogs: !job.cannotConvert && job.state != .queued
        }
    }

    /// `files` holds the files of the game the Convert page shows that exist (WindowState.jobFiles)
    @MainActor func isEnabled(for job: ConversionJob, in model: AppModel, files: Set<URL>) -> Bool {
        switch self {
        case .start: model.canStart(job)
        case .cancel: !job.cancelRequested
        case .port: model.portBlockReason(titleID: job.titleID) == nil
        case .openSurvey, .showProvisionalProfile: file(for: job).map { files.contains($0) } ?? false
        case .remove: !job.state.isActive
        case .removeFinished: model.jobs.contains { $0.state.isFinished }
        default: true
        }
    }

    /// The file Open Survey and Show Provisional Profile need: the survey, and the provisional profile's game.tsv
    @MainActor func file(for job: ConversionJob) -> URL? {
        guard let titleID = job.titleID else { return nil }
        switch self {
        case .openSurvey: return ConversionCommand.surveyFile(folder: job.folder, titleID: titleID)
        case .showProvisionalProfile: return ConversionCommand.provisionalProfile(folder: job.folder, titleID: titleID).appendingPathComponent("game.tsv")
        default: return nil
        }
    }

    @MainActor fileprivate func help(for job: ConversionJob, in model: AppModel) -> String {
        switch self {
        case .start:
            if model.canStart(job) { return "Start converting" }
            return model.startBlockReason(job) ?? "Another conversion or an nxnative operation is running"
        case .cancel: return "Cancel the conversion (⌘.)"
        case .retry: return "Convert the game again"
        case .convert: return "Convert the game with a provisional profile (best effort)"
        case .play: return job.app.map { "Open \($0.lastPathComponent)" } ?? "Open the app"
        case .chooseAnotherFolder: return "Remove this folder and choose another"
        case .survey: return "Run the script's survey and write the provisional profile, without packing an app"
        case .port:
            return model.portBlockReason(titleID: job.titleID)
                ?? "Hand the game to Claude Code or Codex, which attempts the port in a worktree of nxnative"
        case .openSurvey: return job.titleID.map { ConversionCommand.surveyFile(folder: job.folder, titleID: $0).path } ?? ""
        case .showProvisionalProfile: return job.titleID.map { ConversionCommand.provisionalProfile(folder: job.folder, titleID: $0).path } ?? ""
        case .showInFinder: return job.app == nil ? "Show the game folder in Finder" : "Show the app in Finder"
        case .showLogs: return "Open the script's log folder"
        case .remove: return job.state.isActive ? "The game is being converted" : "Remove the game from the queue"
        case .removeFinished: return "Remove every game that has finished from the queue"
        }
    }

    @MainActor func perform(on job: ConversionJob, in model: AppModel) {
        switch self {
        case .start: model.start(job)
        case .cancel: model.cancel(job)
        case .retry: model.retry(job)
        case .convert: model.convert(job)
        case .play: if let app = job.app { NSWorkspace.shared.open(app) }
        case .chooseAnotherFolder:
            model.remove(job)
            model.chooseGameFolders()
        case .survey: model.survey(job)
        case .port: model.offerPort(for: job)
        case .openSurvey: if let survey = file(for: job) { NSWorkspace.shared.open(survey) }
        case .showProvisionalProfile: if let profile = file(for: job) { NSWorkspace.shared.activateFileViewerSelecting([profile]) }
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([job.app ?? job.folder])
        case .showLogs:
            // The script's log folder, or the game folder when there is none yet
            guard let titleID = job.titleID else { return NSWorkspace.shared.activateFileViewerSelecting([job.folder]) }
            let logs = ConversionCommand.logsFolder(folder: job.folder, titleID: titleID)
            if FileManager.default.fileExists(atPath: logs.path) {
                NSWorkspace.shared.open(logs)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([job.folder])
            }
        case .remove: model.remove(job)
        case .removeFinished: model.removeFinished()
        }
    }

    /// The job page's prominent action (toolbar group 3); preparing and running jobs show Cancel there as a symbol button instead
    @MainActor static func prominent(for job: ConversionJob) -> JobAction? {
        if job.cannotConvert { return .chooseAnotherFolder }
        switch job.state {
        case .queued: return .start
        case .preparing, .running: return .cancel
        case .installing: return nil
        case .succeeded: return job.options.surveyOnly ? .convert : .play
        case .failed, .cancelled: return .retry
        }
    }

    /// The job page's More menu, in sections; JobActionMenuItems leaves out what does not apply
    @MainActor static func more(for job: ConversionJob) -> [[JobAction]] {
        let sections: [[JobAction]]
        if job.cannotConvert {
            sections = [[.remove]]
        } else {
            switch job.state {
            case .queued: sections = [[.survey, .port], [.remove]]
            case .preparing, .running, .installing: sections = [[.showLogs]]
            case .succeeded:
                sections = job.options.surveyOnly ? [[.showLogs, .openSurvey, .showProvisionalProfile, .port], [.remove]] : [[.showLogs], [.remove]]
            case .failed: sections = [[.showLogs, .survey, .port], [.remove]]
            case .cancelled: sections = [[.showLogs], [.remove]]
            }
        }
        return sections + [[.removeFinished]]
    }

    /// The sidebar row's context menu
    static let contextMenu: [[JobAction]] = [[.start, .cancel, .retry, .survey, .port, .play, .showInFinder], [.remove]]
}

/// A job action as a toolbar or page button: a text button in the prominent glass style, or the action's title and symbol
struct JobActionButton: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    private let action: JobAction
    private let job: ConversionJob
    private let prominent: Bool

    init(_ action: JobAction, job: ConversionJob, prominent: Bool = false) {
        self.action = action; self.job = job; self.prominent = prominent
    }

    var body: some View {
        let title = action.title(for: job, in: model)
        Group {
            if prominent {
                Button(title) { action.perform(on: job, in: model) }.buttonStyle(.glassProminent)
            } else {
                Button(title, systemImage: action.symbol, role: action.isDestructive ? .destructive : nil) { action.perform(on: job, in: model) }
            }
        }
        .disabled(!action.isEnabled(for: job, in: model, files: window.jobFiles))
        .help(action.help(for: job, in: model))
    }
}

/// Job actions as menu items, text only, with a divider between sections; actions that do not apply to the job are left out
struct JobActionMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    private let sections: [[JobAction]]
    private let job: ConversionJob

    init(_ sections: [[JobAction]], job: ConversionJob) {
        self.sections = sections; self.job = job
    }

    var body: some View {
        let shown = sections.map { $0.filter { $0.applies(to: job, in: model) } }.filter { !$0.isEmpty }
        ForEach(shown.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(shown[index], id: \.self) { action in
                Button(action.title(for: job, in: model), role: action.isDestructive ? .destructive : nil) { action.perform(on: job, in: model) }
                    .disabled(!action.isEnabled(for: job, in: model, files: window.jobFiles))
                    .help(action.help(for: job, in: model))
            }
        }
    }
}

extension AppModel {
    /// The game the Convert page shows: the selected one, else the first in the queue
    var shownJob: ConversionJob? { selectedJob ?? jobs.first }
}
