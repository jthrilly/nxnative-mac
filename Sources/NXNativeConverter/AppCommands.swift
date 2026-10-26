// The menu bar: every command of the toolbars, the More menus and the context menus, enabled by the same rules (JobAction, LibraryAction,
// PortAction and the model). ⌘R and ⌘. start and stop what the page shows: a conversion, or on the Ports page the agent.
// Commands get the model and the window state explicitly: views in a menu do not see the window's environment
import AppKit
import ConverterCore
import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    let window: WindowState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(LibraryTab.storageKey) private var libraryTab = LibraryTab.games
    @AppStorage(PortTab.storageKey) private var portTab = PortTab.overview

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Game Folder…") { show(); model.chooseGameFolders() }
                .keyboardShortcut("o")
            Divider()
            Button("Play") { show(); play?() }
                .disabled(play == nil)
            Button("Show in Finder") { show(); showInFinder?() }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(showInFinder == nil)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                Button(page.title) { show(); model.page = page }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
        }
        CommandMenu("Conversion") { conversionMenu }
        CommandMenu("Library") { libraryMenu }
        CommandMenu("Port") { portMenu }
        CommandMenu("nxnative") { repositoryMenu }
    }

    private var onPorts: Bool { model.shownPage == .ports }

    private func show() { openWindow(id: "main") }

    // MARK: File

    private var play: (() -> Void)? {
        switch model.shownPage {
        case .convert:
            guard let job = model.shownJob, JobAction.play.applies(to: job, in: model) else { return nil }
            return { JobAction.play.perform(on: job, in: model) }
        case .library:
            guard let entry = selectedEntry else { return nil }
            return { LibraryAction.play.perform(on: entry, in: model) }
        case .ports, .repository, .setup:
            return nil
        }
    }

    private var showInFinder: (() -> Void)? {
        switch model.shownPage {
        case .convert:
            guard let job = model.shownJob else { return nil }
            return { JobAction.showInFinder.perform(on: job, in: model) }
        case .library:
            if let entry = selectedEntry { return { LibraryAction.showInFinder.perform(on: entry, in: model) } }
            let targets = historyTargets
            return targets.present.isEmpty ? nil : { targets.showFolders() }
        case .ports:
            guard let port = model.shownPort, PortAction.showWorktree.isEnabled(for: port, in: model, files: window.portFiles) else { return nil }
            return { PortAction.showWorktree.perform(on: port, in: model, window: window) }
        case .repository, .setup:
            return nil
        }
    }

    // MARK: Conversion

    @ViewBuilder private var conversionMenu: some View {
        Button("Show Current Conversion") {
            show()
            if let job = model.activeJob { model.page = .convert; model.selectedJobID = job.id }
        }
        .disabled(model.activeJob == nil)
        Divider()
        Button("Start") { show(); model.startSelectedOrNext() }
            .keyboardShortcut(onPorts ? nil : KeyboardShortcut("r"))
            .disabled(!model.canStartAny)
        Button("Cancel Current") { show(); model.cancelCurrent() }
            .keyboardShortcut(onPorts ? nil : KeyboardShortcut("."))
            .disabled(!model.canCancelCurrent)
        Divider()
        jobItem(.retry, onConvert: true)
        jobItem(.convert, title: "Convert with Provisional Profile", onConvert: true)
        jobItem(.survey, onConvert: true)
        jobItem(.port, onConvert: true)
        jobItem(.chooseAnotherFolder, onConvert: true)
        Divider()
        jobItem(.showLogs, onConvert: true)
        jobItem(.openSurvey, onConvert: true)
        jobItem(.showProvisionalProfile, onConvert: true)
        Divider()
        jobItem(.remove, title: "Remove Game", onConvert: false)
        Button("Remove Finished") { show(); model.removeFinished() }
            .disabled(!model.jobs.contains { $0.state.isFinished })
    }

    /// A job action on the game the Convert page shows, enabled when it applies and can run (Open Survey and Show Provisional Profile when the job
    /// page found their files)
    private func jobItem(_ action: JobAction, title: String? = nil, onConvert: Bool) -> some View {
        let job = onConvert && model.shownPage != .convert ? nil : model.shownJob
        let enabled = job.map { action.applies(to: $0, in: model) && action.isEnabled(for: $0, in: model, files: window.jobFiles) } ?? false
        return Button(title ?? job.map { action.title(for: $0, in: model) } ?? action.title) {
            show()
            if let job { action.perform(on: job, in: model) }
        }
        .disabled(!enabled)
    }

    // MARK: Library

    /// Library › Games: the selected app
    private var selectedEntry: LibraryEntry? {
        guard model.shownPage == .library, libraryTab == .games, let id = window.selectedApp else { return nil }
        return model.library.first { $0.id == id }
    }

    /// Library › History: the selected records
    private var historyTargets: HistoryTargets {
        let ids = model.shownPage == .library && libraryTab == .history ? window.selectedRecords : []
        return HistoryTargets(ids, records: model.records.reversed(), files: window.libraryFiles)
    }

    @ViewBuilder private var libraryMenu: some View {
        libraryItem(.rebuild)
        libraryItem(.openLog)
        libraryItem(.openSaveFolder)
        Divider()
        let targets = historyTargets
        Button(targets.present.isEmpty ? "Convert Again" : targets.convertAgainTitle) { show(); targets.convertAgain(in: model) }
            .disabled(targets.present.isEmpty)
        if targets.failed.count > 1 {
            Menu("Port with an Agent") {
                ForEach(targets.failed) { record in historyPortItem(record, title: record.gameName + "…") }
            }
        } else if let record = targets.failed.first {
            historyPortItem(record, title: "Port with an Agent…")
        } else {
            Button("Port with an Agent…") {}.disabled(true)
        }
        Button("Remove from History") { show(); targets.remove(in: model, window: window) }
            .disabled(targets.ids.isEmpty)
        Divider()
        Button("Refresh Library") { show(); Task { await window.refreshLibrary(model) } }
            .disabled(window.refreshingLibrary)
    }

    private func libraryItem(_ action: LibraryAction) -> some View {
        let entry = selectedEntry
        let enabled = entry.map { action.applies(to: $0) && action.isEnabled(for: $0, files: window.libraryFiles) } ?? false
        return Button(action.title) {
            show()
            if let entry { action.perform(on: entry, in: model) }
        }
        .disabled(!enabled)
    }

    private func historyPortItem(_ record: ConversionRecord, title: String) -> some View {
        Button(title) { show(); model.offerPort(for: record) }
            .disabled(model.portBlockReason(titleID: record.titleID) != nil)
    }

    // MARK: Port

    @ViewBuilder private var portMenu: some View {
        Button("Show Running Agent") {
            show()
            if let run = model.activePortRun {
                model.page = .ports
                if model.selectedPortID != run.titleID { model.selectedRunID = nil }
                model.selectedPortID = run.titleID
                portTab = .transcript
            }
        }
        .disabled(model.activePortRun == nil)
        Divider()
        Button(PortAction.continueRun.title) {
            show()
            if let port = model.shownPort { model.page = .ports; model.continuePort(port) }
        }
        .keyboardShortcut(onPorts ? KeyboardShortcut("r") : nil)
        .disabled(!(model.shownPort.map(model.canStartRun) ?? false))
        Button(PortAction.stop.title) { show(); model.stopPortRun() }
            .keyboardShortcut(onPorts ? KeyboardShortcut(".") : nil)
            .disabled(!model.canStopPortRun)
        Divider()
        portItem(.openInTerminal)
        portItem(.showChanges)
        portItem(.saveCheckpoint)
        portItem(.rebase)
        portItem(.buildApp)
        Divider()
        portItem(.showGameFolder)
        Button("Refresh Ports") { show(); Task { await window.refreshPorts(model) } }
            .disabled(model.ports.isEmpty || !model.isReady)
        Divider()
        portItem(.remove)
    }

    /// A port action on the port the Ports page shows
    private func portItem(_ action: PortAction) -> some View {
        let port = model.shownPort
        return Button(action.title) {
            show()
            if let port { action.perform(on: port, in: model, window: window) }
        }
        .disabled(!(port.map { action.isEnabled(for: $0, in: model, files: window.portFiles) } ?? false))
    }

    // MARK: nxnative

    @ViewBuilder private var repositoryMenu: some View {
        Button("Check for Updates") { show(); model.page = .repository; Task { await model.checkForUpdates() } }
            .keyboardShortcut("u")
            .disabled(!model.canCheckForUpdates)
        Button("Update") { show(); model.page = .repository; Task { await model.update() } }
            .disabled(!model.canUpdate)
        Button(model.discardTitle + "…") { show(); model.page = .repository; window.confirmsDiscard = true }
            .disabled(!model.canDiscardAndUpdate)
        Divider()
        Button("Check Prerequisites") { show(); model.page = .setup; Task { await model.recheck() } }
            .disabled(!model.isReady || model.checking)
        Button("Install Missing Requirements") { show(); model.page = .setup; Task { await model.installMissing() } }
            .disabled(!model.canInstallMissing)
        Divider()
        Button("Rebuild nxnative Converter and Relaunch") { show(); model.page = .repository; Task { await model.rebuildConverter() } }
            .disabled(!model.canRebuildConverter)
        Button("Show nxnative in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.settings.repositoryURL]) }
            .disabled(model.repository?.exists != true)
    }
}
