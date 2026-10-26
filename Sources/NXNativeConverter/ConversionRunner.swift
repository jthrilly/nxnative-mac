// One conversion: checks, build_ipa_from_nsp.py --platform mac-app --progress json in its own process group (output folded into the job's BuildState in
// batches), then the install into the Applications folder, the library record and the notification. A survey-only run ends at the survey (nothing is
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
        job.nxnative = try? await GitRepository(path: repo, environment: env).version()
        if let v = job.nxnative { job.note("nxnative \(v.shortCommit)\(v.modified ? " (modified)" : "")\(job.repository != nil ? " · " + (v.branch ?? "port worktree") : "") · \(v.subject)") }
        if job.cancelRequested { return conclude(job, .cancelled, nil) }

        var options = job.options
        if options.signingIdentity.isEmpty { options.signingIdentity = settings.signingIdentity }
        let arguments = ConversionCommand.arguments(script: script, folder: job.folder, keys: keys, options: options)
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
        if options.surveyOnly, let game = job.build.game, !game.provisional {   // a known build (the script's same_build): it packed the app, there is no survey
            job.options.surveyOnly = false
            job.note("No survey: \(job.name) is a known build of game profile \(game.profile), and the app was made from it.")
        } else if options.surveyOnly {
            guard let titleID = job.titleID else { return conclude(job, .failed, "The survey finished, but the game's title ID is unknown.") }
            let survey = ConversionCommand.surveyFile(folder: job.folder, titleID: titleID)
            guard fm.fileExists(atPath: survey.path) else { return conclude(job, .failed, "The survey finished, but \(survey.path) was not found.") }
            job.surveyWritten = survey
            job.note("Survey written: \(survey.path)")
            return conclude(job, .succeeded, nil)
        }
        guard let app = builtApp(of: job) else {
            return conclude(job, .failed, "The conversion finished, but the app it made was not found in \(job.folder.path).")
        }
        job.builtApp = app
        await install(job, app: app)
    }

    private func builtApp(of job: ConversionJob) -> URL? {
        let fm = FileManager.default
        func existing(_ path: String?) -> URL? { path.flatMap { !$0.isEmpty && fm.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil } }
        if let result = job.build.result, result.ok, let url = existing(result.path) { return url }
        if let url = existing(job.build.game?.output) { return url }
        for line in job.build.log.suffix(100).reversed() where line.kind == .info {
            guard let r = line.text.range(of: "done: ") else { continue }
            if let url = existing(ConversionCommand.appPath(fromDoneMessage: String(line.text[r.lowerBound...])) ?? ConversionCommand.appPath(fromDoneMessage: line.text)) {
                return url
            }
        }
        return existing(job.folder.appendingPathComponent(job.name + ".app").path)
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
            let outcome = try await AppInstaller().install(app: app, into: directory, mode: mode)
            if let replaced = outcome.replaced { job.note("The previous copy went to the Trash: \(replaced.path)") }
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
        let game = job.build.game
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        let profile: String?
        switch job.match {
        case .tested(let p, _), .untestedVersion(let p, _, _): profile = p.id
        case .noProfile: profile = nil
        }
        let status: ConversionStatus = state == .succeeded ? .succeeded : state == .cancelled ? .cancelled : .failed
        appendRecord(ConversionRecord(
            id: UUID(), folder: job.folder.path, titleID: job.titleID, gameName: job.name, gameVersion: nonEmpty(game?.version),
            package: nonEmpty(game?.package) ?? nonEmpty(job.options.package), profile: nonEmpty(game?.profile) ?? profile,
            provisional: game?.provisional ?? (job.match == .noProfile), derived: game?.derived ?? false,
            builtAppPath: job.builtApp?.path, installedAppPath: job.installedApp?.path, startedAt: job.startedAt ?? Date(), finishedAt: job.finishedAt,
            status: status, message: message, nxnative: job.nxnative, options: job.options))
        Task { await refreshLibrary() }
        guard settings.notifyWhenDone else { return }
        switch state {
        case .succeeded where job.options.surveyOnly: Notifier.post(title: "\(job.name): survey written", body: job.surveyWritten?.path ?? "In the game folder.")
        case .succeeded: Notifier.post(title: "\(job.name) is ready", body: job.installedApp.map { "Installed in \($0.deletingLastPathComponent().path)." } ?? "The app is in the game folder.")
        case .failed: Notifier.post(title: "\(job.name) could not be converted", body: message ?? "See the log for details.")
        default: break
        }
    }
}
