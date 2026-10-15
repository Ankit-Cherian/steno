import AppKit
import StenoKit
import SwiftUI

/// What the status item shows.
enum MenuBarIconState: Equatable, Sendable {
    case idle
    /// Idle with a dot: something needs attention, such as microphone access being off.
    case attention
    case recording
    case transcribing

    static func derive(lifecycle: RecordingLifecycleState, isRecording: Bool, microphoneDenied: Bool) -> MenuBarIconState {
        switch lifecycle {
        case .recordingPressToTalk, .recordingHandsFree: return .recording
        case .transcribing: return .transcribing
        case .idle: break
        }
        if isRecording { return .recording }
        return microphoneDenied ? .attention : .idle
    }

    var accessibilityDescription: String {
        switch self {
        case .idle: "Steno"
        case .attention: "Steno, needs attention: Microphone access is off"
        case .recording: "Steno, recording"
        case .transcribing: "Steno, transcribing"
        }
    }
}

/// Template images for the status item, drawn from the voice quill's small cut in `BrandMark`, the
/// one definition of the mark.
@MainActor
enum MenuBarIcon {
    /// Levels the recording frames are drawn at, quietest first.
    nonisolated static let frameLevels: [Float] = [0.15, 0.45, 0.75, 1.0]
    /// The frame shown under Reduce Motion and before any level arrives.
    nonisolated static let staticRecordingFrame = 2
    /// The icon never changes faster than this.
    nonisolated static let minimumFrameInterval: TimeInterval = 0.1

    static let height: CGFloat = 18

    static let idle = makeIdle(withBadge: false)
    static let attention = makeIdle(withBadge: true)
    static let recordingFrames = frameLevels.map { makeTile(lengths: recordingLengths(level: $0), written: 0, filled: true) }
    static let transcribing = makeTile(lengths: nil, written: transcribingLine, filled: false)

    /// How much of the nib's line the transcribing icon shows: part way, still writing.
    nonisolated static let transcribingLine: CGFloat = 0.6

    /// The recording icon's outer barbs at a level: the quill's own listening lengths, as if the
    /// level had held for a moment.
    nonisolated static func recordingLengths(level: Float) -> [CGFloat] {
        let history = [Float](repeating: level, count: BrandMark.Motion.travel + 1)
        return BrandMark.Motion.lengths(cut: .small, history: history, phase: 0)
    }

    static func image(for state: MenuBarIconState, frame: Int) -> NSImage {
        switch state {
        case .idle: idle
        case .attention: attention
        case .recording: recordingFrames[min(max(frame, 0), recordingFrames.count - 1)]
        case .transcribing: transcribing
        }
    }

    /// The frame for a 0...1 level.
    nonisolated static func frame(for level: Float) -> Int {
        switch level {
        case ..<0.12: 0
        case ..<0.4: 1
        case ..<0.7: 2
        default: 3
        }
    }

    // MARK: Drawing

    /// Fills the quill's small cut fitted to `box`, on whole pixels at the scale being drawn, 1x
    /// or 2x.
    private static func drawQuill(in context: CGContext, box: CGRect, lengths: [CGFloat]? = nil, written: CGFloat = 0) {
        let scale = max(1, abs(context.ctm.a))
        context.addPath(BrandMark.path(in: box, cut: .small, lengths: lengths, written: written, pixelScale: scale))
        context.fillPath()
    }

    /// The badge's square in the attention icon: below the quill's tip, where its nib's line
    /// would run.
    static let badgeRect = CGRect(x: 17, y: 11, width: 6, height: 6)

    /// The quill in an 18 pt box, as a template image; with a badge at its lower right when
    /// something needs attention.
    private static func makeIdle(withBadge: Bool) -> NSImage {
        let size = CGSize(width: withBadge ? 23 : 18, height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            drawQuill(in: context, box: CGRect(x: 0, y: 0, width: 18, height: 18))
            if withBadge {
                // A clear ring keeps the badge apart from the barbs.
                context.setBlendMode(.clear)
                context.fillEllipse(in: badgeRect.insetBy(dx: -1.5, dy: -1.5))
                context.setBlendMode(.normal)
                context.fillEllipse(in: badgeRect)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The recording and transcribing indication: a filled tile with the quill cut out while
    /// recording, its outer barbs lit by the level; an outlined tile with the quill writing its
    /// line while transcribing.
    private static func makeTile(lengths: [CGFloat]?, written: CGFloat, filled: Bool) -> NSImage {
        let size = CGSize(width: 26, height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let tile = CGRect(x: 0.75, y: 0.75, width: size.width - 1.5, height: size.height - 1.5)
            let tilePath = CGPath(roundedRect: tile, cornerWidth: 5, cornerHeight: 5, transform: nil)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            if filled {
                context.addPath(tilePath)
                context.fillPath()
                context.setBlendMode(.clear)
            } else {
                context.setLineWidth(1.5)
                context.addPath(tilePath)
                context.strokePath()
            }
            let side: CGFloat = 16
            let box = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            drawQuill(in: context, box: box, lengths: lengths, written: written)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Decides when a new level frame is written: only when the frame changes, at most ten times a
/// second, and never under Reduce Motion.
struct MenuBarLevelGate: Sendable {
    private(set) var frame = MenuBarIcon.staticRecordingFrame
    private var lastWrite: TimeInterval = -.infinity

    /// Returns the frame to show, or nil when the icon should stay as it is.
    mutating func update(level: Float, now: TimeInterval, reduceMotion: Bool) -> Int? {
        guard !reduceMotion else { return nil }
        let next = MenuBarIcon.frame(for: level)
        guard next != frame, now - lastWrite >= MenuBarIcon.minimumFrameInterval else { return nil }
        frame = next
        lastWrite = now
        return next
    }

    mutating func reset() {
        frame = MenuBarIcon.staticRecordingFrame
        lastWrite = -.infinity
    }
}
