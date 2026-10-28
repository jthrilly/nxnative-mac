// The main window: the sidebar and the page it shows, the window-wide drop target for game folders, the running-work items in the toolbar, the app's
// alerts and the confirmations and sheets any page, the sidebar or the menu bar can raise. WindowState holds the view state the pages, the window and
// the menus share, and the file checks they enable their actions by
import AppKit
import ConverterCore
import SwiftUI

/// The view state shared by the pages, the main window and the menu bar
@MainActor @Observable final class WindowState {
    /// Library › Games: the selected app (a LibraryEntry's id)
    var selectedApp: URL?
    /// Library › History: the selected records
    var selectedRecords: Set<UUID> = []
    /// Asks before Discard Local Changes and Update (the alert is the main window's)
    var confirmsDiscard = false
    private(set) var refreshingLibrary = false
    /// The Library's files that exist: each app's log file and save folder, and the game folders of the records
    private(set) var libraryFiles: Set<URL> = []
    /// The ports' folders and worktrees that exist
    private(set) var portFiles: Set<URL> = []
    /// The files of the game the Convert page shows that exist: its survey and its provisional profile's game.tsv
    private(set) var jobFiles: Set<URL> = []
    /// Bumped to check the files again: when the app becomes active, and after a refresh
    private(set) var fileChecks = 0

    fileprivate func recheckFiles() { fileChecks += 1 }

    /// Library › Refresh: looks for game apps again, then checks the files again
    func refreshLibrary(_ model: AppModel) async {
        guard !refreshingLibrary else { return }
        refreshingLibrary = true
        await model.refreshLibrary()
        refreshingLibrary = false
        recheckFiles()
    }

    /// Refresh Ports: reads the worktrees' state again, then checks the files again
    func refreshPorts(_ model: AppModel) async {
        await model.refreshPortStatuses()
        recheckFiles()
    }

    fileprivate func checkLibraryFiles(_ urls: [URL]) async { libraryFiles = await FileCheck.existing(urls) }
    fileprivate func checkPortFiles(_ urls: [URL]) async { portFiles = await FileCheck.existing(urls) }

    /// The job page's check: a check its .task cancelled, for a job no longer shown or a state it has left, must not overwrite the newer one
    func checkJobFiles(_ job: ConversionJob) async {
        let found = await FileCheck.existing([JobAction.openSurvey, .showProvisionalProfile].compactMap { $0.file(for: job) })
        guard !Task.isCancelled else { return }
        jobFiles = found
    }

    /// Selections of apps and records that are gone
    fileprivate func prune(_ model: AppModel) {
        if let app = selectedApp, !model.library.contains(where: { $0.id == app }) { selectedApp = nil }
        let records = Set(model.records.map(\.id))
        if !selectedRecords.isSubset(of: records) { selectedRecords.formIntersection(records) }
    }
}

/// The job page's tabs
enum JobTab: String {
    case stages, log
    static let storageKey = "jobDetailTab"
}

/// The Library's tabs
enum LibraryTab: String {
    case games, history
    static let storageKey = "libraryTab"
}

/// The port page's tabs
enum PortTab: String {
    case overview, runs, transcript
    static let storageKey = "portDetailTab"
}

/// The Settings window's tabs
enum SettingsTab: String {
    case general, conversion, install, agents
    static let storageKey = "settingsTab"
}

extension AppModel {
    /// The page shown: nil is the Convert page, as the sidebar's selection can be empty
    var shownPage: Page { page ?? .convert }

    // One rule for each nxnative and Setup command, shared by the menu bar, the toolbars and the pages
    var canCheckForUpdates: Bool { canOperate && repository?.isGitRepository == true }
    var canUpdate: Bool { canOperate && incomingCount > 0 }
    var canDiscardAndUpdate: Bool { canOperate && pullBlockedByLocalChanges }
    var canInstallMissing: Bool { canOperate && missingRunFixes > 0 }

