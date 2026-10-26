// The port page's Transcript tab: the transcript of the run chosen in its header (by default the running one, else the newest), live from memory
// while it runs and for the runs of this session, else read back from its raw file
import ConverterCore
import SwiftUI

struct PortTranscriptTab: View {
    @Environment(AppModel.self) private var model
    let port: PortRecord
    @State private var loaded: PortLoadedTranscript?

    var body: some View {
        if let run = model.shownRun(of: port) {
            transcript(of: run)
        } else {
            TranscriptPaneLayout {
                EmptyView()
            } content: {
                ContentUnavailableView("No Runs Yet", systemImage: "sparkles", description: Text("Continue… starts the agent on this port."))
            }
        }
    }

    @ViewBuilder private func transcript(of run: AgentRunRecord) -> some View {
        if let live = model.liveRun(run.id) {
            AgentTranscriptView(transcript: live.transcript, kind: live.kind, rawFile: live.transcriptFile, live: !live.finished) {
                PortRunPicker(port: port)
            }
            .id(run.id)
        } else if run.interactive {
            TranscriptPaneLayout {
                PortRunPicker(port: port)
                Spacer()
            } content: {
                ContentUnavailableView {
                    Label("Interactive Session", systemImage: "apple.terminal")
                } description: {
                    Text("\(run.kind.displayName) ran in Terminal, where its conversation is; the app does not follow it. "
                        + "When the session has ended, Save Checkpoint keeps its work on \(port.branch).")
                } actions: {
                    PortActionButton(.saveCheckpoint, port: port)
                }
            }
        } else if let path = run.transcriptFile {
            let file = URL(fileURLWithPath: path)
            AgentTranscriptView(transcript: loaded?.id == run.id ? loaded?.transcript ?? AgentTranscript() : AgentTranscript(), kind: run.kind, rawFile: file,
                                loading: loaded?.id != run.id) {
                PortRunPicker(port: port)
            }
            .id(run.id)
            .task(id: run.id) {
                let transcript = await AppModel.loadTranscript(file: file, kind: run.kind, date: run.startedAt)
                loaded = PortLoadedTranscript(id: run.id, transcript: transcript)
            }
        } else {
            TranscriptPaneLayout {
                PortRunPicker(port: port)
                Spacer()
            } content: {
                ContentUnavailableView("No Transcript", systemImage: "text.bubble", description: Text("This run has no transcript file."))
            }
        }
    }
}

/// A finished run's transcript as read from its file (nil when it could not be read)
private struct PortLoadedTranscript {
    let id: UUID
    let transcript: AgentTranscript?
}

/// The runs of the port, newest first, as "date · status"; the choice is the run the Runs table selects too
private struct PortRunPicker: View {
    @Environment(AppModel.self) private var model
    let port: PortRecord

    var body: some View {
        Picker("Run", selection: Binding(get: { model.shownRun(of: port)?.id }, set: { model.selectedRunID = $0 })) {
            ForEach(Array(port.runs.reversed())) { run in
                Text(title(run)).tag(Optional(run.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("The run whose transcript is shown")
    }

    private func title(_ run: AgentRunRecord) -> String {
        let status = model.activePortRun?.id == run.id ? AgentRunStatus.running : run.status
        return "\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(status.title)"
    }
}
