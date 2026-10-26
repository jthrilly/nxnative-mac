// What can be done in the Library, in one place: a game app's actions (its tile's context menu, the toolbar, the inspector and the Library menu) and
// the actions on selected history records (the table's context menu and the Library menu)
import AppKit
import ConverterCore
import SwiftUI

enum LibraryAction: Hashable {
    case play, showInFinder, rebuild, openLog, openSaveFolder

    var title: String {
        switch self {
        case .play: "Play"
        case .showInFinder: "Show in Finder"
        case .rebuild: "Rebuild with Current nxnative"
        case .openLog: "Open Log"
        case .openSaveFolder: "Open Save Folder"
        }
    }

    var symbol: String {
        switch self {
        case .play: "play.fill"
        case .showInFinder: "folder"
        case .rebuild: "arrow.triangle.2.circlepath"
        case .openLog: "doc.plaintext"
        case .openSaveFolder: "externaldrive"
        }
    }

    /// Rebuild needs the record of the conversion that built the app
    func applies(to entry: LibraryEntry) -> Bool { self != .rebuild || entry.record != nil }

    /// `files` holds the Library's files that exist (WindowState.libraryFiles)
    func isEnabled(for entry: LibraryEntry, files: Set<URL>) -> Bool {
        switch self {
        case .play, .showInFinder: true
        case .rebuild: entry.record.map { files.contains($0.folderURL) } ?? false
        case .openLog: files.contains(entry.logFile)
        case .openSaveFolder: files.contains(entry.saveFolder)
        }
    }

    func help(for entry: LibraryEntry, files: Set<URL>) -> String {
        let enabled = isEnabled(for: entry, files: files)
        switch self {
        case .play: return "Open \(entry.app.name)"
        case .showInFinder: return "Show the app in Finder"
        case .rebuild: return enabled ? "Convert the game folder again with the current nxnative" : "The game folder is not there"
        case .openLog: return enabled ? entry.logFile.path : "The game has not written a log yet"
        case .openSaveFolder: return enabled ? entry.saveFolder.path : "The game has no save folder yet"
        }
    }

    @MainActor func perform(on entry: LibraryEntry, in model: AppModel) {
        switch self {
        case .play: NSWorkspace.shared.open(entry.app.url)
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([entry.app.url])
        case .rebuild: if let record = entry.record { model.rebuild(record) }
        case .openLog: NSWorkspace.shared.open(entry.logFile)
        case .openSaveFolder: NSWorkspace.shared.open(entry.saveFolder)
        }
    }

    /// A game app's menu: its tile's context menu
    fileprivate static let menu: [[LibraryAction]] = [[.play, .showInFinder, .rebuild], [.openLog, .openSaveFolder]]
}

/// What the history actions apply to: the newest selected record of each game folder that is still there, and of those the failed ones with a
/// title ID (one per game) for "Port with an Agent…". Remove from History applies to the whole selection
struct HistoryTargets {
    let ids: Set<UUID>
    let present: [ConversionRecord]
    let failed: [ConversionRecord]

    /// `records` newest first, as the table lists them
    init(_ ids: Set<UUID>, records: [ConversionRecord], files: Set<URL>) {
        self.ids = ids
        present = records.filter { ids.contains($0.id) && files.contains($0.folderURL) }
            .reduce(into: [ConversionRecord]()) { newest, record in if !newest.contains(where: { $0.folder == record.folder }) { newest.append(record) } }
        failed = present.filter { $0.status == .failed && $0.titleID != nil }
            .reduce(into: [ConversionRecord]()) { newest, record in if !newest.contains(where: { $0.titleID == record.titleID }) { newest.append(record) } }
    }

    var convertAgainTitle: String { present.count == 1 ? "Convert Again" : "Convert \(present.count) Games Again" }
    fileprivate var showFoldersTitle: String { present.count == 1 ? "Show Game Folder in Finder" : "Show Game Folders in Finder" }

    @MainActor func convertAgain(in model: AppModel) { present.forEach(model.rebuild) }
    func showFolders() { NSWorkspace.shared.activateFileViewerSelecting(present.map(\.folderURL)) }

    /// Removes the records and takes them out of the selection
    @MainActor func remove(in model: AppModel, window: WindowState) {
        model.removeRecords(ids)
        window.selectedRecords.subtract(ids)
    }
}

/// A game app's actions as menu items, text only
struct LibraryEntryMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    private let entry: LibraryEntry

    init(entry: LibraryEntry) { self.entry = entry }

    var body: some View {
        ForEach(LibraryAction.menu.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(LibraryAction.menu[index].filter { $0.applies(to: entry) }, id: \.self) { action in
                Button(action.title) { action.perform(on: entry, in: model) }
                    .disabled(!action.isEnabled(for: entry, files: window.libraryFiles))
                    .help(action.help(for: entry, files: window.libraryFiles))
            }
        }
    }
}

/// The history actions on records `ids` as menu items: the table's context menu
struct HistoryMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    private let ids: Set<UUID>

    init(ids: Set<UUID>) { self.ids = ids }

    var body: some View {
        let targets = HistoryTargets(ids, records: model.records.reversed(), files: window.libraryFiles)
        if !targets.present.isEmpty {
            Button(targets.convertAgainTitle) { targets.convertAgain(in: model) }
            if targets.failed.count == 1, let record = targets.failed.first {
                HistoryPortButton(record: record, title: "Port with an Agent…")
            } else if targets.failed.count > 1 {
                Menu("Port with an Agent") { ForEach(targets.failed) { HistoryPortButton(record: $0, title: $0.gameName + "…") } }
            }
            Button(targets.showFoldersTitle) { targets.showFolders() }
            Divider()
        }
        if !ids.isEmpty {
            Button("Remove from History", role: .destructive) { targets.remove(in: model, window: window) }
        }
    }
}

/// "Port with an Agent…" on a failed record, disabled with the reason as help when a port cannot start now
private struct HistoryPortButton: View {
    @Environment(AppModel.self) private var model
    private let record: ConversionRecord
    private let title: String

    init(record: ConversionRecord, title: String) { self.record = record; self.title = title }

    var body: some View {
        let block = model.portBlockReason(titleID: record.titleID)
        Button(title) { model.offerPort(for: record) }
            .disabled(block != nil)
            .help(block ?? "Hand the game to Claude Code or Codex, which attempts the port in a worktree of nxnative")
    }
}
