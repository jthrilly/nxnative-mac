// The console's output (git operations and fixes) with its header: what runs, the line count, Stop and Clear, and the log controls. The nxnative
// and Setup pages show it under their content
import SwiftUI

struct OutputPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("logAutoScroll") private var autoScroll = true

    var body: some View {
        let console = model.console
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Text(console.title ?? "Output").font(.headline).lineLimit(1)
                Text("\(console.lines.count) line\(console.lines.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if console.isRunning {
                    ProgressView().controlSize(.small).accessibilityLabel("Running")
                }
                Spacer(minLength: Space.s)
                if console.canStop {
                    Button("Stop Command", systemImage: "stop.fill") { console.stop() }
                        .labelStyle(.iconOnly)
                        .help("Stop the command")
                }
                Button("Clear Console", systemImage: "trash") { console.clear() }
                    .labelStyle(.iconOnly)
                    .help("Clear the console")
                    .disabled(console.isRunning)
                LogControls(autoScroll: $autoScroll, canCopy: !console.lines.isEmpty) {
                    console.lines.map(\.text).joined(separator: "\n")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            Divider()
            LogConsoleView(lines: console.lines, autoScroll: autoScroll)
        }
    }
}
