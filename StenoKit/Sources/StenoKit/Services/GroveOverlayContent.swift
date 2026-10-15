#if os(macOS)
import AppKit
import QuartzCore

// MARK: - The mark

/// The mark's place in the overlay. Its geometry and motion are `BrandMark` and `BrandMarkView`.
enum GroveMark {
    /// The square the mark is fitted to in the overlay.
    static let size: CGFloat = 22
}

// MARK: - What a row shows

enum GroveGlyph: Equatable {
    /// The voice quill: working, and every way a dictation succeeded.
    case mark
    case caution
    case microphoneOff
    case noSpeech

    var symbolName: String? {
        switch self {
        case .mark: nil
        case .caution: "exclamationmark.triangle.fill"
        case .microphoneOff: "mic.slash.fill"
        case .noSpeech: "waveform.slash"
        }
    }

    var color: NSColor {
        switch self {
        case .mark: GrovePalette.mint
        case .caution, .microphoneOff: GrovePalette.warning
        case .noSpeech: GrovePalette.neutralGlyph
        }
    }
}

/// What one state of the overlay shows, in the quiet design's terms. Pure: it is derived from the
/// presentation (and the result that produced it) so every state can be checked without drawing.
struct GroveRowModel: Equatable {
    enum Lead: Equatable {
        case none
        /// The live voice bars: 11 on their own, 7 beside a timer.
        case bars(Int)
        /// The mark: looping while transcribing, drawn in once a result is there.
        case mark(done: Bool)
        case symbol(GroveGlyph)
    }

    enum PrimaryStyle: Equatable {
        /// "Inserted", "Copied": 12 pt semibold cream.
        case verb
        /// A notice: 12 pt medium cream.
        case notice
        /// "Transcribing": 12 pt medium in the subtext colour.
        case working
        /// The last-minute countdown: 12 pt medium, tabular, amber.
        case countdown
    }

    var tone: GroveTone
    var lead: Lead
    var primary: String?
    var primaryStyle: PrimaryStyle = .notice
    var time: String?
    /// The words after the verb: the reason a copy was made.
    var secondary: String?
    /// The first line of what was inserted, shown under the verb in a two-line card. Present only
    /// when the words are allowed on screen.
    var detail: String?
    /// The app a result went to; drawn with its icon.
    var appName: String?
    var keyHint: String?
    var actionTitle: String?
    var showsStop = false
    var showsDiscard = false

    var glyph: GroveGlyph? {
        switch lead {
        case .mark: .mark
        case .symbol(let glyph): glyph
        case .none, .bars: nil
        }
    }

    var showsBars: Bool { if case .bars = lead { true } else { false } }

    /// - Parameters:
    ///   - insertWords: the first line of the inserted words, when they may be shown. A successful
    ///     result then reads "Inserted into Mail" instead of naming the app with its icon.
    static func make(
        for presentation: OverlayPresentation, result: OverlayResult?,
        insertWords: String? = nil
    ) -> GroveRowModel {
        let p = presentation
        var model = GroveRowModel(tone: .forest, lead: .none)
        model.showsStop = p.showsStop
        model.showsDiscard = p.showsDiscard
        model.keyHint = p.keyHint
        model.actionTitle = p.action.map(actionTitle)

        if p.nib == .live {
            let beside = p.showsStop || p.time != nil || p.tone == .countdown
            model.lead = .bars(beside ? 7 : 11)
            model.time = p.time
            if p.tone == .countdown {
                model.primary = p.label
                model.primaryStyle = .countdown
            }
            return model
        }
        if p.restoresPrevious {
            // "Still finishing the last one" and its kin: a notice with no glyph.
            model.tone = .graphite
            model.primary = p.label
            return model
        }
        switch p.mark {
        case .some(.check):
            model.lead = .mark(done: true)
            model.primaryStyle = .verb
            if let insertWords, p.tone != .brief {
                model.primary = p.label
                model.detail = insertWords
            } else {
                model.primary = p.label.hasPrefix("Pasted") ? "Pasted" : "Inserted"
                if p.tone != .brief, case .inserted(let appName?, _)? = result { model.appName = appName }
            }
        case .some(.copy):
            model.lead = .mark(done: true)
            model.primary = "Copied"
            model.primaryStyle = .verb
            if case .copied(let reason)? = result { model.secondary = copyReason(reason) }
        case .some(.caution):
            model.tone = .graphite
            model.lead = .symbol(microphoneProblem(result) ? .microphoneOff : .caution)
            model.primary = p.label
        case .some(.microphone):
            model.tone = .graphite
            model.lead = .symbol(.noSpeech)
            model.primary = "No speech detected"
        case nil:
            if p.label.hasPrefix("Recording discarded") {
                model.tone = .graphite
                model.primary = "Discarded"
            } else {
                // Transcribing: the mark, working, and the word for it.
                model.lead = .mark(done: false)
                model.primary = "Transcribing"
                model.primaryStyle = .working
            }
        }
        return model
    }

