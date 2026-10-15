#if os(macOS)
import AppKit

/// How the recording overlay looks. `.grove`, the default and the look the app ships, is the
/// quiet forest overlay that grows out of the notch on a notched built-in display and floats as
/// a capsule everywhere else. `.quill` is the earlier indigo capsule.
public enum OverlayAppearanceStyle: Sendable, Equatable {
    case quill
    case grove
}

// MARK: - Placement

/// The notch of a built-in display, in global screen coordinates.
struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// The notch's horizontal centre, in global screen coordinates.
    var centerX: CGFloat
}

/// What the placement decision needs to know about one display. Read fresh from `NSScreen`
/// at every decision; never kept.
struct OverlayDisplayDescriptor: Equatable {
    var id: UInt32
    var frame: CGRect
    var visibleFrame: CGRect
    var isBuiltIn: Bool
    var safeAreaTop: CGFloat
    var auxiliaryTopLeft: CGRect?
    var auxiliaryTopRight: CGRect?

    /// Set only when the display reports a camera housing: a top inset and both top areas.
    var notch: NotchGeometry? {
        guard safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
              right.minX > left.maxX else { return nil }
        return NotchGeometry(width: right.minX - left.maxX, height: safeAreaTop, centerX: (left.maxX + right.minX) / 2)
    }

    /// The menu bar's height, from the gap between the frame and the visible frame.
    var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }
}

enum OverlayPlacement: Equatable {
    /// Grows out of the notch of the only display.
    case notch(display: OverlayDisplayDescriptor, notch: NotchGeometry)
    /// The top-centre capsule on a display.
    case capsule(display: OverlayDisplayDescriptor)

    var display: OverlayDisplayDescriptor {
        switch self {
        case .notch(let display, _), .capsule(let display): display
        }
    }

    var isNotch: Bool {
        if case .notch = self { return true }
        return false
    }
}

enum OverlayPlacementPolicy {
    /// Notch mode only when exactly one display is online (mirrored and Sidecar displays count
    /// as external), it is the built-in display and it reports a notch. Otherwise the capsule
    /// goes on the display under `targetPoint`, then the first display.
    static func resolve(
        displays: [OverlayDisplayDescriptor],
        onlineDisplayCount: Int,
        targetPoint: CGPoint?
    ) -> OverlayPlacement? {
        if onlineDisplayCount == 1, displays.count == 1, let only = displays.first,
           only.isBuiltIn, let notch = only.notch {
            return .notch(display: only, notch: notch)
        }
        if let targetPoint, let target = display(under: targetPoint, in: displays) {
            return .capsule(display: target)
        }
        return displays.first.map { .capsule(display: $0) }
    }

    /// The display under `point`. A display's top pixel row reports y == `frame.maxY`, which
    /// `CGRect.contains` leaves out, and in a stacked pair it is also the upper display's minY.
    /// A display whose top row the point sits on therefore wins, so the shared edge belongs to
    /// the lower display.
    private static func display(under point: CGPoint, in displays: [OverlayDisplayDescriptor]) -> OverlayDisplayDescriptor? {
        displays.first { $0.frame.minX <= point.x && point.x < $0.frame.maxX && point.y == $0.frame.maxY }
            ?? displays.first { $0.frame.contains(point) }
    }
}

// MARK: - Shapes

/// Paths for the overlay's shapes. Every builder emits the same sequence of segments whatever
/// its parameters, so a path can spring to another path of the same builder.
enum GroveShapes {
    /// A quarter circle written as one cubic, as a fraction of its radius.
    private static let k: CGFloat = 0.5523

    /// Concave radius of the shoulders where the neck widens into the body. They start at the
    /// menu bar's bottom edge, never above it.
    static let ear: CGFloat = 10
    /// Corner radius of a card that holds live words.
    static let containerRadius: CGFloat = 18

