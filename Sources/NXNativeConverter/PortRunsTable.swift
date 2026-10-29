// The port page's Runs tab: the agent runs on the port, newest first, with what each cost and left behind. The selection is the run the Transcript
// tab shows; double-click or Return opens it there
import ConverterCore
import SwiftUI

struct PortRunsTable: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PortTab.storageKey) private var tab = PortTab.overview
    let port: PortRecord

    var body: some View {
        Group {
            if port.runs.isEmpty {
                ContentUnavailableView("No Runs Yet", systemImage: "sparkles", description: Text("Continue… starts the agent on this port."))
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.fill.quinary, in: .card)
        .clipShape(.card)
    }

    private var table: some View {
        Table(Array(port.runs.reversed()), selection: selection) {
            TableColumn("Agent") { run in
                Label(run.kind.displayName, systemImage: run.interactive ? "apple.terminal" : "sparkles").labelStyle(.titleAndIcon)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Started") { run in Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)) }
                .width(min: 100, ideal: 130)
            TableColumn("Duration") { run in PortRunDuration(run: run, live: isLive(run)) }
                .width(min: 55, ideal: 65)
            TableColumn("Status") { run in statusChip(run) }
                .width(min: 90, ideal: 105)
            TableColumn("Cost") { run in Text(run.usage?.costUSD.map(PortRunFormat.cost) ?? "—").monospacedDigit() }
                .width(min: 45, ideal: 60)
            TableColumn("Tokens") { run in Text(PortRunFormat.tokens(run.usage)).monospacedDigit().help(PortRunFormat.tokenHelp(run.usage)) }
                .width(min: 60, ideal: 90)
            TableColumn("Turns") { run in Text(run.turns.map { "\($0)" } ?? "—").monospacedDigit() }
                .width(min: 35, ideal: 45)
            TableColumn("Checkpoint") { run in Text(run.checkpoint.map { String($0.prefix(9)) } ?? "—").monospaced().textSelection(.enabled) }
                .width(min: 70, ideal: 85)
            TableColumn("Message") { run in message(run) }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: UUID.self) { _ in
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            model.selectedRunID = id
            tab = .transcript
        }
    }

    private var selection: Binding<UUID?> {
        Binding(get: { model.shownRun(of: port)?.id }, set: { model.selectedRunID = $0 })
    }

    private func isLive(_ run: AgentRunRecord) -> Bool { model.isActiveRun(run.id) }

    private func statusChip(_ run: AgentRunRecord) -> some View {
        let status = model.isActiveRun(run.id) ? AgentRunStatus.running : run.status
        return StatusChip(status.title, symbol: status.symbol, tone: status.tone)
            .accessibilityLabel("Status: \(status.title)")
    }

    private func message(_ run: AgentRunRecord) -> some View {
        let text = run.message ?? run.report?.summary ?? ""
        return Text(text).lineLimit(1).help(text)
    }
}

/// How long a run took: ticking while it runs, "—" for a run that never finished
private struct PortRunDuration: View {
    let run: AgentRunRecord
    let live: Bool

    var body: some View {
        if live {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(ProgressFormat.duration(context.date.timeIntervalSince(run.startedAt))).monospacedDigit()
            }
        } else if let end = run.finishedAt {
            Text(ProgressFormat.duration(end.timeIntervalSince(run.startedAt))).monospacedDigit()
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

/// The figures of agent runs: their cost in US dollars and their tokens (input / output, compact)
enum PortRunFormat {
    static func cost(_ usd: Double) -> String { usd.formatted(.currency(code: "USD").precision(.fractionLength(2))) }

    fileprivate static func tokens(_ usage: AgentUsage?) -> String {
        guard let usage, usage.inputTokens != nil || usage.outputTokens != nil else { return "—" }
        return "\(compact(usage.inputTokens ?? 0)) / \(compact(usage.outputTokens ?? 0))"
    }

    fileprivate static func tokenHelp(_ usage: AgentUsage?) -> String {
        guard let usage else { return "" }
        var parts: [String] = []
        if let n = usage.inputTokens { parts.append("\(n.formatted()) input tokens") }
        if let n = usage.cachedInputTokens { parts.append("\(n.formatted()) cached") }
        if let n = usage.outputTokens { parts.append("\(n.formatted()) output tokens") }
        return parts.joined(separator: ", ")
    }

    private static func compact(_ n: Int) -> String { n.formatted(.number.notation(.compactName).precision(.significantDigits(1...3))) }
}
