// The Convert sheet: what a drop, Add Game Folder… or Convert for Another Platform… asks before anything is queued. The games it found (each with
// Port with an Agent…), the platforms to make them for (a Mac app, an Xcode project for iPhone and iPad, or both: a job each) as two choices at the top,
// the language, Survey only for a game with no profile, and for a single game its version, app name and bundle ID. Nothing is queued or started until
// Convert; Cancel leaves the queue as it was
import ConverterCore
import SwiftUI

/// A game folder the sheet offers, scanned
struct PendingGame: Identifiable {
    var id: URL { folder }
    let folder: URL
    let scan: NSPFolderScan
}

/// What the Convert sheet was opened for: the games, the profiles they match against, the options it starts from, and the port worktree they are
/// converted from (nil: the nxnative folder)
struct ConvertRequest: Identifiable {
    let id = UUID()
    var games: [PendingGame]
    var profiles: [GameProfile]
    var options: ConversionOptions
    var repository: URL?
    var title: String?   // "Convert … for iPhone & iPad"; nil: from the games
    var platforms: Set<ConversionOutput>? = nil   // the platforms chosen to start with; nil: the ones chosen last time

    /// The platforms the last Convert made, else the default output of Settings
    static let platformsKey = "convert.platforms"
    @MainActor static func rememberedPlatforms(_ settings: AppSettings) -> Set<ConversionOutput> {
        let saved = Set((UserDefaults.standard.string(forKey: platformsKey) ?? "").split(separator: ",").compactMap { ConversionOutput(rawValue: String($0)) })
        return saved.isEmpty ? [settings.defaultOutput] : saved
    }

    func match(_ game: PendingGame, package: String) -> ProfileMatch { GameProfiles.match(game.scan, in: profiles, package: package) }
}

