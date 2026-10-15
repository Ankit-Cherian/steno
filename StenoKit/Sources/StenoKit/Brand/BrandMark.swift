import CoreGraphics

/// Steno's mark, the voice quill: the one definition every surface draws from. The window's
/// SwiftUI views, the overlay, the menu bar icon, the runtime Dock icon and the icon generator
/// (`StenoIconRenderer`) all ask this type for paths and colours; none of them knows the shape.
///
/// The quill is a curved rachis that ends in a cut nib, with dense barbs on both sides. The barbs
/// of the outer vane (lower right) are the voice: their lengths trace a spoken rhythm at rest and
/// follow the live level while Steno listens. The nib writes a line along the baseline while
/// Steno transcribes and when a result lands. The nib is cut by one slit from the point into the
/// calamus, with no round hole, so it reads as a cut quill rather than a fountain pen.
///
/// Geometry is written on a 100-unit square (y down) and fitted to the largest square centred in
/// the caller's rect. There are two cuts: `full`, 36 barb slots a side, from 48 pixels up; and
/// `small`, a filled vane with the voice on its outer edge over a heavier shaft, for the 16 and 32
/// pixel icons, the 18 pt menu bar template and the overlay's 22 pt glyph.
public enum BrandMark {
    /// The mark's name.
    public static let name = "Voice quill"

    // MARK: Cuts

    public enum Cut: Sendable, Equatable {
        /// 36 barb slots a side, each a stroke with round caps, two left out as the feather's
        /// splits.
        case full
        /// A filled vane whose outer edge carries the voice in 12 segments, over a heavier shaft
        /// with the cut nib. For drawn sizes under 48 pixels.
        case small

        /// Barb slots per side, from the base of the vane to the tip; for the small cut, the
        /// segments of the outer edge.
        var perSide: Int { self == .full ? 36 : 12 }
        /// Slots left empty, as the feather's natural splits.
        var gaps: Set<Int> { self == .full ? [13, 25] : [] }
        /// Barb stroke width on the 100-unit square (the full cut only).
        var barbWidth: CGFloat { 1.5 }
        /// How far a barb, or the small cut's edge, leans toward the tip, as a share of its reach.
        var lean: CGFloat { self == .full ? 0.55 : 0.5 }
        /// The rachis width the shaft outline is built from.
        var rachisWidth: CGFloat { self == .full ? 2.6 : 4.6 }
        /// The written line's stroke width.
        var lineWidth: CGFloat { self == .full ? 1.8 : 4.4 }
        /// The slit's width.
        var slitWidth: CGFloat { self == .full ? 0.42 : 1.8 }
        /// How far a one-colour small cut's gap along the shaft reaches past the shaft's edges.
        var rachisGap: CGFloat { 0.4 }

        /// True when the barbs are strokes (the full cut), false when the vane is a fill.
        public var strokesBarbs: Bool { self == .full }

        /// The cut for a mark drawn `pixels` wide: the full mark from 48 pixels up.
        public static func forPixels(_ pixels: CGFloat) -> Cut { pixels >= 48 ? .full : .small }

        /// How many lengths the outer vane takes, base to tip.
        public var barbCount: Int { perSide - gaps.count }
    }

    // MARK: The rachis

    static let nib = CGPoint(x: 10, y: 94)
    static let bend = CGPoint(x: 30, y: 30)
    static let tip = CGPoint(x: 92, y: 6)
    /// Where the vane starts along the rachis.
    static let vaneStart: CGFloat = 0.24
    /// Vane reach at its widest: the outer (voice) side and the inner side.
    static let outer: CGFloat = 18
    static let inner: CGFloat = 8
    /// Where along the vane it is widest.
    static let peak: CGFloat = 0.42
    /// How strongly the resting voice shapes the outer edge.
    static let voice: CGFloat = 0.22
    /// The resting voice: one scallop per level along the outer vane.
    static let levels: [CGFloat] = [0.5, 0.9, 0.62, 1.0, 0.72, 0.95, 0.55, 0.85, 0.66, 0.4]
    /// The share of the rachis that is the cut nib.
    static let nibCut: CGFloat = 0.13
    /// The written line runs from the nib to here.
    static let lineEndX: CGFloat = 82

