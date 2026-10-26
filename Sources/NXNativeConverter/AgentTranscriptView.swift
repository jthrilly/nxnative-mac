// An agent run's transcript, read like a chat log: the agent's prose as paragraphs, each tool call as a monospaced line ("$ command", "Read path")
// with a status dot in the gutter, whose output opens below it, warnings and errors as notices, the app's own notes in grey. Its header row carries
// what the page puts before it (the Transcript tab's run picker), the counts, the agent's state and the small controls
import AppKit
import ConverterCore
import SwiftUI

struct AgentTranscriptView<Leading: View>: View {
    private let transcript: AgentTranscript
    private let kind: AgentKind
    private let rawFile: URL?
    private let live: Bool
    private let loading: Bool
    private let leading: Leading
    @AppStorage("transcriptAutoScroll") private var autoScroll = true
    @State private var rawExists = false

    init(transcript: AgentTranscript, kind: AgentKind, rawFile: URL? = nil, live: Bool = false, loading: Bool = false, @ViewBuilder leading: () -> Leading) {
        self.transcript = transcript; self.kind = kind; self.rawFile = rawFile; self.live = live; self.loading = loading; self.leading = leading()
    }

    var body: some View {
        TranscriptPaneLayout {
            leading
            if !loading {
                Text(countText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
            }
            Spacer(minLength: Space.s)
            if live {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("\(kind.displayName) is working").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            controls
        } content: {
            content
        }
        .task(id: TranscriptRawFileKey(path: rawFile?.path, empty: transcript.entries.isEmpty)) {
            guard let rawFile else { rawExists = false; return }
            rawExists = await FileCheck.existing([rawFile]).contains(rawFile)
        }
    }

    private var countText: String {
        let n = transcript.entries.count, tools = transcript.toolCalls
        return "\(n) entr\(n == 1 ? "y" : "ies") · \(tools) tool call\(tools == 1 ? "" : "s")"
    }

    @ViewBuilder private var controls: some View {
        LogControls(autoScroll: $autoScroll, autoScrollHelp: "Scroll to new entries as they arrive", canCopy: !transcript.entries.isEmpty,
                    copyHelp: "Copy the transcript as text", copyLabel: "Copy Transcript") { plainText }
        Button("Open Raw Transcript", systemImage: "doc.text.magnifyingglass") {
            if let rawFile { NSWorkspace.shared.activateFileViewerSelecting([rawFile]) }
        }
        .labelStyle(.iconOnly)
        .help("Show the run's raw JSONL transcript in Finder")
        .disabled(!rawExists)
    }

    @ViewBuilder private var content: some View {
        if transcript.entries.isEmpty {
            if loading {
                ProgressView("Reading the transcript…")
            } else {
                ContentUnavailableView(live ? "Waiting for \(kind.displayName)" : "No Transcript", systemImage: "text.bubble",
                                       description: Text(live ? "What the agent says and does appears here as it works."
                                                              : "This run has no transcript in the app."))
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(transcript.entries) { entry in
                            TranscriptEntryRow(entry: entry, kind: kind, live: live).id(entry.id)
                        }
                    }
                    .padding(.horizontal, Space.s).padding(.vertical, 10)
                }
                .onAppear { if let last = transcript.entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: transcript.entries.last?.id) { _, last in
                    if autoScroll, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var plainText: String {
        transcript.entries.map { entry -> String in
            switch entry.kind {
            case .tool: return entry.title + (entry.detail.isEmpty ? "" : "\n" + entry.detail)
            case .text, .warning, .error, .note: return entry.plainText
            }
        }.joined(separator: "\n\n")
    }
}

extension AgentTranscriptView where Leading == EmptyView {
    init(transcript: AgentTranscript, kind: AgentKind, rawFile: URL? = nil, live: Bool = false, loading: Bool = false) {
        self.init(transcript: transcript, kind: kind, rawFile: rawFile, live: live, loading: loading) { EmptyView() }
    }
}

/// A Transcript tab's layout, with or without a transcript: a header row of small controls over a card that fills the rest
struct TranscriptPaneLayout<Header: View, Content: View>: View {
    private let header: Header
    private let content: Content

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header(); self.content = content()
    }

    var body: some View {
        VStack(spacing: Space.s) {
            HStack(spacing: Space.m) { header }
                .controlSize(.small)
                .frame(minHeight: 22)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.quinary, in: .card)
                .clipShape(.card)
        }
    }
}

private struct TranscriptRawFileKey: Hashable {
    var path: String?
    var empty: Bool
}

private extension AgentEntry {
    /// The words of a prose, warning, error or note entry: a prose entry's title is its first line (or, for a report, the milestone over its summary)
    var plainText: String { detail.isEmpty ? title : detail.hasPrefix(title) ? detail : title + "\n" + detail }
}

/// Agents write Markdown; inline styles (code, bold, links) are shown, block syntax stays as written. Each text is parsed once: rows are made again
/// whenever a live transcript grows
@MainActor private final class TranscriptMarkdownCache {
    static let shared = TranscriptMarkdownCache()
    private var parsed: [String: AttributedString] = [:]

    func attributed(_ text: String) -> AttributedString {
        if let hit = parsed[text] { return hit }
        if parsed.count >= 4_000 { parsed.removeAll(keepingCapacity: true) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let value = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        parsed[text] = value
        return value
    }
}

private enum TranscriptMetrics {
    static let gutter: CGFloat = 28
    static let textWidth: CGFloat = 720
    static var rowShape: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: 6), isUniform: true) }
}