    /// The notch silhouette: a neck exactly as wide as the notch from the top of the screen
    /// down to `neckHeight` (the menu bar's bottom edge), then 10 pt concave shoulders (`ear`)
    /// into a body of `bodyWidth`. Nothing is wider than the notch above `neckHeight`, so the
    /// menu bar beside the notch stays clear.
    ///
    /// The body's top outer corner takes `topCorner` but never more than the room the shoulder
    /// leaves; a body only the shoulders wider than the neck has a square top corner.
    ///
    /// y grows downward from the top of the panel.
    static func notch(
        centerX cx: CGFloat, neckWidth n: CGFloat, neckHeight h: CGFloat,
        bodyWidth w: CGFloat, bodyBottom bottom: CGFloat,
        ear e: CGFloat = ear, topCorner requestedTop: CGFloat = 0, bottomCorner rb: CGFloat
    ) -> CGPath {
        let left = cx - n / 2, right = cx + n / 2
        let wl = cx - w / 2, wr = cx + w / 2
        let top = h + e
        let room = max(0, (w - n) / 2 - e)
        let rt = min(requestedTop, room)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: left, y: 0))
        p.addLine(to: CGPoint(x: right, y: 0))
        p.addLine(to: CGPoint(x: right, y: h))
        p.addCurve(to: CGPoint(x: right + e, y: top),
                   control1: CGPoint(x: right, y: h + k * e), control2: CGPoint(x: right + e - k * e, y: top))
        p.addLine(to: CGPoint(x: wr - rt, y: top))
        p.addCurve(to: CGPoint(x: wr, y: top + rt),
                   control1: CGPoint(x: wr - rt + k * rt, y: top), control2: CGPoint(x: wr, y: top + rt - k * rt))
        p.addLine(to: CGPoint(x: wr, y: bottom - rb))
        p.addCurve(to: CGPoint(x: wr - rb, y: bottom),
                   control1: CGPoint(x: wr, y: bottom - rb + k * rb), control2: CGPoint(x: wr - rb + k * rb, y: bottom))
        p.addLine(to: CGPoint(x: wl + rb, y: bottom))
        p.addCurve(to: CGPoint(x: wl, y: bottom - rb),
                   control1: CGPoint(x: wl + rb - k * rb, y: bottom), control2: CGPoint(x: wl, y: bottom - rb + k * rb))
        p.addLine(to: CGPoint(x: wl, y: top + rt))
        p.addCurve(to: CGPoint(x: wl + rt, y: top),
                   control1: CGPoint(x: wl, y: top + rt - k * rt), control2: CGPoint(x: wl + rt - k * rt, y: top))
        p.addLine(to: CGPoint(x: left - e, y: top))
        p.addCurve(to: CGPoint(x: left, y: h),
                   control1: CGPoint(x: left - e + k * e, y: top), control2: CGPoint(x: left, y: h + k * e))
        p.closeSubpath()
        return p
    }

    /// The notch silhouette with the body folded away: only the neck remains. The shape the
    /// notch emerges from and retracts into.
    static func closedNotch(centerX cx: CGFloat, neckWidth n: CGFloat, neckHeight h: CGFloat) -> CGPath {
        notch(centerX: cx, neckWidth: n, neckHeight: h, bodyWidth: n, bodyBottom: h, ear: 0, topCorner: 0, bottomCorner: 0)
    }

    /// The body alone (no neck), which casts the shadow in notch mode.
    static func body(
        centerX cx: CGFloat, width w: CGFloat, top: CGFloat, bottom: CGFloat,
        topCorner rt: CGFloat = 0, bottomCorner rb: CGFloat
    ) -> CGPath {
        let wl = cx - w / 2, wr = cx + w / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: wl + rt, y: top))
        p.addLine(to: CGPoint(x: wr - rt, y: top))
        p.addCurve(to: CGPoint(x: wr, y: top + rt),
                   control1: CGPoint(x: wr - rt + k * rt, y: top), control2: CGPoint(x: wr, y: top + rt - k * rt))
        p.addLine(to: CGPoint(x: wr, y: bottom - rb))
        p.addCurve(to: CGPoint(x: wr - rb, y: bottom),
                   control1: CGPoint(x: wr, y: bottom - rb + k * rb), control2: CGPoint(x: wr - rb + k * rb, y: bottom))
        p.addLine(to: CGPoint(x: wl + rb, y: bottom))
        p.addCurve(to: CGPoint(x: wl, y: bottom - rb),
                   control1: CGPoint(x: wl + rb - k * rb, y: bottom), control2: CGPoint(x: wl, y: bottom - rb + k * rb))
        p.addLine(to: CGPoint(x: wl, y: top + rt))
        p.addCurve(to: CGPoint(x: wl + rt, y: top),
                   control1: CGPoint(x: wl, y: top + rt - k * rt), control2: CGPoint(x: wl + rt - k * rt, y: top))
        p.closeSubpath()
        return p
    }

    /// A rounded rectangle: the floating capsule and the live-words container.
    static func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.height / 2, rect.width / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}

