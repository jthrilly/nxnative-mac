// The stages of a conversion as the script reports them, on a rail: status, name · step, the count and its bar, the ETA, then the summary and elapsed
// time, and a row for the stages still to come. It follows the newest stage
import ConverterCore
import SwiftUI

struct StageListView: View {
    private let stages: [StageRecord]
    private let upcoming: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(stages: [StageRecord], upcoming: Int = 0) {
        self.stages = stages; self.upcoming = upcoming
    }

    var body: some View {
        if stages.isEmpty {
            ContentUnavailableView("No Stages Yet", systemImage: "list.bullet", description: Text("The script's stages appear here as it runs."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(stages) { stage in
                            StageRow(stage: stage, first: stage.id == stages.first?.id, last: stage.id == stages.last?.id && upcoming == 0)
                                .id(stage.id)
                                .transition(.opacity)
                        }
                        if upcoming > 0 { UpcomingRow(count: upcoming) }
                    }
                    .padding(.vertical, 6)
                    .motion(Motion.fade, value: stages.count)
                }
                .onAppear { if let last = stages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: stages.count) {
                    guard let last = stages.last else { return }
                    if reduceMotion {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    } else {
                        withAnimation(Motion.fade) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

/// The rail behind a row's 18-point node column: from the row's top to its node, and from its node to the row's bottom, joining the next row's
private struct Rail: View {
    let above: Bool
    let below: Bool
    var dashedAbove = false

    var body: some View {
        let color = Color(nsColor: .separatorColor)
        VStack(spacing: 0) {
            RailLine().stroke(above ? color : .clear, style: StrokeStyle(lineWidth: 2, dash: dashedAbove ? [2, 3] : [])).frame(height: 6)
            Color.clear.frame(height: 18)
            RailLine().stroke(below ? color : .clear, lineWidth: 2).frame(maxHeight: .infinity)
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

private struct RailLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

private struct StageRow: View {
    let stage: StageRecord
    let first: Bool
    let last: Bool

    var body: some View {
        let running = stage.status == .running
        HStack(alignment: .top, spacing: 10) {
            node.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).fontWeight(running ? .semibold : .regular).lineLimit(1)
                    Spacer(minLength: 8)
                    if let elapsed {
                        Text(ProgressFormat.duration(elapsed)).font(.mono).foregroundStyle(.secondary)
                    }
                }
                if running, let progress = stage.progress {
                    let count = ProgressFormat.count(progress)
                    if let fraction = progress.fraction { ProgressView(value: min(max(fraction, 0), 1)).controlSize(.small) }
                    HStack {
                        if !count.isEmpty { Text(count).monospacedDigit() }
                        if !progress.note.isEmpty { Text(progress.note).lineLimit(1) }
                        Spacer()
                        if let eta = progress.eta, eta > 0 { Text("about \(ProgressFormat.duration(eta)) left").monospacedDigit() }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !stage.summary.isEmpty {
                    Text(stage.summary)
                        .font(.caption)
                        .foregroundStyle(stage.status == .failed ? Tone.failure.text : .secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(alignment: .leading) { Rail(above: !first, below: !last).padding(.leading, 8) }
        .background { if running { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.06)) } }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private var title: String { stage.step.isEmpty ? stage.name : "\(stage.name) · \(stage.step)" }

    private var elapsed: Double? { stage.status == .running ? stage.progress?.elapsed ?? Date().timeIntervalSince(stage.startedAt) : stage.elapsed }

    @ViewBuilder private var node: some View {
        switch stage.status {
        case .running: ProgressView().controlSize(.small).accessibilityLabel("Running")
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success.glyph).accessibilityLabel("Done")
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Tone.failure.glyph).accessibilityLabel("Failed")
        }
    }
}

private struct UpcomingRow: View {
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(width: 14, height: 14)
                .frame(width: 18, height: 18)
            Text(count == 1 ? "1 more stage" : "\(count) more stages").foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .background(alignment: .leading) { Rail(above: true, below: false, dashedAbove: true) }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}
