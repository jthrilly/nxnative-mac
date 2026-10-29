// The sheet that starts an agent run on a port ("Port with an Agent…", Continue…): which agent, unattended in the app or interactive in Terminal, its
// limits and model, the agent's sandbox (an unattended run without one is confirmed first), extra instructions, and what handing a game to an agent means
import AppKit
import ConverterCore
import SwiftUI

struct StartPortSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let request: PortSheetRequest
    @State private var kind: AgentKind
    @State private var interactive: Bool
    // Bound as text and parsed when used: a value-bound field commits only on Return or when it loses focus, so Start would read a stale value
    @State private var budgetText: String
    @State private var hoursText: String
    @State private var claudeModel: String
    @State private var codexModel: String
    @State private var claudeSandbox: ClaudeSandbox
    @State private var codexSandbox: CodexSandbox
    @State private var ignoreUserConfig: Bool
    @State private var instructions = ""
    @State private var aboutExpanded: Bool
    @State private var confirmFullAccess = false
    private let defaultHours: Double

    private static let instructionsHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .body)
        return (NSLayoutManager().defaultLineHeight(for: font) * 5).rounded(.up) + Space.s
    }()

    init(request: PortSheetRequest, settings: AppSettings, lastKind: AgentKind?) {
        self.request = request
        defaultHours = settings.agentTimeLimitHours
        _kind = State(initialValue: lastKind ?? settings.defaultAgent)
        _interactive = State(initialValue: request.interactive)
        _budgetText = State(initialValue: settings.agentBudgetUSD.formatted(.number.precision(.fractionLength(0...2))))
        _hoursText = State(initialValue: settings.agentTimeLimitHours.formatted(.number.precision(.fractionLength(0...1))))
        _claudeModel = State(initialValue: settings.claudeModel)
        _codexModel = State(initialValue: settings.codexModel)
        _claudeSandbox = State(initialValue: settings.claudeSandbox)
        _codexSandbox = State(initialValue: settings.codexSandbox)
        _ignoreUserConfig = State(initialValue: settings.codexIgnoreUserConfig)
        // A first port shows what handing the game to an agent means; a continued one has seen it
        _aboutExpanded = State(initialValue: !request.continuing)
    }

    var body: some View {
        Form {
            agentSection
            modeSection
            modelSection
            limitsSection
            sandboxSection
            instructionsSection
            aboutSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaBar(edge: .top) { header }
        .safeAreaBar(edge: .bottom) { statusLine }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 560, idealHeight: 720)
        .presentationSizing(.form)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(interactive ? "Open in Terminal" : "Start", action: confirmOrStart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .onAppear {
            if model.agentExecutable(kind) == nil, let other = AgentKind.allCases.first(where: { model.agentExecutable($0) != nil }) { kind = other }
        }
        .confirmationDialog("Run \(kind.displayName) without a sandbox?", isPresented: $confirmFullAccess, titleVisibility: .visible) {
            Button("Run Without Sandbox", role: .destructive, action: start)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(fullAccessWarning)
        }
    }

    // MARK: - Header and status

    private var header: some View {
        HStack(spacing: Space.m) {
            GameArtwork(.gameFolder(request.folder, titleID: request.titleID), name: request.gameName, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.continuing ? "Continue the Port of \(request.gameName)" : "Port \(request.gameName) with an Agent")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text("\(request.titleID) · \(request.folder.path.abbreviatedPath)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(request.folder.path)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.page)
        .padding(.bottom, Space.s)
    }

    private var statusLine: some View {
        status
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.s)
    }

    /// Why the run cannot start now (a port block with its title and message, the app's state, the agent, the limits), else what the run resumes
    @ViewBuilder private var status: some View {
        if let block = runBlock {
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title).fontWeight(.semibold).foregroundStyle(.primary)
                Text(block.message)
            }
            .accessibilityElement(children: .combine)
        } else if model.isQuitting || !model.isReady {
            Text(model.isQuitting ? "nxnative Converter is quitting." : "The shell environment is not ready yet.")
        } else if model.agentExecutable(kind) == nil {
            Text("\(kind.displayName) is not installed: set it up on the Setup page.")
        } else if !interactive, let problem = limitsProblem {
            Label(problem, systemImage: Tone.warning.symbol).foregroundStyle(Tone.warning.text)
        } else {
            Text(sessionHint)
        }
    }

    // MARK: - Sections

    private var agentSection: some View {
        Section {
            Picker("Agent", selection: $kind) {
                ForEach(AgentKind.allCases) { agent in
                    HStack(spacing: Space.s) {
                        Text(agent.displayName)
                        Spacer(minLength: Space.m)
                        Text(agentState(agent)).foregroundStyle(.secondary)
                    }
                    .tag(agent)
                    .disabled(model.agentExecutable(agent) == nil)
                    .help(agentHelp(agent))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        } header: {
            Text("Agent")
        } footer: {
            let missing = AgentKind.allCases.filter { model.agentExecutable($0) == nil }
            VStack(alignment: .leading, spacing: Space.xs) {
                if let detail = agentDetail(kind) {
                    Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(detail)
                }
                if !missing.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(missing.count == 1 ? "\(missing[0].displayName) is not installed."
                                                : "\(missing.map(\.displayName).formatted(.list(type: .and))) are not installed.")
                            .foregroundStyle(.secondary)
                        Button("Set Up on the Setup Page…", action: openSetup)
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $interactive) {
                Text("Unattended in the App").tag(false)
                Text("Interactive in Terminal").tag(true)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
        } header: {
            Text("Mode")
        } footer: {
            Text(modeHint).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var limitsSection: some View {
        Section("Limits") {
            if kind == .claudeCode {
                NumberField("Budget", unit: "USD", text: $budgetText)
                    .disabled(interactive)
                    .help("Claude Code stops when the run has cost this much (--max-budget-usd)")
            }
            NumberField("Time limit", unit: "hours", text: $hoursText)
                .disabled(interactive)
                .help("The app stops the agent after this long; its work is saved as a checkpoint")
        }
    }

    private var modelSection: some View {
        Section {
            switch kind {
            case .claudeCode: ClaudeModelPicker("Model", selection: $claudeModel)
            case .codex: TextField("Model", text: $codexModel, prompt: Text("Default"))
            }
        } header: {
            Text("Model")
        } footer: {
            Text(kind == .claudeCode ? "The Claude model the agent runs on (--model). The default is Opus 5.5; set another in Settings › Agents."
                 : "The model Codex runs on (-m); empty uses your Codex settings.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var sandboxSection: some View {
        switch kind {
        case .claudeCode:
            Section {
                Picker("Sandbox", selection: $claudeSandbox) {
                    Text("Sandboxed").tag(ClaudeSandbox.sandboxed)
                    Text("Full access").tag(ClaudeSandbox.fullAccess)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if claudeSandbox == .fullAccess { Notice(.warning, message: fullAccessWarning) }
            } header: {
                Text("Sandbox")
            } footer: {
                Text("Sandboxed: Claude Code's commands run in its sandbox, which cannot read the key file, writes only in the worktree, the game folder, "
                     + "nxnative's own folders and the build tools' folders, and reaches only the sites a port downloads from.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .codex:
            Section {
                Picker("Sandbox", selection: $codexSandbox) {
                    Text("Sandboxed, with network").tag(CodexSandbox.workspaceWrite)
                    Text("Full access").tag(CodexSandbox.fullAccess)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if codexSandbox == .fullAccess { Notice(.warning, message: fullAccessWarning) }
                Toggle("Ignore my Codex settings (~/.codex/config.toml)", isOn: $ignoreUserConfig)
            } header: {
                Text("Sandbox")
            } footer: {
                Text("Sandboxed: Codex writes only in the worktree and the game folder, with network access for downloads.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var instructionsSection: some View {
        Section {
            TextEditor(text: $instructions)
                .font(.body)
                .frame(minHeight: Self.instructionsHeight)
                .accessibilityLabel("Extra instructions")
        } header: {
            Text("Extra Instructions")
        } footer: {
            Text("Added to the prompt, after the porting rules: what to look at first, what to avoid.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aboutSection: some View {
        Section("About This Port") {
            DisclosureGroup("What happens and what is sent", isExpanded: $aboutExpanded) {
                Text(disclosure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - The agents

    // "Not installed" only when the app has no executable to run; with one, a warning from its check means it is not signed in
    private func agentState(_ agent: AgentKind) -> String {
        guard model.agentExecutable(agent) != nil else { return "Not installed" }
        switch model.agentCheck(agent)?.state {
        case .ok?: return "Ready"
        case .warning?: return "Not signed in"
        case .missing?, .unknown?, nil: return "Not checked"
        }
    }

    private func agentHelp(_ agent: AgentKind) -> String {
        guard let detail = agentDetail(agent) else { return "Install it on the Setup page (Agents), or set its path in Settings › Agents" }
        return model.agentCheck(agent)?.state == .warning ? "Sign in on the Setup page (Agents) before starting" : detail
    }

    /// An installed agent's check (its version and sign-in), else the executable the run uses
    private func agentDetail(_ agent: AgentKind) -> String? {
        guard let executable = model.agentExecutable(agent) else { return nil }
        if let detail = model.agentCheck(agent)?.detail, !detail.isEmpty { return detail }
        return executable
    }

    // MARK: - Starting

    private var port: PortRecord? { model.port(request.titleID) }

    // A new port has no worktree yet: only another agent, an operation on its title ID or a conversion of its folder can be in the way (as startPort sees it)
    private var runBlock: PortBlock? {
        model.runBlock(port ?? PortRecord(titleID: request.titleID, gameName: request.gameName, folder: request.folder.path, workspace: "", branch: "",
                                          baseCommit: "", createdAt: .distantPast))
    }

    private var budget: Double? { NumberField.positive(budgetText) }
    private var hours: Double? { NumberField.positive(hoursText) }

    private var limitsProblem: String? {
        if hours == nil { return "The time limit must be a number of hours above 0." }
        if kind == .claudeCode && budget == nil { return "The budget must be an amount in USD above 0." }
        return nil
    }

    private var canStart: Bool {
        model.isReady && !model.isQuitting && model.agentExecutable(kind) != nil && runBlock == nil && (interactive || limitsProblem == nil)
    }

    private var fullAccess: Bool { kind == .claudeCode ? claudeSandbox == .fullAccess : codexSandbox == .fullAccess }

    private var fullAccessWarning: String {
        switch kind {
        case .claudeCode:
            "Claude Code runs its commands without its sandbox: they can read and change any file your account can, the key file included. "
                + "The guard still blocks the common ways of reading the key file."
        case .codex:
            "Codex runs every command without a sandbox or approvals: it can read and change any file your account can, the key file included. "
                + "Nothing keeps it from reading the key file: it is only told not to."
        }
    }

    private var modeHint: String {
        if interactive {
            return "Terminal opens with \(kind.displayName) in the port's worktree; you approve its steps there. "
                + "The app does not follow the session: Save Checkpoint on the Ports page keeps its work."
        }
        return "\(kind.displayName) works on its own, here in the app: its transcript is live on the Ports page, Stop ends it, "
            + "and its work is saved as a checkpoint when it stops."
    }

    private var sessionHint: String {
        guard request.continuing, let port else { return "A new worktree and branch are made for the port." }
        if let session = port.lastSession(of: kind) {
            return "Resumes the last \(kind.displayName) session (\(session.prefix(8))…) with the previous report."
        }
        return "Starts a new \(kind.displayName) session with the previous report."
    }

    private var disclosure: String {
        let worktree = port?.workspace ?? model.settings.portsFolderURL.appendingPathComponent(request.titleID).path
        let branch = port?.branch ?? PortWorkspace.branchName(titleID: request.titleID)
        let keys: String
        switch (kind, claudeSandbox) {
        case (.claudeCode, .sandboxed):
            keys = "Claude Code is blocked from reading it by a hook that fails closed and by deny rules that name its path, and its commands run in "
                + "Claude Code's sandbox, which cannot read it: not even the repository's tools can there, "
                + "so the app extracts what is missing outside the sandbox."
        case (.claudeCode, .fullAccess):
            keys = "Claude Code is blocked from reading it by a hook that fails closed and by deny rules that name its path; "
                + "without the sandbox, nothing else stops its commands."
        case (.codex, _):
            keys = "Codex is only told not to read it."
        }
        let folder = worktree.abbreviatedPath
        return "The agent changes nxnative in its own worktree (\(folder), branch \(branch)) and runs commands on this Mac. "
            + "What it reads — logs, disassembly, the survey — is sent to Anthropic or OpenAI. The key file: \(keys) "
            + "A port can take many hours and may not succeed."
    }

    /// An unattended run without a sandbox is confirmed each time; an interactive one asks in Terminal before each step
    private func confirmOrStart() {
        guard canStart else { return }
        if !interactive && fullAccess { confirmFullAccess = true } else { start() }
    }

    private func start() {
        guard canStart else { return }
        let options = PortRunOptions(kind: kind, interactive: interactive, budgetUSD: kind == .claudeCode && !interactive ? budget : nil,
                                     timeLimitHours: hours ?? defaultHours, model: kind == .claudeCode ? claudeModel : codexModel, claudeSandbox: claudeSandbox,
                                     codexSandbox: codexSandbox, ignoreUserConfig: ignoreUserConfig, instructions: instructions)
        dismiss()
        model.startPort(request, options: options)
    }

    private func openSetup() {
        dismiss()
        model.page = .setup
    }
}
