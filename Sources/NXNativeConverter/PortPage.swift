// The Ports page, in one of three states: no port yet, an agent preparing a port that has no record yet, or the shown port with its header (artwork,
// milestones, what runs on it now) and the Overview, Runs and Transcript tabs, the port's actions in the toolbar. The store's notice tops every state
import AppKit
import ConverterCore
import SwiftUI

struct PortPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.portsNotice {
                PortsStoreNoticeBanner(notice: notice)
                    .padding(.horizontal, Space.page)
                    .padding(.top, Space.m)
            }
            state
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var state: some View {
        if let port = model.shownPort {
            PortDetailView(port: port).id(port.titleID)
        } else if let run = model.activeRun(model.shownPortID) {
            PortPreparingView(run: run)
        } else {
            PortsEmptyView()
        }
    }
}

/// What this launch's read of the ports store reported (the ports that could be read are listed), with the file it kept as it was
private struct PortsStoreNoticeBanner: View {
    @Environment(AppModel.self) private var model
    let notice: PortsStoreNotice

    var body: some View {
        Notice(.warning, title: notice.title, message: notice.message) {
            if let file = notice.file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .help("Show the file that could not be read in Finder")
            }
            Button("Dismiss") { model.portsNotice = nil }
                .help("Hide this notice")
        }
    }
}

private struct PortsEmptyView: View {
    @Environment(AppModel.self) private var model

    private static let message = "A port is an attempt to make a game nxnative has no profile for work on the Mac. "
        + "An AI coding agent — Claude Code or Codex — follows nxnative's porting guide in a git worktree of its own, here in the app or in Terminal, "
        + "and reports how far it got."
    private static let detail = "Start one with “Port with an Agent…” on a game without a profile or a failed conversion on the Convert page, "
        + "or on a failed conversion in the Library's history."

    var body: some View {
        ContentUnavailableView {
            Label("Port a game nxnative doesn't know yet", systemImage: "hammer.fill")
        } description: {
            Text(Self.message + "\n\n" + Self.detail)
        } actions: {
            Button("Go to Convert") { model.page = .convert }
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Ports")
    }
}

/// An agent run on a game with no port record yet: the worktree is being made. Its transcript fills the page
private struct PortPreparingView: View {
    @Environment(AppModel.self) private var model
    let run: PortRun

    var body: some View {
        VStack(spacing: Space.l) {
            PortHeaderLayout(artwork: .gameFolder(run.folder, titleID: run.titleID), name: run.gameName, titleID: run.titleID, agent: run.kind.displayName) {
                StatusChip("Preparing", symbol: "hourglass")
            } details: {
                PortActivityLine(text: run.phase, startedAt: run.startedAt)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.l)
            AgentTranscriptView(transcript: run.transcript, kind: run.kind, rawFile: run.transcriptFile, live: !run.finished)
                .id(run.id)
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.l)
        }
        .navigationTitle(run.gameName)
        .navigationSubtitle("\(run.kind.displayName) is preparing")
        .toolbar {
            ToolbarItem {
                Button(PortAction.stop.title, systemImage: PortAction.stop.symbol) { model.stopPortRun(run.titleID) }
                    .disabled(!model.canStopPortRun(run.titleID))
                    .help(PortAction.stopHelp)
            }
        }
    }
}

