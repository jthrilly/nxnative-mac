// AppSettings: the converter's preferences, kept in UserDefaults (every key has a default). The model is told about changes that need a refresh
// (repository, keys, Python, the agents' paths) through onChange
import ConverterCore
import Foundation
import Observation

@MainActor @Observable final class AppSettings {
    enum Key: String, CaseIterable {
        case repositoryPath, keysPath, pythonPath, installDirectory, installMode, defaultLanguage, defaultOutput, signingIdentity, teamID, startAutomatically, checkForUpdatesAtLaunch, notifyWhenDone
        case defaultAgent, claudePath, codexPath, agentBudgetUSD, agentTimeLimitHours, claudeModel, codexModel, claudeSandbox, codexSandbox, codexIgnoreUserConfig, portsFolder
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: ((Key) -> Void)?

    var repositoryPath: String { didSet { store(repositoryPath, .repositoryPath) } }
    var keysPath: String { didSet { store(keysPath, .keysPath) } }
    var pythonPath: String { didSet { store(pythonPath, .pythonPath) } }
    var installDirectory: String { didSet { store(installDirectory, .installDirectory) } }
    var installMode: InstallMode { didSet { store(installMode.rawValue, .installMode) } }
    var defaultLanguage: String { didSet { store(defaultLanguage, .defaultLanguage) } }
    var defaultOutput: ConversionOutput { didSet { store(defaultOutput.rawValue, .defaultOutput) } }
    var signingIdentity: String { didSet { store(signingIdentity, .signingIdentity) } }
    var teamID: String { didSet { store(teamID, .teamID) } }                             // "" = the team chosen in Xcode, else the script's placeholder
    var startAutomatically: Bool { didSet { store(startAutomatically, .startAutomatically) } }
    var checkForUpdatesAtLaunch: Bool { didSet { store(checkForUpdatesAtLaunch, .checkForUpdatesAtLaunch) } }
    var notifyWhenDone: Bool { didSet { store(notifyWhenDone, .notifyWhenDone) } }
    var defaultAgent: AgentKind { didSet { store(defaultAgent.rawValue, .defaultAgent) } }
    var claudePath: String { didSet { store(claudePath, .claudePath) } }                 // "" = claude on the shell's PATH
    var codexPath: String { didSet { store(codexPath, .codexPath) } }
    var agentBudgetUSD: Double { didSet { store(agentBudgetUSD, .agentBudgetUSD) } }
    var agentTimeLimitHours: Double { didSet { store(agentTimeLimitHours, .agentTimeLimitHours) } }
    var claudeModel: String { didSet { store(claudeModel, .claudeModel) } }               // "" = the agent's default
    var codexModel: String { didSet { store(codexModel, .codexModel) } }
    var claudeSandbox: ClaudeSandbox { didSet { store(claudeSandbox.rawValue, .claudeSandbox) } }   // Claude Code's own sandbox around its commands
    var codexSandbox: CodexSandbox { didSet { store(codexSandbox.rawValue, .codexSandbox) } }
    var codexIgnoreUserConfig: Bool { didSet { store(codexIgnoreUserConfig, .codexIgnoreUserConfig) } }
    var portsFolder: String { didSet { store(portsFolder, .portsFolder) } }               // "" = nxnative-ports beside the nxnative folder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        // The first usual place that holds a checkout, else ~/nxnative, where the nxnative page offers to download it
        let checkout = ["Projects/nxnative", "Developer/nxnative", "nxnative"].map { home.appendingPathComponent($0).path }
            .first { fm.fileExists(atPath: $0 + "/scripts/build_ipa_from_nsp.py") }
        let keys = ["/.switch/prod.keys", "/Games/prod.keys"].map { home.path + $0 }.first { fm.fileExists(atPath: $0) }
        repositoryPath = defaults.string(forKey: Key.repositoryPath.rawValue) ?? checkout ?? home.appendingPathComponent("nxnative").path
        keysPath = defaults.string(forKey: Key.keysPath.rawValue) ?? keys ?? ""
        pythonPath = defaults.string(forKey: Key.pythonPath.rawValue) ?? ""
        installDirectory = defaults.string(forKey: Key.installDirectory.rawValue) ?? "/Applications"
        installMode = defaults.string(forKey: Key.installMode.rawValue).flatMap(InstallMode.init(rawValue:)) ?? .move
        defaultLanguage = defaults.string(forKey: Key.defaultLanguage.rawValue) ?? ""
        defaultOutput = defaults.string(forKey: Key.defaultOutput.rawValue).flatMap(ConversionOutput.init(rawValue:)) ?? .macApp
        signingIdentity = defaults.string(forKey: Key.signingIdentity.rawValue) ?? ""
        teamID = defaults.string(forKey: Key.teamID.rawValue) ?? ""
        startAutomatically = defaults.object(forKey: Key.startAutomatically.rawValue) as? Bool ?? true
        checkForUpdatesAtLaunch = defaults.object(forKey: Key.checkForUpdatesAtLaunch.rawValue) as? Bool ?? true
        notifyWhenDone = defaults.object(forKey: Key.notifyWhenDone.rawValue) as? Bool ?? true
        defaultAgent = defaults.string(forKey: Key.defaultAgent.rawValue).flatMap(AgentKind.init(rawValue:)) ?? .claudeCode
        claudePath = defaults.string(forKey: Key.claudePath.rawValue) ?? ""
        codexPath = defaults.string(forKey: Key.codexPath.rawValue) ?? ""
        agentBudgetUSD = defaults.object(forKey: Key.agentBudgetUSD.rawValue) as? Double ?? 20
        agentTimeLimitHours = defaults.object(forKey: Key.agentTimeLimitHours.rawValue) as? Double ?? 4
        claudeModel = defaults.string(forKey: Key.claudeModel.rawValue) ?? ""
        codexModel = defaults.string(forKey: Key.codexModel.rawValue) ?? ""
        claudeSandbox = defaults.string(forKey: Key.claudeSandbox.rawValue).flatMap(ClaudeSandbox.init(rawValue:)) ?? .sandboxed
        codexSandbox = defaults.string(forKey: Key.codexSandbox.rawValue).flatMap(CodexSandbox.init(rawValue:)) ?? .workspaceWrite
        codexIgnoreUserConfig = defaults.object(forKey: Key.codexIgnoreUserConfig.rawValue) as? Bool ?? false
        portsFolder = defaults.string(forKey: Key.portsFolder.rawValue) ?? ""
    }

    var repositoryURL: URL { URL(fileURLWithPath: (repositoryPath as NSString).expandingTildeInPath).standardizedFileURL }
    var keysURL: URL? { keysPath.isEmpty ? nil : URL(fileURLWithPath: (keysPath as NSString).expandingTildeInPath).standardizedFileURL }
    var installDirectoryURL: URL { URL(fileURLWithPath: (installDirectory as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL }
    var portsFolderURL: URL {
        portsFolder.isEmpty ? PortWorkspace.defaultsDirectory(repository: repositoryURL)
            : URL(fileURLWithPath: (portsFolder as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    func agentPath(_ kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: return claudePath
        case .codex: return codexPath
        }
    }

    func agentModel(_ kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: return claudeModel
        case .codex: return codexModel
        }
    }

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        onChange?(key)
    }
}
