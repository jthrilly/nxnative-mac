// The Setup page: what a conversion needs (Apple silicon, Xcode and its Metal Toolchain, Homebrew tools, .NET, Python and its modules, nxnative,
// prod.keys), each with its state and the fixes for it, the optional coding agents that attempt ports, and the console the fixes run in below
import ConverterCore
import SwiftUI

struct SetupPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VSplitView {
            content.frame(minHeight: 240, maxHeight: .infinity)
            if !model.console.lines.isEmpty || model.console.isRunning {
                OutputPane().frame(minHeight: 120, idealHeight: 200)
            }
        }
        .navigationTitle("Setup")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    private var subtitle: String {
        if model.checking { return "Checking…" }
        if model.checks.isEmpty { return "" }
        let failed = model.failedRequiredChecks
        return failed == 0 ? "Ready to convert" : "\(failed) requirement\(failed == 1 ? "" : "s") missing"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button("Check Again", systemImage: "arrow.clockwise") { Task { await model.recheck() } }
                .help("Check every requirement again")
                .disabled(!model.isReady || model.checking)
        }
        ToolbarSpacer(.fixed)
            .hidden(model.missingRunFixes == 0)
        ToolbarItem {
            Button("Install Missing") { Task { await model.installMissing() } }
                .buttonStyle(.glassProminent)
                .help("Run the fixes of every missing requirement that can run here")
                .disabled(!model.canInstallMissing)
        }
        .visibilityPriority(.high)
        .hidden(model.missingRunFixes == 0)
    }

    @ViewBuilder private var content: some View {
        if model.checks.isEmpty {
            ProgressView(model.isReady ? "Checking…" : "Reading the shell environment…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ChecksForm()
        }
    }
}

/// The status, then the checks by kind: required, optional, and the agents. While the checks run again the old results stay, dimmed
private struct ChecksForm: View {
    @Environment(AppModel.self) private var model
    private static let agents = Set(AgentKind.allCases.map(\.prerequisite))

    var body: some View {
        let required = model.checks.filter(\.required)
        let optional = model.checks.filter { !$0.required && !Self.agents.contains($0.id) }
        let agentChecks = model.checks.filter { Self.agents.contains($0.id) }
        let dimming = model.checking ? 0.6 : 1
        Form {
            Section {
                statusRow
            } footer: {
                if model.isConverting { Text("Fixes wait until the conversion has finished.").foregroundStyle(.secondary) }
            }
            Section("Required") {
                CheckRows(checks: required, allOK: "All \(required.count) requirements are met").opacity(dimming)
            }
            if !optional.isEmpty {
                Section {
                    CheckRows(checks: optional, allOK: "All \(optional.count) are installed").opacity(dimming)
                } header: {
                    Text("Optional")
                } footer: {
                    Text("Only some games need these.").foregroundStyle(.secondary)
                }
            }
            if !agentChecks.isEmpty {
                Section {
                    ForEach(agentChecks) { CheckRow(check: $0) }.opacity(dimming)
                } header: {
                    Text("Agents (Optional)")
                } footer: {
                    Text("A coding agent can attempt the port of a game nxnative has no profile for (the Ports page). "
                         + "Either one is enough; conversions do not need them.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusRow: some View {
        let missing = model.failedRequiredChecks
        if model.checking {
            PageStatusRow("Checking…", symbol: nil, tone: .neutral)
        } else if missing == 0 {
            PageStatusRow("Ready to convert", subtitle: "Everything a conversion needs is installed.", symbol: "checkmark.seal.fill", tone: .success)
        } else {
            PageStatusRow("\(missing) thing\(missing == 1 ? "" : "s") to install before converting",
                          subtitle: "Install Missing runs every fix that can run here; the others say what to do.", symbol: "exclamationmark.triangle.fill",
                          tone: .warning)
        }
    }
}

/// A section's checks, folded into one line when every one of them is OK
private struct CheckRows: View {
    let checks: [PrerequisiteCheck]
    let allOK: String

    var body: some View {
        if checks.allSatisfy({ $0.state == .ok }) {
            DisclosureGroup(allOK) { ForEach(checks) { CheckRow(check: $0) } }
        } else {
            ForEach(checks) { CheckRow(check: $0) }
        }
    }
}

private struct CheckRow: View {
    @Environment(AppModel.self) private var model
    let check: PrerequisiteCheck
    @State private var agentInstalled = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            stateSymbol.font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).fontWeight(.medium)
                if !check.detail.isEmpty {
                    Text(check.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.m)
            if check.state != .ok, !check.fixes.isEmpty {
                VStack(alignment: .trailing, spacing: Space.xs) {
                    ForEach(Array(check.fixes.enumerated()), id: \.offset) { _, fix in
                        Button(fix.title, systemImage: fix.symbol) { Task { await model.perform(fix) } }
                            .help(fix.help)
                            .disabled(fix.needsConsole && !model.canOperate)
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .task(id: check) { agentInstalled = agent.map { model.agentExecutable($0) != nil } ?? true }
    }

    /// An agent's check warns both when it is not installed and when it is not signed in: the two are told apart
    private var agent: AgentKind? { AgentKind.allCases.first { $0.prerequisite == check.id } }

    private var stateSymbol: some View {
        let state = SymbolState(check, agent: agent != nil, agentInstalled: agentInstalled)
        return Image(systemName: state.symbol)
            .foregroundStyle(state.color)
            .accessibilityLabel(state.label)
            .help(state.help ? state.label : "")
    }
}

/// How a check's state is drawn: its symbol, colour and spoken name, and whether the name is also the symbol's help
private struct SymbolState {
    let symbol: String
    let color: Color
    let label: String
    let help: Bool

    init(_ check: PrerequisiteCheck, agent: Bool, agentInstalled: Bool) {
        switch check.state {
        case .ok:
            (symbol, color, label, help) = ("checkmark.circle.fill", Tone.success.glyph, "OK", false)
        case .missing:
            (symbol, color, label, help) = check.required ? ("xmark.circle.fill", Tone.failure.glyph, "Missing", false)
                : ("minus.circle.fill", Color.secondary, "Missing", false)
        case .warning where agent && !agentInstalled:
            (symbol, color, label, help) = ("minus.circle.fill", Color.secondary, "Not installed", true)
        case .warning where agent:
            (symbol, color, label, help) = ("exclamationmark.triangle.fill", Tone.warning.glyph, "Not signed in", true)
        case .warning:
            (symbol, color, label, help) = ("exclamationmark.triangle.fill", Tone.warning.glyph, "Warning", false)
        case .unknown:
            (symbol, color, label, help) = ("questionmark.circle", Color.secondary, "Unknown", false)
        }
    }
}

private extension FixAction {
    /// Runs in the console, which one operation at a time holds
    var needsConsole: Bool {
        switch self {
        case .run, .admin: true
        case .terminal, .openURL, .chooseFile, .chooseFolder: false
        }
    }
}