    static func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * nib.x + 2 * u * t * bend.x + t * t * tip.x,
                       y: u * u * nib.y + 2 * u * t * bend.y + t * t * tip.y)
    }

    static func tangent(_ t: CGFloat) -> CGPoint {
        let d = CGPoint(x: 2 * (1 - t) * (bend.x - nib.x) + 2 * t * (tip.x - bend.x),
                        y: 2 * (1 - t) * (bend.y - nib.y) + 2 * t * (tip.y - bend.y))
        let l = max(0.0001, (d.x * d.x + d.y * d.y).squareRoot())
        return CGPoint(x: d.x / l, y: d.y / l)
    }

    /// The outer side: lower right of a shaft rising to the upper right.
    static func outward(_ t: CGFloat) -> CGPoint {
        let d = tangent(t)
        return CGPoint(x: -d.y, y: d.x)
    }

    /// The vane's reach along its length `u` (0 at the base, 1 at the tip): rounded at the base,
    /// widest at `peak`, a long taper to the point.
    static func envelope(_ u: CGFloat) -> CGFloat {
        if u < peak { return sin(u / peak * .pi / 2) * 0.85 + 0.15 * (u / peak) }
        let x = (u - peak) / (1 - peak)
        return pow(cos(x * .pi / 2), 0.9)
    }

    /// The resting voice at `u`: one rounded scallop per level.
    static func voiceAt(_ u: CGFloat) -> CGFloat {
        let n = levels.count
        let f = u * CGFloat(n)
        let i = min(n - 1, Int(f))
        return levels[i] * (0.75 + 0.25 * sin((f - CGFloat(i)) * .pi))
    }

    /// The resting length of an outer barb at `u`, as a share of the envelope.
    static func restingShare(_ u: CGFloat) -> CGFloat { (1 - voice) + voice * voiceAt(u) * 1.25 }

    // MARK: Fitting

    /// The 100-unit square fitted to the largest square centred in `rect`.
    static func fit(_ rect: CGRect) -> CGAffineTransform {
        let k = min(rect.width, rect.height) / 100
        return CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: rect.midX - 50 * k, ty: rect.midY - 50 * k)
    }

    /// The figure's bounds on the 100-unit square, resting, without the written line.
    public static var bounds: CGRect { path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).boundingBoxOfPath }

    // MARK: Barbs

    /// The barb slots drawn in a cut: their position `u` along the vane, base to tip.
    static func slots(_ cut: Cut) -> [CGFloat] {
        (0..<cut.perSide).filter { !cut.gaps.contains($0) }.map { (CGFloat($0) + 0.5) / CGFloat(cut.perSide) }
    }

    /// The outer vane in `rect`. For the full cut, the barbs' centrelines, to stroke at
    /// `barbWidth(in:cut:)` with round caps; for the small cut, the vane's outline, to fill. Either
    /// way the path has the same elements whatever the lengths, so it can be animated.
    ///
    /// - Parameter lengths: the outer lengths as a share of the envelope, base to tip
    ///   (`cut.barbCount` values). Nil is the resting voice.
    public static func outerVane(in rect: CGRect, cut: Cut, lengths: [CGFloat]? = nil) -> CGPath {
        cut.strokesBarbs ? barbLines(in: rect, cut: cut, outerSide: true, lengths: lengths)
            : vaneOutline(in: rect, cut: cut, outerSide: true, lengths: lengths)
    }

    /// The inner vane in `rect`, as `outerVane` draws it. It never moves.
    public static func innerVane(in rect: CGRect, cut: Cut) -> CGPath {
        cut.strokesBarbs ? barbLines(in: rect, cut: cut, outerSide: false, lengths: nil)
            : vaneOutline(in: rect, cut: cut, outerSide: false, lengths: nil)
    }

    public static func barbWidth(in rect: CGRect, cut: Cut) -> CGFloat { cut.barbWidth * fit(rect).a }

    /// Both vanes as one filled outline.
    public static func barbs(in rect: CGRect, cut: Cut, lengths: [CGFloat]? = nil) -> CGPath {
        let both = CGMutablePath()
        both.addPath(innerVane(in: rect, cut: cut))
        both.addPath(outerVane(in: rect, cut: cut, lengths: lengths))
        guard cut.strokesBarbs else { return both.normalized() }
        return both.copy(strokingWithWidth: barbWidth(in: rect, cut: cut), lineCap: .round, lineJoin: .round, miterLimit: 10)
            .normalized()
    }

    /// A place along the vane, worked out once per cut so a live update only scales lengths: the
    /// rachis point, the direction a barb runs on each side (leaning toward the tip), the envelope
    /// and the resting voice there.
    struct Station {
        var u: CGFloat
        var center: CGPoint
        var outerRay: CGPoint
        var innerRay: CGPoint
        var envelope: CGFloat
        var resting: CGFloat

        init(u: CGFloat, lean: CGFloat) {
            let t = BrandMark.vaneStart + (1 - BrandMark.vaneStart) * u
            let d = BrandMark.tangent(t), o = BrandMark.outward(t)
            self.u = u
            center = BrandMark.point(t)
            outerRay = CGPoint(x: o.x + d.x * lean, y: o.y + d.y * lean)
            innerRay = CGPoint(x: -o.x + d.x * lean, y: -o.y + d.y * lean)
            envelope = BrandMark.envelope(u)
            resting = BrandMark.restingShare(u)
        }

        func end(outerSide: Bool, share: CGFloat) -> CGPoint {
            let w = (outerSide ? BrandMark.outer * share : BrandMark.inner) * envelope
            let ray = outerSide ? outerRay : innerRay
            return CGPoint(x: center.x + ray.x * w, y: center.y + ray.y * w)
        }
    }

    /// The full cut's barb slots, and the small cut's 49 places along its edge.
    static let fullStations = slots(.full).map { Station(u: $0, lean: Cut.full.lean) }
    static let smallSteps = 48
    static let smallStations = (0...smallSteps).map { Station(u: CGFloat($0) / CGFloat(smallSteps), lean: Cut.small.lean) }

    private static func barbLines(in rect: CGRect, cut: Cut, outerSide: Bool, lengths: [CGFloat]?) -> CGPath {
        let path = CGMutablePath()
        let transform = fit(rect)
        for (n, station) in fullStations.enumerated() {
            let share = lengths.flatMap { $0.isEmpty ? nil : $0[n % $0.count] } ?? station.resting
            path.move(to: station.center, transform: transform)
            path.addLine(to: station.end(outerSide: outerSide, share: share), transform: transform)
        }
        return path
    }

    /// The small cut's vane on one side: from the rachis at the base, along the edge to the tip,
    /// and back down the rachis.
    private static func vaneOutline(in rect: CGRect, cut: Cut, outerSide: Bool, lengths: [CGFloat]?) -> CGPath {
        let transform = fit(rect)
        let count = cut.barbCount
        func share(_ station: Station) -> CGFloat {
            guard let lengths, !lengths.isEmpty else { return station.resting }
            let f = max(0, min(CGFloat(count - 1), station.u * CGFloat(count) - 0.5))
            let i = Int(f), j = min(count - 1, i + 1), w = f - CGFloat(i)
            return lengths[i % lengths.count] * (1 - w) + lengths[j % lengths.count] * w
        }
        let path = CGMutablePath()
        path.move(to: smallStations[0].center, transform: transform)
        for station in smallStations {
            path.addLine(to: station.end(outerSide: outerSide, share: outerSide ? share(station) : 1), transform: transform)
        }
        for station in smallStations.reversed() {
            path.addLine(to: station.center, transform: transform)
        }
        path.closeSubpath()
        return path
    }

    // MARK: Shaft and nib

    /// The shaft as one filled outline: the cut nib with its slit, a calamus a little thicker than
    /// the rachis, and the rachis thinning to the tip.
    public static func shaft(in rect: CGRect, cut: Cut) -> CGPath {
        let transform = fit(rect)
        let width = cut.rachisWidth
        let calamus = width * 0.95
        func half(_ t: CGFloat, left: Bool) -> CGFloat {
            if t < nibCut {
                let x = t / nibCut
                return calamus * (left ? pow(x, 0.55) : pow(x, 1.7))
            }
            if t < vaneStart { return calamus }
            let x = (t - vaneStart) / (1 - vaneStart)
            return calamus * (1 - x) * 0.55 + width * 0.18
        }
        let steps = cut == .full ? 120 : 60
        var leftEdge: [CGPoint] = [], rightEdge: [CGPoint] = []
        for k in 0...steps {
            let t = CGFloat(k) / CGFloat(steps)
            let p = point(t), d = tangent(t)
            let o = CGPoint(x: -d.y, y: d.x)
            leftEdge.append(CGPoint(x: p.x - o.x * half(t, left: true), y: p.y - o.y * half(t, left: true)))
            rightEdge.append(CGPoint(x: p.x + o.x * half(t, left: false), y: p.y + o.y * half(t, left: false)))
        }
        let outline = CGMutablePath()
        outline.move(to: nib, transform: transform)
        for e in leftEdge.dropFirst() { outline.addLine(to: e, transform: transform) }
        for e in rightEdge.reversed() { outline.addLine(to: e, transform: transform) }
        outline.closeSubpath()
        return outline.subtracting(slit(in: rect, cut: cut))
    }

    /// The slit: one cut from the point up into the calamus.
    static func slit(in rect: CGRect, cut: Cut) -> CGPath {
        let transform = fit(rect)
        let line = CGMutablePath()
        line.move(to: point(0.012), transform: transform)
        line.addLine(to: point(nibCut * 0.95), transform: transform)
        return line.copy(strokingWithWidth: cut.slitWidth * transform.a, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    }

    // MARK: The written line

    /// The line the nib writes, as a centreline from the nib to the right: stroke it at
    /// `lineWidth(in:cut:)` with round caps and draw it by stroke end.
    public static func line(in rect: CGRect) -> CGPath {
        let transform = fit(rect)
        let path = CGMutablePath()
        path.move(to: nib, transform: transform)
        path.addLine(to: CGPoint(x: lineEndX, y: nib.y), transform: transform)
        return path
    }

    public static func lineWidth(in rect: CGRect, cut: Cut) -> CGFloat { cut.lineWidth * fit(rect).a }

    /// `written` of the line (0 to 1) as a filled outline.
    public static func writtenLine(in rect: CGRect, cut: Cut, written: CGFloat) -> CGPath {
        let share = max(0, min(1, written))
        guard share > 0 else { return CGMutablePath() }
        let transform = fit(rect)
        let path = CGMutablePath()
        path.move(to: nib, transform: transform)
        path.addLine(to: CGPoint(x: nib.x + (lineEndX - nib.x) * share, y: nib.y), transform: transform)
        return path.copy(strokingWithWidth: lineWidth(in: rect, cut: cut), lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    // MARK: The whole mark

    /// The mark fitted to `rect` as one fill, for a template image or a single-colour glyph.
    ///
    /// - Parameters:
    ///   - cut: the full mark, or the small cut; nil picks by the drawn size at `pixelScale`.
    ///   - lengths: the outer barbs' lengths, as `outerVane(in:cut:lengths:)` takes them.
    ///   - written: how much of the nib's line shows, 0 to 1.
    ///   - pixelScale: when given, the fitted square lands on whole device pixels at this backing
    ///     scale, so the shaft and the line keep crisp edges in a small template.
    public static func path(in rect: CGRect, cut: Cut? = nil, lengths: [CGFloat]? = nil, written: CGFloat = 0,
                            pixelScale: CGFloat? = nil) -> CGPath {
        var square = rect
        if let s = pixelScale, s > 0 {
            let side = (min(rect.width, rect.height) * s).rounded() / s
            square = CGRect(x: ((rect.midX - side / 2) * s).rounded() / s, y: ((rect.midY - side / 2) * s).rounded() / s,
                            width: side, height: side)
        }
        let chosen = cut ?? Cut.forPixels(min(square.width, square.height) * (pixelScale ?? 2))
        let vane = barbs(in: square, cut: chosen, lengths: lengths)
        let stem = shaft(in: square, cut: chosen)
        let line = writtenLine(in: square, cut: chosen, written: written)
        guard !chosen.strokesBarbs else { return vane.union(stem).union(line) }
        // In one colour the small cut's shaft would vanish into its filled vane, so inside the
        // vane the shaft is a gap, and below it the calamus and nib are solid.
        let gap = stem.copy(strokingWithWidth: 2 * chosen.rachisGap * fit(square).a, lineCap: .round, lineJoin: .round,
                            miterLimit: 10).union(stem)
        return vane.subtracting(gap).union(stem.subtracting(vane)).union(line)
    }

    // MARK: Colours

    /// The mark's colour roles: the tile, the barbs' gradient (from the lower left
    /// to the upper right of their bounds) and the shaft, nib and line.
    public struct Colors: Equatable, Sendable {
        public var tileTop: UInt32
        public var tileBottom: UInt32
        public var barbLow: UInt32
        public var barbHigh: UInt32
        public var shaft: UInt32

        public static let green = Colors(tileTop: 0x2E6A4B, tileBottom: 0x133222, barbLow: 0xCDE4D5, barbHigh: 0xF7FBF8, shaft: 0x9FDDB4)
    }

    // MARK: Placement in a tile

    /// The glyph's square as a share of an app icon tile's side, and its nudge from the tile's
    /// centre as a share of the side (x right, y down).
    public static let tileShare: CGFloat = 0.86
    public static let tileOffset = CGSize(width: 6.0 / 824, height: 4.0 / 824)
    /// The small cut fills more of a small tile, so it reads at 16 and 32 pixels.
    public static let smallTileShare: CGFloat = 0.96

    /// The square to draw the mark in, inside a tile `tile`.
    public static func box(inTile tile: CGRect, cut: Cut = .full) -> CGRect {
        let side = min(tile.width, tile.height) * (cut == .small ? smallTileShare : tileShare)
        return CGRect(x: tile.midX - side / 2 + tileOffset.width * tile.width,
                      y: tile.midY - side / 2 + tileOffset.height * tile.height,
                      width: side, height: side)
    }

    // MARK: Motion

    /// The quill's motion, in numbers. Surfaces run it on the render server; these values are what
    /// they share.
    public enum Motion {
        /// An outer barb's length while listening, as a share of the envelope: `floor` at silence,
        /// `floor + span` at a full level.
        public static let floor: CGFloat = 0.35
        public static let span: CGFloat = 0.75
        /// The level at which a barb reaches its full length.
        public static let referenceLevel: Float = 0.6
        /// How many level updates back the tip barbs read: the voice travels from the nib to the tip.
        public static let travel = 6
        /// How far the rhythm's phase turns with each level update.
        public static let phaseStep: CGFloat = 0.22
        /// The time a barb takes to reach a new length, a little longer than a level update.
        public static let barbEase: Double = 0.12
        /// The transcribing loop: the line draws by `drawnBy`, holds, and fades out by the end.
        public static let writeDuration: Double = 2.2
        public static let writeKeyTimes: [Double] = [0, 0.55, 0.8, 1]
        /// The barbs settling back to rest when listening ends.
        public static let settleDuration: Double = 0.35
        /// The result's line completing.
        public static let resultDuration: Double = 0.35

        /// The rhythm across the barbs at a phase, 0...1: two waves, as in the motion study.
        public static func rhythm(barb k: Int, phase: CGFloat) -> CGFloat {
            let x = CGFloat(k)
            return max(0.08, min(1, 0.5 + 0.28 * sin(x * 0.9 + phase) + 0.22 * sin(x * 0.37 - phase * 1.6)))
        }

        /// The outer barbs' lengths for the recent levels (newest first, 0...1) at a phase. Each barb
        /// reads a level from further back the nearer it is to the tip, shaped by the rhythm.
        public static func lengths(cut: Cut, history: [Float], phase: CGFloat) -> [CGFloat] {
            let count = cut.barbCount
            return (0..<count).map { k in
                let back = history.isEmpty ? 0 : min(history.count - 1, k * travel / max(count - 1, 1))
                let level = history.isEmpty ? 0 : CGFloat(min(1, max(0, history[back]) / referenceLevel))
                let live = level * (0.45 + 0.55 * rhythm(barb: k, phase: phase))
                return floor + span * live
            }
        }
    }
}
