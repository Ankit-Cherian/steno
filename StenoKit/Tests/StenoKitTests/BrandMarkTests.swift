import AppKit
import QuartzCore
import Testing
@testable import StenoKit

@Suite("The voice quill, the one definition")
struct BrandMarkTests {
    private let square = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test("Its key proportions on the 100-unit square: nib low left, tip high right, a wide outer vane")
    func proportions() {
        #expect(BrandMark.name == "Voice quill")
        #expect(BrandMark.nib == CGPoint(x: 10, y: 94) && BrandMark.tip == CGPoint(x: 92, y: 6))
        #expect(BrandMark.bend == CGPoint(x: 30, y: 30) && BrandMark.vaneStart == 0.24)
        #expect(BrandMark.outer == 18 && BrandMark.inner == 8 && BrandMark.peak == 0.42 && BrandMark.voice == 0.22)
        let bounds = BrandMark.bounds
        #expect((8...11).contains(bounds.minX) && (93...95).contains(bounds.maxY), "the nib is the low left point: \(bounds)")
        #expect((91...95).contains(bounds.maxX) && (3...7).contains(bounds.minY), "the tip is the high right point: \(bounds)")
        // The outer vane (lower right) reaches more than twice as far as the inner one.
        let outer = BrandMark.outerVane(in: square, cut: .full).boundingBoxOfPath
        let inner = BrandMark.innerVane(in: square, cut: .full).boundingBoxOfPath
        #expect(outer.maxY > inner.maxY && inner.minX < outer.minX)
        #expect(BrandMark.envelope(BrandMark.peak) > 0.99 && BrandMark.envelope(1) < 0.01)
    }

    @Test("The full cut has 36 barb slots a side with two splits; the small cut is a 12-segment vane")
    func cuts() {
        #expect(BrandMark.Cut.full.perSide == 36 && BrandMark.Cut.full.gaps == [13, 25] && BrandMark.Cut.full.barbCount == 34)
        #expect(BrandMark.Cut.full.barbWidth == 1.5 && BrandMark.Cut.full.lean == 0.55 && BrandMark.Cut.full.rachisWidth == 2.6)
        #expect(BrandMark.Cut.small.barbCount == 12 && !BrandMark.Cut.small.strokesBarbs)
        #expect(BrandMark.Cut.forPixels(32) == .small && BrandMark.Cut.forPixels(36) == .small)
        #expect(BrandMark.Cut.forPixels(64) == .full)
        // Both cuts keep the same outline: the small cut is the full one simplified.
        let full = BrandMark.path(in: square, cut: .full).boundingBoxOfPath
        let small = BrandMark.path(in: square, cut: .small).boundingBoxOfPath
        #expect(abs(full.minX - small.minX) < 3 && abs(full.maxY - small.maxY) < 3 && abs(full.maxX - small.maxX) < 3)
    }

    @Test("The nib is cut by one slit from the point, with no round hole")
    func nibSlit() {
        for cut in [BrandMark.Cut.full, .small] {
            let shaft = BrandMark.shaft(in: square, cut: cut)
            let end = BrandMark.point(BrandMark.nibCut * 0.95)
            let mid = BrandMark.point(BrandMark.nibCut * 0.5)
            #expect(!shaft.contains(mid), "the slit parts the nib")
            // Where a breather hole would sit, around the slit's end, the shaft is solid.
            let d = BrandMark.tangent(BrandMark.nibCut * 0.95)
            let across = CGPoint(x: -d.y, y: d.x)
            let side = cut.slitWidth / 2 + 0.25
            #expect(shaft.contains(CGPoint(x: end.x + across.x * side, y: end.y + across.y * side)))
            #expect(shaft.contains(CGPoint(x: end.x - across.x * side, y: end.y - across.y * side)))
            #expect(shaft.contains(CGPoint(x: end.x + d.x * 0.6, y: end.y + d.y * 0.6)))
        }
    }

