// Game Settings: a game app's settings drawn from the list it carries (launcher.json), as nxnative's front-end guidance has a front end do it (docs/frontends.md).
// Save keeps the choices in the app's own preferences (launcher.<VAR>, only those away from the tested defaults), where the game's own settings window and a start
// from Finder read them too. Play Once starts the game with the values shown for that start only (its launch environment), and keeps nothing. A start from here
// skips the game's own window (DM_LAUNCHER=0), since this sheet takes its place; the saved choices still apply. A setting an env.txt sets is shown, not changed
import AppKit
import ConverterCore
import SwiftUI

struct GameSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let entry: LibraryEntry
    private let source: GameSettingsSource
    private let store: AppPreferencesStore
    @State private var form: GameSettingsForm
    @AppStorage("gameSettings.advanced") private var advanced = false

    init(entry: LibraryEntry) {
        self.entry = entry
        let source = GameSettingsSource.load(app: entry.app.url)
        let store = AppPreferencesStore(domain: GameLaunch.preferencesDomain(bundleID: entry.app.bundleID, titleID: entry.app.titleID))
        self.source = source
        self.store = store
        let list: GameSettingsList
        if case .list(let l) = source { list = l } else { list = GameSettingsList(game: entry.app.titleID, settings: []) }
        _form = State(initialValue: GameSettingsForm(list: list, store: store, fixed: EnvFile.fixedValues(app: entry.app.url, titleID: entry.app.titleID)))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            buttons
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 460, idealHeight: 640)
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            GameArtwork(entry.artwork, name: entry.app.name, size: 56, shape: entry.artworkShape)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.app.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text("Game Settings").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding([.horizontal, .top], Space.page)
    }

    @ViewBuilder private var content: some View {
        switch source {
        case .missing:
            ContentUnavailableView("No Settings", systemImage: "slider.horizontal.3",
                                   description: Text("This app carries no settings list: the nxnative that made it had none. Rebuild it with the current nxnative to "
                                                     + "choose its settings here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unsupported(let why):
            ContentUnavailableView("Settings Not Readable", systemImage: "exclamationmark.triangle", description: Text(why))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .list:
            settingsForm
        }
    }

    private var settingsForm: some View {
        Form {
            let basic = form.sections(basic: true), others = form.sections(basic: false)
            if !form.fixed.isEmpty {
                Section {
                    Notice(.info, message: "Settings an env.txt sets are greyed out: the game's own (in ~/Library/Application Support/nxnative/\(entry.app.titleID)/) "
                           + "or the app's. Remove the line there to choose them here.", onCard: false)
                }
            }
            ForEach(basic) { section in
                Section(section.title) { ForEach(section.rows) { row($0) } }
            }
            if !basic.isEmpty && !others.isEmpty {
                Section { DisclosureGroup("Advanced settings", isExpanded: $advanced) {} }
            }
            if basic.isEmpty || advanced {
                ForEach(others) { section in
                    Section(section.title) { ForEach(section.rows) { row($0) } }
                }
            }
            Section {
                Button("Reset to Tested Defaults") { form.reset() }
                    .disabled(!form.differsFromDefaults)
            } footer: {
                Text("Brings back the settings this game was tested with. A setting left at its tested default follows the defaults of a later build.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ s: GameSetting) -> some View {
        let fixed = form.isFixed(s)
        return VStack(alignment: .leading, spacing: 2) {
            control(s)
            if fixed {
                Text("Set by env.txt").font(.caption).foregroundStyle(.secondary)
            } else if !s.note.isEmpty {
                Text(s.note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(fixed)
    }

    @ViewBuilder private func control(_ s: GameSetting) -> some View {
        switch s.kind {
        case .choice:
            Picker(s.label, selection: binding(s)) {
                ForEach(s.options, id: \.value) { option in Text(option.label).tag(option.value) }
            }
        case .toggle:
            Toggle(s.label, isOn: Binding(get: { form.value(s) == s.on }, set: { on in form.values[s.env] = on ? s.on : s.off }))
        case .range:
            let lo = s.min ?? 0, hi = s.max ?? lo
            let value = min(max(Double(form.value(s)) ?? Double(s.defaultValue) ?? lo, lo), hi)
            LabeledContent(s.label) {
                HStack(spacing: Space.s) {
                    if hi > lo {
                        Slider(value: Binding(get: { value }, set: { form.values[s.env] = Self.text($0, step: s.step) }), in: lo...hi,
                               step: s.step.flatMap { $0 > 0 ? $0 : nil } ?? (hi - lo) / 100)
                            .labelsHidden()
                    }
                    Text(form.rangeLabel(s, value))
                        .monospacedDigit()
                        .frame(minWidth: 80, alignment: .trailing)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: Space.s) {
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.m)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Play Once") { play(overrides: form.launchOverrides); dismiss() }
                .help("Start the game with these settings for this start only, without keeping them")
            Button("Save") { form.save(to: store); dismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isList)
                .help("Keep these settings for every start of the game, from here, the game's own window or Finder")
        }
        .padding(Space.page)
    }

    private var footnote: String {
        isList ? "Kept in the game's own preferences, which its settings window and a start from Finder use too." : "The game starts with its tested defaults."
    }

    private var isList: Bool { if case .list = source { true } else { false } }

    private func binding(_ s: GameSetting) -> Binding<String> {
        Binding(get: { form.value(s) }, set: { form.values[s.env] = $0 })
    }

    /// A slider's value as the setting's string: on its step, without a float's tail (0.75, not 0.7500000000000001)
    static func text(_ value: Double, step: Double?) -> String {
        var v = value
        if let step, step > 0 { v = (v / step).rounded() * step }
        return String((v * 1000).rounded() / 1000)
    }

    /// Starts the game without its own settings window; `overrides` win over the saved choices and the env.txt files for this start only
    private func play(overrides: [String: String]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = GameLaunch.environment(overrides: overrides)
        let app = entry.app.url, name = entry.app.name, model = model
        Task { @MainActor in
            do { _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration) } catch {
                model.alert = AlertItem(title: "\(name) could not be started", message: error.localizedDescription)
            }
        }
    }
}
