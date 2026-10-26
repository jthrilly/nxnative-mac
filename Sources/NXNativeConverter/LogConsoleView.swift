// A monospaced, selectable log (a conversion's log, or the console of git operations and fixes): an NSTextView that appends new lines and drops the
// oldest in place instead of laying out thousands of lines again for every batch. Its header and controls are the page's (LogControls)
import AppKit
import ConverterCore
import SwiftUI

enum ConsoleStyle { case normal, warning, alert, command, note }

protocol ConsoleDisplayLine: Identifiable where ID == Int {
    var displayText: String { get }
    var style: ConsoleStyle { get }
}

extension LogLine: ConsoleDisplayLine {
    var displayText: String { text }
    var style: ConsoleStyle {
        switch kind {
        case .info: .normal
        case .warning: .warning
        case .error: .alert
        }
    }
}

extension ConsoleLine: ConsoleDisplayLine {
    var displayText: String { text }
    var style: ConsoleStyle {
        switch kind {
        case .output: .normal
        case .error: .alert
        case .command: .command
        case .note: .note
        }
    }
}

struct LogConsoleView<Line: ConsoleDisplayLine>: View {
    private let lines: [Line]
    private let autoScroll: Bool

    init(lines: [Line], autoScroll: Bool) {
        self.lines = lines; self.autoScroll = autoScroll
    }

    var body: some View {
        ConsoleTextView(lines: lines, autoScroll: autoScroll)
    }
}

private struct ConsoleTextView<Line: ConsoleDisplayLine>: NSViewRepresentable {
    let lines: [Line]
    let autoScroll: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = NSTextView()
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.textContainerInset = NSSize(width: 12, height: 8)
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.unregisterDraggedTypes()   // dropped folders go to the window's drop target, not into the text
        text.setAccessibilityLabel("Log")
        scroll.documentView = text
        context.coordinator.text = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(lines: lines, autoScroll: autoScroll)
    }

    @MainActor final class Coordinator {
        weak var text: NSTextView?
        private var entries: [(id: Int, length: Int)] = []   // the lines in the text view and their UTF-16 lengths (with the newline)
        private var autoScrolled = true
        private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        // The tones' text colours: dynamic, so the text follows the appearance and Increase Contrast (systemRed and systemOrange are too faint as text)
        private let failure = NSColor(Tone.failure.text), warning = NSColor(Tone.warning.text)
        private let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.15
            return style
        }()

        func update(lines: [Line], autoScroll: Bool) {
            guard let view = text, let storage = view.textStorage else { return }
            let firstNew = lines.first?.id ?? Int.max, lastNew = lines.last?.id ?? Int.min
            // A log whose ids went back (a new run, or Clear) is laid out again from the start
            let reset = lines.isEmpty || (entries.last.map { $0.id > lastNew } ?? false) || (entries.first.map { $0.id > firstNew } ?? false)
            storage.beginEditing()
            if reset {
                storage.setAttributedString(NSAttributedString())
                entries.removeAll()
            } else {
                var drop = 0, length = 0
                while drop < entries.count, entries[drop].id < firstNew { length += entries[drop].length; drop += 1 }
                if drop > 0 {
                    storage.deleteCharacters(in: NSRange(location: 0, length: min(length, storage.length)))
                    entries.removeFirst(drop)
                }
            }
            let lastShown = entries.last?.id ?? Int.min
            let start = lines.lastIndex { $0.id <= lastShown }.map { $0 + 1 } ?? lines.startIndex
            let added = NSMutableAttributedString()
            for line in lines[start...] {
                let s = line.displayText + "\n"
                added.append(NSAttributedString(string: s, attributes: attributes(line.style)))
                entries.append((line.id, s.utf16.count))
            }
            if added.length > 0 { storage.append(added) }
            storage.endEditing()
            let turnedOn = autoScroll && !autoScrolled
            autoScrolled = autoScroll
            if autoScroll, added.length > 0 || reset || turnedOn { view.scrollToEndOfDocument(nil) }
        }

        private func attributes(_ style: ConsoleStyle) -> [NSAttributedString.Key: Any] {
            switch style {
            case .normal: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            case .warning: [.font: font, .foregroundColor: warning, .paragraphStyle: paragraph]
            case .alert: [.font: font, .foregroundColor: failure, .paragraphStyle: paragraph]
            case .command: [.font: bold, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            case .note: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
            }
        }
    }
}
