// The Library's history: every conversion in a sortable table, with the nxnative version that ran it and what came of it
import ConverterCore
import SwiftUI

struct HistoryTable: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var window
    let records: [ConversionRecord]
    @Binding var selection: Set<UUID>
    @State private var sortOrder = [KeyPathComparator(\ConversionRecord.startedAt, order: .reverse)]

    var body: some View {
        Table(records.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn(Text(verbatim: "").accessibilityLabel("Status")) { HistoryStatus(status: $0.status) }.width(24)
            TableColumn("Game", value: \.gameName) { HistoryGame(record: $0) }.width(min: 180, ideal: 200)
            TableColumn("nxnative") { record in
                let text = Self.version(record)
                Text(text).font(.monoSmall).lineLimit(1).truncationMode(.middle).help(text)
            }
            .width(min: 110, ideal: 160)
            TableColumn("Took", value: \.took) { record in
                Text(record.finishedAt.map { ProgressFormat.duration($0.timeIntervalSince(record.startedAt)) } ?? "—").monospacedDigit()
            }
            .width(min: 44, ideal: 52)
            TableColumn("When", value: \.startedAt) { Text($0.startedAt.formatted(date: .abbreviated, time: .shortened)) }.width(min: 100, ideal: 132)
            TableColumn("Result") { HistoryResult(record: $0) }.width(min: 140, ideal: 180)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in HistoryMenuItems(ids: ids) }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            HistoryTargets(selection, records: records, files: window.libraryFiles).remove(in: model, window: window)
        }
    }

    private static func version(_ record: ConversionRecord) -> String {
        guard let version = record.nxnative else { return "—" }
        return version.shortCommit + (version.modified ? " (modified)" : "") + (version.branch.map { " · " + $0 } ?? "")
    }
}

private extension ConversionRecord {
    /// How long the conversion took, for sorting: a record that never finished sorts as the shortest
    var took: TimeInterval { finishedAt.map { $0.timeIntervalSince(startedAt) } ?? -1 }
}

private struct HistoryStatus: View {
    let status: ConversionStatus

    var body: some View {
        switch status {
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success.glyph).accessibilityLabel("Succeeded")
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Tone.failure.glyph).accessibilityLabel("Failed")
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary).accessibilityLabel("Cancelled")
        }
    }
}

private struct HistoryGame: View {
    let record: ConversionRecord

    var body: some View {
        HStack(spacing: Space.s) {
            GameArtwork(record.titleID.map { .gameFolder(record.folderURL, titleID: $0) }, name: record.gameName, size: 20)
            Text(record.gameName).fontWeight(.medium).lineLimit(1)
            if let version = record.gameVersion, !version.isEmpty { Text(version).foregroundStyle(.secondary).lineLimit(1) }
        }
        .help((record.titleID.map { $0 + " · " } ?? "") + record.folder)
    }
}

private struct HistoryResult: View {
    let record: ConversionRecord

    var body: some View {
        let result = Self.result(record)
        Text(result.short).foregroundStyle(result.color).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(result.full)
    }

    private static func result(_ record: ConversionRecord) -> (short: String, full: String, color: Color) {
        let message = record.message.flatMap { $0.isEmpty ? nil : $0 }
        switch record.status {
        case .failed: return (message ?? "Failed", message ?? "Failed", Tone.failure.text)
        case .cancelled: return (message ?? "Cancelled", message ?? "Cancelled", .secondary)
        case .succeeded:
            if record.options.surveyOnly { return ("Survey only", "Survey only", .secondary) }
            guard let path = record.installedAppPath ?? record.builtAppPath else { return ("", "", .secondary) }
            return (path.abbreviatedPath, path, .primary)
        }
    }
}