private struct PortDetailView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PortTab.storageKey) private var tab = PortTab.overview
    let port: PortRecord

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                header
                if model.terminalSessions.contains(port.titleID) { PortTerminalSessionNotice() }
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.l)
            Picker("View", selection: $tab) {
                Text("Overview").tag(PortTab.overview)
                Text("Runs").tag(PortTab.runs)
                Text("Transcript").tag(PortTab.transcript)
            }
            .pickerStyle(.tabs)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, minHeight: 40)
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(port.gameName)
        .modifier(PortSubtitle(running: runningSince, idle: idleSubtitle))
        .toolbar { toolbar }
        .task(id: port.titleID) { await model.refreshPortStatus(port.titleID) }
    }

    /// The agent and its start, while it runs on this port
    private var runningSince: PortSubtitle.Running? {
        guard let run = model.activeRun(port.titleID) else { return nil }
        return PortSubtitle.Running(agent: run.kind.displayName, startedAt: run.startedAt)
    }

    private var idleSubtitle: String {
        var parts = [port.latestReport?.milestone.title ?? "No report yet", "\(port.runs.count) run\(port.runs.count == 1 ? "" : "s")"]
        if port.totalCostUSD > 0 { parts.append(PortRunFormat.cost(port.totalCostUSD)) }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        PortHeaderLayout(artwork: .gameFolder(port.folderURL, titleID: port.titleID), name: port.gameName, titleID: port.titleID,
                         agent: port.runs.last?.kind.displayName, cost: port.totalCostUSD > 0 ? port.totalCostUSD : nil) {
            if let milestone = port.latestReport?.milestone {
                StatusChip(milestone.title, symbol: milestone.symbol, tone: milestone.tone)
                    .help("The highest milestone the agent reported")
                    .accessibilityLabel("Milestone: \(milestone.title)")
            } else {
                StatusChip("No report yet")
            }
            if let run = runningSince {
                StatusChip("\(run.agent) running", symbol: "bolt.circle.fill", tone: .info)
            }
        } details: {
            MilestoneTrack(milestone: port.latestReport?.milestone)
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.vertical, Space.xs)
            if let operation = model.portOperations[port.titleID] {
                PortActivityLine(text: operation, startedAt: nil)
            } else if let run = model.activeRun(port.titleID) {
                PortActivityLine(text: run.phase, startedAt: run.startedAt)
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .overview:
            PortOverviewForm(port: port)
        case .runs:
            PortRunsTable(port: port)
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.l)
        case .transcript:
            PortTranscriptTab(port: port)
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.l)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            PortActionButton(.buildApp, port: port)
            PortActionButton(.showChanges, port: port)
            PortActionButton(.openInTerminal, port: port)
            Menu("More", systemImage: "ellipsis") {
                PortActionMenuItems([[.saveCheckpoint, .rebase], [.showWorktree, .showGameFolder, .refresh], [.remove]], port: port)
            }
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityLabel("More Actions")
        }
        ToolbarSpacer(.fixed)
        if model.isRunning(port) {
            ToolbarItem { PortActionButton(.stop, port: port) }
        } else {
            ToolbarItem { PortActionButton(.continueRun, port: port, prominent: true) }
                .visibilityPriority(.high)
        }
    }
}

/// The window's subtitle under a port's name: the running agent and how long it has run (ticking), else the port's state
private struct PortSubtitle: ViewModifier {
    struct Running: Equatable {
        var agent: String
        var startedAt: Date
    }

    let running: Running?
    let idle: String
    @State private var now = Date.now

