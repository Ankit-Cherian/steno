#if os(macOS)
import AppKit
import CoreText

/// What the live card shows of the current hypothesis. Every range is an exact range of
/// that hypothesis: earlier hypotheses are never stitched into it, because only the
/// transcription engine owns those words.
struct OverlayTranscriptViewportSnapshot: Equatable {
    let sourceText: String
    /// The fully visible lines, newest at the bottom.
    let visibleText: String
    let visibleRange: Range<Int>
    /// Hidden older text, then the visible lines. Together they partition `sourceText`.
    let pageRanges: [Range<Int>]

    static let empty = OverlayTranscriptViewportSnapshot(sourceText: "", visibleText: "", visibleRange: 0..<0, pageRanges: [])
}

/// The live card's text, laid out with Core Text at the card's measure and cut to its newest
/// lines. One line above the visible ones is kept as a "peek" that the card shows faded at
/// its top edge, so older words visibly leave rather than vanish.
struct OverlayTranscriptLayout {
    /// Only the end of a long hypothesis is typeset; the card never shows more than a few lines.
    static let typesetCharacterLimit = 1_200

    /// Attributed text from the start of the peek line (or the first visible line) to the end.
    let drawnText: NSAttributedString
    /// Lines of `drawnText`, oldest first. The first is the peek line when `hasPeekLine`.
    let lines: [CTLine]
    let hasPeekLine: Bool
    let snapshot: OverlayTranscriptViewportSnapshot
    /// The words start with a right-to-left letter, so each line is set flush right.
    var isRightToLeft = false

    var visibleLineCount: Int { lines.count - (hasPeekLine ? 1 : 0) }

    /// Lays out `source` and keeps its newest `maximumLines` lines.
    ///
    /// - Parameters:
    ///   - stableCount: characters at the start of `source` that are settled; the rest is wet ink.
    ///   - attributes: builds the attributes for a run, given whether it is wet.
    static func make(
        source: String,
        stableCount: Int,
        width: CGFloat,
        maximumLines: Int,
        attributes: (_ wet: Bool) -> [NSAttributedString.Key: Any]
    ) -> OverlayTranscriptLayout {
        let characters = Array(source)
        guard !characters.isEmpty, width > 0, maximumLines > 0 else {
            return OverlayTranscriptLayout(
                drawnText: NSAttributedString(string: ""), lines: [], hasPeekLine: false,
                snapshot: characters.isEmpty ? .empty : .init(
                    sourceText: source, visibleText: "", visibleRange: characters.count..<characters.count,
                    pageRanges: [0..<characters.count])
            )
        }

        // Typeset a bounded suffix that starts at a word boundary.
        var start = max(0, characters.count - typesetCharacterLimit)
        if start > 0, let space = characters[start...].firstIndex(where: \.isWhitespace) {
            start = min(characters.count - 1, space + 1)
        }
        // Drawn with each run of whitespace as one space, so a blank line in the words never
        // takes a row; one character for one, so every range stays a range of `source`.
        let shown = collapsedWhitespace(characters, from: start)
        let rightToLeft = LiveWordsText.isRightToLeft(String(shown[start...].prefix(400)))
        let direction = paragraphStyle(rightToLeft: rightToLeft)
        let styled: (Bool) -> [NSAttributedString.Key: Any] = { wet in
            var run = attributes(wet)
            run[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = direction
            return run
        }
        let typeset = attributedRun(shown, from: start, stableCount: stableCount, attributes: styled)
        let lineRanges = lineCharacterRanges(typeset, width: width)

        let visibleCount = min(maximumLines, lineRanges.count)
        let firstVisible = lineRanges.count - visibleCount
        let hasPeek = firstVisible > 0
        let drawnStart = start + lineRanges[hasPeek ? firstVisible - 1 : firstVisible].lowerBound
        let visibleStart = start + lineRanges[firstVisible].lowerBound

        let drawn = attributedRun(shown, from: drawnStart, stableCount: stableCount, attributes: styled)
        var lines = makeLines(drawn, width: width)
        // The drawn text re-typesets identically from a line start; guard against drift anyway.
        let expected = visibleCount + (hasPeek ? 1 : 0)
        if lines.count > expected { lines = Array(lines.suffix(expected)) }

        let snapshot = OverlayTranscriptViewportSnapshot(
            sourceText: source,
            visibleText: String(characters[visibleStart...]),
            visibleRange: visibleStart..<characters.count,
            pageRanges: visibleStart > 0 ? [0..<visibleStart, visibleStart..<characters.count] : [0..<characters.count]
        )
        return OverlayTranscriptLayout(drawnText: drawn, lines: lines, hasPeekLine: hasPeek && lines.count == expected,
                                       snapshot: snapshot, isRightToLeft: rightToLeft)
    }

    /// Whitespace that draws nothing: a run's second and later characters, and any before the
    /// first word. A zero-width space keeps the break opportunity without the width.
    static let hiddenSpace: Character = "\u{200B}"
    private static let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}"))

