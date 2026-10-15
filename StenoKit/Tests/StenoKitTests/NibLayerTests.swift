import CoreGraphics
import QuartzCore
import Testing
@testable import StenoKit

@Suite("Live quill nib")
@MainActor
struct NibLayerTests {
    @Test("The quill geometry is complete and parses into closed outlines")
    func geometryParses() {
        #expect(QuillGeometry.barbs.count == 41)
        #expect(QuillGeometry.barbs.filter(\.isRightVane).count == 22)
        #expect(QuillGeometry.shaftOutline.count > 100)
        #expect(QuillGeometry.smallShaftOutline.count > 100)
        #expect(QuillGeometry.silhouetteOutline.count > 100)
        #expect(QuillGeometry.smallShaftOutline.first == CGPoint(x: 215, y: 900))
        #expect(QuillGeometry.silhouetteOutline.first == CGPoint(x: 298.4, y: 721))
    }

    @Test("The nib draws every second right-vane barb and every fourth left-vane barb")
    func barbSubset() {
        #expect(NibLayer.barbs.count == 11 + 5)
        #expect(NibLayer.barbs.prefix(11).filter(\.isRightVane).count == 11)
        #expect(NibLayer.barbs.suffix(5).filter(\.isRightVane).isEmpty)
        #expect(NibLayer().barbCount == 16)
    }

    @Test("Level 0 gives rest lengths and level 1 gives full lengths")
    func levelMapping() {
        let nib = NibLayer()
        nib.setMode(.live)
        nib.setLevel(0)
        #expect(nib.barbStrokeEnds.allEqual(NibLayer.restLength))
        nib.setLevel(1)
        #expect(nib.barbStrokeEnds.allEqual(1))
        nib.setLevel(0.4)
        let middle = nib.barbStrokeEnds
        let inRange = middle.filter { $0 > NibLayer.restLength && $0 < 1 }.count == middle.count
        #expect(inRange)
        #expect(Set(middle).count > 1, "neighbouring barbs answer the same level differently")
        nib.setLevel(5)
        #expect(nib.level == 1)
        nib.setLevel(.nan)
        #expect(nib.level == 0)
    }

    @Test("Live lengths rise with the level for every barb", arguments: [0, 5, 15])
    func lengthsAreMonotonic(barbIndex: Int) {
        var previous: CGFloat = 0
        for step in 0...20 {
            let length = NibLayer.liveLength(level: Float(step) / 20, barbIndex: barbIndex)
            #expect(length >= previous)
            previous = length
        }
        #expect(previous == 1)
    }

    @Test("Rest and working hold fixed lengths; the level only drives live")
    func modes() {
        let nib = NibLayer()
        #expect(nib.mode == .rest)
        #expect(nib.barbStrokeEnds.allEqual(NibLayer.restLength))
        nib.setLevel(1)
        #expect(nib.barbStrokeEnds.allEqual(NibLayer.restLength))
        nib.setMode(.working)
        #expect(nib.barbStrokeEnds.allEqual(NibLayer.workingLength))
        #expect(nib.isSweeping)
        nib.setMode(.live)
        #expect(!nib.isSweeping)
        #expect(nib.barbStrokeEnds.allEqual(1))
    }

    @Test("Reduce Motion keeps the shape and shows the level by opacity at most ten times a second")
    func reduceMotion() {
        var now: CFTimeInterval = 100
        let nib = NibLayer(reduceMotion: true)
        nib.clock = { now }
        nib.setMode(.live)
        nib.setLevel(0)
        #expect(nib.barbStrokeEnds.allEqual(NibLayer.reducedMotionLength))
        #expect(nib.barbOpacities.allEqual(0.45))

        now += 0.05
        nib.setLevel(1)
        #expect(nib.barbOpacities.allEqual(0.45), "a second change within 100 ms is not shown")

        now += 0.06
        nib.setLevel(1)
        #expect(nib.barbOpacities.allEqual(1))
        #expect(nib.barbStrokeEnds.allEqual(NibLayer.reducedMotionLength))

        nib.setMode(.working)
        #expect(!nib.isSweeping, "no sweep under Reduce Motion")
        #expect(nib.barbOpacities.allEqual(1))
    }

    @Test("Turning Reduce Motion off restores length-driven barbs")
    func reduceMotionToggle() {
        let nib = NibLayer(reduceMotion: true)
        nib.setMode(.live)
        nib.setLevel(1)
        nib.reduceMotion = false
        #expect(nib.barbStrokeEnds.allEqual(1))
        #expect(nib.barbOpacities.allEqual(1))
    }

    @Test("Level updates never animate implicitly or change paths")
    func noImplicitAnimationsOrPathChanges() {
        let nib = NibLayer()
        nib.setMode(.live)
        let layers = nib.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        let paths = layers.map(\.path)
        for step in 0..<30 { nib.setLevel(Float(step % 10) / 10) }
        #expect(layers.map(\.path) == paths)
        let animated = layers.filter { !($0.animationKeys() ?? []).isEmpty }
        #expect(animated.isEmpty)
    }

    @Test("The result mark is a 15 pt disc at the tip, hidden until set", arguments: NibLayer.ResultMark.allCases)
    func resultMark(mark: NibLayer.ResultMark) {
        let nib = NibLayer()
        #expect(nib.resultMark == nil)
        nib.setResultMark(mark)
        #expect(nib.resultMark == mark)
        #expect(nib.resultMarkFrame == CGRect(x: 14, y: 15, width: 15, height: 15))
        nib.setResultMark(nil)
        #expect(nib.resultMark == nil)
    }

    @Test("The nib scales with its bounds")
    func scalesWithBounds() {
        let nib = NibLayer()
        nib.bounds = CGRect(x: 0, y: 0, width: 48, height: 54)
        nib.layoutSublayers()
        nib.setResultMark(.check)
        #expect(nib.resultMarkFrame == CGRect(x: 28, y: 30, width: 30, height: 30))
    }

    @Test("The drawing stays upright in flipped and unflipped hosts")
    func orientsToHost() {
        let unparented = NibLayer()
        #expect(unparented.flipsForHost)

        let flippedHost = CALayer()
        flippedHost.isGeometryFlipped = true
        let inFlipped = NibLayer()
        flippedHost.addSublayer(inFlipped)
        inFlipped.layoutSublayers()
        #expect(!inFlipped.flipsForHost)

        let plainHost = CALayer()
        let inPlain = NibLayer()
        plainHost.addSublayer(inPlain)
        inPlain.layoutSublayers()
        #expect(inPlain.flipsForHost)
    }

    @Test("Token colours mix and measure contrast like the design sources")
    func colorMath() {
        let low = QuillColor(hex: 0x2F5BE6)
        let high = QuillColor(hex: 0x7BB8E8)
        #expect(low.mixed(with: high, amount: 0.5).description == "#558ae7")
        #expect(QuillColor(hex: 0x000000).contrastRatio(on: .white) == 21)
        #expect(abs(QuillColor(hex: 0x767676).contrastRatio(on: .white) - 4.54) < 0.01)
    }
}

private extension Array where Element: Equatable {
    func allEqual(_ value: Element) -> Bool { allSatisfy { $0 == value } }
}