    private static func microphoneProblem(_ result: OverlayResult?) -> Bool {
        switch result {
        case .microphoneAccessOff?, .microphoneDisconnected?: true
        default: false
        }
    }

    static func actionTitle(_ action: OverlayPresentation.Action) -> String {
        switch action {
        case .copy: "Copy"
        case .openSettings: "Open Settings"
        case .undo: "Undo"
        }
    }

    static func copyReason(_ reason: CopyReason) -> String? {
        switch reason {
        case .secureField: "Password field"
        case .fieldChanged: "Field changed"
        case .appChanged: "App changed"
        case .appNotResponding: "App didn\u{2019}t respond"
        case .accessibilityOff: "Accessibility off"
        case .noTextField: "No text field"
        case .other: nil
        }
    }
}

// MARK: - Type

/// The fonts of the quiet overlay at a text scale. The system face throughout.
struct GroveFonts {
    var textScale: CGFloat = 1

    private var size: CGFloat { (12 * textScale).rounded() }

    func primary(_ style: GroveRowModel.PrimaryStyle) -> NSFont {
        switch style {
        case .verb: .systemFont(ofSize: size, weight: .semibold)
        case .notice, .working: .systemFont(ofSize: size, weight: .medium)
        case .countdown: .monospacedDigitSystemFont(ofSize: size, weight: .medium)
        }
    }

    var time: NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .medium) }
    var secondary: NSFont { .systemFont(ofSize: size, weight: .regular) }
    var chip: NSFont { .systemFont(ofSize: size, weight: .semibold) }
    var keycap: NSFont { .systemFont(ofSize: (11 * textScale).rounded(), weight: .semibold) }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }
}

// MARK: - Layout of a row

/// Where every part of a row sits, in the row's own coordinates (origin top left). Pure
/// arithmetic: the width a state hugs, and the frames inside it.
struct GroveRowLayout: Equatable {
    enum Part: Hashable {
        case bars, mark, symbol, primary, time, secondary, appIcon, keycap, action, cancel, stop
    }

    var width: CGFloat
    var frames: [Part: CGRect]
    /// The row's own height: the one it was made for, or the two-line card's.
    var height: CGFloat = 0