    @Test("The written line runs from the nib to x 82 along the baseline")
    func writtenLine() {
        let line = BrandMark.writtenLine(in: square, cut: .full, written: 1).boundingBoxOfPath
        #expect(abs(line.minX - (10 - 0.9)) < 0.01 && abs(line.maxX - (82 + 0.9)) < 0.01 && abs(line.midY - 94) < 0.01)
        #expect(BrandMark.writtenLine(in: square, cut: .full, written: 0).isEmpty)
        let half = BrandMark.writtenLine(in: square, cut: .full, written: 0.5).boundingBoxOfPath
        #expect(abs(half.maxX - (46 + 0.9)) < 0.01)
    }

    @Test("Fitted to any square, centred, scaling with it")
    func fitting() {
        let a = BrandMark.path(in: CGRect(x: 0, y: 0, width: 50, height: 50), cut: .full).boundingBoxOfPath
        let b = BrandMark.path(in: CGRect(x: 10, y: 5, width: 100, height: 100), cut: .full).boundingBoxOfPath
        #expect(abs(b.width - 2 * a.width) < 0.01 && abs(b.minX - (10 + 2 * a.minX)) < 0.01 && abs(b.minY - (5 + 2 * a.minY)) < 0.01)
        let wide = BrandMark.path(in: CGRect(x: 0, y: 0, width: 200, height: 100), cut: .full).boundingBoxOfPath
        #expect(abs(wide.minX - (50 + BrandMark.bounds.minX)) < 0.01)
    }

    @Test("At menu bar sizes the fitted square lands on whole pixels at 1x and 2x")
    func pixelSnapping() {
        for scale in [1.0, 2.0] as [CGFloat] {
            let rect = CGRect(x: 0.3, y: 0.2, width: 18, height: 18)
            let snapped = BrandMark.path(in: rect, cut: .small, written: 1, pixelScale: scale).boundingBoxOfPath
            // The line's left cap starts on the square's nib: whole pixels put it where the
            // unsnapped square at the rounded origin would.
            let reference = BrandMark.path(in: CGRect(x: (0.3 * scale).rounded() / scale, y: (0.2 * scale).rounded() / scale,
                                                      width: 18, height: 18), cut: .small, written: 1).boundingBoxOfPath
            #expect(abs(snapped.minX - reference.minX) < 0.001 && abs(snapped.minY - reference.minY) < 0.001, "\(scale)x")
        }
    }

    @Test("Colours: the forest tile, the barbs' gradient and the shaft")
    func colors() {
        let green = BrandMark.Colors.green
        #expect(green.tileTop == 0x2E6A4B && green.tileBottom == 0x133222)
        #expect(green.barbLow == 0xCDE4D5 && green.barbHigh == 0xF7FBF8 && green.shaft == 0x9FDDB4)
    }

    @Test("In a tile the quill's square is 0.86 of the side, nudged 6 and 4 of 824")
    func tilePlacement() {
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let box = BrandMark.box(inTile: tile)
        #expect(abs(box.width - 824 * 0.86) < 0.01)
        #expect(abs(box.midX - (tile.midX + 6)) < 0.01 && abs(box.midY - (tile.midY + 4)) < 0.01)
        #expect(BrandMark.box(inTile: tile, cut: .small).width > box.width)
    }

    @Test("Listening lengths: silence rests every barb at the floor; the voice travels to the tip")
    func listeningLengths() {
        let silent = BrandMark.Motion.lengths(cut: .full, history: [0, 0, 0, 0, 0, 0, 0], phase: 0)
        #expect(silent.count == 34 && silent.allSatisfy { $0 == BrandMark.Motion.floor })
        // A level just arrived: the base barbs rise, the tip barbs have not heard it yet.
        let onset = BrandMark.Motion.lengths(cut: .full, history: [0.6, 0, 0, 0, 0, 0, 0], phase: 0)
        #expect(onset.first! > BrandMark.Motion.floor && onset.last! == BrandMark.Motion.floor)
        let loud = BrandMark.Motion.lengths(cut: .small, history: [Float](repeating: 1, count: 7), phase: 1)
        #expect(loud.count == 12 && loud.allSatisfy { $0 > BrandMark.Motion.floor && $0 <= BrandMark.Motion.floor + BrandMark.Motion.span })
    }

