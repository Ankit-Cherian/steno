import AppKit
import StenoKit
import SwiftUI

// MARK: - Wrapping line

/// Lays its children out in a line and wraps to the next line when they do not fit.
struct GroveFlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 4
    /// Items of different heights share a row's centre, or its top for columns of text.
    var alignsTops = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (alignsTops ? 0 : (row.height - size.height) / 2)),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Ready line

/// The sentence under the Today title, with its keys as keycaps.
struct GroveReadyLine {
    enum Piece: Equatable {
        case word(String)
        case key(String)
    }

    /// "Ready. Hold [⌥ Option] in any app and speak. Press [F18] for hands-free."
    static func pieces(_ shortcuts: TodayShortcuts) -> [Piece] {
        let markup: String
        switch (shortcuts.optionHold, shortcuts.handsFreeKey) {
        case (true, .some(let key)):
            markup = "Ready. Hold [[⌥ Option]] in any app and speak. Press [[\(key)]] for hands-free."
        case (true, .none):
            markup = "Ready. Hold [[⌥ Option]] in any app and speak."
        case (false, .some(let key)):
            markup = "Ready. Press [[\(key)]] in any app to start and stop hands-free."
        case (false, .none) where shortcuts.needsInputMonitoring:
            markup = "Your shortcuts need Input Monitoring. Turn it on for Steno in System Settings › Privacy & Security."
        case (false, .none):
            markup = "Shortcuts are off. Turn one on in Settings › Recording to dictate from any app."
        }
        return parse(markup)
    }

    static func parse(_ markup: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(markup)
        while !rest.isEmpty {
            if let open = rest.range(of: "[["), let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
                pieces += words(String(rest[..<open.lowerBound]))
                pieces.append(.key(String(rest[open.upperBound..<close.lowerBound])))
                rest = rest[close.upperBound...]
            } else {
                pieces += words(String(rest))
                break
            }
        }
        return pieces
    }

    private static func words(_ text: String) -> [Piece] {
        text.split(separator: " ").map { .word(String($0)) }
    }

    /// The sentence as VoiceOver reads it: keys by their names.
    static func spoken(_ pieces: [Piece]) -> String {
        pieces.map { piece in
            switch piece {
            case .word(let word): word
            case .key(let key): Keycap.spokenName(for: key.replacingOccurrences(of: "⌥ Option", with: "⌥"))
            }
        }.joined(separator: " ")
    }
}

// MARK: - Header

/// Today's voice stage at rest: the large Dictate control. The same forest surface becomes the
/// live stage while a dictation runs. It says how to dictate from any app, and which
/// microphone is ready.
struct GroveTodayHeader: View {
    let status: TodayStatus
    let shortcuts: TodayShortcuts
    var microphoneName: String?
    var onStart: () -> Void = {}
    var onOpenMicrophoneSettings: () -> Void = {}
    var onOpenRecordingSettings: () -> Void = {}
    @Environment(\.groveTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Group {
            if status == .microphoneOff {
                stage(title: "Microphone access is off", action: ("Open System Settings", onOpenMicrophoneSettings)) {
                    Text("Turn on Steno in System Settings › Privacy & Security › Microphone.")
                        .groveFont(12).foregroundStyle(theme.subtextColor)
                }
            } else {
                // One button whatever the shortcuts: only the line under "Dictate" changes, so
                // the stage keeps its name and its tooltip with every shortcut off. Space starts
                // it only while it has the keyboard focus, as with any button: a stray Space
                // elsewhere in the window must not open the microphone.
                Button(action: onStart) {
                    stage(title: "Dictate", action: nil) {
                        if let noShortcutsLine {
                            Text(noShortcutsLine).groveFont(12).foregroundStyle(theme.subtextColor)
                        } else {
                            readyLine
                        }
                    }
                }
                .buttonStyle(GroveFocusedButtonStyle(look: GroveStageButtonStyle(isHovered: $isHovered), cornerRadius: 22))
                .help("Dictate here. The words are copied when you stop.")
                .accessibilityLabel("Dictate")
                .accessibilityHint(noShortcutsLine ?? GroveReadyLine.spoken(GroveReadyLine.pieces(shortcuts)))
                .accessibilityIdentifier("today.start")
            }
        }
    }

    /// What the stage says when no shortcut can start a dictation outside the window.
    private var noShortcutsLine: String? {
        guard !shortcuts.optionHold && shortcuts.handsFreeKey == nil else { return nil }
        return shortcuts.needsInputMonitoring
            ? "Click to dictate here. Your shortcuts need Input Monitoring. Turn it on for Steno in System Settings › Privacy & Security."
            : "Click to dictate here. To dictate in any app, turn on a shortcut in Settings › Recording."
    }