    static func defaultMeasure(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// - Parameters:
    ///   - height: the row's height (34 for a capsule, 32 for the body below the notch).
    ///   - fixedWidth: set when the row spans a container (live words): content is placed in it
    ///     rather than the row hugging its content.
    ///   - minimumWidth: the least the row may be (the notch plus its shoulders).
    ///   - maximumWidth: the most; text gives way beyond it.
    @MainActor
    static func make(
        model: GroveRowModel, hasAppIcon: Bool, height: CGFloat, geometryScale g: CGFloat, textScale: CGFloat,
        fixedWidth: CGFloat? = nil, minimumWidth: CGFloat = 0, maximumWidth: CGFloat = .greatestFiniteMagnitude,
        measure: (String, NSFont) -> CGFloat = GroveRowLayout.defaultMeasure
    ) -> GroveRowLayout {
        let fonts = GroveFonts(textScale: textScale)
        let control = (22 * g).rounded()
        let gap = (model.showsBars ? 10 : 8) * g

        // The flowing items, left to right.
        var flow: [(Part, CGSize, CGFloat)] = []   // part, size, gap before
        func add(_ part: Part, _ size: CGSize, before: CGFloat? = nil) {
            flow.append((part, size, flow.isEmpty ? 0 : (before ?? gap)))
        }
        func text(_ part: Part, _ string: String, _ font: NSFont, before: CGFloat? = nil) {
            add(part, CGSize(width: measure(string, font), height: GroveFonts.lineHeight(font)), before: before)
        }
        switch model.lead {
        case .none: break
        case .bars(let count):
            add(.bars, CGSize(width: (5 * CGFloat(count) - 2.5) * g, height: 18 * g))
        case .mark:
            add(.mark, CGSize(width: GroveMark.size * g, height: GroveMark.size * g))
        case .symbol:
            add(.symbol, CGSize(width: 14 * g, height: 14 * g))
        }
        if let primary = model.primary { text(.primary, primary, fonts.primary(model.primaryStyle)) }
        if let time = model.time { text(.time, time, fonts.time) }
        if let app = model.appName {
            if hasAppIcon { add(.appIcon, CGSize(width: 15 * g, height: 15 * g)) }
            text(.secondary, app, fonts.secondary, before: hasAppIcon ? 5 * g : nil)
        } else if let secondary = model.secondary {
            text(.secondary, secondary, fonts.secondary)
        }
        if let hint = model.keyHint {
            add(.keycap, CGSize(width: measure(hint, fonts.keycap) + 12 * g, height: 20 * g))
        }
        if let action = model.actionTitle {
            add(.action, CGSize(width: measure(action, fonts.chip) + 20 * g, height: control))
        }
        var trailing: [(Part, CGSize)] = []
        if model.showsDiscard { trailing.append((.cancel, CGSize(width: control, height: control))) }
        if model.showsStop { trailing.append((.stop, CGSize(width: control, height: control))) }

        let flowWidth = flow.reduce(CGFloat(0)) { $0 + $1.1.width + $1.2 }
        let trailingGap = 8 * g
        let trailingWidth = trailing.enumerated().reduce(CGFloat(0)) { $0 + $1.element.1.width + ($1.offset > 0 ? trailingGap : 0) }

        // Insets: concentric with the capsule's radius where a control ends the row.
        let controlInset = (height - control) / 2
        let container = fixedWidth != nil
        let sideInset = (container ? 16 : 12) * g
        let barsOnly = model.lead == .bars(11) && flow.count == 1 && trailing.isEmpty
        let left = barsOnly ? 18 * g : sideInset
        let endsWithControl = !trailing.isEmpty || flow.last?.0 == .action
        let right = barsOnly ? 18 * g : (endsWithControl ? controlInset : sideInset)

        let hug = left + flowWidth + (trailing.isEmpty ? 0 : gap + trailingWidth) + right
        var width = fixedWidth ?? min(max(hug, minimumWidth), maximumWidth)
        // Text gives way when the row cannot hold its content.
        var shrink = max(0, hug - width)
        var sizes: [Part: CGSize] = [:]
        for item in flow { sizes[item.0] = item.1 }
        if shrink > 0 {
            for part in [Part.primary, .secondary] where shrink > 0 {
                guard var size = sizes[part] else { continue }
                let take = min(shrink, max(0, size.width - 40 * g))
                size.width -= take
                sizes[part] = size
                shrink -= take
            }
            width = max(width, min(width, hug))
        }
        let adjustedFlowWidth = flow.reduce(CGFloat(0)) { $0 + (sizes[$1.0]?.width ?? 0) + $1.2 }

        let leftAligned = model.showsBars && (model.time != nil || model.primaryStyle == .countdown)
        let trailingStart = width - right - trailingWidth
        // Content is centred on the row, never nearer to the trailing controls than a gap.
        let flowLimit = (trailing.isEmpty ? width - right : trailingStart - gap) - adjustedFlowWidth
        var x = leftAligned ? left : max(left, min((width - adjustedFlowWidth) / 2, flowLimit))
        var frames: [Part: CGRect] = [:]
        func centered(_ size: CGSize) -> CGFloat { ((height - size.height) / 2).rounded() }
        for item in flow {
            x += item.2
            let size = sizes[item.0] ?? item.1
            var y = centered(size)
            if item.0 == .time { y += 0.5 }
            frames[item.0] = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width
        }
        var trailingX = trailingStart
        for (index, item) in trailing.enumerated() {
            if index > 0 { trailingX += trailingGap }
            frames[item.0] = CGRect(origin: CGPoint(x: trailingX, y: centered(item.1)), size: item.1)
            trailingX += item.1.width
        }
        return GroveRowLayout(width: width, frames: frames, height: height)
    }

    // MARK: Two-line card

    private static let cardInset: CGFloat = 14
    private static let cardTop: CGFloat = 10
    private static let cardMarkGap: CGFloat = 7
    private static let cardLineGap: CGFloat = 5

    /// The height of the two-line card: 62 pt at the default size. The mark's line, the words'
    /// line, 10 pt above and below, 5 pt between.
    static func cardHeight(geometryScale g: CGFloat, textScale: CGFloat) -> CGFloat {
        let line = GroveFonts.lineHeight(GroveFonts(textScale: textScale).secondary)
        return (cardTop * g).rounded() + (GroveMark.size * g).rounded() + (cardLineGap * g).rounded()
            + line + (cardTop * g).rounded()
    }

    /// The two-line card: the mark and the verb on the first line, the first line of the inserted
    /// words under them, both flush to a 14 pt inset. Right-to-left words sit flush to the right
    /// inset instead, where they start. It is as wide as its words need (the words at most
    /// `GroveInsertMoment.widestWords`), never narrower than `minimumWidth`.
    @MainActor
    static func makeCard(
        model: GroveRowModel, geometryScale g: CGFloat, textScale: CGFloat,
        minimumWidth: CGFloat = 0, maximumWidth: CGFloat = .greatestFiniteMagnitude,
        measure: (String, NSFont) -> CGFloat = GroveRowLayout.defaultMeasure
    ) -> GroveRowLayout {
        let fonts = GroveFonts(textScale: textScale)
        let inset = (cardInset * g).rounded()
        let top = (cardTop * g).rounded()
        let side = (GroveMark.size * g).rounded()
        let markGap = (cardMarkGap * g).rounded()
        let lineGap = (cardLineGap * g).rounded()
        let verbFont = fonts.primary(.verb)
        let verbWidth = model.primary.map { measure($0, verbFont) } ?? 0
        let wordsWidth = model.detail.map { min(measure($0, fonts.secondary), GroveInsertMoment.widestWords * g) } ?? 0
        let hug = 2 * inset + max(side + markGap + verbWidth, wordsWidth)
        let width = min(max(hug, minimumWidth), maximumWidth)
        let height = cardHeight(geometryScale: g, textScale: textScale)

        var frames: [Part: CGRect] = [:]
        frames[.mark] = CGRect(x: inset, y: top, width: side, height: side)
        let verbHeight = GroveFonts.lineHeight(verbFont)
        let verbX = inset + side + markGap
        frames[.primary] = CGRect(
            x: verbX, y: top + ((side - verbHeight) / 2).rounded(),
            width: max(0, min(verbWidth, width - inset - verbX)), height: verbHeight
        )
        let wordsHeight = GroveFonts.lineHeight(fonts.secondary)
        let wordsFrameWidth = max(0, min(wordsWidth, width - 2 * inset))
        let rightToLeft = model.detail.map { LiveWordsText.isRightToLeft($0) } ?? false
        frames[.secondary] = CGRect(
            x: rightToLeft ? width - inset - wordsFrameWidth : inset, y: top + side + lineGap,
            width: wordsFrameWidth, height: wordsHeight
        )
        return GroveRowLayout(width: width, frames: frames, height: height)
    }
}

// MARK: - The insert moment

/// The rules of the insert moment, pure so they can be checked without drawing: the island never
/// goes narrower between listening and its result, and words show only where they are allowed.
enum GroveInsertMoment {
    /// The inserted words' line is never wider than this at the default text size.
    static let widestWords: CGFloat = 360