struct ConvertSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let request: ConvertRequest
    @State private var options: ConversionOptions
    @State private var platforms: Set<ConversionOutput>
    @State private var surveyOnly = false
    @State private var advanced = false

    init(request: ConvertRequest, settings: AppSettings) {
        self.request = request
        _options = State(initialValue: request.options)
        _platforms = State(initialValue: request.platforms ?? ConvertRequest.rememberedPlatforms(settings))
    }

    var body: some View {
        Form {
            Section {
                PlatformChoice(selection: $platforms)
                    .listRowInsets(EdgeInsets(top: Space.s, leading: Space.s, bottom: Space.s, trailing: Space.s))
                if platforms.contains(.xcodeProject) {
                    Text(xcodeNote).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Platforms")
            } footer: {
                Text("Choose one or both: each platform is converted in turn.").foregroundStyle(.secondary)
            }
            Section("Options") {
                LanguagePicker("Language", selection: $options.language)
                if games.contains(where: { request.match($0, package: options.package) == .noProfile }) {
                    Toggle(isOn: $surveyOnly) {
                        Text("Survey only")
                        Text(games.count == 1 ? "This game has no profile yet: write its survey and provisional profile, and stop there."
                             : "For the games with no profile: write their surveys and provisional profiles, and stop there.")
                    }
                }
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    if let game = single {
                        Picker("Game version", selection: $options.package) {
                            Text("Newest (v\(game.scan.newestVersion))").tag("")
                            ForEach(game.scan.versions, id: \.self) { version in
                                Text(version == 0 ? "v0 (base game)" : "v\(version)").tag("v\(version)")
                            }
                        }
                        TextField("App name", text: $options.appName, prompt: Text(game.scan.displayName))
                        TextField("Bundle ID", text: $options.bundleID, prompt: Text("Automatic"))
                    }
                    Toggle("Allow damaged game files", isOn: $options.allowDamaged)
                }
            }
            Section(games.count == 1 ? "Game" : "\(games.count) Games") {
                ForEach(games) { game in
                    GameRow(game: game, match: request.match(game, package: options.package)) {
                        dismiss()
                        model.offerPort(for: game)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaBar(edge: .top) { header }
        .safeAreaBar(edge: .bottom) { statusLine }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 600)
        .presentationSizing(.form)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isConverting ? "Add to Queue" : "Convert") {
                    model.confirmConversion(request, options: options, platforms: platforms, surveyOnly: surveyOnly)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!games.contains { $0.scan.isConvertible } || platforms.isEmpty)
            }
        }
    }

    private var games: [PendingGame] { request.games }
    private var single: PendingGame? { games.count == 1 ? games.first : nil }

    private var xcodeNote: String {
        let team = model.settings.teamID.trimmingCharacters(in: .whitespaces)
        return "The project goes in the game's folder and is added to NxNative.xcworkspace beside it. Open it in Xcode, choose your iPhone or iPad and Run. "
            + (team.isEmpty ? "Choose its signing team in Xcode, or set a Team ID in Settings › Conversion." : "It is signed with team \(team).")
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            if let game = single {
                GameArtwork(game.scan.titleIDString.map { ArtworkSource.gameFolder(game.folder, titleID: $0) }, name: game.scan.displayName, size: 48)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title ?? (single.map { "Convert \($0.scan.displayName)" } ?? "Convert \(games.count) Games"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let game = single {
                    Text(game.folder.path.abbreviatedPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(game.folder.path)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.page)
        .padding(.bottom, Space.s)
    }

    private var statusLine: some View {
        Text(status)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.s)
    }

    private var status: String {
        if !games.contains(where: { $0.scan.isConvertible }) { return games.count == 1 ? "This folder can't be converted." : "None of these folders can be converted." }
        if platforms.isEmpty { return "Choose a platform to convert for, or Port with an Agent under the game." }
        if model.isConverting, let active = model.activeJob { return "\(active.name) is being converted: \(games.count == 1 ? "this game starts" : "these games start") when it has finished." }
        return "The game settings (frame rate, render scale…) are chosen in the Library, under Game Settings, once the app is made."
    }
}

/// The two platforms as large choices that each turn on and off, toggles to VoiceOver
private struct PlatformChoice: View {
    @Binding var selection: Set<ConversionOutput>

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(ConversionOutput.allCases, id: \.self) { output in
                Button {
                    if selection.contains(output) { selection.remove(output) } else { selection.insert(output) }
                } label: { card(output) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection.contains(output) ? [.isSelected, .isToggle] : [.isToggle])
                    .help(output.platformDetail)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Platforms")
    }

    private func card(_ output: ConversionOutput) -> some View {
        let selected = selection.contains(output)
        return VStack(spacing: Space.xs) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
            Image(systemName: output.platformSymbol)
                .font(.system(size: 28))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(height: 34)
                .accessibilityHidden(true)
            Text(output.platformName).font(.headline)
            Text(output.platformDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A game in the sheet: its art, name, versions and whether nxnative has a tested profile for it
private struct GameRow: View {
    @Environment(AppModel.self) private var model
    let game: PendingGame
    let match: ProfileMatch
    let port: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: Space.s) {
                GameArtwork(game.scan.titleIDString.map { ArtworkSource.gameFolder(game.folder, titleID: $0) }, name: game.scan.displayName, size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.scan.displayName).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let titleID = game.scan.titleIDString, game.scan.isConvertible {
                let block = model.portBlockReason(titleID: titleID)
                Button(model.port(titleID) == nil ? "Port with an Agent…" : "Continue Port…", action: port)
                    .controlSize(.small)
                    .disabled(block != nil)
                    .help(block ?? "Hand this game to a coding agent that works on nxnative until it runs, instead of converting it now")
            }
        }
    }

    private var detail: String {
        guard game.scan.isConvertible else { return game.scan.errors.first ?? "Can't be converted" }
        switch match {
        case .tested(_, let display): return "Tested: \(display)"
        case .untestedVersion(_, let version, _): return "\(version): an untested version, packed from a derived profile"
        case .noProfile: return "No profile yet: a provisional one is made, and the app may not boot"
        }
    }
}

extension ConversionOutput {
    var platformName: String {
        switch self {
        case .macApp: "Mac"
        case .xcodeProject: "iPhone & iPad"
        }
    }

    var platformSymbol: String {
        switch self {
        case .macApp: "macbook"
        case .xcodeProject: "iphone"
        }
    }

    var platformDetail: String {
        switch self {
        case .macApp: "An app, installed like any other"
        case .xcodeProject: "An Xcode project that Xcode signs and installs on your device"
        }
    }
}
