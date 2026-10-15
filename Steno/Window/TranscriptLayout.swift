import AppKit
import os
import StenoKit
import SwiftUI

/// Geometry of dictation text that flows in a column of its own width: the system font at a
/// size scaled by the text-size step, with no margin or line numbers beside it.
struct TranscriptMetrics: Equatable, Sendable {
    let scale: CGFloat
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let measure: CGFloat
    /// Draws no more than this many lines and ends the last with an ellipsis.
    let maxLines: Int?

    /// Dictation text that flows at `measure` points wide: `baseSize` scaled by the text-size
    /// step, on a line 1.5 times the size.
    init(flowing baseSize: CGFloat, measure: CGFloat, scale: CGFloat = 1, maxLines: Int? = nil) {
        self.scale = max(0.5, scale)
        let size = (baseSize * self.scale * 2).rounded() / 2
        // Large reading sizes need less leading than body sizes to hold together as a block.
        let leading: CGFloat = size >= 20 ? 1.36 : size >= 16 ? 1.45 : 1.5
        fontSize = size
        lineHeight = (size * leading).rounded()
        self.measure = max(80, measure.rounded(.down))
        self.maxLines = maxLines
    }
}

/// Builds the attributes shared by the text view and the line counter, so the counted
/// lines are the drawn lines.
enum TranscriptTypesetter {
    static func font(_ metrics: TranscriptMetrics) -> NSFont {
        .systemFont(ofSize: metrics.fontSize)
    }

    static func paragraphStyle(_ metrics: TranscriptMetrics) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = metrics.lineHeight
        style.maximumLineHeight = metrics.lineHeight
        style.lineBreakMode = .byWordWrapping
        // Avoids a lone word on the last line.
        style.lineBreakStrategy = .pushOut
        style.hyphenationFactor = 0
        return style
    }

    /// Centres the glyphs vertically in the fixed line height.
    static func baselineOffset(_ metrics: TranscriptMetrics) -> CGFloat {
        let font = font(metrics)
        let natural = font.ascender - font.descender
        return max(0, (metrics.lineHeight - natural) / 2 - 1)
    }

    static func attributes(_ metrics: TranscriptMetrics, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font(metrics),
            .paragraphStyle: paragraphStyle(metrics),
            .baselineOffset: baselineOffset(metrics),
            .foregroundColor: color,
            .kern: 0
        ]
    }

    /// A paragraph in a right-to-left script starts at the right and runs right to left; the
    /// others keep the left edge. The counter and the text view share this, so lines match.
    static func attributedString(_ text: String, metrics: TranscriptMetrics, color: NSColor) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: attributes(metrics, color: color))
        guard text.unicodeScalars.contains(where: { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFEFF).contains($0.value) })
        else { return string }
        let rightToLeft = NSMutableParagraphStyle()
        rightToLeft.setParagraphStyle(paragraphStyle(metrics))
        rightToLeft.alignment = .right
        rightToLeft.baseWritingDirection = .rightToLeft
        let nsText = text as NSString
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: [.byParagraphs, .substringNotRequired]) { _, _, range, _ in
            if GrovePreviewText.isRightToLeft(nsText.substring(with: range)) {
                string.addAttribute(.paragraphStyle, value: rightToLeft, range: range)
            }
        }
        return string
    }

    /// A TextKit stack configured exactly like the text view.
    static func makeContainer(_ metrics: TranscriptMetrics) -> NSTextContainer {
        let container = NSTextContainer(size: CGSize(width: metrics.measure, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        configure(container, metrics)
        return container
    }

    /// Sizes a container to the measure and applies the line limit, or lifts it. A text view
    /// that is updated in place must call this too, or "Show all" grows the frame while the
    /// text stays cut at the old limit.
    static func configure(_ container: NSTextContainer, _ metrics: TranscriptMetrics) {
        container.size = CGSize(width: metrics.measure, height: .greatestFiniteMagnitude)
        if let maxLines = metrics.maxLines {
            container.maximumNumberOfLines = maxLines
            container.lineBreakMode = .byTruncatingTail
        } else {
            container.maximumNumberOfLines = 0
            container.lineBreakMode = .byWordWrapping
        }
    }
}

/// Counts the wrapped lines of a dictation at a text size and measure, with the same TextKit
/// layout the text view draws.
@MainActor
enum TranscriptLineCounter {
    private struct Key: Hashable {
        let text: String
        let scale: CGFloat
        let fontName: String
        let fontSize: CGFloat
        let measure: CGFloat
        let lineHeight: CGFloat
        let maxLines: Int?
    }

    private static var cache: [Key: Int] = [:]

    static func lineCount(_ text: String, metrics: TranscriptMetrics) -> Int {
        guard !text.isEmpty else { return 0 }
        let key = Key(text: text, scale: metrics.scale, fontName: TranscriptTypesetter.font(metrics).fontName,
                      fontSize: metrics.fontSize, measure: metrics.measure, lineHeight: metrics.lineHeight,
                      maxLines: metrics.maxLines)
        if let cached = cache[key] { return cached }
        let count = fragments(text, metrics: metrics).count
        if cache.count > 2_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = count
        return count
    }

    /// The line fragment rects in text-column coordinates (y grows downward).
    static func fragments(_ text: String, metrics: TranscriptMetrics) -> [CGRect] {
        let storage = NSTextStorage(attributedString: TranscriptTypesetter.attributedString(text, metrics: metrics, color: .black))
        let layout = NSLayoutManager()
        let container = TranscriptTypesetter.makeContainer(metrics)
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var rects: [CGRect] = []
        let glyphs = layout.glyphRange(for: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            rects.append(rect)
        }
        return rects
    }

    /// The line (0-based) that holds `range` and the range's rect, for anchoring Fix a word.
    static func locate(_ range: NSRange, in text: String, metrics: TranscriptMetrics) -> (line: Int, rect: CGRect)? {
        let storage = NSTextStorage(attributedString: TranscriptTypesetter.attributedString(text, metrics: metrics, color: .black))
        let layout = NSLayoutManager()
        let container = TranscriptTypesetter.makeContainer(metrics)
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        guard NSMaxRange(range) <= storage.length, range.length > 0 else { return nil }
        let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        var line = 0
        var found: Int?
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, lineGlyphs, stop in
            if NSLocationInRange(glyphRange.location, lineGlyphs) {
                found = line
                stop.pointee = true
            }
            line += 1
        }
        return found.map { ($0, rect) }
    }
}