    /// The least width a state may have: the shell's own minimum, or the listening island's width
    /// when one was showing, whichever is wider. Nothing between listening and its result is
    /// narrower than listening.
    static func minimumWidth(shell: CGFloat, listening: CGFloat?) -> CGFloat {
        max(shell, listening ?? 0)
    }

    /// The words to show under a successful result, or nil when they may not be shown. Only a
    /// result the "After inserting" rule already says in words carries them, and only when the
    /// presenter was offered some; a copy, a problem and a brief confirmation never do.
    static func words(for state: OverlayState, offered: String?) -> String? {
        guard case .result(.inserted, showsWords: true) = state else { return nil }
        return DictationResultPresentation.insertedWordsLine(of: offered)
    }
}

// MARK: - Views

/// The live voice bars: 11 on their own, 7 beside a timer. 2.5 pt wide with 2.5 pt gaps, up to
/// 18 pt tall, and never shorter than 3 pt, so silence is a row of dots rather than a gap.
///
/// One level arrives at a time. Each bar shows the level from a few updates ago, the further from
/// the middle the older, so the voice ripples outward from the centre.
@MainActor
final class GroveBarsView: NSView {
    static let profile: [CGFloat] = [0.25, 0.45, 0.8, 1.0, 0.65, 0.9, 0.5, 0.3, 0.55, 0.35, 0.2]
    static let barWidth: CGFloat = 2.5
    static let gap: CGFloat = 2.5
    static let maximumHeight: CGFloat = 18
    static let minimumHeight: CGFloat = 3
    /// The level at which a bar reaches its profile height.
    static let referenceLevel: Float = 0.6
    static let delayedSamples = 6