// MARK: - Layout

/// Where the overlay's pieces sit in its fixed-size panel. y grows downward from the panel's
/// top edge. Pure arithmetic, so the notch invariant and the placement can be checked without
/// drawing.
///
/// There is one container. A status row (a capsule, or the body below the neck) is all there is
/// until live words show: then the same shape grows downward to hold them, and the row stays
/// as its top line.
struct GroveLayout: Equatable {
    var placement: OverlayPlacement
    var panelSize: CGSize
    /// The top of the status row (the capsule, or the body below the shoulders).
    var rowTop: CGFloat
    var rowHeight: CGFloat
    /// The row's width at its widest state.
    var maximumRowWidth: CGFloat
    /// The container's width when it holds live words.
    var cardWidth: CGFloat
    var wordsInsetTop: CGFloat
    var wordsInsetBottom: CGFloat
    var lineHeight: CGFloat
    var maximumLines: Int
    var showsTranscript: Bool
    var containerRadius: CGFloat
    /// The height of the two-line card a successful result grows into.
    var insertCardHeight: CGFloat = 0

    var centerX: CGFloat { panelSize.width / 2 }
    var neckWidth: CGFloat? { if case .notch(_, let notch) = placement { notch.width } else { nil } }

    /// Where the neck ends and the body begins. The menu bar and the notch never reach lower.
    var neckHeight: CGFloat? {
        guard case .notch(let display, let notch) = placement else { return nil }
        return max(notch.height, display.menuBarHeight).rounded(.up)
    }

    /// The narrowest a row may be in notch mode: the notch plus its two shoulders.
    var minimumRowWidth: CGFloat {
        guard let neckWidth else { return 0 }
        return neckWidth + 2 * GroveShapes.ear
    }

    func rowWidth(for width: CGFloat) -> CGFloat { max(width, minimumRowWidth) }

    var rowBottom: CGFloat { rowTop + rowHeight }

    /// The panel's frame in global screen coordinates.
    var panelFrame: CGRect {
        let display = placement.display
        switch placement {
        case .notch(_, let notch):
            let x = notch.centerX - panelSize.width / 2
            return CGRect(
                x: (x * 2).rounded() / 2, y: display.frame.maxY - panelSize.height,
                width: panelSize.width, height: panelSize.height
            )
        case .capsule:
            let x = display.frame.midX - panelSize.width / 2
            let top = display.visibleFrame.maxY - Self.capsuleTopGap + OverlayPanelLayoutPolicy.shadowMargins.top
            return CGRect(
                x: (x * 2).rounded() / 2, y: (top - panelSize.height).rounded(),
                width: panelSize.width, height: panelSize.height
            )
        }
    }

    /// Below the menu bar, in points.
    static let capsuleTopGap: CGFloat = 12