    @Test("The icon artwork and its Icon Composer layers")
    func artwork() throws {
        let image = try #require(BrandIconArtwork.image(px: 128, colors: .green))
        #expect(image.width == 128)
        let png = try #require(BrandIconArtwork.png(px: 32, colors: .green))
        #expect(png.count > 200)
        #expect(BrandIconArtwork.cut(px: 16) == .small && BrandIconArtwork.cut(px: 32) == .small && BrandIconArtwork.cut(px: 64) == .full)
        let barbs = BrandIconArtwork.barbsSVG()
        #expect(barbs.hasPrefix("<svg") && barbs.contains("#CDE4D5") && barbs.contains("#F7FBF8") && barbs.contains("url(#barbs)"))
        #expect(BrandIconArtwork.shaftSVG().contains("fill=\"#9FDDB4\""))
    }
}

@Suite("The voice quill's layers")
@MainActor
struct BrandMarkViewTests {
    private func makeView(side: CGFloat = 22) -> BrandMarkView {
        let view = BrandMarkView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        view.pixelScale = 2
        return view
    }

    @Test("Listening moves only the outer vane's path, on the render server")
    func listening() throws {
        let view = makeView()
        view.play(.listening, animated: true)
        let silent = try #require(view.outerVanePath)
        for _ in 0..<4 { view.setLevel(0.7) }
        #expect(view.outerVanePath != silent)
        let move = try #require(view.layer?.sublayers?.first?.sublayers?.first?.mask?.sublayers?.last?.animation(forKey: BrandMarkView.barbsKey)
            as? CABasicAnimation)
        #expect(move.keyPath == "path" && move.duration == BrandMark.Motion.barbEase)
        #expect(view.lineEnd == 0)
    }

    @Test("Writing settles the barbs and loops the line; the result completes it once and holds")
    func writingAndResult() throws {
        let view = makeView(side: 30)
        #expect(view.cut == .full)
        view.play(.listening, animated: true)
        view.setLevel(0.8)
        view.play(.writing, animated: true)
        #expect(view.lengths == nil)
        let loop = try #require(view.lineAnimation(forKey: BrandMarkView.loopKey) as? CAAnimationGroup)
        #expect(loop.repeatCount == .infinity && loop.duration == BrandMark.Motion.writeDuration)
        let keyPaths = (loop.animations ?? []).compactMap { ($0 as? CAPropertyAnimation)?.keyPath }
        #expect(keyPaths == ["strokeEnd", "opacity"])
        view.play(.written, animated: true)
        #expect(view.lineEnd == 1 && view.lineAnimation(forKey: BrandMarkView.loopKey) == nil)
        #expect(view.lineAnimation(forKey: BrandMarkView.lineKey) != nil)
        view.stop()
        #expect(!view.isAnimating && view.motion == .still)
    }

    @Test("Reduce Motion: the barbs never move; listening fades them, writing dims, the result fades in")
    func reduceMotion() {
        let view = makeView()
        view.reduceMotion = true
        var now: CFTimeInterval = 0
        view.clock = { now }
        view.play(.listening, animated: true)
        let rest = view.outerVanePath
        view.setLevel(0.6)
        #expect(view.outerVanePath == rest && view.barbsOpacity == 1)
        now = 0.05
        view.setLevel(0)
        #expect(view.barbsOpacity == 1, "at most one write per interval")
        now = 0.2
        view.setLevel(0)
        #expect(view.barbsOpacity == NibLayer.reducedMotionOpacityRange.lowerBound)
        view.play(.writing, animated: true)
        #expect(view.quillOpacity == BrandMarkView.dimmedOpacity && view.lineAnimation(forKey: BrandMarkView.loopKey) == nil)
        view.play(.written, animated: true)
        #expect(view.quillOpacity == 1 && view.lineEnd == 1)
    }

    @Test("The small cut below 48 pixels, the full cut above")
    func cutBySize() {
        #expect(makeView(side: 22).cut == .small)
        #expect(makeView(side: 30).cut == .full)
        let view = makeView(side: 30)
        view.pixelScale = 1
        #expect(view.cut == .small)
    }
}
