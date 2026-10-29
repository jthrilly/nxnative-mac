// One conversion: checks, build_ipa_from_nsp.py --platform mac-app --progress json -o <app> in its own process group (output folded into the job's BuildState in
// batches), then the install into the Applications folder, the library record and the notification. As nxnative's front-end guidance has it, the run is judged
// by its exit status (0 finished, 1 an error its last [RED] message names, 2 arguments the script refused, which it says on stderr, 130 interrupted), and the
// app is where -o put it: no message's wording is read. An Xcode project run (--platform ios --prepare-xcode)
// installs nothing: it ends at the project, which the Library lists and opens in Xcode. A survey-only run ends at the survey (nothing is
// installed), unless the script found the game to be a known build under another title ID and made the app instead; a job from a port runs the port
// worktree's script. Every run that started is recorded
import AppKit
import ConverterCore
import Foundation

extension AppModel {
    func run(_ job: ConversionJob) async {
        let fm = FileManager.default
        guard let env = environment else { return conclude(job, .failed, "The shell environment is not ready yet. Try again in a moment.") }
        let repo = job.repository ?? settings.repositoryURL, script = ConversionCommand.script(in: repo)
        guard fm.fileExists(atPath: script.path) else {
            if job.repository != nil { return conclude(job, .failed, "The port's worktree \(repo.path) has no scripts/build_ipa_from_nsp.py. Check the port on the Ports page.") }
            return conclude(job, .failed, "nxnative was not found at \(repo.path) (it has no scripts/build_ipa_from_nsp.py). Choose or download it on the Setup page.")
        }
        guard let keys = settings.keysURL, fm.fileExists(atPath: keys.path) else {
            let shown = settings.keysURL.map { " at \($0.path)" } ?? ""
            return conclude(job, .failed, "The prod.keys file was not found\(shown). Choose it on the Setup page.")
        }
        guard let python = pythonExecutable else {
            return conclude(job, .failed, "Python 3 was not found on the shell's PATH. Install it or choose an interpreter on the Setup page.")
        }
        let support = ScriptSupport(repository: repo)
        if let missing = support?.missing(for: job.options.output), !missing.isEmpty {
            return conclude(job, .failed, "The NSP script in \(repo.path) is older than this app: it has no \(missing.joined(separator: " or ")). "
                            + "Update nxnative on the nxnative page, or choose a newer checkout in Settings.")
        }
        job.nxnative = try? await GitRepository(path: repo, environment: env).version()
        if let v = job.nxnative { job.note("nxnative \(v.shortCommit)\(v.modified ? " (modified)" : "")\(job.repository != nil ? " · " + (v.branch ?? "port worktree") : "") · \(v.subject)") }
        if job.cancelRequested { return conclude(job, .cancelled, nil) }

        var options = job.options
        if options.signingIdentity.isEmpty { options.signingIdentity = settings.signingIdentity }
        let teamID = settings.teamID.trimmingCharacters(in: .whitespaces)
        let appOutput = job.appOutput
        let arguments = ConversionCommand.arguments(script: script, folder: job.folder, keys: keys, options: options, teamID: teamID, app: appOutput)
        var variables = env.variables
        variables["PYTHONUNBUFFERED"] = "1"
        job.note("$ " + ([python] + arguments).map(Shell.quoteIfNeeded).joined(separator: " "))

        let process = Subprocess(executable: python, arguments: arguments, environment: variables, currentDirectory: repo)
        let batcher = LineBatcher { [weak job] lines in job?.ingest(lines) }
        do { try process.start { stream, line in batcher.add(stream, line) } } catch {
            return conclude(job, .failed, "\(python) could not be started: \(error.localizedDescription)")
        }
        job.process = process
        job.markRunning()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Converting \(job.name)")
        let status = await process.waitUntilExit()
        ProcessInfo.processInfo.endActivity(activity)
        batcher.flush()
        job.process = nil

        if job.cancelRequested || status == 130 { return conclude(job, .cancelled, nil) }
        guard status == 0 else { return conclude(job, .failed, job.failureMessage(status: status)) }
        job.buildFinished()
        if options.surveyOnly {
            let survey = job.titleID.map { ConversionCommand.surveyFile(folder: job.folder, titleID: $0) }
            if let survey, fm.fileExists(atPath: survey.path) {
                job.surveyWritten = survey
                job.note("Survey written: \(survey.path)")
                return conclude(job, .succeeded, nil)
            }
            // A known build under another title ID (the script's same_build) has no survey: the script made the app instead
            guard options.output == .macApp, fm.fileExists(atPath: appOutput.path) else {
                return conclude(job, .failed, "The survey finished, but \(survey?.path ?? "its survey.md") was not found.")
            }
            job.options.surveyOnly = false
            job.note("No survey: \(job.name) is a build nxnative knows, and the app was made from its profile.")
        }
        if options.output == .xcodeProject {
            guard let prepared = preparedProject(of: job) else {
                return conclude(job, .failed, "The Xcode project was prepared, but it was not found in \(job.folder.path).")
            }
            job.xcodeProject = prepared.project; job.xcodeWorkspace = prepared.workspace
            job.note("Xcode project: \(prepared.project.path)")
            job.note("Workspace: \(prepared.workspace.path) (Open in Xcode, choose the game's scheme and your iPhone or iPad, then Run)")
            return conclude(job, .succeeded, nil)
        }
        guard fm.fileExists(atPath: appOutput.path) else {
            return conclude(job, .failed, "The conversion finished, but the app it was to make at \(appOutput.path) is not there.")
        }
        job.builtApp = appOutput
        await install(job, app: appOutput)
    }