    private var bars: [CALayer] = []
    /// The bars' colour.
    var color: NSColor = GrovePalette.mint {
        didSet {
            guard color != oldValue else { return }
            withoutActions { bars.forEach { $0.backgroundColor = color.cgColor } }
        }
    }
    private(set) var count = 11
    private var scale: CGFloat = 1
    private var history = [Float](repeating: 0, count: GroveBarsView.delayedSamples)
    private var lastReducedMotionWrite: CFTimeInterval?
    private(set) var heights: [CGFloat] = []
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            lastReducedMotionWrite = nil
            write()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        configure(count: 11, scale: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(count newCount: Int, scale newScale: CGFloat) {
        guard newCount != count || newScale != scale || bars.isEmpty else { return }
        count = newCount
        scale = newScale
        withoutActions {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<newCount).map { _ in
                let bar = CALayer()
                bar.backgroundColor = color.cgColor
                bar.cornerRadius = Self.barWidth * newScale / 2
                bar.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "frame": NSNull(), "cornerRadius": NSNull()]
                layer?.addSublayer(bar)
                return bar
            }
        }
        heights = []
        write()
    }

    /// Back to rest: a row of dots.
    func reset() {
        history = [Float](repeating: 0, count: Self.delayedSamples)
        lastReducedMotionWrite = nil
        write()
    }

    /// 0...1, already smoothed by the meter.
    func setLevel(_ level: Float) {
        let clamped = max(0, min(1, level.isFinite ? level : 0))
        if reduceMotion {
            let now = clock()
            if let last = lastReducedMotionWrite, now - last < NibLayer.reducedMotionInterval { return }
            lastReducedMotionWrite = now
        }
        history.removeLast()
        history.insert(clamped, at: 0)
        write()
    }

    private func fraction(bar index: Int) -> CGFloat {
        let weight = Self.profile[index % Self.profile.count]
        if reduceMotion { return weight }
        let distance = abs(index - count / 2)
        let sample = history[min(distance, history.count - 1)]
        return min(1, weight * CGFloat(sample / Self.referenceLevel))
    }

    private func write() {
        let new = (0..<count).map { index -> CGFloat in
            let h = max(Self.minimumHeight, Self.maximumHeight * fraction(bar: index)) * scale
            return (h * 2).rounded() / 2
        }
        let opacity: Float = reduceMotion
            ? NibLayer.reducedMotionOpacityRange.lowerBound
                + (NibLayer.reducedMotionOpacityRange.upperBound - NibLayer.reducedMotionOpacityRange.lowerBound)
                * min(1, history[0] / Self.referenceLevel)
            : 1
        guard new != heights || bars.first?.opacity != opacity else { return }
        heights = new
        layoutBars(opacity: opacity)
    }

    private func layoutBars(opacity: Float) {
        let width = Self.barWidth * scale
        let step = (Self.barWidth + Self.gap) * scale
        withoutActions {
            for (index, bar) in bars.enumerated() where index < heights.count {
                let h = heights[index]
                bar.frame = CGRect(x: CGFloat(index) * step, y: ((bounds.height - h) / 2), width: width, height: h)
                bar.opacity = opacity
            }
        }
    }

    override func layout() {
        super.layout()
        layoutBars(opacity: bars.first?.opacity ?? 1)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutBars(opacity: bars.first?.opacity ?? 1)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// A status symbol: the caution triangle, the microphone, the waveform. System symbols, tinted.
@MainActor
final class GroveSymbolView: NSImageView {
    private(set) var glyph: GroveGlyph?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyDown
        imageAlignment = .alignCenter
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func show(_ newGlyph: GroveGlyph?, scale: CGFloat) {
        glyph = newGlyph
        guard let name = newGlyph?.symbolName else {
            image = nil
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: (11 * scale).rounded(), weight: .semibold)
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        contentTintColor = newGlyph?.color
    }
}

#endif