    static func make(
        placement: OverlayPlacement,
        metrics: OverlayAccessibilityMetrics,
        showsTranscript: Bool,
        transcriptLines: Int,
        showsInsertCard: Bool = false
    ) -> GroveLayout {
        let margins = OverlayPanelLayoutPolicy.shadowMargins
        let rowHeight = placement.isNotch ? metrics.groveNotchRowHeight : metrics.capsuleHeight
        var layout = GroveLayout(
            placement: placement, panelSize: .zero, rowTop: 0, rowHeight: rowHeight,
            maximumRowWidth: 0, cardWidth: metrics.cardWidth,
            wordsInsetTop: metrics.cardInsets.top, wordsInsetBottom: metrics.cardInsets.bottom,
            lineHeight: metrics.transcriptLineHeight, maximumLines: max(1, transcriptLines),
            showsTranscript: showsTranscript, containerRadius: metrics.cardCornerRadius,
            insertCardHeight: GroveRowLayout.cardHeight(geometryScale: metrics.geometryScale, textScale: metrics.textScale)
        )
        layout.maximumRowWidth = layout.rowWidth(for: metrics.groveMaximumRowWidth)
        layout.rowTop = (layout.neckHeight.map { $0 + GroveShapes.ear }) ?? margins.top
        let content = max(layout.maximumRowWidth, showsTranscript ? metrics.cardWidth : 0)
        var height = layout.rowTop + rowHeight + margins.bottom
        if showsTranscript { height += layout.wordsHeight(lines: layout.maximumLines) }
        // The panel holds the card too, so it never has to resize while the card grows.
        if showsInsertCard { height = max(height, layout.rowTop + layout.insertCardHeight + margins.bottom) }
        var size = CGSize(width: content + margins.horizontal, height: height)
        let display = placement.display
        size.width = min(size.width, max(1, display.frame.width - 2 * OverlayPanelLayoutPolicy.screenEdgeInset))
        size.height = min(size.height, max(1, display.frame.height - 2 * OverlayPanelLayoutPolicy.screenEdgeInset))
        layout.panelSize = size
        return layout
    }

    /// The height of the live words below the row, for `lines` lines.
    func wordsHeight(lines: Int) -> CGFloat {
        wordsInsetTop + CGFloat(max(1, lines)) * lineHeight + wordsInsetBottom
    }

    /// The status row's rectangle for a state of `width`, in panel coordinates.
    func rowRect(width: CGFloat) -> CGRect {
        let w = min(rowWidth(for: width), panelSize.width)
        return CGRect(x: ((panelSize.width - w) / 2).rounded(), y: rowTop, width: w, height: rowHeight)
    }

    /// The two-line card's rectangle for a state of `width`, in panel coordinates: the row's top
    /// and centre, grown downward.
    func insertCardRect(width: CGFloat) -> CGRect {
        let w = min(rowWidth(for: width), panelSize.width)
        return CGRect(x: ((panelSize.width - w) / 2).rounded(), y: rowTop, width: w, height: insertCardHeight)
    }

    /// The bottom of the shape: the row's, the two-line card's, or the container's when it holds
    /// `lines` lines.
    private func shapeBottom(lines: Int?, card: Bool) -> CGFloat {
        if card { return rowTop + insertCardHeight }
        return lines.map { rowBottom + wordsHeight(lines: $0) } ?? rowBottom
    }

    private func cornerRadius(lines: Int?, card: Bool) -> CGFloat {
        (lines == nil && !card) ? rowHeight / 2 : containerRadius
    }

    /// The shell's outline for a row of `width`, or for the container around `lines` lines of
    /// words (then `width` is the container's).
    func shellPath(rowWidth width: CGFloat, lines: Int? = nil, card: Bool = false) -> CGPath {
        let row = rowRect(width: width)
        let bottom = shapeBottom(lines: lines, card: card)
        let radius = cornerRadius(lines: lines, card: card)
        switch placement {
        case .notch(_, let notch):
            return GroveShapes.notch(
                centerX: centerX, neckWidth: notch.width, neckHeight: neckHeight ?? notch.height,
                bodyWidth: row.width, bodyBottom: bottom, topCorner: radius, bottomCorner: radius
            )
        case .capsule:
            return GroveShapes.rounded(CGRect(x: row.minX, y: row.minY, width: row.width, height: bottom - row.minY), radius: radius)
        }
    }

    /// What casts the shadow: the body only in notch mode, so the menu bar beside the notch is
    /// never darkened.
    func shadowPath(rowWidth width: CGFloat, lines: Int? = nil, card: Bool = false) -> CGPath {
        let row = rowRect(width: width)
        let bottom = shapeBottom(lines: lines, card: card)
        let radius = cornerRadius(lines: lines, card: card)
        switch placement {
        case .notch(_, let notch):
            let room = max(0, (row.width - notch.width) / 2 - GroveShapes.ear)
            return GroveShapes.body(
                centerX: centerX, width: row.width, top: row.minY, bottom: bottom,
                topCorner: min(radius, room), bottomCorner: radius
            )
        case .capsule:
            return GroveShapes.rounded(CGRect(x: row.minX, y: row.minY, width: row.width, height: bottom - row.minY), radius: radius)
        }
    }

