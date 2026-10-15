import AppKit
import SwiftUI

/// Marks drawn on dictation text: search matches, a word being fixed, and fixed words.
struct TranscriptTextMarks: Equatable {
    /// Search matches, tinted with the selection colour.
    var highlights: [NSRange] = []
    /// The word a Fix a word popover is open for, struck through in place (no reflow).
    var strike: NSRange?
    /// Words already corrected, underlined in the accent.
    var fixed: [NSRange] = []
}

/// One dictation's text, set by TextKit at its metrics' measure: read-only, selectable,
/// copyable. The line counter uses the same typesetter, so its count matches these lines.
struct TranscriptTextView: NSViewRepresentable {
    let text: String
    let metrics: TranscriptMetrics
    var marks = TranscriptTextMarks()
    /// While true, selecting a word reports it through `onPickWord`.
    var picksWord = false
    var onPickWord: ((NSRange) -> Void)?
    /// The dictation's stored text, which `text` may differ from only in characters that are
    /// drawn in place of others (same UTF-16 length). Copying a selection writes this, not `text`.
    var storedText: String?
    /// Whether copying a selection marks it concealed, for words dictated into a password field.
    var concealsCopy = false
    @Environment(\.quillTheme) private var theme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptNSTextView {
        let container = TranscriptTypesetter.makeContainer(metrics)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let view = TranscriptNSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.focusRingType = .none
        view.usesFindBar = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: TranscriptNSTextView, context: Context) {
        context.coordinator.picksWord = picksWord
        context.coordinator.onPickWord = onPickWord
        view.storedText = storedText
        view.concealsCopy = concealsCopy
        let signature = Signature(text: text, metrics: metrics, marks: marks, theme: theme)
        view.selectedTextAttributes = [.backgroundColor: theme.palette.accent.opacity(0.24).nsColor]
        guard view.signature != signature else { return }
        let selection = view.selectedRanges
        view.signature = signature
        if let container = view.textContainer { TranscriptTypesetter.configure(container, metrics) }
        view.textStorage?.setAttributedString(attributed())
        let lines = TranscriptLineCounter.lineCount(text, metrics: metrics)
        view.setFrameSize(CGSize(width: metrics.measure, height: CGFloat(lines) * metrics.lineHeight))
        let length = view.textStorage?.length ?? 0
        let kept = selection.filter { NSMaxRange($0.rangeValue) <= length }
        if !kept.isEmpty { view.selectedRanges = kept }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptNSTextView, context: Context) -> CGSize? {
        let lines = TranscriptLineCounter.lineCount(text, metrics: metrics)
        return CGSize(width: metrics.measure, height: CGFloat(lines) * metrics.lineHeight)
    }

    private func attributed() -> NSAttributedString {
        let result = NSMutableAttributedString(
            attributedString: TranscriptTypesetter.attributedString(text, metrics: metrics, color: theme.palette.ink.nsColor)
        )
        let length = result.length
        func valid(_ range: NSRange) -> Bool { range.length > 0 && NSMaxRange(range) <= length }
        for range in marks.highlights where valid(range) {
            result.addAttribute(.backgroundColor, value: theme.palette.accent.opacity(theme.scheme == .dark ? 0.26 : 0.20).nsColor, range: range)
        }
        for range in marks.fixed where valid(range) {
            result.addAttributes([
                .backgroundColor: theme.palette.accentWash.nsColor,
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: theme.palette.accent.nsColor
            ], range: range)
        }
        if let strike = marks.strike, valid(strike) {
            result.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: theme.palette.accent.nsColor,
                .foregroundColor: (theme.scheme == .dark ? theme.palette.ink2 : theme.palette.ink3).nsColor,
                .backgroundColor: theme.palette.accent.opacity(0.18).nsColor
            ], range: strike)
        }
        return result
    }

    struct Signature: Equatable {
        let text: String
        let metrics: TranscriptMetrics
        let marks: TranscriptTextMarks
        let theme: QuillTheme
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var picksWord = false {
            didSet { if picksWord != oldValue { lastReported = nil } }
        }
        var onPickWord: ((NSRange) -> Void)?
        private var lastReported: NSRange?

        func textViewDidChangeSelection(_ notification: Notification) {
            // A drag reports once: the text view sends no selection change until the mouse comes up.
            guard picksWord, let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            guard range.length > 0 else { return }
            let word = view.selectionRange(forProposedRange: range, granularity: .selectByWord)
            guard word != lastReported else { return }
            lastReported = word
            let callback = onPickWord
            DispatchQueue.main.async { callback?(word) }
        }

        /// Return opens Fix a word for the selected word.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let callback = onPickWord else { return false }
            let range = textView.selectedRange()
            guard range.length > 0 || picksWord else { return false }
            let word = textView.selectionRange(forProposedRange: range, granularity: .selectByWord)
            guard word.length > 0 else { return false }
            lastReported = word
            DispatchQueue.main.async { callback(word) }
            return true
        }
    }
}

final class TranscriptNSTextView: NSTextView {
    var signature: TranscriptTextView.Signature?
    /// What a copy of the selection writes: the stored text of the same range, not the characters
    /// drawn in its place. Nil copies what is drawn.
    var storedText: String?
    /// Whether a copy is marked concealed (see nspasteboard.org), so clipboard managers skip it.
    var concealsCopy = false

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Plain text only: no rich-text flavor can carry the drawn characters out.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        storedText == nil ? super.writablePasteboardTypes : [.string]
    }

    /// Edit > Copy, a drag and a Service all write through here. The text is the stored text of
    /// the selected range, which has the same UTF-16 length as the drawn text.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storedText else { return super.writeSelection(to: pboard, types: types) }
        let stored = storedText as NSString
        let range = selectedRange()
        guard types.contains(.string), range.length > 0, NSMaxRange(range) <= stored.length else { return false }
        pboard.declareTypes(concealsCopy ? [.string, Self.concealedType] : [.string], owner: nil)
        let wrote = pboard.setString(stored.substring(with: range), forType: .string)
        if concealsCopy { pboard.setData(Data(), forType: Self.concealedType) }
        return wrote
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        frame.size
    }

    // NSTextView tracks a click or drag inside mouseDown; once it returns the mouse is up,
    // so a word pick reports exactly once.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if let delegate = delegate as? TranscriptTextView.Coordinator {
            delegate.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: self))
        }
    }

    /// The rect of `range` in this view, for anchoring a popover to a word.
    func rect(for range: NSRange) -> CGRect? {
        guard let layoutManager, let textContainer, NSMaxRange(range) <= (textStorage?.length ?? 0) else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
    }
}