    func body(content: Content) -> some View {
        content
            .navigationSubtitle(running.map { "\($0.agent) is working · " + ProgressFormat.duration(now.timeIntervalSince($0.startedAt)) } ?? idle)
            .task(id: running) {
                guard running != nil else { return }
                while !Task.isCancelled {
                    now = .now
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

/// A port's header, also for a port being prepared: the artwork, the name, "title ID · agent · cost", the chips, then what follows them
private struct PortHeaderLayout<Chips: View, Details: View>: View {
    let artwork: ArtworkSource
    let name: String
    let titleID: String
    let agent: String?
    var cost: Double?
    @ViewBuilder let chips: Chips
    @ViewBuilder let details: Details

    var body: some View {
        HStack(alignment: .top, spacing: Space.l) {
            GameArtwork(artwork, name: name, size: 64)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(name).font(.title.bold()).lineLimit(2).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    Text(titleID).monospaced().textSelection(.enabled)
                    if let agent {
                        Text("·").accessibilityHidden(true)
                        Text(agent)
                    }
                    if let cost {
                        Text("·").accessibilityHidden(true)
                        Text(PortRunFormat.cost(cost)).help("What the agent runs cost so far (as Claude Code reports it)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                ChipRow { chips }
                    .padding(.top, 2)
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What runs on the port now, after a small spinner: a worktree operation, or the agent's phase and how long it has run
private struct PortActivityLine: View {
    let text: String
    let startedAt: Date?

    var body: some View {
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(text).lineLimit(1)
            if let startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("· " + ProgressFormat.duration(context.date.timeIntervalSince(startedAt))).monospacedDigit()
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct PortTerminalSessionNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Notice(.info, title: "Agent session open in Terminal", message: PortBlock.terminalSession.message, symbol: "apple.terminal") {
            Button("Check Again") { model.refreshTerminalSessions() }
                .help("Look again whether the Terminal session has ended")
        }
    }
}

// MARK: - Overview

private struct PortOverviewForm: View {
    @Environment(AppModel.self) private var model
    let port: PortRecord

    var body: some View {
        Form {
            if let run = model.liveRun(model.shownRun(of: port)?.id), !run.leftOut.isEmpty {
                PortLeftOutSection(files: run.leftOut)
            }
            Section("Latest Report") { PortReportRows(report: port.latestReport) }
            PortWorktreeSection(port: port)
        }
        .formStyle(.grouped)
    }
}

/// What the run's checkpoint did not take, and why: the files are still in the worktree, uncommitted
private struct PortLeftOutSection: View {
    let files: [SkippedFile]

    var body: some View {
        Section {
            Notice(.warning, title: "\(files.count) file\(files.count == 1 ? " was" : "s were") left out of the checkpoint",
                   message: "They stay in the worktree but are not committed on the port's branch.", onCard: false)
            DisclosureGroup("Files Left Out") {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(file.path).font(.monoSmall).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(file.path)
                        Spacer(minLength: Space.s)
                        Text(PortRules.reason(file.reason)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct PortReportRows: View {
    let report: AgentReport?

    var body: some View {
        if let report {
            if !report.summary.isEmpty {
                Text(report.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            list("Next Steps", report.nextSteps, symbol: "arrow.right.circle.fill", tone: .brand)
            list("Blockers", report.blockers, symbol: "exclamationmark.octagon.fill", tone: .failure)
            if !report.changedFiles.isEmpty {
                DisclosureGroup(report.changedFiles.count == 1 ? "1 Changed File" : "\(report.changedFiles.count) Changed Files") {
                    ForEach(Array(report.changedFiles.enumerated()), id: \.offset) { _, path in
                        Text(path).font(.monoSmall).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
                    }
                }
            }
        } else {
            Text("No report yet. The agent writes one at the end of each unattended run: how far it got, what it changed, what comes next.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func list(_ title: String, _ items: [String], symbol: String, tone: Tone) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                Label {
                    Text(title).foregroundStyle(tone.text)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tone.glyph)
                }
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(item).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, Space.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PortWorktreeSection: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    let port: PortRecord

    var body: some View {
        Section("Worktree") {
            LabeledContent("Game Folder") { path(port.folder, reveal: .showGameFolder) }
            LabeledContent("Worktree") { path(port.workspace, reveal: .showWorktree) }
            LabeledContent("Branch") {
                Text(port.branch).font(.monoSmall).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(port.branch)
            }
            LabeledContent("Base") { Text(baseText).font(.monoSmall).textSelection(.enabled) }
            if let status {
                if status.exists {
                    LabeledContent("nxnative") {
                        if status.commitsBehind > 0 { warning(aheadBehind(status)) } else { Text(aheadBehind(status)) }
                    }
                    LabeledContent("Changes") { Text(changes(status)) }
                    if !status.uncommittedFiles.isEmpty {
                        LabeledContent("Uncommitted") {
                            Text("\(status.uncommittedFiles.count) file\(status.uncommittedFiles.count == 1 ? "" : "s")")
                                .help(status.uncommittedFiles.prefix(40).joined(separator: "\n"))
                        }
                    }
                } else {
                    LabeledContent("State") { warning("The worktree is missing: the next run makes it again from the branch.") }
                }
            }
            LabeledContent("Created") { Text(port.createdAt.formatted(date: .abbreviated, time: .shortened)) }
        }
    }

    private var status: PortWorkspaceStatus? { model.portStatuses[port.titleID] }

    private var baseText: String {
        let base = status?.base ?? port.baseCommit
        return base.isEmpty ? "unknown" : String(base.prefix(9))
    }

    private func path(_ path: String, reveal: PortAction) -> some View {
        HStack(spacing: Space.xs) {
            Text(path.abbreviatedPath)
                .font(.monoSmall)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
            Button(reveal.title, systemImage: "magnifyingglass") { reveal.perform(on: port, in: model, window: window) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .disabled(!reveal.isEnabled(for: port, in: model, files: window.portFiles))
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(Tone.warning.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.glyph)
        }
    }

    private func aheadBehind(_ s: PortWorkspaceStatus) -> String {
        let ahead = "\(s.commitsAhead) commit\(s.commitsAhead == 1 ? "" : "s") ahead"
        return s.commitsBehind == 0 ? ahead + ", up to date" : ahead + ", \(s.commitsBehind) behind (Rebase onto nxnative brings them in)"
    }

    private func changes(_ s: PortWorkspaceStatus) -> String {
        guard s.filesChanged > 0 else { return "none since the base" }
        return "\(s.filesChanged) file\(s.filesChanged == 1 ? "" : "s"), +\(s.insertions.formatted()) \u{2212}\(s.deletions.formatted())"
    }
}