    /// The shell with its body folded into the notch: the start of the emergence and the end of
    /// the retraction. Nil outside notch mode.
    var closedShellPath: CGPath? {
        guard let neckWidth, let neckHeight else { return nil }
        return GroveShapes.closedNotch(centerX: centerX, neckWidth: neckWidth, neckHeight: neckHeight)
    }

    var closedShadowPath: CGPath? {
        guard let neckHeight else { return nil }
        return GroveShapes.body(centerX: centerX, width: neckWidth ?? 0, top: neckHeight, bottom: neckHeight, topCorner: 0, bottomCorner: 0)
    }

    /// The live words' rectangle, directly below the row and inside the container.
    func cardRect(lines: Int, metrics: OverlayAccessibilityMetrics) -> CGRect {
        let width = min(cardWidth, panelSize.width - OverlayPanelLayoutPolicy.shadowMargins.horizontal)
        return CGRect(x: ((panelSize.width - width) / 2).rounded(), y: rowBottom, width: width, height: wordsHeight(lines: lines))
    }
}

// MARK: - Motion

/// The grove overlay's motion, decided from the form and the Reduce Motion setting. There are
/// four movements: the bars with the voice, the shell changing width for a result, the notch
/// emerging and retracting, and the mark drawing. Under Reduce Motion each becomes a
/// short cross-fade (the quill has its own motion, in `BrandMarkView`).
enum GroveMotion: Equatable {
    /// Nothing moves: the overlay is simply there.
    case none
    /// The shell changes width: a 0.35 s spring with no bounce.
    case widthSpring
    /// The notch grows out of the screen edge: the open spring, response 0.42, damping 0.8.
    case emergence
    /// The notch folds back: 0.28 s, no bounce.
    case retract
    /// A cross-fade of this many seconds.
    case crossFade(TimeInterval)

    static let reducedMotionFade: TimeInterval = 0.14
    /// Controls arrive this long after the shape starts to move.
    static let controlsDelay: TimeInterval = 0.09

    static func widthChange(reduceMotion: Bool) -> GroveMotion {
        reduceMotion ? .crossFade(reducedMotionFade) : .widthSpring
    }

    /// A capsule appears at once, full size, with or without Reduce Motion: it answers a key
    /// press many times a day. Only a notch grows, and under Reduce Motion it fades in instead.
    static func appear(isNotch: Bool, reduceMotion: Bool) -> GroveMotion {
        guard isNotch else { return .none }
        return reduceMotion ? .crossFade(reducedMotionFade) : .emergence
    }

    static func disappear(isNotch: Bool, reduceMotion: Bool) -> GroveMotion {
        if isNotch, !reduceMotion { return .retract }
        return .crossFade(0.15)
    }
}

// MARK: - Springs

/// A spring in the terms the design uses (a perceptual duration and a bounce), converted to the
/// mass, stiffness and damping that Core Animation takes on every supported system.
struct GroveSpring: Equatable {
    var duration: TimeInterval
    var bounce: Double

    /// The notch emerging: response 0.42, damping 0.8.
    static let emergence = GroveSpring(duration: 0.42, bounce: 0.2)
    /// The shell changing width for a result.
    static let widthChange = GroveSpring(duration: 0.35, bounce: 0)
    /// The notch retracting.
    static let retract = GroveSpring(duration: 0.28, bounce: 0)

    var stiffness: CGFloat { CGFloat(pow(2 * Double.pi / duration, 2)) }
    var damping: CGFloat { CGFloat(4 * Double.pi * (1 - bounce) / duration) }

    func animation(keyPath: String, from: Any?, to: Any?) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = stiffness
        animation.damping = damping
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = true
        return animation
    }
}
#endif
