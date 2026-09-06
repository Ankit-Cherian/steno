#if os(macOS)
import AppKit
import CoreText

/// The page is an exact range of the current hypothesis. Previous hypotheses
/// are never stitched into it: only the transcription engine owns those words.
struct OverlayTranscriptViewportSnapshot: Equatable {
    let sourceText: String
    let visibleText: String
    let visibleRange: Range<Int>
    let pageRanges: [Range<Int>]
}

struct OverlayTranscriptViewport {
    private(set) var snapshot = OverlayTranscriptViewportSnapshot(
        sourceText: "", visibleText: "", visibleRange: 0..<0, pageRanges: []
    )
    private var continuityEpoch: UInt64?

    mutating func reset() {
        snapshot = .init(sourceText: "", visibleText: "", visibleRange: 0..<0, pageRanges: [])
        continuityEpoch = nil
    }

    /// Keep the current page's origin while that prefix is unchanged. A revised
    /// earlier passage or a replaced rolling window invalidates the old origin.
    /// Capacity is supplied by the same native typesetter used to draw the text.
    mutating func update(
        _ text: String,
        continuityEpoch: UInt64 = 0,
        fits: (String) -> Bool
    ) -> OverlayTranscriptViewportSnapshot {
        let characters = Array(text)
        let oldOrigin = snapshot.visibleRange.lowerBound
        let prefixIsUnchanged = self.continuityEpoch == continuityEpoch
            && (characters.count > oldOrigin || oldOrigin == 0)
            && text.prefix(oldOrigin) == snapshot.sourceText.prefix(oldOrigin)
        var boundaries = prefixIsUnchanged
            ? snapshot.pageRanges.map(\.lowerBound).filter { $0 <= oldOrigin }
            : [0]
        if boundaries.isEmpty { boundaries = [0] }
        var start = boundaries.last ?? 0

        while start < characters.count {
            let remaining = characters.count - start
            // Find a nearby upper bound before binary search. Measuring the
            // whole remaining hypothesis for every page becomes quadratic on
            // a large first snapshot, even though each page is only a few lines.
            var low = 0
            var high = min(128, remaining)
            while fits(String(characters[start..<(start + high)])) {
                low = high
                if high == remaining { break }
                high = min(remaining, high * 2)
            }
            if low == remaining { break }
            // high is a known non-fitting prefix; trailing whitespace is
            // measured by the typesetter without consuming another page.
            high -= 1
            while low < high {
                let middle = (low + high + 1) / 2
                if fits(String(characters[start..<(start + middle)])) {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            // Even a display smaller than one glyph must make progress. The
            // source range remains intact; normal display policy reserves room.
            let capacity = max(1, low)
            if start + capacity >= characters.count { break }
            let prefix = String(characters[start..<(start + capacity)])
            let advance = Self.readableBoundary(in: prefix) ?? capacity
            start += max(1, advance)
            boundaries.append(start)
        }
        let pageRanges = boundaries.enumerated().map { offset, boundary in
            boundary..<(offset + 1 < boundaries.count ? boundaries[offset + 1] : characters.count)
        }
        snapshot = .init(
            sourceText: text,
            visibleText: String(characters[start...]),
            visibleRange: start..<characters.count,
            pageRanges: text.isEmpty ? [] : pageRanges
        )
        self.continuityEpoch = continuityEpoch
        return snapshot
    }

    private static func readableBoundary(in prefix: String) -> Int? {
        var completedSentenceEnd: String.Index?
        prefix.enumerateSubstrings(in: prefix.startIndex..<prefix.endIndex,
                                   options: [.bySentences, .substringNotRequired]) { _, range, enclosing, _ in
            let sentence = prefix[range].trimmingCharacters(in: .whitespacesAndNewlines)
            // Foundation also reports an unfinished tail as a sentence. Only
            // prefer completed punctuation; abbreviation rules remain its own.
            let punctuation = sentence.reversed().drop(while: { "\"'”’)]}".contains($0) }).first
            if let punctuation, ".!?。！？".contains(punctuation) {
                completedSentenceEnd = enclosing.upperBound
            }
        }
        if let completedSentenceEnd {
            return prefix.distance(from: prefix.startIndex, to: completedSentenceEnd)
        }
        if let whitespace = prefix.lastIndex(where: \.isWhitespace) {
            return prefix.distance(from: prefix.startIndex, to: prefix.index(after: whitespace))
        }
        return nil
    }
}

@MainActor
enum OverlayTranscriptTypesetter {
    static func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(2, font.pointSize * 0.16)
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let text = typographicContent(text)
        guard text.length > 0, width > 0 else { return 0 }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
        return ceil(size.height) + 2
    }

    static func fits(_ text: NSAttributedString, in size: CGSize) -> Bool {
        let text = typographicContent(text)
        guard text.length > 0 else { return true }
        guard size.width > 0, size.height > 0, height(of: text, width: size.width) <= size.height else {
            return false
        }
        let frame = frame(for: text, in: CGRect(origin: .zero, size: size))
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.location == 0, visible.length == text.length else { return false }
        return (CTFrameGetLines(frame) as! [CTLine]).allSatisfy {
            CTLineGetTypographicBounds($0, nil, nil, nil) <= size.width + 0.5
        }
    }

    // Trailing spaces and blank lines carry no visible glyphs. Exclude them
    // from capacity measurement, while the viewport and accessibility retain
    // the original bytes; whitespace alone must not turn a page blank.
    private static func typographicContent(_ text: NSAttributedString) -> NSAttributedString {
        let range = (text.string as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        guard range.location != NSNotFound else { return NSAttributedString(string: "") }
        return text.attributedSubstring(from: NSRange(location: 0, length: NSMaxRange(range)))
    }

    static func frame(for text: NSAttributedString, in rect: CGRect) -> CTFrame {
        CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(typographicContent(text)), CFRange(location: 0, length: 0),
            CGPath(rect: rect, transform: nil), nil
        )
    }
}

/// Core Text supplies both measurement and drawing so word wrap, long tokens,
/// complex graphemes, and right-to-left passages share one layout decision.
@MainActor
final class OverlayTranscriptView: NSView {
    var font: NSFont = .systemFont(ofSize: 15)
    var textColor: NSColor = .labelColor
    var attributedStringValue = NSAttributedString(string: "") {
        didSet { needsDisplay = true }
    }
    var stringValue: String {
        get { attributedStringValue.string }
        set { attributedStringValue = OverlayTranscriptTypesetter.attributed(newValue, font: font, color: textColor) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Live transcript, provisional")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.textMatrix = .identity
        CTFrameDraw(OverlayTranscriptTypesetter.frame(for: attributedStringValue, in: bounds), context)
        context.restoreGState()
    }
}
#endif
