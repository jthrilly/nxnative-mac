// The Settings window: General (where nxnative, prod.keys and Python are), Conversion (defaults for new jobs), Install (where the app goes, and how) and
// Agents (the coding agents that attempt ports, their defaults, and where the ports' worktrees go). The pane shown is the SettingsTab user default, so
// the last pane reopens and a page can open Settings on a given pane by writing it first
import AppKit
import ConverterCore
import SwiftUI

struct SettingsWindow: View {
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralPane() }
            Tab("Conversion", systemImage: "arrow.down.app", value: SettingsTab.conversion) { ConversionPane() }
            Tab("Install", systemImage: "externaldrive", value: SettingsTab.install) { InstallPane() }
            Tab("Agents", systemImage: "hammer", value: SettingsTab.agents) { AgentsPane() }
        }
        .frame(width: 600)
        .scenePadding(.bottom)
    }
}

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                PathRow("nxnative folder", path: settings.repositoryPath, placeholder: "Not set", chooseDisabled: model.isConverting) {
                    model.chooseRepositoryFolder()
                }
                PathRow("prod.keys", path: settings.keysPath, placeholder: "Not set") { model.chooseKeysFile() }
            } footer: {
                Text("The keys stay where they are: the conversion reads them from this file.").foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Python interpreter") {
                    HStack {
                        TextField("Python interpreter", text: $settings.pythonPath, prompt: Text("python3 on the shell's PATH"))
                            .labelsHidden()
                            .font(.mono)
                        Button("Choose…") { model.choosePython() }
                    }
                }
            } footer: {
                Text(pythonHint).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Check for nxnative updates at launch", isOn: $settings.checkForUpdatesAtLaunch)
            }
        }
        .formStyle(.grouped)
    }

    private var pythonHint: String {
        guard model.isReady else { return "Reading the shell environment…" }
        if let python = model.pythonExecutable { return "Uses \(python)." }
        return "No python3 was found on the login shell's PATH."
    }
}