    /// Where --prepare-xcode makes the game's project and the workspace it adds it to
    private func preparedProject(of job: ConversionJob) -> (project: URL, workspace: URL)? {
        let fm = FileManager.default
        guard let titleID = job.titleID else { return nil }
        let project = ConversionCommand.xcodeProject(folder: job.folder, titleID: titleID)
        let workspace = ConversionCommand.xcodeWorkspace(folder: job.folder)
        guard fm.fileExists(atPath: project.path), fm.fileExists(atPath: workspace.path) else { return nil }
        return (project, workspace)
    }

    private func install(_ job: ConversionJob, app: URL) async {
        job.markInstalling()
        let mode = settings.installMode, directory = settings.installDirectoryURL
        switch mode {
        case .move: job.note("Moving \(app.lastPathComponent) into \(directory.path)…")
        case .copy: job.note("Copying \(app.lastPathComponent) into \(directory.path)…")
        case .none: job.note("Leaving \(app.lastPathComponent) in the game folder")
        }
        do {
            if mode != .none, !FileManager.default.fileExists(atPath: directory.path), directory.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            // older copies of the game under other names: in the install folder, the Applications folders and the game folder
            let copiesIn = AppInstaller.standardDestinations() + [app.deletingLastPathComponent()]
            let outcome = try await AppInstaller().install(app: app, into: directory, mode: mode, copiesIn: copiesIn)
            if let replaced = outcome.replaced { job.note("The previous copy went to the Trash: \(replaced.path)") }
            for copy in outcome.oldCopies { job.note("An older copy under another name went to the Trash: \(copy.path)") }
            for warning in outcome.warnings { job.note("Warning: \(warning)") }
            if outcome.warnings.isEmpty { job.note("Cleared the extended attributes (xattr -cr)") }
            if mode == .none { job.builtApp = outcome.installedURL } else {
                job.installedApp = outcome.installedURL
                job.note("Installed: \(outcome.installedURL.path)")
            }
            conclude(job, .succeeded, nil)
        } catch InstallError.foreignApp(let path) {
            job.foreignApp = URL(fileURLWithPath: path)
            job.note("Not installed: \(path) is another app (not an nxnative app of this game), and it is left as it is.")
            conclude(job, .failed, "The app was made (\(app.path)), but \(path) is already there and is not an nxnative app of this game, so it was not replaced. "
                     + "Move or rename that app and retry, or choose another install folder in Settings.")
        } catch {
            job.note("The install failed: \(error.localizedDescription)")
            conclude(job, .failed, "The app was made (\(app.path)) but could not be installed: \(error.localizedDescription)")
        }
    }

    /// Ends the job, records it in the library and tells the user
    private func conclude(_ job: ConversionJob, _ state: JobState, _ message: String?) {
        if let message, state != .succeeded { job.note(message) }
        if state == .cancelled { job.note("Cancelled.") }
        job.finish(state, message: message)
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        let profile: String?, version: String?, derived: Bool
        switch job.match {
        case .tested(let p, let display): profile = p.id; version = display; derived = false
        case .untestedVersion(let p, _, _): profile = p.id; version = nil; derived = true
        case .noProfile: profile = nil; version = nil; derived = false
        }
        let status: ConversionStatus = state == .succeeded ? .succeeded : state == .cancelled ? .cancelled : .failed
        appendRecord(ConversionRecord(
            id: UUID(), folder: job.folder.path, titleID: job.titleID, gameName: job.name, gameVersion: version,
            package: nonEmpty(job.options.package), profile: profile,
            provisional: job.match == .noProfile, derived: derived,
            builtAppPath: job.builtApp?.path, installedAppPath: job.installedApp?.path, xcodeProjectPath: job.xcodeProject?.path,
            xcodeWorkspacePath: job.xcodeWorkspace?.path, startedAt: job.startedAt ?? Date(), finishedAt: job.finishedAt,
            status: status, message: message, nxnative: job.nxnative, options: job.options))
        Task { await refreshLibrary() }
        guard settings.notifyWhenDone else { return }
        switch state {
        case .succeeded where job.options.surveyOnly: Notifier.post(title: "\(job.name): survey written", body: job.surveyWritten?.path ?? "In the game folder.")
        case .succeeded where job.xcodeProject != nil: Notifier.post(title: "\(job.name): Xcode project ready", body: "Open it in Xcode from the Library to run it on your iPhone or iPad.")
        case .succeeded: Notifier.post(title: "\(job.name) is ready", body: job.installedApp.map { "Installed in \($0.deletingLastPathComponent().path)." } ?? "The app is in the game folder.")
        case .failed: Notifier.post(title: "\(job.name) could not be converted", body: message ?? "See the log for details.")
        default: break
        }
    }
}