/// The time beside a dictation.
enum TranscriptMargin {
    /// 24-hour time: "10:24".
    static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// App names by bundle ID, looked up once. Lists show hundreds of rows.
@MainActor
enum AppNames {
    private static var cache: [String: String] = [:]

    /// What the window calls an app it can't name: no bundle ID was recorded, or the system
    /// reported none ("unknown").
    nonisolated static let unknownApp = "Unknown app"

    static func name(for bundleID: String) -> String {
        if let name = cache[bundleID] { return name }
        let name = isUnknown(bundleID) ? unknownApp : StenoDesign.appDisplayName(for: bundleID)
        cache[bundleID] = name
        return name
    }

    nonisolated private static func isUnknown(_ bundleID: String) -> Bool {
        bundleID.isEmpty || bundleID == "unknown"
    }

    /// Installed-app lookups ask Launch Services, which costs about a millisecond in a debug
    /// build and was repeated for every row on every redraw and for every dictation on every
    /// search keystroke. An answer is kept for a minute, so an app installed meanwhile appears soon.
    private static var installed: [String: (name: String?, at: CFAbsoluteTime)] = [:]
    private static let installedLifetime: CFAbsoluteTime = 60

    private static func installedName(for bundleID: String) -> String? {
        let now = CFAbsoluteTimeGetCurrent()
        if let known = installed[bundleID], now - known.at < installedLifetime { return known.name }
        let name = StenoDesign.installedAppName(for: bundleID)
        installed[bundleID] = (name, now)
        return name
    }

    /// The app an entry was dictated into: the installed app's name, else the name stored with the
    /// dictation, else the last part of the bundle ID.
    static func name(for entry: TranscriptEntry) -> String {
        resolve(
            installed: installedName(for: entry.appBundleID),
            stored: entry.record?.appName,
            bundleID: entry.appBundleID
        )
    }

    nonisolated static func resolve(installed: String?, stored: String?, bundleID: String) -> String {
        if let installed { return installed }
        // "Unknown" is what the system context stores when it had no app to name.
        if let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty, stored != "Unknown" { return stored }
        guard !isUnknown(bundleID) else { return unknownApp }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

extension TranscriptEntry {
    /// The words shown for the dictation: cleaned text, or the raw text when cleanup left nothing.
    var displayText: String { cleanText.isEmpty ? rawText : cleanText }

    /// Whether there are words to copy or fix. An empty no-speech entry from an older version
    /// has none.
    var hasWords: Bool { !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Words as people count them: Chinese and Japanese split into their words, not at spaces.
    var wordCount: Int { TranscriptWordCounts.count(for: self) }
}

/// Each dictation's word count, kept so a redraw or a new dictation counts only text not seen
/// before. Splitting Chinese or Japanese into words costs about ten times a whitespace split.
/// A count is reused only while the dictation's text has the same length and hash; the text
/// itself is not kept.
enum TranscriptWordCounts {
    private struct Counted: Sendable {
        var length: Int
        var hash: Int
        var words: Int
    }

    private static let memo = OSAllocatedUnfairLock<[UUID: Counted]>(initialState: [:])

    static func count(for entry: TranscriptEntry) -> Int {
        let text = entry.displayText
        let length = text.utf8.count
        let hash = text.hashValue
        if let counted = memo.withLock({ $0[entry.id] }), counted.length == length, counted.hash == hash {
            return counted.words
        }
        let words = WordCount.count(text)
        memo.withLock { memo in
            if memo.count >= 8_192 { memo.removeAll(keepingCapacity: true) }
            memo[entry.id] = Counted(length: length, hash: hash, words: words)
        }
        return words
    }
}