private struct TranscriptEntryRow: View {
    let entry: AgentEntry
    let kind: AgentKind
    let live: Bool

    var body: some View {
        Group {
            switch entry.kind {
            case .text:
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Image(systemName: "text.bubble.fill").font(.system(size: 12)).foregroundStyle(Tone.brand.glyph)
                        .frame(width: TranscriptMetrics.gutter).accessibilityHidden(true)
                    Text(TranscriptMarkdownCache.shared.attributed(entry.plainText)).textSelection(.enabled)
                        .frame(maxWidth: TranscriptMetrics.textWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6).padding(.horizontal, Space.s)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(kind.displayName): \(entry.plainText)")
            case .tool:
                TranscriptToolRow(entry: entry, live: live)
            case .warning:
                Notice(.warning, message: entry.plainText)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Warning: \(entry.plainText)")
                    .padding(.vertical, Space.xs).padding(.horizontal, Space.s)
            case .error:
                Notice(.failure, message: entry.plainText)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Error: \(entry.plainText)")
                    .padding(.vertical, Space.xs).padding(.horizontal, Space.s)
            case .note:
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Image(systemName: "info.circle").frame(width: TranscriptMetrics.gutter).accessibilityHidden(true)
                    Text(entry.plainText).textSelection(.enabled).frame(maxWidth: TranscriptMetrics.textWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.vertical, Space.xs).padding(.horizontal, Space.s)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Note: \(entry.plainText)")
            }
        }
        .help(entry.date.formatted(date: .omitted, time: .standard))
    }
}

private struct TranscriptToolRow: View {
    let entry: AgentEntry
    let live: Bool             // a tool without a result in a finished run was cut off, not running
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        let hasOutput = !entry.detail.isEmpty
        VStack(alignment: .leading, spacing: Space.xs) {
            Button { if hasOutput { expanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    dot.frame(width: TranscriptMetrics.gutter)
                    Text(entry.title).font(.mono).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(entry.ok == false ? Tone.failure.text : Color.primary)
                    Spacer(minLength: Space.s)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(hovering ? .secondary : .tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hasOutput ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(entry.title)
            .accessibilityLabel("\(statusWord) \(entry.title)")
            .accessibilityHint(!hasOutput ? "" : expanded ? "Hides the output" : "Shows the output")
            if expanded {
                ScrollView {
                    Text(entry.detail).font(.monoSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Space.s)
                }
                .frame(maxHeight: 260)
                .background(Color(nsColor: .controlBackgroundColor), in: TranscriptMetrics.rowShape)
                .padding(.leading, TranscriptMetrics.gutter)
            }
        }
        .padding(.vertical, Space.xs).padding(.horizontal, Space.s)
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear, in: TranscriptMetrics.rowShape)
        .motion(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }

    private var statusWord: String {
        switch entry.ok {
        case true?: "Succeeded:"
        case false?: "Failed:"
        case nil: live ? "Running:" : "Not finished:"
        }
    }

    // A dot's bottom sits on the title's baseline, which centres it on the lowercase letters
    @ViewBuilder private var dot: some View {
        switch entry.ok {
        case true?: Circle().fill(Tone.success.glyph).frame(width: 7, height: 7).accessibilityHidden(true)
        case false?: Circle().fill(Tone.failure.glyph).frame(width: 7, height: 7).accessibilityHidden(true)
        case nil where live: ProgressView().controlSize(.mini).frame(width: 10, height: 10).accessibilityHidden(true)
        case nil: Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: 7, height: 7).accessibilityHidden(true)
        }
    }
}
