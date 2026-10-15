#if os(macOS)
import AppKit
import QuartzCore

/// The voice quill as live layers, for the overlay and the window. Everything that moves runs on
/// the render server: a level update writes one path with a short animation, the transcribing
/// loop and the result are animations on the line's stroke end and opacity, and nothing runs
/// while the view is still or hidden. No timer, and no SwiftUI state, drives a frame.
///
/// - `listening`: the outer vane follows the voice. Each level update moves the outer barbs (or,
///   in the small cut, the outer edge) to new lengths from `BrandMark.Motion.lengths`; the inner
///   vane never moves.
/// - `writing`: the barbs settle to rest and the nib draws its line, left to right, in a calm loop.
/// - `written`: the line completes once, then everything holds.
/// - Reduce Motion: the barbs never move. Listening fades the barbs with the level, at most every
///   `NibLayer.reducedMotionInterval`; writing dims the quill; the result fades it to full.
@MainActor
public final class BrandMarkView: NSView {
    public enum Motion: Equatable, Sendable {
        case still
        case listening
        case writing
        case written
    }

    static let barbsKey = "steno.quill.barbs"
    static let loopKey = "steno.quill.loop"
    static let lineKey = "steno.quill.line"
    static let fadeKey = "steno.quill.fade"
    /// The quill's opacity while writing under Reduce Motion.
    public static let dimmedOpacity: Float = 0.6
    /// The line's stroke end when the writing loop is shown without motion.
    public static let stillWritingEnd: CGFloat = 0.6

    private let container = CALayer()
    private let barbFill = CAGradientLayer()
    private let barbMask = CALayer()
    private let innerVane = CAShapeLayer()
    private let outerVane = CAShapeLayer()
    private let shaft = CAShapeLayer()
    private let line = CAShapeLayer()