    /// `characters` with each run of whitespace from `start` on drawn as one space.
    private static func collapsedWhitespace(_ characters: [Character], from start: Int) -> [Character] {
        var shown = characters
        var previousIsSpace = true
        for index in start..<shown.count {
            if shown[index].isWhitespace {
                shown[index] = previousIsSpace ? hiddenSpace : " "
                previousIsSpace = true
            } else {
                previousIsSpace = false
            }
        }
        return shown
    }

    private static func paragraphStyle(rightToLeft: Bool) -> CTParagraphStyle {
        var direction: CTWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
        return withUnsafeBytes(of: &direction) { bytes in
            var setting = CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
                                                  value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
    }

    private static func attributedRun(
        _ characters: [Character],
        from start: Int,
        stableCount: Int,
        attributes: (Bool) -> [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let split = min(max(start, stableCount), characters.count)
        let result = NSMutableAttributedString(string: String(characters[start..<split]), attributes: attributes(false))
        result.append(NSAttributedString(string: String(characters[split...]), attributes: attributes(true)))
        return result
    }

    private static func makeLines(_ text: NSAttributedString, width: CGFloat) -> [CTLine] {
        lineUTF16Ranges(text, width: width).map {
            CTTypesetterCreateLine(CTTypesetterCreateWithAttributedString(text), CFRange(location: $0.location, length: $0.length))
        }
    }

    private static func lineUTF16Ranges(_ text: NSAttributedString, width: CGFloat) -> [NSRange] {
        let length = text.length
        guard length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var ranges: [NSRange] = []
        var location = 0
        while location < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, location, Double(width)))
            ranges.append(NSRange(location: location, length: min(count, length - location)))
            location += count
        }
        // Trailing whitespace and blank lines are not rows: they join the last line with words.
        while ranges.count > 1, let last = ranges.last,
              (text.string as NSString).substring(with: last).trimmingCharacters(in: blank).isEmpty {
            ranges.removeLast()
            let previous = ranges.removeLast()
            ranges.append(NSRange(location: previous.location, length: previous.length + last.length))
        }
        return ranges
    }

    /// Line ranges in characters (grapheme clusters), so they never split a cluster.
    private static func lineCharacterRanges(_ text: NSAttributedString, width: CGFloat) -> [Range<Int>] {
        let string = text.string
        var boundaries: [Int] = []
        for range in lineUTF16Ranges(text, width: width) {
            let utf16Index = string.utf16.index(string.utf16.startIndex, offsetBy: range.location)
            let index = string.rangeOfComposedCharacterSequence(at: utf16Index).lowerBound
            let offset = string.distance(from: string.startIndex, to: index)
            if boundaries.last != offset { boundaries.append(offset) }
        }
        let total = string.count
        return boundaries.enumerated().map { position, lower in
            lower..<(position + 1 < boundaries.count ? boundaries[position + 1] : total)
        }.filter { !$0.isEmpty }
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

extension NSAttributedString.Key {
    /// Marks words the speech model may still change.
    static let overlayWetInk = NSAttributedString.Key("StenoOverlayWetInk")
}

/// The live card's text: newest line at the bottom, a faded peek line at the top, wet words
/// in their own colour with a dotted underline. Display only; accessibility reads the full
/// current hypothesis as the value.
@MainActor
final class OverlayTranscriptView: NSView {
    var font: NSFont = .systemFont(ofSize: 15)
    var textColor: NSColor = .white
    /// The card fill, used for the top fade.
    var fadeColor: NSColor = .clear { didSet { needsDisplay = true } }
    var showsFade = true { didSet { needsDisplay = true } }
    var lineHeight: CGFloat = 22 { didSet { needsDisplay = true } }
    var contentInsets = NSEdgeInsets(top: 12, left: 18, bottom: 14, right: 18) { didSet { needsDisplay = true } }
    var fadeHeight: CGFloat = 20
    /// The card's corner radius; text and fade stay inside the rounded shape.
    var cornerRadius: CGFloat = 16 { didSet { needsDisplay = true } }
    var wetUnderlineColor: NSColor = .clear

    /// The fully visible text.
    private(set) var attributedStringValue = NSAttributedString(string: "")
    private var lines: [CTLine] = []
    /// Lines start at the right edge, for right-to-left words.
    private(set) var isRightToLeft = false

    var stringValue: String { attributedStringValue.string }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Live transcript, provisional")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func show(_ layout: OverlayTranscriptLayout) {
        lines = layout.lines
        isRightToLeft = layout.isRightToLeft
        let visible = layout.snapshot.visibleText
        attributedStringValue = NSAttributedString(string: visible, attributes: [.font: font])
        needsDisplay = true
    }

    func clear() {
        lines = []
        isRightToLeft = false
        attributedStringValue = NSAttributedString(string: "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.clip()
        let ascent = font.ascender
        let descent = -font.descender
        let halfLeading = (lineHeight - (ascent + descent)) / 2
        let bottom = bounds.height - contentInsets.bottom
        for (offset, line) in lines.reversed().enumerated() {
            let lineTop = bottom - CGFloat(offset + 1) * lineHeight
            guard lineTop + lineHeight > 0 else { break }
            // Without the fade (Increase Contrast) a half-shown line would be sliced, not faded.
            if !showsFade, lineTop < contentInsets.top - 0.5 { break }
            let baseline = lineTop + halfLeading + ascent
            context.saveGState()
            let measure = bounds.width - contentInsets.left - contentInsets.right
            let indent = isRightToLeft ? CGFloat(CTLineGetPenOffsetForFlush(line, 1, Double(measure))) : 0
            // Core Text draws y-up; flip around this line's baseline.
            context.translateBy(x: contentInsets.left + indent, y: baseline)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
            drawWetUnderline(line, in: context, descent: descent)
            context.restoreGState()
        }
        if showsFade, fadeHeight > 0 {
            let colors = [fadeColor.cgColor, fadeColor.withAlphaComponent(0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: fadeHeight), options: [])
            }
        }
        context.restoreGState()
    }

    /// A dotted rule under wet words, so they read as provisional without relying on colour.
    private func drawWetUnderline(_ line: CTLine, in context: CGContext, descent: CGFloat) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard attributes[NSAttributedString.Key.overlayWetInk] as? Bool == true else { continue }
            let range = CTRunGetStringRange(run)
            var start = CTLineGetOffsetForStringIndex(line, range.location, nil)
            var end = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
            if start > end { swap(&start, &end) }
            // Leave trailing spaces undecorated.
            let trailing = CTLineGetTrailingWhitespaceWidth(line)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            end = min(end, lineWidth - CGFloat(trailing))
            guard end - start > 1 else { continue }
            let y = -min(descent, 4)
            context.saveGState()
            context.setStrokeColor(wetUnderlineColor.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [1, 2])
            context.move(to: CGPoint(x: start, y: y))
            context.addLine(to: CGPoint(x: end, y: y))
            context.strokePath()
            context.restoreGState()
        }
    }
}
#endif
