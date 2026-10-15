import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The app icon drawn from `BrandMark`: the brand tile on Apple's 1024 icon grid with the voice
/// quill on it. The app draws the runtime Dock icon and onboarding's tile with it, and
/// `StenoIconRenderer` writes the icon set and the Icon Composer layers with it, so all of them
/// follow the one mark definition.
public enum BrandIconArtwork {
    /// The 824 tile, 100 in from each side of a 1024 canvas, scaled to `px`.
    public static func tileRect(px: CGFloat) -> CGRect {
        let s = px / 1024
        return CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    }

    /// The tile's corner radius at `px`, for callers that build the continuous-corner shape.
    public static func cornerRadius(px: CGFloat) -> CGFloat { 185 * px / 1024 }

    /// The cut the icon uses at `px`: the small cut at 16 and 32 pixels.
    public static func cut(px: CGFloat) -> BrandMark.Cut { px <= 32 ? .small : .full }

    /// Draws the icon into a y-down context `px` wide.
    ///
    /// - Parameter tileShape: the tile's outline at `tileRect(px:)`. Pass a continuous-corner
    ///   rounded rectangle; it defaults to circular corners.
    public static func draw(in ctx: CGContext, px: CGFloat, colors: BrandMark.Colors, tileShape: CGPath? = nil) {
        let s = px / 1024
        let tile = tileRect(px: px)
        let shape = tileShape ?? CGPath(roundedRect: tile, cornerWidth: cornerRadius(px: px), cornerHeight: cornerRadius(px: px), transform: nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.saveGState()
        // Shadow offsets are in the base space, which is y up whatever the context's transform.
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: color(0, 0.28))
        ctx.addPath(shape)
        ctx.setFillColor(color(colors.tileBottom))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        if let fill = CGGradient(colorsSpace: space, colors: [color(colors.tileTop), color(colors.tileBottom)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
        }
        let glowCenter = CGPoint(x: tile.midX, y: tile.minY - 0.05 * tile.height)
        if let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 640 * s, options: [])
        }
        if px >= 64 {
            // The rim: 3 units inside the edge, bright at the top and gone by the middle.
            ctx.addPath(shape)
            ctx.setLineWidth(6 * s)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            if let rim = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.26), color(0xFFFFFF, 0.02)] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.midY), options: [])
            }
        }
        ctx.restoreGState()

        let cut = cut(px: px)
        var box = BrandMark.box(inTile: tile, cut: cut)
        if px <= 64 {
            // Whole pixels for the fitted square, so the shaft and nib stay crisp.
            box = CGRect(x: box.minX.rounded(), y: box.minY.rounded(), width: box.width.rounded(), height: box.height.rounded())
        }
        ctx.saveGState()
        if px >= 64 {
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 20 * s, color: color(0, 0.18))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        drawGlyph(in: ctx, box: box, cut: cut, colors: colors)
        if px >= 64 { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    /// The quill in its colours, fitted to `box`: the barbs in their gradient, then the shaft and
    /// nib, then `written` of the line.
    public static func drawGlyph(in ctx: CGContext, box: CGRect, cut: BrandMark.Cut, colors: BrandMark.Colors,
                                 lengths: [CGFloat]? = nil, written: CGFloat = 0) {
        let barbs = BrandMark.barbs(in: box, cut: cut, lengths: lengths)
        let bounds = barbs.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(barbs)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     colors: [color(colors.barbLow), color(colors.barbHigh)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: bounds.minX, y: bounds.maxY), end: CGPoint(x: bounds.maxX, y: bounds.minY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
        ctx.setFillColor(color(colors.shaft))
        ctx.addPath(BrandMark.shaft(in: box, cut: cut))
        ctx.fillPath()
        let line = BrandMark.writtenLine(in: box, cut: cut, written: written)
        if !line.isEmpty {
            ctx.addPath(line)
            ctx.fillPath()
        }
    }

    /// The icon as an image `px` pixels square.
    public static func image(px: Int, colors: BrandMark.Colors, tileShape: CGPath? = nil) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, px: CGFloat(px), colors: colors, tileShape: tileShape)
        return ctx.makeImage()
    }

    /// The icon as PNG data.
    public static func png(px: Int, colors: BrandMark.Colors, tileShape: CGPath? = nil) -> Data? {
        guard let image = image(px: px, colors: colors, tileShape: tileShape) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Icon Composer layers

    /// The square the quill sits in on Icon Composer's 1024 canvas, where the canvas is the tile.
    static var composerBox: CGRect { BrandMark.box(inTile: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }

    /// The barbs layer: both vanes in their gradient, lower left to upper right, on a 1024 canvas.
    public static func barbsSVG(colors: BrandMark.Colors = .green) -> String {
        let path = BrandMark.barbs(in: composerBox, cut: .full)
        let b = path.boundingBoxOfPath
        let gradient = String(format: "<defs><linearGradient id=\"barbs\" gradientUnits=\"userSpaceOnUse\" x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\">",
                              b.minX, b.maxY, b.maxX, b.minY)
            + "<stop offset=\"0\" stop-color=\"\(hex(colors.barbLow))\"/><stop offset=\"1\" stop-color=\"\(hex(colors.barbHigh))\"/>"
            + "</linearGradient></defs>"
        return svg(gradient + "<path d=\"\(svgPath(path))\" fill=\"url(#barbs)\"/>")
    }

    /// The shaft-and-nib layer, with the slit cut, on a 1024 canvas.
    public static func shaftSVG(colors: BrandMark.Colors = .green) -> String {
        svg("<path d=\"\(svgPath(BrandMark.shaft(in: composerBox, cut: .full)))\" fill=\"\(hex(colors.shaft))\" fill-rule=\"nonzero\"/>")
    }

    private static func svg(_ body: String) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">" + body + "</svg>"
    }

    static func svgPath(_ path: CGPath) -> String {
        var parts: [String] = []
        func f(_ p: CGPoint) -> String { String(format: "%.1f,%.1f", p.x, p.y) }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: parts.append("M" + f(e.points[0]))
            case .addLineToPoint: parts.append("L" + f(e.points[0]))
            case .addQuadCurveToPoint: parts.append("Q" + f(e.points[0]) + " " + f(e.points[1]))
            case .addCurveToPoint: parts.append("C" + f(e.points[0]) + " " + f(e.points[1]) + " " + f(e.points[2]))
            case .closeSubpath: parts.append("Z")
            @unknown default: break
            }
        }
        return parts.joined(separator: " ")
    }

    static func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
