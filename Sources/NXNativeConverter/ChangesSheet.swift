// Show Changes: a port's diff against its base commit and its uncommitted changes, read-only, in a monospaced text view that colours the diff's
// lines, scrolls sideways instead of wrapping and has the find bar (⌘F)
import AppKit
import SwiftUI

struct ChangesSheet: View {
    private let item: DiffSheetItem
    @Environment(\.dismiss) private var dismiss

    init(item: DiffSheetItem) {
        self.item = item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.m)
                CopyButton(help: "Copy the whole diff") { item.text }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(item.text.isEmpty)
            }
            if item.text.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The worktree is the same as its base commit."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffTextView(text: item.text)
                    .clipShape(.sheetCard)
                    .overlay { ConcentricRectangle.sheetCard.stroke(.separator, lineWidth: 1) }
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.page)
        .padding(.bottom, Space.m)
        .frame(minWidth: 760, idealWidth: 960, minHeight: 520, idealHeight: 700)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        // Esc as a key equivalent, not drawn: No Changes has no focusable view, so nothing else closes the sheet on Esc there (the find bar still
        // takes Esc first)
        .background { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).hidden() }
    }
}

private struct DiffTextView: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    // Laid out for horizontal scrolling: the container is as wide as the longest line and the text view grows to it, so lines never wrap
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let view = NSTextView()
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width, .height]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 12, height: 8)
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.unregisterDraggedTypes()   // dropped folders go to the window's drop target, not into the text
        view.setAccessibilityLabel("Changes")
        scroll.documentView = view
        context.coordinator.view = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.show(text)
    }

    @MainActor final class Coordinator {
        weak var view: NSTextView?
        private var shown: String?
        private let regular = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        // The tones' text colours: dynamic, so the diff follows the appearance and Increase Contrast (systemGreen and systemRed are faint as text)
        private let added = NSColor(Tone.success.text), removed = NSColor(Tone.failure.text), hunk = NSColor(Tone.info.text)

        func show(_ text: String) {
            guard text != shown, let storage = view?.textStorage else { return }
            shown = text
            let styled = NSMutableAttributedString(string: text, attributes: [.font: regular, .foregroundColor: NSColor.labelColor])
            let lines = NSString(string: text)
            lines.enumerateSubstrings(in: NSRange(location: 0, length: lines.length), options: .byLines) { line, range, _, _ in
                if let line, let attributes = self.attributes(line) { styled.addAttributes(attributes, range: range) }
            }
            storage.setAttributedString(styled)
            view?.scrollToBeginningOfDocument(nil)
        }

        // A file's header lines first: "+++" and "---" would otherwise read as an added and a removed line
        private func attributes(_ line: String) -> [NSAttributedString.Key: Any]? {
            if line.hasPrefix("diff --git") || line.hasPrefix("+++") || line.hasPrefix("---") { return [.font: bold] }
            if line.hasPrefix("+") { return [.foregroundColor: added] }
            if line.hasPrefix("-") { return [.foregroundColor: removed] }
            if line.hasPrefix("@@") { return [.foregroundColor: hunk] }
            return nil
        }
    }
}
