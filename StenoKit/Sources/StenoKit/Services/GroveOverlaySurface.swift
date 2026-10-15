#if os(macOS)
import AppKit
import QuartzCore

/// Which family a surface belongs to. Green means only "working, or it worked"; a notice or a
/// problem is graphite.
enum GroveTone: Equatable {
    case forest
    case graphite
}

/// The quiet palette: a dark forest island, graphite for notices, cream text and sage mint.
/// Light and dark appearances look the same; the island is always dark.
enum GrovePalette {
    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
        )
    }

    static let cream = color(0xEEF6F0)
    static let subtext = color(0xA9C4B2)
    static let mint = color(0x9FDDB4)
    /// Problems: the caution glyph, and the last-minute countdown.
    static let warning = color(0xF0C77E)
    /// A neutral notice's glyph on graphite.
    static let neutralGlyph = color(0xB5BAB7)
    /// Text on the cream Stop and action buttons.
    static let onCream = color(0x143322)
    static let black = color(0x000000)

    /// Top and bottom of the working fill.
    static let forest: [UInt32] = [0x213A2B, 0x0F2419]

    /// Top and bottom of the fill.
    static func gradient(_ tone: GroveTone) -> [UInt32] {
        switch tone {
        case .forest: forest
        case .graphite: [0x2A2C2B, 0x1B1C1B]
        }
    }

    /// The fill's colour a fraction of the way down, for the fade behind live words.
    static func fill(_ tone: GroveTone, at fraction: CGFloat) -> NSColor {
        let stops = gradient(tone)
        let t = max(0, min(1, fraction))
        func channel(_ shift: UInt32) -> CGFloat {
            let a = CGFloat((stops[0] >> shift) & 0xFF), b = CGFloat((stops[1] >> shift) & 0xFF)
            return (a + (b - a) * t) / 255
        }
        return NSColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }

    /// The single top-lit hairline: white 14 % at the top, 3 % at the bottom. Increase Contrast
    /// swaps it for one flat, readable line.
    static let hairlineTop = NSColor.white.withAlphaComponent(0.14)
    static let hairlineBottom = NSColor.white.withAlphaComponent(0.03)
    static let increasedContrastRim = cream.withAlphaComponent(0.6)
    static let hairlineWidth: CGFloat = 0.75

    /// One soft shadow: black 30 %, radius 10, 4 pt down.
    static let shadowOpacity: Float = 0.30
    static let shadowRadius: CGFloat = 10
    static let shadowDrop: CGFloat = 4
}

/// One island: the capsule, the notch shell, or either grown to hold live words.
///
/// Layers, bottom to top: one soft shadow cast from a path, then the shell: the fill gradient
/// (and, in notch mode, a pure black neck down to the menu bar's bottom edge, with the body
/// starting there: a hard seam), and the hairline. Everything inside the shape is clipped by one
/// path mask, so a width change is one path spring that the render server runs; the app does no
/// work per frame. Never takes mouse events.
@MainActor
final class GroveSurfaceView: NSView {
    struct Style: Equatable {
        var tone = GroveTone.forest
        var reduceTransparency = false
        var increaseContrast = false
    }

    struct Geometry {
        var shape: CGPath
        var shadow: CGPath
        /// The rectangle the fill gradient spans: the capsule, or the body below the neck.
        var gradientRect: CGRect
        /// Height of the pure black neck, or nil for a shape without one.
        var neckHeight: CGFloat?
        /// The hairline follows the capsule and the container, not the notch.
        var hasHairline: Bool
    }

    private let shadowLayer = CAShapeLayer()
    private let shell = CALayer()
    private let shellMask = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private let neck = CALayer()
    private let hairline = CAGradientLayer()
    private let hairlineMask = CAShapeLayer()
    private var style = Style()
    private(set) var geometry: Geometry?
    private var shadowOpacity: Float = GrovePalette.shadowOpacity

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        guard let root = layer else { return }
        root.masksToBounds = false

        // The shape needs a fill for its shadow to draw; the shell covers it.
        shadowLayer.fillColor = GrovePalette.color(0x0F2419).cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowRadius = GrovePalette.shadowRadius
        // The drop is carried by the shadow path, written y-down like the shell. A shadow offset
        // is read differently by a window and by an offscreen render.
        shadowLayer.shadowOffset = .zero
        shadowLayer.shadowOpacity = shadowOpacity
        shadowLayer.zPosition = 0
        root.addSublayer(shadowLayer)