    public private(set) var motion: Motion = .still
    public private(set) var cut: BrandMark.Cut = .small
    /// Under Reduce Motion the barbs never move.
    public var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            if motion == .listening { play(.listening, animated: false) }
        }
    }
    /// The backing scale the cut is chosen for; the window's, once there is one.
    public var pixelScale: CGFloat? {
        didSet { if pixelScale != oldValue { rebuild() } }
    }
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }

    private var history = [Float](repeating: 0, count: BrandMark.Motion.travel + 1)
    private var phase: CGFloat = 0
    private var lastReducedWrite: CFTimeInterval?
    /// The outer lengths now shown, or nil at rest.
    public private(set) var lengths: [CGFloat]?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let noActions: [String: CAAction] = [
            "path": NSNull(), "strokeEnd": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(),
            "frame": NSNull(), "lineWidth": NSNull(), "hidden": NSNull(), "transform": NSNull(), "fillColor": NSNull(),
            "strokeColor": NSNull(), "colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(), "contents": NSNull(),
        ]
        for layer in [container, barbFill, barbMask, innerVane, outerVane, shaft, line] as [CALayer] { layer.actions = noActions }
        line.fillColor = nil
        line.lineCap = .round
        line.strokeEnd = 0
        barbMask.addSublayer(innerVane)
        barbMask.addSublayer(outerVane)
        barbFill.mask = barbMask
        container.addSublayer(barbFill)
        container.addSublayer(shaft)
        container.addSublayer(line)
        layer?.addSublayer(container)
        setColors(.green)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { true }

    /// The barbs' gradient, low (lower left) to high (upper right), and the shaft, nib and line.
    public func setColors(barbLow: NSColor, barbHigh: NSColor, shaft shaftColor: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barbFill.colors = [barbLow.cgColor, barbHigh.cgColor]
        shaft.fillColor = shaftColor.cgColor
        line.strokeColor = shaftColor.cgColor
        CATransaction.commit()
    }

    public func setColors(_ colors: BrandMark.Colors) {
        setColors(barbLow: Self.color(colors.barbLow), barbHigh: Self.color(colors.barbHigh), shaft: Self.color(colors.shaft))
    }

    /// The barbs' colours, for tests.
    public var barbColors: [CGColor] { (barbFill.colors as? [CGColor]) ?? [] }
    public var shaftColor: CGColor? { shaft.fillColor }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        rebuild()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    private var square: CGRect {
        let side = min(bounds.width, bounds.height)
        return CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    /// What the layers were last built for; a layout pass that changes none of it does nothing.
    private var builtFor: (bounds: CGRect, cut: BrandMark.Cut)?

    private func rebuild() {
        let square = square
        let scale = pixelScale ?? window?.backingScaleFactor ?? 2
        cut = BrandMark.Cut.forPixels(square.width * scale)
        if let builtFor, builtFor.bounds == bounds, builtFor.cut == cut { return }
        builtFor = (bounds, cut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in [container, barbFill, shaft, line] as [CALayer] { layer.frame = bounds }
        barbMask.frame = barbFill.bounds
        innerVane.frame = barbMask.bounds
        outerVane.frame = barbMask.bounds
        let vaneWidth = BrandMark.barbWidth(in: square, cut: cut)
        for vane in [innerVane, outerVane] {
            if cut.strokesBarbs {
                vane.fillColor = nil
                vane.strokeColor = NSColor.black.cgColor
                vane.lineWidth = vaneWidth
                vane.lineCap = .round
            } else {
                vane.fillColor = NSColor.black.cgColor
                vane.strokeColor = nil
            }
        }
        innerVane.path = BrandMark.innerVane(in: square, cut: cut)
        let resting = BrandMark.outerVane(in: square, cut: cut)
        outerVane.removeAnimation(forKey: Self.barbsKey)
        outerVane.path = lengths.map { BrandMark.outerVane(in: square, cut: cut, lengths: $0) } ?? resting
        shaft.path = BrandMark.shaft(in: square, cut: cut)
        line.path = BrandMark.line(in: square)
        // Never thinner than a point, so the line reads at glyph sizes.
        line.lineWidth = max(BrandMark.lineWidth(in: square, cut: cut), 1)
        // The gradient runs from the lower left to the upper right of the resting barbs.
        var barbs = resting.boundingBoxOfPath.union(innerVane.path?.boundingBoxOfPath ?? .null)
        if cut.strokesBarbs { barbs = barbs.insetBy(dx: -vaneWidth / 2, dy: -vaneWidth / 2) }
        guard bounds.width > 0, bounds.height > 0, !barbs.isNull else { return }
        let flipped = barbFill.contentsAreFlipped()
        func unit(_ p: CGPoint) -> CGPoint {
            let y = p.y / bounds.height
            return CGPoint(x: p.x / bounds.width, y: flipped ? y : 1 - y)
        }
        barbFill.startPoint = unit(CGPoint(x: barbs.minX, y: barbs.maxY))
        barbFill.endPoint = unit(CGPoint(x: barbs.maxX, y: barbs.minY))
    }

    // MARK: Motion

    /// Plays `newMotion`. A result continues the line from wherever the loop had it.
    public func play(_ newMotion: Motion, animated: Bool) {
        let previous = motion
        let lineNow = line.presentation()?.strokeEnd ?? line.strokeEnd
        let lineOpacityNow = line.presentation()?.opacity ?? line.opacity
        let containerNow = container.presentation()?.opacity ?? container.opacity
        motion = newMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        line.removeAnimation(forKey: Self.loopKey)
        line.removeAnimation(forKey: Self.lineKey)
        container.removeAnimation(forKey: Self.fadeKey)
        line.opacity = 1
        barbFill.opacity = 1
        switch newMotion {
        case .still:
            settleBarbs(animated: false)
            line.strokeEnd = 0
            container.opacity = 1
        case .listening:
            history = [Float](repeating: 0, count: history.count)
            lastReducedWrite = nil
            line.strokeEnd = 0
            container.opacity = 1
            if reduceMotion {
                settleBarbs(animated: false)
                barbFill.opacity = NibLayer.reducedMotionOpacityRange.lowerBound
            } else {
                writeLengths(animated: animated)
            }
        case .writing:
            settleBarbs(animated: animated && !reduceMotion)
            if reduceMotion {
                line.strokeEnd = 0
                container.opacity = Self.dimmedOpacity
                return
            }
            container.opacity = 1
            // A still frame (an offscreen render) shows the line part way written.
            line.strokeEnd = Self.stillWritingEnd
            if animated, previous == .still || previous == .written { fadeIn(from: previous == .still ? 0 : containerNow) }
            guard animated else { return }
            line.add(Self.writingLoop(), forKey: Self.loopKey)
        case .written:
            settleBarbs(animated: animated && !reduceMotion)
            line.strokeEnd = 1
            container.opacity = 1
            guard animated else { return }
            if reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = previous == .writing ? Self.dimmedOpacity : 0
                fade.toValue = Float(1)
                fade.duration = GroveMotion.reducedMotionFade
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fade.fillMode = .backwards
                container.add(fade, forKey: Self.fadeKey)
                return
            }
            if previous != .writing { fadeIn(from: previous == .listening ? containerNow : 0) }
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = previous == .writing && lineOpacityNow > 0.5 ? lineNow : 0
            draw.toValue = CGFloat(1)
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = previous == .writing ? lineOpacityNow : 1
            show.toValue = Float(1)
            let group = CAAnimationGroup()
            group.animations = [draw, show]
            group.duration = BrandMark.Motion.resultDuration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .backwards
            line.add(group, forKey: Self.lineKey)
        }
    }

    private func fadeIn(from opacity: Float) {
        guard opacity < 1 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = Float(1)
        fade.duration = BrandMark.Motion.resultDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        container.add(fade, forKey: Self.fadeKey)
    }

    /// The writing loop: the line draws on, holds, then fades so the next pass starts clean.
    static func writingLoop() -> CAAnimation {
        let times = BrandMark.Motion.writeKeyTimes.map { NSNumber(value: $0) }
        let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
        draw.values = [CGFloat(0), CGFloat(1), CGFloat(1), CGFloat(1)]
        draw.keyTimes = times
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        draw.timingFunctions = [ease, CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .linear)]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [Float(1), Float(1), Float(1), Float(0)]
        fade.keyTimes = times
        fade.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .linear), ease]
        let group = CAAnimationGroup()
        group.animations = [draw, fade]
        group.duration = BrandMark.Motion.writeDuration
        group.repeatCount = .infinity
        return group
    }

    /// Stops everything and forgets what was showing: the quill is not on screen.
    public func stop() {
        motion = .still
        for layer in [line, outerVane, container] as [CALayer] { layer.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lengths = nil
        outerVane.path = BrandMark.outerVane(in: square, cut: cut)
        line.strokeEnd = 0
        container.opacity = 1
        barbFill.opacity = 1
        CATransaction.commit()
    }

    /// 0...1, already smoothed by the meter. Only listening uses it.
    public func setLevel(_ level: Float) {
        guard motion == .listening else { return }
        let clamped = max(0, min(1, level.isFinite ? level : 0))
        if reduceMotion {
            let now = clock()
            if let last = lastReducedWrite, now - last < NibLayer.reducedMotionInterval { return }
            lastReducedWrite = now
            let range = NibLayer.reducedMotionOpacityRange
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            barbFill.opacity = range.lowerBound + (range.upperBound - range.lowerBound)
                * min(1, clamped / BrandMark.Motion.referenceLevel)
            CATransaction.commit()
            return
        }
        history.removeLast()
        history.insert(clamped, at: 0)
        phase += BrandMark.Motion.phaseStep
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        writeLengths(animated: true)
        CATransaction.commit()
    }

    private func writeLengths(animated: Bool) {
        let next = BrandMark.Motion.lengths(cut: cut, history: history, phase: phase)
        lengths = next
        setOuter(BrandMark.outerVane(in: square, cut: cut, lengths: next), duration: animated ? BrandMark.Motion.barbEase : 0)
    }

    private func settleBarbs(animated: Bool) {
        guard lengths != nil || outerVane.animation(forKey: Self.barbsKey) != nil else { return }
        lengths = nil
        setOuter(BrandMark.outerVane(in: square, cut: cut), duration: animated ? BrandMark.Motion.settleDuration : 0)
    }

    /// Moves the outer vane to `path`, from wherever it shows now.
    private func setOuter(_ path: CGPath, duration: Double) {
        let from = outerVane.presentation()?.path ?? outerVane.path
        outerVane.removeAnimation(forKey: Self.barbsKey)
        outerVane.path = path
        guard duration > 0, let from else { return }
        let move = CABasicAnimation(keyPath: "path")
        move.fromValue = from
        move.toValue = path
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        outerVane.add(move, forKey: Self.barbsKey)
    }

    // MARK: Evidence

    public var isAnimating: Bool {
        line.animation(forKey: Self.loopKey) != nil || line.animation(forKey: Self.lineKey) != nil
            || container.animation(forKey: Self.fadeKey) != nil || outerVane.animation(forKey: Self.barbsKey) != nil
    }

    /// How much of the line is written, 0 to 1.
    public var lineEnd: CGFloat { line.strokeEnd }
    public var quillOpacity: Float { container.opacity }
    public var barbsOpacity: Float { barbFill.opacity }
    /// The outer vane's path now, for tests.
    public var outerVanePath: CGPath? { outerVane.path }
    /// The animation running on the line under `key`, for tests.
    public func lineAnimation(forKey key: String) -> CAAnimation? { line.animation(forKey: key) }
}
#endif
