// The selected game app or Xcode project in the Library's inspector: its art and facts, how far its nxnative is behind, its platform (and converting it for
// the other one), what built it, and its files
import ConverterCore
import SwiftUI

struct LibraryInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    let entry: LibraryEntry

    var body: some View {
        Form {
            Section { header }
            if let behind = entry.commit.flatMap({ model.commitsBehind[$0] }), behind > 0 {
                Section {
                    Notice(.info, title: "\(behind) newer commit\(behind == 1 ? "" : "s") in nxnative",
                           message: entry.isXcodeProject ? "Prepare Again makes the project again with the current version."
                            : "Rebuild makes the game again with the current version.", onCard: false) { rebuild }
                }
            }
            Section("Platform") {
                LabeledContent("Made for", value: (entry.isXcodeProject ? ConversionOutput.xcodeProject : .macApp).platformName)
                if LibraryAction.otherPlatform.applies(to: entry) {
                    LabeledContent(entry.otherPlatform.platformName) { button("Convert…", action: .otherPlatform) }
                }
            }
            Section("Built With") { builtWith }
            Section("Files") { files }
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        VStack(spacing: Space.s) {
            GameArtwork(entry.artwork, name: entry.app.name, size: 128, shape: entry.artworkShape)
                .padding(.bottom, Space.xs)
                .accessibilityHidden(true)
            Text(entry.app.name)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            meta
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s)
    }

    private var meta: Text {
        var parts = [Text(entry.app.titleID).font(.mono)]
        if let version = entry.app.version, !version.isEmpty { parts.insert(Text(version), at: 0) }
        if let code = entry.app.language, !code.isEmpty {
            parts.append(Text(ConversionCommand.languages.first { $0.code == code }?.name ?? code))
        }
        if entry.isXcodeProject { parts.append(Text(entry.kindText)) }
        return Self.joined(parts)
    }

    @ViewBuilder private var rebuild: some View {
        if LibraryAction.rebuild.applies(to: entry) {
            Button(entry.isXcodeProject ? "Prepare Again" : "Rebuild") { LibraryAction.rebuild.perform(on: entry, in: model) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!LibraryAction.rebuild.isEnabled(for: entry, files: window.libraryFiles))
                .help(LibraryAction.rebuild.help(for: entry, files: window.libraryFiles))
        }
    }

    @ViewBuilder private var builtWith: some View {
        if let commit = entry.commit {
            let built = entry.record?.nxnative.flatMap { $0.commit == commit ? $0 : nil }
            let parts = [Text("nxnative \(commit.prefix(9))").font(.mono)] + (built?.branch.map { [Text($0)] } ?? [])
                + (entry.modified ? [Text("modified")] : [])
            Self.joined(parts).textSelection(.enabled)
        } else {
            Text("Unknown nxnative version").foregroundStyle(Tone.warning.text)
        }
        if let date = entry.commitDate {
            LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .shortened))
        }
        let location = entry.app.url.deletingLastPathComponent().path
        LabeledContent("Location") {
            Button(location.abbreviatedPath) { LibraryAction.showInFinder.perform(on: entry, in: model) }
                .buttonStyle(.link)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(location)
        }
    }

    @ViewBuilder private var files: some View {
        if entry.isXcodeProject {
            LabeledContent("Project") { button(LibraryAction.showInFinder.title, action: .showInFinder) }
            LabeledContent("Workspace") { button("Open in Xcode", action: .play) }
        } else {
            LabeledContent("App") { button(LibraryAction.showInFinder.title, action: .showInFinder) }
            LabeledContent("Settings") { button("Choose…", action: .gameSettings) }
            LabeledContent("Log") { button("Open", action: .openLog) }
            LabeledContent("Save Folder") { button("Open", action: .openSaveFolder) }
        }
    }

    /// A Files row's button: VoiceOver reads the action's full title ("Open Log"), the row shows the short one
    private func button(_ title: String, action: LibraryAction) -> some View {
        Button(title) { action.perform(on: entry, in: model) }
            .disabled(!action.isEnabled(for: entry, files: window.libraryFiles))
            .help(action.help(for: entry, files: window.libraryFiles))
            .accessibilityLabel(action.title(for: entry))
    }

    private static func joined(_ parts: [Text]) -> Text {
        guard let first = parts.first else { return Text(verbatim: "") }
        return parts.dropFirst().reduce(first) { line, part in Text("\(line) · \(part)") }
    }
}
