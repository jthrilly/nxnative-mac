// The running work in the toolbar of every page: the conversion, the agent run and the console's operation each show as a button with its progress
// while their own page is not the one shown, and the button goes to that page
import ConverterCore
import SwiftUI

struct ActivityToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        if let job = model.activeJob, !(model.shownPage == .convert && model.shownJob?.id == job.id) {
            ToolbarItem(placement: .principal) { ConversionActivity(job: job) }
                .visibilityPriority(.high)
        }
        if let run = model.activePortRun, !(model.shownPage == .ports && model.shownPortID == run.titleID) {
            ToolbarItem(placement: .principal) { AgentActivity(run: run) }
                .visibilityPriority(.high)
        }
        if let operation = ConsoleOperation(model), model.shownPage != operation.page {
            ToolbarItem(placement: .principal) { ConsoleActivity(operation: operation) }
                .visibilityPriority(.high)
        }
    }
}

private struct ConversionActivity: View {
    @Environment(AppModel.self) private var model
    let job: ConversionJob

    var body: some View {
        Button {
            model.page = .convert
            model.selectedJobID = job.id
        } label: {
            Label {
                HStack(spacing: 0) {
                    Text(job.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading)
                    Text(" · " + progress).monospacedDigit()
                }
            } icon: {
                ActivityRing(fraction: job.progressFraction)
            }
        }
        .labelStyle(.titleAndIcon)
        .help("Show the conversion of \(job.name)")
        .accessibilityLabel("\(job.name), \(job.statusText)")
        .accessibilityHint("Shows the conversion")
    }

    private var progress: String {
        switch job.state {
        case .installing: "Installing…"
        case .running: ProgressFormat.percent(job.build.overallFraction)
        default: "Preparing…"
        }
    }
}

private struct AgentActivity: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PortTab.storageKey) private var portTab = PortTab.overview
    let run: PortRun

    var body: some View {
        Button {
            model.page = .ports
            if model.selectedPortID != run.titleID { model.selectedRunID = nil }
            model.selectedPortID = run.titleID
            portTab = .transcript
        } label: {
            Label {
                Text("\(run.kind.displayName): \(run.gameName)").lineLimit(1).truncationMode(.tail).frame(maxWidth: 260)
            } icon: {
                ActivityRing(fraction: nil)
            }
        }
        .labelStyle(.titleAndIcon)
        .help(run.phase)
        .accessibilityLabel("\(run.kind.displayName) is porting \(run.gameName)")
        .accessibilityValue(run.phase)
        .accessibilityHint("Shows the agent's transcript")
    }
}

private struct ConsoleActivity: View {
    @Environment(AppModel.self) private var model
    let operation: ConsoleOperation

    var body: some View {
        Button {
            model.page = operation.page
        } label: {
            Label {
                Text(operation.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 260)
            } icon: {
                ActivityRing(fraction: nil)
            }
        }
        .labelStyle(.titleAndIcon)
        .help(model.console.lines.last?.text ?? "")
        .accessibilityLabel(operation.title)
        .accessibilityHint(operation.page == .repository ? "Shows the nxnative page" : "Shows the Setup page")
    }
}

/// The console's operation, or the shell environment being read at launch, and the page that shows its output
private struct ConsoleOperation {
    let title: String
    let page: Page

    private static let repositoryOperations: Set<String> = [
        "Checking for updates", "Updating nxnative", "Discarding local changes", "Downloading nxnative",
    ]

    @MainActor init?(_ model: AppModel) {
        if let title = model.console.title {
            self.title = title
            page = Self.repositoryOperations.contains(title) ? .repository : .setup
        } else if !model.isReady {
            title = "Reading the shell environment…"
            page = .setup
        } else {
            return nil
        }
    }
}

/// A mini progress ring (0 while preparing, 1 while installing), or a spinner when there is no fraction; it dims with an inactive window
private struct ActivityRing: View {
    let fraction: Double?
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Group {
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.circular)
            } else {
                ProgressView()
            }
        }
        .controlSize(.mini)
        .opacity(appearsActive ? 1 : 0.5)
        .saturation(appearsActive ? 1 : 0)
        .accessibilityHidden(true)
    }
}
