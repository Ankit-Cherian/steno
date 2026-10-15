import Foundation
import QuartzCore

/// The live quill: the Steno mark at overlay size, its barbs driven by the input level.
///
/// Built once from `QuillGeometry` (right-vane barbs every second one, left-vane barbs every
/// fourth, and the small shaft). Per update it writes only `strokeEnd` and `opacity` on
/// existing shape layers inside a transaction with implicit animations disabled; paths are
/// rebuilt only when the bounds change. It casts no shadow.
///
/// Modes:
/// - `live`: barb lengths follow `setLevel(_:)`, from the rest length in silence to full length.
/// - `working`: barbs hold at a short length; after `sweepDelay` a slow opacity sweep runs along
///   the vane, one pass every `sweepDuration`.
/// - `rest`: short, still barbs (results and idle).
///
/// With `reduceMotion` the shape stays fixed, the level is shown by opacity between
/// `reducedMotionOpacityRange` at most once per `reducedMotionInterval`, and working has no sweep.
public final class NibLayer: CALayer {
    public enum Mode: Sendable, Equatable {
        case live
        case working
        case rest
    }

    /// A small mark at the tip of the nib that says how a dictation ended.
    public enum ResultMark: Sendable, Equatable, CaseIterable {
        case check
        case copy
        case caution
        case microphone
    }

    public struct Palette: Sendable, Equatable {
        public var low: QuillColor
        public var high: QuillColor
        public var shaft: QuillColor

        public init(low: QuillColor, high: QuillColor, shaft: QuillColor) {
            self.low = low
            self.high = high
            self.shaft = shaft
        }

        /// On the working indigo of the overlay and recording plate.
        public static let onWorking = Palette(low: QuillColor(hex: 0x7BB8E8), high: QuillColor(hex: 0xC9E6FA), shaft: .white)
        /// On light paper.
        public static let light = Palette(low: QuillColor(hex: 0x2F5BE6), high: QuillColor(hex: 0x7BB8E8), shaft: QuillColor(hex: 0x142C8C))

        /// One colour throughout, for template-style use such as the menu bar.
        public static func solid(_ color: QuillColor) -> Palette {
            Palette(low: color, high: color, shaft: color)
        }
    }

    /// Default display size: 24 pt wide, with the mark's aspect ratio.
    public static let preferredSize = CGSize(width: 24, height: 27)
    /// Barb length (fraction of full) in silence and at rest.
    public static let restLength: CGFloat = 0.35
    /// Barb length while working.
    public static let workingLength: CGFloat = 0.42
    /// Fixed barb length under Reduce Motion while live.
    public static let reducedMotionLength: CGFloat = 0.62
    /// Opacity range used to show the level under Reduce Motion.
    public static let reducedMotionOpacityRange: ClosedRange<Float> = 0.45...1.0
    /// Minimum time between visible level changes under Reduce Motion (10 Hz).
    public static let reducedMotionInterval: CFTimeInterval = 0.1
    /// One pass of the working sweep.
    public static let sweepDuration: CFTimeInterval = 1.2
    /// Working holds still this long before the sweep starts.
    public static let sweepDelay: CFTimeInterval = 0.25
    /// Lowest opacity a barb reaches during the sweep.
    public static let sweepMinimumOpacity: Float = 0.35
    /// Diameter of the result mark's disc.
    public static let resultMarkDiameter: CGFloat = 15
    /// Fill behind the result mark: the working indigo it sits on.
    public static let resultMarkDisc = QuillColor(hex: 0x142C8C)

    static let barbStrokeWidth: CGFloat = 46
    static let sweepAnimationKey = "steno.nib.sweep"

    /// The barbs the nib draws, in drawing order.
    public static let barbs: [QuillGeometry.Barb] = {
        let right = QuillGeometry.barbs.filter { $0.dx > 0 }
        let left = QuillGeometry.barbs.filter { $0.dx < 0 }
        return stride(from: 0, to: right.count, by: 2).map { right[$0] }
            + stride(from: 0, to: left.count, by: 4).map { left[$0] }
    }()