private struct ConversionPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LanguagePicker("Default language", selection: $settings.defaultLanguage)
            } footer: {
                Text("The game's language for new conversions; each game can use another.").foregroundStyle(.secondary)
            }
            Section {
                TextField("Signing identity", text: $settings.signingIdentity, prompt: Text("Ad-hoc"))
            } footer: {
                Text("A codesign identity for the app (--mac-sign), such as “Developer ID Application: …”. "
                     + "Empty signs ad-hoc, which is enough on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Start conversions automatically", isOn: $settings.startAutomatically)
                Toggle("Notify when a conversion ends", isOn: $settings.notifyWhenDone)
            } footer: {
                if !Notifier.isAvailable {
                    Text("Notifications need the app bundle (scripts/build_app.py); the Dock icon bounces instead.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct InstallPane: View {
    @Environment(AppModel.self) private var model
    private static let custom = "\u{1}custom"
    /// Custom… while its panel is open; the picker shows the install folder again after it
    @State private var choosing: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Install into", selection: destination) {
                    ForEach(standard, id: \.self) { Text($0.abbreviatedPath).tag($0) }
                    if !standard.contains(currentPath) { Text(currentPath.abbreviatedPath).tag(currentPath) }
                    Divider()
                    Text("Custom…").tag(Self.custom)
                }
                .disabled(settings.installMode == .none)
                Picker("When done", selection: $settings.installMode) {
                    Text("Move the app").tag(InstallMode.move)
                    Text("Copy the app").tag(InstallMode.copy)
                    Text("Don't install").tag(InstallMode.none)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(Self.help(settings.installMode)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var standard: [String] { AppInstaller.standardDestinations().map(\.path) }
    private var currentPath: String { model.settings.installDirectoryURL.path }

    private var destination: Binding<String> {
        Binding(get: { choosing ?? currentPath }, set: { value in
            if value == Self.custom {
                choosing = value
                chooseCustom()
            } else {
                model.settings.installDirectory = value
            }
        })
    }

    /// A sheet on the Settings window rather than a modal loop, so the picker's change and the running conversion carry on while it is open
    private func chooseCustom() {
        let panel = NSOpenPanel()
        panel.title = "Install Games Into"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = model.settings.installDirectoryURL
        let done: @MainActor (NSApplication.ModalResponse) -> Void = { [model] response in
            if response == .OK, let url = panel.url { model.settings.installDirectory = url.path }
            choosing = nil
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    private static func help(_ mode: InstallMode) -> String {
        let tail = " A game already there goes to the Trash first; its saves are kept (they are in ~/Library/Application Support/nxnative). "
            + "Then xattr -cr clears the app's quarantine attributes."
        switch mode {
        case .move:
            return "“Move” keeps one copy: on the same drive the app is just moved; on another drive it is copied, then the original is removed." + tail
        case .copy: return "“Copy” keeps the app in the game folder too. On the same APFS drive the copy is a clone and takes no extra space." + tail
        case .none: return "“Don't install” leaves the app in the game folder; only its extended attributes are cleared."
        }
    }
}

private struct AgentsPane: View {
    @Environment(AppModel.self) private var model
    // The budget and the time limit are typed as text and stored once the text is a number above 0, as a number field would commit only on Return or
    // when it loses focus. nil shows the stored value
    @State private var budget: String?
    @State private var hours: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Default agent", selection: $settings.defaultAgent) {
                    ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                }
                agentPath(.claudeCode, text: $settings.claudePath)
                agentPath(.codex, text: $settings.codexPath)
            } footer: {
                Text("Empty paths use the agent found on the login shell's PATH.").foregroundStyle(.secondary)
            }
            Section {
                NumberField("Budget (Claude Code)", unit: "USD", text: budgetText)
                NumberField("Time limit", unit: "hours", text: hoursText)
                TextField("Claude Code model", text: $settings.claudeModel, prompt: Text("Default"))
                TextField("Codex model", text: $settings.codexModel, prompt: Text("Default"))
            } header: {
                Text("Defaults for a Run")
            } footer: {
                if !Self.isValid(budget) || !Self.isValid(hours) {
                    Text("The budget and the time limit must be numbers above 0. "
                         + "Until they are, runs use \(Self.text(settings.agentBudgetUSD)) USD and \(Self.text(settings.agentTimeLimitHours)) hours.")
                        .foregroundStyle(Tone.warning.text)
                }
            }
            Section {
                Picker("Claude Code sandbox", selection: $settings.claudeSandbox) {
                    Text("Sandboxed: commands run in Claude Code's sandbox").tag(ClaudeSandbox.sandboxed)
                    Text("Full access").tag(ClaudeSandbox.fullAccess)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                switch settings.claudeSandbox {
                case .sandboxed:
                    Text("Claude Code's commands run in its sandbox: they write only to the port's worktree, the game folder, nxnative's own folders "
                         + "and the build tools' folders (NuGet, .NET, caches and temporary files), and cannot read the key file. "
                         + "Each run can choose otherwise.")
                        .foregroundStyle(.secondary)
                case .fullAccess:
                    Text("Without the sandbox, Claude Code's commands can read and change any file your account can, the key file included; "
                         + "only a hook stops the common ways of reading it. Unattended runs ask first.")
                        .foregroundStyle(Tone.warning.text)
                }
            }
            Section {
                Picker("Codex sandbox", selection: $settings.codexSandbox) {
                    Text("Sandboxed, with network").tag(CodexSandbox.workspaceWrite)
                    Text("Full access").tag(CodexSandbox.fullAccess)
                }
                .pickerStyle(.radioGroup)
                Toggle("Ignore my Codex settings (~/.codex/config.toml)", isOn: $settings.codexIgnoreUserConfig)
            } footer: {
                Text("Your Codex settings may name a model or options a ChatGPT sign-in cannot use; "
                     + "ignoring them runs Codex with its defaults and the options above.")
                    .foregroundStyle(.secondary)
            }
            Section {
                PathRow("Ports folder", path: settings.portsFolder.isEmpty ? settings.portsFolderURL.path : settings.portsFolder, placeholder: "") {
                    choosePortsFolder()
                }
            } footer: {
                let place = settings.portsFolder.isEmpty ? "the default: beside the nxnative folder" : "a custom folder"
                Text("Each port's git worktree of nxnative goes here (\(place)). "
                     + "Existing ports keep theirs.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            budget = nil
            hours = nil
        }
    }

    private var budgetText: Binding<String> {
        Binding(get: { budget ?? Self.text(model.settings.agentBudgetUSD) }, set: { text in
            budget = text
            if let value = NumberField.positive(text) { model.settings.agentBudgetUSD = value }
        })
    }

    private var hoursText: Binding<String> {
        Binding(get: { hours ?? Self.text(model.settings.agentTimeLimitHours) }, set: { text in
            hours = text
            if let value = NumberField.positive(text) { model.settings.agentTimeLimitHours = value }
        })
    }

    private static func isValid(_ text: String?) -> Bool { text.map { NumberField.positive($0) != nil } ?? true }

    private static func text(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) }

    private func agentPath(_ kind: AgentKind, text: Binding<String>) -> some View {
        let title = "\(kind.displayName) path"
        let found = model.agentExecutable(kind).map(\.abbreviatedPath) ?? "\(kind.executableName) on the shell's PATH"
        return LabeledContent(title) {
            HStack {
                TextField(title, text: text, prompt: Text(found)).labelsHidden()
                Button("Choose…") { chooseExecutable(kind.displayName, into: text) }
            }
        }
    }

    private func chooseExecutable(_ title: String, into text: Binding<String>) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(title)"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path }
    }

    private func choosePortsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Ports Folder"
        panel.message = "Choose where the ports' worktrees of nxnative go."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = model.settings.portsFolderURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { model.settings.portsFolder = url.path }
    }
}