    /// Discard Local Changes and Update, naming the local commits too when the reset takes them off the branch
    var discardTitle: String {
        let commits = repository?.outgoing.count ?? 0
        return commits == 0 ? "Discard Local Changes and Update" : "Discard Local Changes and \(commits) Commit\(commits == 1 ? "" : "s") and Update"
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        @Bindable var window = window
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: ColumnWidth.sidebarMax)
        } detail: {
            DetailRouter()
                .splitColumnContent()
                .environment(\.dropTargeted, dropTargeted)
                // The container is there before the card, so the card's glass transition applies when it appears
                .overlay { GlassEffectContainer { if showsDropOverlay { DropCard() } }.allowsHitTesting(false) }
                .motion(.easeOut(duration: 0.15), value: showsDropOverlay)
                .toolbar { ActivityToolbar() }
        }
        .dropDestination(for: DroppedFile.self) { files, _ in
            if !files.isEmpty { model.addFolders(files.map(\.url)) }
        }
        .onDropSessionUpdated { session in dropTargeted = session.phase == .entering || session.phase == .active }
        .overlay { if showsDropOverlay { DropOverlay() } }
        .motion(.easeOut(duration: 0.15), value: showsDropOverlay)
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK") {}
        } message: { Text($0.message) }
        .alert(removePortTitle, isPresented: Binding(get: { model.portToRemove != nil }, set: { if !$0 { model.portToRemove = nil } }),
               presenting: model.portToRemove) { port in
            Button("Remove Port", role: .destructive) { Task { await model.removePort(port) } }
            Button("Cancel", role: .cancel) {}
        } message: { port in
            Text(Self.removePortMessage(port))
        }
        .alert(model.discardTitle + "?", isPresented: $window.confirmsDiscard) {
            Button("Discard and Update", role: .destructive) { Task { await model.discardLocalChangesAndUpdate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(discardMessage)
        }
        .sheet(item: $model.portSheet) { request in
            StartPortSheet(request: request, settings: model.settings, lastKind: model.port(request.titleID)?.runs.last?.kind)
                .environment(model)
        }
        .sheet(item: $model.diffSheet) { ChangesSheet(item: $0) }
        .sheet(item: $model.settingsSheet) { GameSettingsSheet(entry: $0).environment(model) }
        .task(id: model.isReady) { await model.refreshPortStatuses() }
        .task(id: LibraryFiles(model, generation: window.fileChecks)) { await window.checkLibraryFiles(LibraryFiles.urls(model)) }
        .task(id: PortPaths(model.ports, statuses: model.portStatuses, generation: window.fileChecks, shown: model.shownPortID)) {
            await window.checkPortFiles(PortPaths.urls(model.ports))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in window.recheckFiles() }
        .onChange(of: model.library.map(\.id)) { window.prune(model) }
        .onChange(of: model.records.map(\.id)) { window.prune(model) }
    }

    // The empty Convert page's drop stage answers a drag by itself
    private var showsDropOverlay: Bool { dropTargeted && !(model.shownPage == .convert && model.jobs.isEmpty) }

    private var removePortTitle: String { "Remove the Port of \(model.portToRemove?.gameName ?? "")?" }

    private static func removePortMessage(_ port: PortRecord) -> String {
        "This removes the worktree \(port.workspace.abbreviatedPath) and the branch \(port.branch) with every commit on it, "
            + "and the port's record. Its transcripts go to the Trash. The game folder is not touched."
    }

    // Built here, not in the alert's builder: Swift cannot type-check it there in reasonable time
    private var discardMessage: String {
        guard let status = model.repository else { return "git reset --hard @{u} throws away the local changes and commits. This cannot be undone." }
        return RepositoryAdvice.resetWarning(status)
    }
}

/// The page the sidebar selects
private struct DetailRouter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.shownPage {
        case .convert:
            if let job = model.shownJob {
                JobPage(job: job).id(job.id)
            } else {
                ConvertLanding()
            }
        case .library: LibraryPage()
        case .ports: PortPage()
        case .repository: RepositoryPage()
        case .setup: SetupPage()
        }
    }
}

/// A file or folder dragged onto the window. Only file URLs import, not URL's web links, so a link dragged over the window does not show the drop
/// card and slides back when dropped
private struct DroppedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            return DroppedFile(url: url)
        }
    }
}

/// What the check of the Library's files is keyed on: the files, and the generation of checks asked for
private struct LibraryFiles: Equatable {
    var urls: [URL]
    var generation: Int

    @MainActor init(_ model: AppModel, generation: Int) {
        urls = Self.urls(model); self.generation = generation
    }

    @MainActor static func urls(_ model: AppModel) -> [URL] {
        model.library.flatMap { entry in [entry.logFile, entry.saveFolder] + (entry.record.map { [$0.folderURL] } ?? []) + (entry.xcodeWorkspace.map { [$0] } ?? []) }
            + model.records.map(\.folderURL)
    }
}

/// What the check of the ports' folders and worktrees is keyed on: their paths, whether each worktree was there when last read, the runs, the
/// generation of checks asked for and the port shown (selecting a port checks again)
private struct PortPaths: Hashable {
    var paths: [String]
    var worktrees: [String: Bool]
    var runs: Int
    var generation: Int
    var shown: String?

    init(_ ports: [PortRecord], statuses: [String: PortWorkspaceStatus], generation: Int, shown: String?) {
        paths = ports.flatMap { [$0.folder, $0.workspace] }
        worktrees = statuses.mapValues(\.exists)
        runs = ports.reduce(0) { $0 + $1.runs.count }
        self.generation = generation
        self.shown = shown
    }

    static func urls(_ ports: [PortRecord]) -> [URL] {
        ports.flatMap { [$0.folder, $0.workspace] }.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
