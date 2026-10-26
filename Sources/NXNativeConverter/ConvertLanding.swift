// The Convert page while the queue is empty: the stage band with the console as a drop target, Choose Folder…, what goes in a game folder and where
// finished apps go
import ConverterCore
import SwiftUI

struct ConvertLanding: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    init() {}

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DropBand()
                VStack(spacing: Space.xl) {
                    VStack(spacing: Space.s) {
                        Button("Choose Folder…") { model.chooseGameFolders() }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.extraLarge)
                        Text(".nsp, .xci, .nsz and .xcz all work. A folder of game folders adds each of them.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    FolderGuide()
                    installLine
                }
                .frame(maxWidth: 720)
                .padding(Space.page)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Convert")
        .toolbar {
            ToolbarItem { AddGameFolderButton() }
        }
    }

    private var installLine: some View {
        let settings = model.settings
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if settings.installMode == .none {
                    Text("Finished apps stay in the game folder.")
                } else {
                    Text("Finished apps go into \(settings.installDirectoryURL.path.abbreviatedPath).")
                        .help(settings.installDirectoryURL.path)
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Change…") {
                settingsTab = .install
                openSettings()
            }
            .buttonStyle(.link)
            .help("Choose where finished apps go in Settings")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// File › Add Game Folder… in the toolbar of the Convert pages
struct AddGameFolderButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Add Game Folder", systemImage: "plus") { model.chooseGameFolders() }
            .help("Add a game folder (⌘O)")
    }
}

/// The band at the top: the console with its halves apart, which plug in and light the screen while folders are dragged over the window
private struct DropBand: View {
    @Environment(\.dropTargeted) private var targeted

    var body: some View {
        StageBand(height: 260) {
            VStack(spacing: Space.m) {
                ConsoleFrame(height: 150, halves: targeted ? .attached : .detached) {
                    BlankScreen(symbol: "square.and.arrow.down", height: 150, symbolSize: 40, lit: targeted)
                }
                VStack(spacing: Space.xs) {
                    Text(targeted ? "Drop to add game folders" : "Turn a Switch game into a Mac app")
                        .font(.stageTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                        .accessibilityAddTraits(.isHeader)
                    Text("Drop a game folder anywhere in this window, or choose one.")
                        .font(.callout)
                        .foregroundStyle(StagePalette.inkSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .motion(Motion.respond, value: targeted)
    }
}

private struct FolderGuide: View {
    private static let files = [
        ExampleFile(symbol: "gamecontroller", name: "My Game [01001234ABCD0000][v0].nsp", kind: "Base game"),
        ExampleFile(symbol: "arrow.up.circle", name: "My Game [01001234ABCD0800][v65536].nsp", kind: "Update"),
        ExampleFile(symbol: "puzzlepiece.extension", name: "My Game [01001234ABCD1001][v0].nsp", kind: "DLC"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("What Goes in a Game Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Space.s) {
                Text("One folder per game: the base game's file, and any update and DLC.")
                    .font(.callout)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label {
                        Text("My Game").font(.mono)
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(Tone.info.glyph)
                    }
                    .accessibilityElement(children: .combine)
                    ForEach(Self.files, id: \.name) { file in
                        HStack(spacing: Space.s) {
                            Label {
                                Text(file.name).font(.mono).lineLimit(1).truncationMode(.middle)
                            } icon: {
                                Image(systemName: file.symbol).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Space.s)
                            Text(file.kind).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 22)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: .card)
        }
    }
}

private struct ExampleFile {
    let symbol: String
    let name: String
    let kind: String
}