        shell.mask = shellMask
        shell.zPosition = 3
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        shell.addSublayer(gradient)
        neck.backgroundColor = GrovePalette.black.cgColor
        neck.isHidden = true
        shell.addSublayer(neck)
        // The hairline is a stroke along the inside of the shape: a path stroked twice as wide as
        // the line, clipped by the shell, masks a top-lit gradient.
        hairlineMask.fillColor = nil
        hairlineMask.strokeColor = NSColor.black.cgColor
        hairlineMask.lineWidth = GrovePalette.hairlineWidth * 2
        hairline.startPoint = CGPoint(x: 0.5, y: 0)
        hairline.endPoint = CGPoint(x: 0.5, y: 1)
        hairline.mask = hairlineMask
        shell.addSublayer(hairline)
        root.addSublayer(shell)

        for layer in [shadowLayer, shell, shellMask, gradient, neck, hairline, hairlineMask] as [CALayer] {
            layer.actions = Self.noActions
        }
        applyStyle(Style(), animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static var noActions: [String: CAAction] {
        let keys = ["path", "shadowPath", "bounds", "position", "frame", "colors", "locations", "opacity",
                    "fillColor", "strokeColor", "hidden", "shadowOpacity", "backgroundColor", "mask"]
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, NSNull() as CAAction) })
    }

    // MARK: Style

    /// A change of tone cross-fades the fill; everything else is set at once.
    func applyStyle(_ newStyle: Style, animated: Bool) {
        let toneChanged = newStyle.tone != style.tone
        let oldColors = gradient.presentation()?.colors ?? gradient.colors
        style = newStyle
        withoutActions {
            let colors = GrovePalette.gradient(newStyle.tone).map { GrovePalette.color($0).cgColor }
            gradient.colors = colors
            let rim = GrovePalette.increasedContrastRim
            hairline.colors = newStyle.increaseContrast
                ? [rim.cgColor, rim.cgColor]
                : [GrovePalette.hairlineTop.cgColor, GrovePalette.hairlineBottom.cgColor]
            shadowLayer.fillColor = colors[1]
            shadowOpacity = newStyle.reduceTransparency ? 0 : GrovePalette.shadowOpacity
            shadowLayer.shadowOpacity = shadowOpacity
            if animated, toneChanged, let oldColors {
                let fade = CABasicAnimation(keyPath: "colors")
                fade.fromValue = oldColors
                fade.toValue = colors
                fade.duration = 0.15
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                gradient.add(fade, forKey: "steno.tone")
            }
        }
    }

    // MARK: Geometry

    /// Sets the shape. With a spring, every path eases from where it is now to the new one.
    func setGeometry(_ new: Geometry, spring: GroveSpring? = nil) {
        let old = geometry
        geometry = new
        withoutActions {
            if spring == nil { removeShapeAnimations() }
            frameLayers(new)
            let unchanged = old.map { $0.shape == new.shape && $0.shadow == new.shadow } ?? false
            let effective = unchanged ? nil : spring
            assign(layer: shellMask, key: "path", old: old?.shape, new: new.shape, spring: effective) { $0.path = new.shape }
            assign(layer: hairlineMask, key: "path", old: old?.shape, new: new.shape, spring: effective) { $0.path = new.shape }
            let cast = shadowCast(new.shadow)
            assign(layer: shadowLayer, key: "shadowPath", old: old.map { shadowCast($0.shadow) }, new: cast, spring: effective) {
                $0.shadowPath = cast
            }
            assign(layer: shadowLayer, key: "path", old: old?.shadow, new: new.shadow, spring: effective) { $0.path = new.shadow }
        }
    }

    private func frameLayers(_ new: Geometry) {
        let full = bounds
        for layer in [shell, shellMask, hairlineMask, shadowLayer] as [CALayer] { layer.frame = full }
        gradient.frame = new.gradientRect
        hairline.frame = new.gradientRect
        // The hairline mask is written in panel coordinates; the gradient it masks starts lower.
        hairlineMask.frame = CGRect(origin: CGPoint(x: -new.gradientRect.minX, y: -new.gradientRect.minY), size: full.size)
        hairline.isHidden = !new.hasHairline
        if let neckHeight = new.neckHeight {
            neck.frame = CGRect(x: 0, y: 0, width: full.width, height: neckHeight)
            neck.isHidden = false
        } else {
            neck.isHidden = true
        }
    }

    private func assign(
        layer: CAShapeLayer, key: String, old: CGPath?, new: CGPath, spring: GroveSpring?,
        set: (CAShapeLayer) -> Void
    ) {
        let from: Any? = layer.animation(forKey: Self.springKey(key)).flatMap { _ in layer.presentation()?.value(forKey: key) }
            ?? old
        set(layer)
        guard let spring, let from else { return }
        layer.add(spring.animation(keyPath: key, from: from, to: new), forKey: Self.springKey(key))
    }

    private static func springKey(_ key: String) -> String { "steno.spring.\(key)" }

    /// The path the shadow layer casts: the shadow shape moved down by the drop.
    private func shadowCast(_ path: CGPath) -> CGPath {
        var drop = CGAffineTransform(translationX: 0, y: GrovePalette.shadowDrop)
        return path.copy(using: &drop) ?? path
    }

    private static let pathKeys = ["path", "shadowPath"]

    /// Plays `spring` from `from` to the current shape, for the notch's emergence.
    func animateFromClosed(shape: CGPath, shadow closedShadow: CGPath, spring: GroveSpring) {
        guard let geometry else { return }
        withoutActions {
            for (layer, key, from, to) in [
                (shellMask, "path", shape, geometry.shape), (hairlineMask, "path", shape, geometry.shape),
                (shadowLayer, "shadowPath", shadowCast(closedShadow), shadowCast(geometry.shadow)),
                (shadowLayer, "path", closedShadow, geometry.shadow),
            ] {
                layer.add(spring.animation(keyPath: key, from: from, to: to), forKey: Self.springKey(key))
            }
            fadeShadow(to: nil, duration: 0.2, delay: 0.1)
        }
    }

    /// Folds the shape into `closed`, and leaves it there.
    func retract(to closed: CGPath, shadow closedShadow: CGPath, spring: GroveSpring) {
        guard var geometry else { return }
        let old = geometry
        geometry.shape = closed
        geometry.shadow = closedShadow
        self.geometry = geometry
        withoutActions {
            for (layer, key, from, to) in [
                (shellMask, "path", old.shape, closed), (hairlineMask, "path", old.shape, closed),
                (shadowLayer, "shadowPath", shadowCast(old.shadow), shadowCast(closedShadow)),
                (shadowLayer, "path", old.shadow, closedShadow),
            ] {
                let start: Any = layer.animation(forKey: Self.springKey(key)).flatMap { _ in layer.presentation()?.value(forKey: key) } ?? from
                layer.removeAnimation(forKey: Self.springKey(key))
                if key == "path" {
                    layer.path = to
                } else {
                    layer.shadowPath = to
                }
                layer.add(spring.animation(keyPath: key, from: start, to: to), forKey: Self.springKey(key))
            }
            fadeShadow(to: 0, duration: 0.12)
        }
    }

    /// The shadow follows the shell out of, and back into, the notch: a folded shell casts none.
    private func fadeShadow(to opacity: Float?, duration: TimeInterval, delay: TimeInterval = 0) {
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = opacity == nil ? 0 : shadowLayer.presentation()?.shadowOpacity ?? shadowLayer.shadowOpacity
        fade.toValue = opacity ?? shadowLayer.shadowOpacity
        fade.duration = duration
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        if let opacity { shadowLayer.shadowOpacity = opacity }
        shadowLayer.add(fade, forKey: "steno.shadowFade")
    }

    func removeAllMotion() {
        removeShapeAnimations()
        gradient.removeAnimation(forKey: "steno.tone")
        shadowLayer.removeAnimation(forKey: "steno.shadowFade")
        // A retraction leaves the shadow off; the style puts it back.
        applyStyle(style, animated: false)
    }

    private func removeShapeAnimations() {
        for layer in [shellMask, hairlineMask, shadowLayer] {
            for key in Self.pathKeys { layer.removeAnimation(forKey: Self.springKey(key)) }
        }
    }

    var isAnimating: Bool {
        [shellMask, hairlineMask, shadowLayer].contains { layer in
            Self.pathKeys.contains { layer.animation(forKey: Self.springKey($0)) != nil }
        } || gradient.animation(forKey: "steno.tone") != nil
    }

    var currentStyle: Style { style }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
#endif