    private func stage<Detail: View>(title: String, action: (String, () -> Void)?, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(theme.cream.opacity(0.10).color).frame(width: 46, height: 46)
                if status == .microphoneOff {
                    Image(systemName: "mic.slash.fill").font(.system(size: 17)).foregroundStyle(theme.warningColor)
                } else {
                    GroveQuill(colors: .glass(theme))
                        .frame(width: 30, height: 30)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).groveFont(17, .semibold).foregroundStyle(theme.creamColor)
                detail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.grove(.cream, .small))
            } else if let microphoneName {
                HStack(spacing: 6) {
                    Circle().fill(theme.mintColor).frame(width: 6, height: 6)
                    Text("Ready · \(microphoneName)").groveFont(11).foregroundStyle(theme.subtextColor).lineLimit(1)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .forestGlass(cornerRadius: 20)
    }

    private var readyLine: some View {
        var pieces = GroveReadyLine.pieces(shortcuts).filter { $0 != .word("Ready.") }
        if case .word(let first)? = pieces.first { pieces[0] = .word(first.lowercased()) }
        return GroveReadyLineView(pieces: pieces)
    }
}

/// "Click, or hold ⌥ Option in any app", under "Dictate". With the keyboard focus on the stage it
/// begins "Press Space, or" instead, which is what starts it from there.
private struct GroveReadyLineView: View {
    let pieces: [GroveReadyLine.Piece]
    @Environment(\.groveTheme) private var theme
    @Environment(\.isFocused) private var stageHasFocus

    var body: some View {
        GroveFlowLayout(spacing: 4, lineSpacing: 3) {
            Text(stageHasFocus ? "Press Space, or" : "Click, or").groveFont(12).foregroundStyle(theme.subtextColor)
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .word(let word):
                    Text(word).groveFont(12).foregroundStyle(theme.subtextColor)
                case .key(let key):
                    Text(key)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.creamColor)
                        .padding(.horizontal, 5)
                        .frame(minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.cream.opacity(0.14).color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The voice stage as a button: it lifts a little on hover and dims while pressed.
struct GroveStageButtonStyle: ButtonStyle {
    @Binding var isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        StageBody(configuration: configuration, isHovered: $isHovered)
    }

    private struct StageBody: View {
        let configuration: ButtonStyleConfiguration
        @Binding var isHovered: Bool

        var body: some View {
            configuration.label
                .brightness(configuration.isPressed ? -0.04 : isHovered ? 0.03 : 0)
                .shadow(color: .black.opacity(isHovered ? 0.16 : 0.08), radius: isHovered ? 12 : 6, y: isHovered ? 5 : 2)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
    }
}

// MARK: - Recording plate

/// Feeds the input level straight to the bars' and the quill's layers, bypassing view state, so
/// the level at 30 Hz never invalidates a view.
@MainActor
final class GroveHaloSource {
    fileprivate weak var view: GroveBarsView?
    /// The listening quill on the stage.
    weak var quill: BrandMarkView?

    init() {}

    func send(_ level: Float) {
        view?.setLevel(level)
        quill?.setLevel(level)
    }
}

/// Voice bars that move only with the input level. At rest they are short dots.
struct GroveLevelBars: NSViewRepresentable {
    var source: GroveHaloSource?
    var color: NSColor
    var count = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> GroveBarsView { GroveBarsView(count: count) }

    func updateNSView(_ view: GroveBarsView, context: Context) {
        view.color = color
        view.reduceMotion = reduceMotion
        source?.view = view
    }
}

final class GroveBarsView: NSView {
    /// Each bar's share of the level, so the bars read as a voice rather than a meter.
    private static let weights: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.4, 0.6, 0.9, 0.5, 0.35]
    private let bars: [CALayer]
    var color: NSColor = .white { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }
    var reduceMotion = false
    private(set) var level: Float = 0

    init(count: Int) {
        bars = (0..<count).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        bars.forEach { layer?.addSublayer($0) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        applyLevel(animated: false)
    }

    /// 0...1, at the meter's rate.
    func setLevel(_ newLevel: Float) {
        level = max(0, min(1, newLevel))
        applyLevel(animated: !reduceMotion)
    }

    private func applyLevel(animated: Bool) {
        let width: CGFloat = 2.5
        let gap = bars.count > 1 ? (bounds.width - width * CGFloat(bars.count)) / CGFloat(bars.count - 1) : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.09 : 0)
        CATransaction.setDisableActions(!animated)
        for (index, bar) in bars.enumerated() {
            let weight = Self.weights[index % Self.weights.count]
            let height = max(3, bounds.height * min(1, CGFloat(level) * 1.4 * weight))
            bar.cornerRadius = width / 2
            bar.frame = CGRect(x: CGFloat(index) * (width + gap), y: (bounds.height - height) / 2, width: width, height: height)
        }
        CATransaction.commit()
    }
}

/// The words on the plate, the settled part full cream and the part that may still change in the
/// soft tail colour.
struct GroveLiveWordsText: View {
    let stable: String
    let tail: String
    /// Draws the whole sentence in full ink (the words have settled).
    var settled = false
    @Environment(\.groveTheme) private var theme

    var body: some View {
        let shown = GroveLiveWords.display(stable: stable, tail: tail)
        (Text(shown.stable).foregroundColor(theme.creamColor)
            + Text(shown.tail).foregroundColor(settled ? theme.creamColor : theme.subtextColor))
            .font(.system(size: 22))
            .tracking(-0.2)
            .lineSpacing(6)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .groveTextDirection(rightToLeft: GrovePreviewText.isRightToLeft(shown.stable + shown.tail))
    }
}

/// The live stage on forest glass: the voice quill, "Listening 0:14 · into Mail", the words as
/// they arrive, and Discard and Stop. While listening the quill's outer barbs follow the voice;
/// while transcribing its nib writes a line; on the result the line completes and holds.
struct GroveRecordingPlate: View {
    enum Mode: Equatable {
        case listening(startedAt: Date?)
        case transcribing
        case settled(GroveOutcome)
    }

    let mode: Mode
    var targetApp: String?
    var startedHere = false
    var stableWords = ""
    var tailWords = ""
    var haloSource: GroveHaloSource?
    var onStop: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onCancel: () -> Void = {}

    @Environment(\.groveTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                lead
                header
            }
            words
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minHeight: 78, alignment: .top)
        .forestGlass(cornerRadius: 20)
    }

