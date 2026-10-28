// A queued game's options, which apply to the job as they change and can be changed until the conversion starts, its game files and the scan's notes
import AppKit
import ConverterCore
import SwiftUI

struct JobOptionsForm: View {
    private let job: ConversionJob
    @State private var advanced = false

    init(job: ConversionJob) { self.job = job }

    var body: some View {
        @Bindable var job = job
        Form {
            Section {
                OutputPicker("Make", selection: $job.options.output)
                    .help("A Mac app, installed like any other, or an Xcode project for iPhone and iPad that Xcode signs and installs on your device")
                if job.match == .noProfile {
                    Toggle("Survey only", isOn: $job.options.surveyOnly)
                        .help("Write the survey and the provisional profile, and stop before making the app or the Xcode project")
                }
                LanguagePicker("Language", selection: $job.options.language)
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Picker("Game version", selection: $job.options.package) {
                        Text("Newest (v\(job.scan.newestVersion))").tag("")
                        ForEach(job.scan.versions, id: \.self) { version in
                            Text(versionLabel(version)).tag("v\(version)")
                        }
                    }
                    TextField("App name", text: $job.options.appName, prompt: Text(job.name))
                    TextField("Bundle ID", text: $job.options.bundleID, prompt: Text("Automatic"))
                    Toggle("Allow damaged game files", isOn: $job.options.allowDamaged)
                }
            } header: {
                Text("Options")
            } footer: {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if job.options.output == .xcodeProject {
                        Text("The project goes in the game folder and is added to NxNative.xcworkspace beside it. Its signing team is "
                             + "Settings › Conversion › Team ID.")
                    }
                    Text("Options can be changed until the conversion starts. The game's settings (frame rate, render scale…) are chosen in the Library, "
                         + "under Game Settings, once the app is made.")
                }
                .foregroundStyle(.secondary)
            }
            Section("Game Files") {
                ForEach(job.scan.files) { file in
                    HStack {
                        Image(systemName: Self.symbol(file.kind)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(Self.detail(file)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ProgressFormat.bytes(Double(file.size))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if !job.scan.warnings.isEmpty {
                Section("Notes") {
                    ForEach(job.scan.warnings, id: \.self) { warning in
                        Label {
                            Text(warning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Tone.warning.glyph)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The builds of the matched profile: their versions are labelled as tested
    private var builds: [ProfileBuild] {
        switch job.match {
        case .tested(let profile, _), .untestedVersion(let profile, _, _): profile.builds
        case .noProfile: []
        }
    }

    private func versionLabel(_ version: Int) -> String {
        let tested = builds.first { $0.version == "v\(version)" }.map { " · \($0.display), tested" } ?? ""
        return (version == 0 ? "v0 (base game)" : "v\(version)") + tested
    }

    private static func symbol(_ kind: NSPKind) -> String {
        switch kind {
        case .base: "gamecontroller"
        case .update: "arrow.up.circle"
        case .dlc: "puzzlepiece.extension"
        case .unknown: "questionmark.circle"
        }
    }

    private static func detail(_ file: NSPFile) -> String {
        var parts: [String]
        switch file.kind {
        case .base: parts = ["Base game"]
        case .update: parts = ["Update"]
        case .dlc: parts = ["DLC"]
        case .unknown: parts = ["Unknown title"]
        }
        if let version = file.version { parts.append("v\(version)") }
        if file.compressed { parts.append("compressed") }
        return parts.joined(separator: " · ")
    }
}