    /// Per-barb weights so neighbouring barbs answer the same level slightly differently.
    /// Deterministic, between 1.0 and 1.35, so every barb reaches full length at level 1.
    static let variation: [CGFloat] = barbs.indices.map { index in
        let golden = (Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        return 1 + 0.35 * CGFloat(golden)
    }

    /// Barb length for `level` in live mode, as a fraction of full length.
    public static func liveLength(level: Float, barbIndex: Int) -> CGFloat {
        let clamped = CGFloat(max(0, min(1, level)))
        let weight = variation[barbIndex % variation.count]
        return restLength + (1 - restLength) * min(1, clamped * weight)
    }

    /// Barb opacity for `level` under Reduce Motion.
    public static func reducedMotionOpacity(level: Float, barbIndex: Int) -> Float {
        let clamped = max(0, min(1, level))
        let weight = Float(variation[barbIndex % variation.count])
        let range = reducedMotionOpacityRange
        return range.lowerBound + (range.upperBound - range.lowerBound) * min(1, clamped * weight)
    }

    public private(set) var mode: Mode = .rest
    public private(set) var level: Float = 0
    public private(set) var resultMark: ResultMark?

    public var reduceMotion: Bool = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            lastReducedMotionWrite = nil
            applyMode()
        }
    }

    public var palette: Palette = .onWorking {
        didSet {
            guard palette != oldValue else { return }
            applyColors()
        }
    }

    /// Fill behind the result mark. Match it to the surface the nib sits on so the mark
    /// reads as cut out of it (the overlay is a little lighter in dark mode).
    public var markDiscColor: QuillColor = NibLayer.resultMarkDisc {
        didSet {
            guard markDiscColor != oldValue else { return }
            applyColors()
        }
    }

    /// Time source, replaceable in tests.
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }

    /// Holds the drawing in y-down coordinates whatever the host's orientation.
    private let canvas = CALayer()
    private var barbLayers: [CAShapeLayer] = []
    private let shaftLayer = CAShapeLayer()
    private let markLayer = CALayer()
    private let markDiscLayer = CAShapeLayer()
    private let markGlyphLayer = CAShapeLayer()
    private var builtBounds: CGRect = .null
    private var builtFlip: Bool?
    private var lastReducedMotionWrite: CFTimeInterval?

    public init(palette: Palette = .onWorking, reduceMotion: Bool = false) {
        super.init()
        self.palette = palette
        self.reduceMotion = reduceMotion
        configure()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? NibLayer {
            mode = other.mode
            level = other.level
            resultMark = other.resultMark
            palette = other.palette
            reduceMotion = other.reduceMotion
            markDiscColor = other.markDiscColor
        }
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        bounds = CGRect(origin: .zero, size: Self.preferredSize)
        masksToBounds = false
        canvas.actions = Self.noActions
        addSublayer(canvas)
        barbLayers = Self.barbs.map { _ in
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineCap = .round
            layer.strokeStart = 0
            layer.actions = Self.noActions
            return layer
        }
        barbLayers.forEach(canvas.addSublayer)
        shaftLayer.actions = Self.noActions
        canvas.addSublayer(shaftLayer)

        markLayer.isHidden = true
        markLayer.actions = Self.noActions
        markDiscLayer.actions = Self.noActions
        markGlyphLayer.actions = Self.noActions
        markGlyphLayer.fillColor = nil
        markGlyphLayer.lineCap = .round
        markGlyphLayer.lineJoin = .round
        markLayer.addSublayer(markDiscLayer)
        markLayer.addSublayer(markGlyphLayer)
        canvas.addSublayer(markLayer)

        applyColors()
        rebuildPathsIfNeeded()
        applyMode()
    }

    private static var noActions: [String: CAAction] {
        let keys = ["strokeEnd", "opacity", "path", "bounds", "position", "hidden",
                    "strokeColor", "fillColor", "lineWidth", "frame"]
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, NSNull() as CAAction) })
    }

    public override func layoutSublayers() {
        super.layoutSublayers()
        rebuildPathsIfNeeded()
    }

    // MARK: - Public control

    public func setMode(_ newMode: Mode) {
        rebuildPathsIfNeeded()
        guard newMode != mode else { return }
        mode = newMode
        applyMode()
    }

    /// Sets the input level, 0...1. Only affects the live mode; cheap enough to call at 30–60 Hz.
    public func setLevel(_ newLevel: Float) {
        level = max(0, min(1, newLevel.isFinite ? newLevel : 0))
        guard mode == .live else { return }
        if reduceMotion {
            let now = clock()
            if let last = lastReducedMotionWrite, now - last < Self.reducedMotionInterval { return }
            lastReducedMotionWrite = now
        }
        writeLevel()
    }

    /// Shows a result mark at the tip of the nib, or hides it with `nil`.
    public func setResultMark(_ mark: ResultMark?) {
        rebuildPathsIfNeeded()
        resultMark = mark
        withoutActions {
            markLayer.isHidden = mark == nil
            guard let mark else { return }
            markGlyphLayer.strokeColor = Self.glyphColor(for: mark).cgColor
            markGlyphLayer.lineWidth = Self.glyphStrokeWidth(for: mark) * glyphScale
            markGlyphLayer.path = Self.glyphPath(for: mark, scale: glyphScale)
        }
    }

    // MARK: - Inspection

    public var barbCount: Int { barbLayers.count }
    public var barbStrokeEnds: [CGFloat] { barbLayers.map(\.strokeEnd) }
    public var barbOpacities: [Float] { barbLayers.map(\.opacity) }
    public var isSweeping: Bool { barbLayers.contains { $0.animation(forKey: Self.sweepAnimationKey) != nil } }
    /// Whether the drawing is flipped to suit an unflipped (y-up) host.
    var flipsForHost: Bool { canvas.isGeometryFlipped }
    /// The disc of the result mark in the drawing's coordinates (origin top left, y down).
    public var resultMarkFrame: CGRect { markLayer.frame }

    // MARK: - Drawing

    private var scale: CGFloat {
        bounds.width / Self.preferredSize.width
    }

    private var glyphScale: CGFloat { scale * 11 / 16 }

    /// Builds paths for the current bounds and host orientation. The drawing is authored
    /// y-down; the canvas flips when the host renders y-up (an unflipped layer tree).
    private func rebuildPathsIfNeeded() {
        let flip = !contentsAreFlipped()
        guard bounds != builtBounds || flip != builtFlip, bounds.width > 0, bounds.height > 0 else { return }
        builtBounds = bounds
        builtFlip = flip
        withoutActions {
            canvas.frame = bounds
            canvas.isGeometryFlipped = flip
        }
        let transform = QuillGeometry.fitting(QuillGeometry.nibViewBox, into: bounds)
        let width = Self.barbStrokeWidth * transform.a
        withoutActions {
            for (layer, barb) in zip(barbLayers, Self.barbs) {
                layer.frame = canvas.bounds
                let path = CGMutablePath()
                path.move(to: barb.start, transform: transform)
                path.addLine(to: barb.end(lengthScale: 1.25, extra: 20), transform: transform)
                layer.path = path
                layer.lineWidth = width
            }
            shaftLayer.frame = canvas.bounds
            shaftLayer.path = QuillGeometry.path(QuillGeometry.smallShaftOutline, transform: transform)

            let diameter = Self.resultMarkDiameter * scale
            let ring = 1.5 * scale
            markLayer.frame = CGRect(
                x: bounds.width - diameter + 5 * scale,
                y: bounds.height - diameter + 3 * scale,
                width: diameter, height: diameter
            )
            markDiscLayer.frame = markLayer.bounds
            markDiscLayer.path = CGPath(ellipseIn: markLayer.bounds.insetBy(dx: -ring, dy: -ring), transform: nil)
            let glyphSide = 16 * glyphScale
            markGlyphLayer.frame = CGRect(
                x: (diameter - glyphSide) / 2, y: (diameter - glyphSide) / 2,
                width: glyphSide, height: glyphSide
            )
        }
        if let resultMark { setResultMark(resultMark) }
    }

    private func applyColors() {
        withoutActions {
            for (layer, barb) in zip(barbLayers, Self.barbs) {
                layer.strokeColor = palette.low.mixed(with: palette.high, amount: Double(barb.position)).cgColor
            }
            shaftLayer.fillColor = palette.shaft.cgColor
            markDiscLayer.fillColor = markDiscColor.cgColor
        }
    }

    private func applyMode() {
        guard !barbLayers.isEmpty else { return }
        withoutActions {
            barbLayers.forEach { $0.removeAnimation(forKey: Self.sweepAnimationKey) }
            switch mode {
            case .rest:
                setBarbs(length: Self.restLength, opacity: 1)
            case .working:
                setBarbs(length: Self.workingLength, opacity: 1)
                if !reduceMotion { startSweep() }
            case .live:
                writeLevelUnthrottled()
            }
        }
    }

    private func writeLevel() {
        withoutActions { writeLevelUnthrottled() }
    }

    private func writeLevelUnthrottled() {
        for (index, layer) in barbLayers.enumerated() {
            if reduceMotion {
                layer.strokeEnd = Self.reducedMotionLength
                layer.opacity = Self.reducedMotionOpacity(level: level, barbIndex: index)
            } else {
                layer.strokeEnd = Self.liveLength(level: level, barbIndex: index)
                layer.opacity = 1
            }
        }
    }

    private func setBarbs(length: CGFloat, opacity: Float) {
        for layer in barbLayers {
            layer.strokeEnd = length
            layer.opacity = opacity
        }
    }

    private func startSweep() {
        let begin = convertTime(CACurrentMediaTime(), from: nil) + Self.sweepDelay
        let count = Double(barbLayers.count)
        for (index, layer) in barbLayers.enumerated() {
            let sweep = CAKeyframeAnimation(keyPath: "opacity")
            sweep.values = [1, Self.sweepMinimumOpacity, 1]
            sweep.keyTimes = [0, 0.5, 1]
            sweep.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            sweep.duration = Self.sweepDuration
            sweep.repeatCount = .infinity
            sweep.beginTime = begin
            sweep.timeOffset = Self.sweepDuration * Double(index) / count
            sweep.isRemovedOnCompletion = false
            layer.add(sweep, forKey: Self.sweepAnimationKey)
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: - Result glyphs (drawn in a 16-unit box, y down)

    static func glyphColor(for mark: ResultMark) -> QuillColor {
        switch mark {
        case .check: QuillColor(hex: 0x8FD1AD)
        case .copy: QuillColor(hex: 0x9FCAF2)
        case .caution: QuillColor(hex: 0xF0B37A)
        case .microphone: QuillColor(hex: 0xC3CCE4)
        }
    }

    static func glyphStrokeWidth(for mark: ResultMark) -> CGFloat {
        mark == .check ? 2.2 : 1.8
    }

    static func glyphPath(for mark: ResultMark, scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let t = CGAffineTransform(scaleX: scale, y: scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch mark {
        case .check:
            path.move(to: p(3.5, 8.4), transform: t)
            path.addLine(to: p(6.6, 11.4), transform: t)
            path.addLine(to: p(12.6, 4.8), transform: t)
        case .copy:
            path.addRoundedRect(in: CGRect(x: 5.5, y: 5.5, width: 8, height: 8), cornerWidth: 1.6, cornerHeight: 1.6, transform: t)
            path.move(to: p(10.5, 5.5), transform: t)
            path.addLine(to: p(10.5, 3.6), transform: t)
            path.addQuadCurve(to: p(8.9, 2), control: p(10.5, 2), transform: t)
            path.addLine(to: p(3.6, 2), transform: t)
            path.addQuadCurve(to: p(2, 3.6), control: p(2, 2), transform: t)
            path.addLine(to: p(2, 8.9), transform: t)
            path.addQuadCurve(to: p(3.6, 10.5), control: p(2, 10.5), transform: t)
            path.addLine(to: p(5.5, 10.5), transform: t)
        case .caution:
            path.move(to: p(8, 2.2), transform: t)
            path.addLine(to: p(14.2, 13), transform: t)
            path.addLine(to: p(1.8, 13), transform: t)
            path.closeSubpath()
            path.move(to: p(8, 6.4), transform: t)
            path.addLine(to: p(8, 9.4), transform: t)
            path.move(to: p(8, 11.2), transform: t)
            path.addLine(to: p(8, 11.21), transform: t)
        case .microphone:
            path.addRoundedRect(in: CGRect(x: 6, y: 2, width: 4, height: 8), cornerWidth: 2, cornerHeight: 2, transform: t)
            path.move(to: p(3.5, 7.5), transform: t)
            path.addArc(center: p(8, 7.5), radius: 4.5, startAngle: .pi, endAngle: 0, clockwise: true, transform: t)
            path.move(to: p(8, 12), transform: t)
            path.addLine(to: p(8, 14), transform: t)
        }
        return path
    }
}