    // MARK: Parts

    /// The status line and the buttons.
    @ViewBuilder
    private var header: some View {
        titleRow
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        buttons
    }

    /// The quill's motion for the mode.
    private var quillMotion: BrandMarkView.Motion {
        switch mode {
        case .listening: .listening
        case .transcribing: .writing
        case .settled: .written
        }
    }

    /// The quill in its own colours, listening, writing and written.
    private var lead: some View {
        GroveQuill(motion: quillMotion, colors: .glass(theme), source: haloSource)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch mode {
            case .listening(let startedAt):
                Text("Listening").groveFont(13, .semibold).foregroundStyle(theme.creamColor)
                HStack(spacing: 0) {
                    ElapsedText(startedAt: startedAt)
                    Text(destinationText)
                }
                .groveFont(12)
                .monospacedDigit()
                .foregroundStyle(theme.subtextColor)
                .lineLimit(1)
                .accessibilityHidden(true)
            case .transcribing:
                Text("Transcribing").groveFont(13, .semibold).foregroundStyle(theme.creamColor)
                Text("The microphone is off.").groveFont(12).foregroundStyle(theme.subtextColor).lineLimit(1)
            case .settled(let outcome):
                Text(outcome.title).groveFont(13, .semibold).foregroundStyle(theme.creamColor).lineLimit(1)
            }
        }
    }

    private var destinationText: String {
        if startedHere { return " · copied when you stop" }
        if let targetApp { return " · into \(targetApp)" }
        return ""
    }

    @ViewBuilder
    private var words: some View {
        let hasLive = !(stableWords.isEmpty && tailWords.isEmpty)
        switch mode {
        case .settled(let outcome):
            if !outcome.text.isEmpty {
                ZStack(alignment: .topLeading) {
                    if hasLive {
                        GroveLiveWordsText(stable: stableWords, tail: tailWords)
                            .opacity(0)
                    }
                    GroveLiveWordsText(stable: outcome.text, tail: "", settled: true)
                }
            }
        case .listening, .transcribing:
            if hasLive {
                GroveLiveWordsText(stable: stableWords, tail: tailWords)
            } else if case .listening = mode {
                Text("Your words appear here as you speak.")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.subtextColor.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch mode {
        case .listening:
            HStack(spacing: 8) {
                Button("Discard", action: onDiscard)
                    .buttonStyle(.grove(.soft, .small))
                    .keyboardShortcut(.cancelAction)
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.grove(.cream, .small))
                // While a recording runs, Space stops it from anywhere in the window: nothing
                // else here takes Space then, and stopping is never a surprise.
                .keyboardShortcut(.space, modifiers: [])
                .help(startedHere ? "Stop and copy (Space)" : "Stop and insert (Space)")
                .accessibilityLabel(startedHere ? "Stop and copy" : "Stop and insert")
            }
        case .transcribing:
            Button("Cancel", action: onCancel)
                .buttonStyle(.grove(.soft, .small))
                .keyboardShortcut(.cancelAction)
        case .settled:
            EmptyView()
        }
    }
}

// MARK: - Problem note

/// A problem or a quiet notice, in the place where the plate was: one sentence and, usually,
/// one action. It does not shake.
struct GroveProblemNote: View {
    let problem: GroveProblem
    var onAction: () -> Void = {}
    var onDismiss: () -> Void = {}
    @Environment(\.groveTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: problem.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(problem.isQuiet ? theme.ink2Color : theme.cautionColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title)
                    .groveFont(13, .semibold)
                    .foregroundStyle(theme.inkColor)
                Text(problem.message)
                    .groveFont(12)
                    .foregroundStyle(theme.ink2Color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let actionTitle = problem.actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.grove(problem.isQuiet ? .outline : .primary))
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.grove(.ghost, .small))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(problem.isQuiet ? theme.wellColor : theme.cautionWash)
        )
        .accessibilityElement(children: .contain)
    }
}
