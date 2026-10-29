// What can be done to a port, in one place: the port page's toolbar and More menu, the sidebar row's context menu and the Port menu all take their
// titles, enablement, help and work from PortAction. Also the view helpers on the model the port views share
import AppKit
import ConverterCore
import SwiftUI

enum PortAction: Hashable {
    case continueRun, stop, openInTerminal, showChanges, saveCheckpoint, rebase, buildApp, showWorktree, showGameFolder, refresh, remove

    var title: String {
        switch self {
        case .continueRun: "Continue…"
        case .stop: "Stop Agent"
        case .openInTerminal: "Open in Terminal"
        case .showChanges: "Show Changes"
        case .saveCheckpoint: "Save Checkpoint"
        case .rebase: "Rebase onto nxnative"
        case .buildApp: "Build App"
        case .showWorktree: "Show Worktree in Finder"
        case .showGameFolder: "Show Game Folder in Finder"
        case .refresh: "Refresh"
        case .remove: "Remove Port…"
        }
    }

    /// The toolbar's symbol; menus are text only
    var symbol: String {
        switch self {
        case .continueRun: "play.fill"
        case .stop: "stop.fill"
        case .openInTerminal: "apple.terminal"
        case .showChanges: "plus.forwardslash.minus"
        case .saveCheckpoint: "checkmark.circle"
        case .rebase: "arrow.triangle.pull"
        case .buildApp: "shippingbox"
        case .showWorktree: "folder"
        case .showGameFolder: "folder"
        case .refresh: "arrow.clockwise"
        case .remove: "trash"
        }
    }

    fileprivate var isDestructive: Bool { self == .remove }

    /// `files` holds the ports' folders and worktrees that exist (WindowState.portFiles)
    @MainActor func isEnabled(for port: PortRecord, in model: AppModel, files: Set<URL>) -> Bool {
        switch self {
        case .continueRun, .openInTerminal: model.canStartRun(port)
        case .stop: model.canStopPortRun(port.titleID)
        case .showChanges: model.portOperations[port.titleID] == nil
        case .saveCheckpoint, .rebase, .remove: model.canOperateOnPort(port)
        case .buildApp: model.canBuildApp(port)
        case .showWorktree: files.contains(port.workspaceURL)
        case .showGameFolder: files.contains(port.folderURL)
        case .refresh: !model.ports.isEmpty && model.isReady
        }
    }

    /// Stop's help needs no port: the page of a port that has no record yet shows it too
    static let stopHelp = "Stop the agent; its work is saved as a checkpoint (⌘.)"

    @MainActor fileprivate func help(for port: PortRecord, in model: AppModel, files: Set<URL>) -> String {
        let enabled = isEnabled(for: port, in: model, files: files)
        switch self {
        case .continueRun: return enabled ? "Start another agent run on this port (⌘R)" : model.portBlockReason(model.runBlock(port))
        case .openInTerminal: return enabled ? "Continue the port interactively in Terminal" : model.portBlockReason(model.runBlock(port))
        case .stop: return Self.stopHelp
        case .showChanges:
            return enabled ? "Show the changes on \(port.branch)" : "\(model.portOperations[port.titleID] ?? "An operation") is running on the worktree"
        case .saveCheckpoint: return enabled ? "Commit the worktree's changes on the port's branch" : model.portBlockReason(model.operationBlock(port))
        case .rebase: return enabled ? "Move the port's branch onto the nxnative checkout's commit" : model.portBlockReason(model.operationBlock(port))
        case .buildApp: return enabled ? "Convert the game with the port's worktree (its script and profile)" : model.portBlockReason(model.buildBlock(port))
        case .showWorktree: return enabled ? port.workspace : "The worktree is not there"
        case .showGameFolder: return enabled ? port.folder : "The game folder is not there"
        case .refresh: return "Read the worktrees' state again"
        case .remove: return enabled ? "Remove the worktree, the branch and the port's record" : model.portBlockReason(model.operationBlock(port))
        }
    }

