// The nxnative page: the checkout's status as Software Update tells it (blocked by local changes, behind, no upstream, never checked, up to date), the
// offer to rebuild this app and the last git error, the checkout's facts, its local changes and commits and the incoming ones; downloading nxnative when
// it is missing; and the console of the git operations below
import ConverterCore
import SwiftUI

struct RepositoryPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VSplitView {
            content.frame(minHeight: 240, maxHeight: .infinity)
            if !model.console.lines.isEmpty || model.console.isRunning {
                OutputPane().frame(minHeight: 120, idealHeight: 200)
            }
        }
        .navigationTitle("nxnative")
        .navigationSubtitle(model.repository?.branch.map { "on \($0)" } ?? "")
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let upstream = model.repository?.upstream
        ToolbarItem {
            Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") { Task { await model.checkForUpdates() } }
                .help("Fetch from \(upstream ?? "the remote") (⌘U)")
                .disabled(!model.canCheckForUpdates)
        }
        ToolbarSpacer(.fixed)
            .hidden(model.incomingCount == 0)
        ToolbarItem {
            Button("Update") { Task { await model.update() } }
                .buttonStyle(.glassProminent)
                .help("Fast-forward to \(upstream ?? "the upstream branch")")
                .disabled(!model.canUpdate)
        }
        .visibilityPriority(.high)
        .hidden(model.incomingCount == 0)
    }

    @ViewBuilder private var content: some View {
        if let status = model.repository {
            if status.exists && status.isNXNative { CheckoutForm(status: status) } else { MissingCheckout(status: status) }
        } else {
            ProgressView("Reading the repository…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The checkout of nxnative: its status, the notices, its facts, and the commits on either side of its upstream
private struct CheckoutForm: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    let status: RepositoryStatus

    var body: some View {
        Form {
            statusSection
            notices
            checkoutSection
            if !status.modifiedFiles.isEmpty { localChangesSection }
            if !status.outgoing.isEmpty { localCommitsSection }
            if status.behind > 0 { updatesSection }
        }
        .formStyle(.grouped)
    }

    private static let converterUpdateMessage = "The checkout has changes to the converter since this copy was built. "
        + "Rebuilding takes a minute; the app then opens again."

    private var waitNote: some View {
        Text("Updates wait until the conversion has finished.").foregroundStyle(.secondary)
    }

    // The note that updates wait goes under the incoming commits, or under the status when there are none
    private var statusSection: some View {
        let summary = StatusSummary.of(status, pullBlocked: model.pullBlockedByLocalChanges)
        return Section {
            if model.pullBlockedByLocalChanges {
                PageStatusRow(summary.title, subtitle: summary.subtitle, symbol: summary.symbol, tone: summary.tone) {
                    Button(model.discardTitle + "…", role: .destructive) { window.confirmsDiscard = true }
                        .buttonStyle(.bordered)
                        .disabled(!model.canDiscardAndUpdate)
                }
            } else {
                PageStatusRow(summary.title, subtitle: summary.subtitle, symbol: summary.symbol, tone: summary.tone)
            }
        } footer: {
            if model.isConverting && status.behind == 0 { waitNote }
        }
    }

    @ViewBuilder private var notices: some View {
        if model.converterUpdateAvailable || model.lastGitError != nil {
            Section {
                if model.converterUpdateAvailable {
                    PageStatusRow("A new version of nxnative Converter is available", subtitle: Self.converterUpdateMessage, symbol: "sparkles", tone: .brand,
                                  symbolFont: .title2) {
                        Button("Rebuild and Relaunch") { Task { await model.rebuildConverter() } }
                            .buttonStyle(.bordered)
                            .disabled(!model.canRebuildConverter)
                    }
                }
                if let error = model.lastGitError { Notice(.failure, message: error, onCard: false) }
            }
        }
    }

    private var checkoutSection: some View {
        Section("Checkout") {
            PathRow("Folder", path: status.path.path, placeholder: "", chooseDisabled: model.isConverting) { model.chooseRepositoryFolder() }
            LabeledContent("Branch", value: status.branch ?? "detached HEAD")
            LabeledContent("Upstream", value: status.upstream ?? "none")
            if let remote = status.remoteURL {
                LabeledContent("Remote") { Text(remote).font(.mono).textSelection(.enabled) }
            }
            if let head = status.head {
                LabeledContent("Version") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(head.subject).lineLimit(2).multilineTextAlignment(.trailing)
                        HStack(spacing: 0) {
                            Text(head.shortSHA).font(.mono)
                            Text(" · " + head.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                }
            }
            if status.ahead > 0 {
                LabeledContent("Local Commits", value: "\(status.ahead) not on \(status.upstream ?? "the upstream")")
            }
            LabeledContent("Last Checked", value: status.lastFetched.map { $0.formatted(.relative(presentation: .named)) } ?? "never")
        }
    }

    private var localChangesSection: some View {
        Section {
            ForEach(status.modifiedFiles, id: \.self) { Text($0).font(.mono).textSelection(.enabled) }
        } header: {
            Text("Local Changes")
        } footer: {
            Text("Tracked files changed in the checkout. An update that touches them stops; you can then discard them.").foregroundStyle(.secondary)
        }
    }

    /// The commits a reset to the upstream takes off the branch, listed before Discard is offered
    private var localCommitsSection: some View {
        let count = max(status.ahead, status.outgoing.count)
        return Section {
            ForEach(status.outgoing) { CommitRow(commit: $0) }
            if count > status.outgoing.count { Text("… and \(count - status.outgoing.count) more").foregroundStyle(.secondary) }
        } header: {
            Text("\(count) Local Commit\(count == 1 ? "" : "s")")
        } footer: {
            Text("Commits on this branch that are not on \(status.upstream ?? "the upstream"). "
                 + "Discarding the local changes takes them off the branch too; only git's reflog keeps them.")
                .foregroundStyle(.secondary)
        }
    }

    private var updatesSection: some View {
        Section {
            ForEach(status.incoming) { CommitRow(commit: $0) }
            if status.behind > status.incoming.count { Text("… and \(status.behind - status.incoming.count) more").foregroundStyle(.secondary) }
        } header: {
            Text("\(status.behind) New Commit\(status.behind == 1 ? "" : "s")")
        } footer: {
            if model.isConverting { waitNote }
        }
    }
}

/// The checkout's status in one sentence: the first of these states that holds
private struct StatusSummary {
    let title: String
    let subtitle: String
    let symbol: String
    let tone: Tone

    static func of(_ status: RepositoryStatus, pullBlocked: Bool) -> StatusSummary {
        if pullBlocked {
            return StatusSummary(title: "Local changes stop the update", subtitle: "Discard them to update, or commit them first.",
                                 symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
        if status.behind > 0 {
            return StatusSummary(title: "\(status.behind) new commit\(status.behind == 1 ? "" : "s") in nxnative",
                                 subtitle: "Update brings them in. Games built before can be rebuilt from the Library.",
                                 symbol: "arrow.down.circle.fill", tone: .info)
        }
        guard let upstream = status.upstream else {
            return StatusSummary(title: "This branch has no upstream branch", subtitle: "nxnative can't be updated from here.",
                                 symbol: "minus.circle", tone: .neutral)
        }
        guard let fetched = status.lastFetched else {
            return StatusSummary(title: "nxnative hasn't been checked for updates", subtitle: "Check for Updates fetches from \(upstream).",
                                 symbol: "questionmark.circle", tone: .neutral)
        }
        let checked = "checked " + fetched.formatted(.relative(presentation: .named))
        return StatusSummary(title: "nxnative is up to date", subtitle: status.head.map { "\($0.shortSHA) · \($0.subject) · \(checked)" } ?? checked,
                             symbol: "checkmark.seal.fill", tone: .success)
    }
}

private struct CommitRow: View {
    let commit: CommitInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(commit.shortSHA).font(.mono).foregroundStyle(.secondary)
            Text(commit.subject).font(.callout).lineLimit(2)
            Spacer()
            Text(commit.date.formatted(date: .abbreviated, time: .omitted)).font(.callout).foregroundStyle(.secondary)
        }
        .help("\(commit.author) · \(commit.sha)")
    }
}

/// The folder is missing, empty or holds something else: choose another, or download nxnative into it when git can
private struct MissingCheckout: View {
    @Environment(AppModel.self) private var model
    let status: RepositoryStatus
    @State private var checked: EmptinessCheck?

    /// Whether the folder is empty, nil until it has been checked: the last check of the same folder holds while it is checked again
    private var emptyFolder: Bool? {
        guard status.exists else { return false }
        return checked.flatMap { $0.path == status.path ? $0.empty : nil }
    }

    var body: some View {
        Group {
            if let emptyFolder {
                // git clone also fills an empty folder
                unavailable(canClone: !status.exists || emptyFolder)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: status) {
            guard status.exists else { return }
            let path = status.path
            checked = EmptinessCheck(path: path, empty: await Self.isEmptyFolder(path))
        }
    }

    private func unavailable(canClone: Bool) -> some View {
        ContentUnavailableView {
            Label(canClone ? "nxnative isn't downloaded yet" : "This folder isn't an nxnative checkout", systemImage: "arrow.down.circle")
        } description: {
            Text(message(canClone: canClone))
        } actions: {
            HStack {
                Button("Choose Folder…") { model.chooseRepositoryFolder() }
                if canClone {
                    Button("Download nxnative") { Task { await model.cloneRepository() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canOperate)
                }
            }
            .controlSize(.large)
        }
    }

    private func message(canClone: Bool) -> String {
        if !canClone {
            return "\(status.path.path) does not hold nxnative (scripts/build_ipa_from_nsp.py is missing). "
                + "Choose your checkout, or another folder to download it into."
        }
        return "nxnative is not at \(status.path.path) yet. Download it from \(GitRepository.defaultRemote), or choose the folder where it is."
    }

    private static func isEmptyFolder(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) { (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == true }.value
    }
}

private struct EmptinessCheck {
    let path: URL
    let empty: Bool
}