    @MainActor func perform(on port: PortRecord, in model: AppModel, window: WindowState) {
        switch self {
        case .continueRun: model.continuePort(port)
        case .stop: model.stopPortRun(port.titleID)
        case .openInTerminal: model.openPortInTerminal(port)
        case .showChanges: Task { await model.showChanges(port) }
        case .saveCheckpoint: Task { await model.saveCheckpoint(port) }
        case .rebase: Task { await model.rebasePort(port) }
        case .buildApp: model.buildApp(port)
        case .showWorktree: NSWorkspace.shared.activateFileViewerSelecting([port.workspaceURL])
        case .showGameFolder: NSWorkspace.shared.activateFileViewerSelecting([port.folderURL])
        case .refresh: Task { await window.refreshPorts(model) }
        case .remove: model.portToRemove = port
        }
    }

    /// The sidebar row's context menu. The port page's More menu has only the actions its toolbar does not show
    static let menu: [[PortAction]] = [[.continueRun, .openInTerminal], [.showChanges, .saveCheckpoint, .rebase, .buildApp],
                                       [.showWorktree, .showGameFolder, .refresh], [.remove]]
}

/// A port action as a toolbar or page button: a text button in the prominent glass style, or the action's title and symbol
struct PortActionButton: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    private let action: PortAction
    private let port: PortRecord
    private let prominent: Bool

    init(_ action: PortAction, port: PortRecord, prominent: Bool = false) {
        self.action = action; self.port = port; self.prominent = prominent
    }

    var body: some View {
        Group {
            if prominent {
                Button(action.title) { action.perform(on: port, in: model, window: window) }.buttonStyle(.glassProminent)
            } else {
                Button(action.title, systemImage: action.symbol, role: action.isDestructive ? .destructive : nil) {
                    action.perform(on: port, in: model, window: window)
                }
            }
        }
        .disabled(!action.isEnabled(for: port, in: model, files: window.portFiles))
        .help(action.help(for: port, in: model, files: window.portFiles))
    }
}

/// Port actions as menu items, text only, with a divider between sections
struct PortActionMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    private let sections: [[PortAction]]
    private let port: PortRecord

    init(_ sections: [[PortAction]] = PortAction.menu, port: PortRecord) {
        self.sections = sections; self.port = port
    }

    var body: some View {
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self) { action in
                Button(action.title, role: action.isDestructive ? .destructive : nil) { action.perform(on: port, in: model, window: window) }
                    .disabled(!action.isEnabled(for: port, in: model, files: window.portFiles))
                    .help(action.help(for: port, in: model, files: window.portFiles))
            }
        }
    }
}

extension AppModel {
    /// Show Running Agent: the agent after the shown port's one (wrapping), or the newest when the shown port has none
    var nextRunToShow: PortRun? {
        guard let i = activePortRuns.firstIndex(where: { shownPage == .ports && $0.titleID == shownPortID }) else { return activePortRuns.last }
        return activePortRuns[(i + 1) % activePortRuns.count]
    }

    /// The port the Ports page shows (a title ID): the selected one, else the newest running agent's, else the newest, the top row of the sidebar
    var shownPortID: String? {
        if let id = selectedPortID, port(id) != nil || activeRun(id) != nil { return id }
        return activePortRuns.last?.titleID ?? ports.last?.titleID
    }

    /// The record of the port shown; nil while the running agent prepares a port that has no record yet
    var shownPort: PortRecord? { shownPortID.flatMap(port) }

    /// Why a port's action cannot run now: the rule that blocks it, else the app's own state
    func portBlockReason(_ block: PortBlock?) -> String {
        if let block { return block.message }
        return isQuitting ? "nxnative Converter is quitting." : "The shell environment is not ready yet."
    }

    /// The run the transcript shows: the one chosen in the table, else the running one, else the newest
    func shownRun(of port: PortRecord) -> AgentRunRecord? {
        if let id = selectedRunID, let run = port.runs.first(where: { $0.id == id }) { return run }
        if let id = activeRun(port.titleID)?.id, let run = port.runs.first(where: { $0.id == id }) { return run }
        return port.runs.last
    }
}
