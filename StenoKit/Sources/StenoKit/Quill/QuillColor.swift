import CoreGraphics
import Foundation

/// An sRGB colour with alpha, used for design tokens and the quill drawings.
///
/// Kept as plain components so tokens can be compared, mixed and checked for
/// contrast without rendering.
public struct QuillColor: Sendable, Hashable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB` with an optional alpha.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public static let white = QuillColor(hex: 0xFFFFFF)

    /// The same colour with a different alpha.
    public func opacity(_ alpha: Double) -> QuillColor {
        QuillColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Linear interpolation between two opaque colours, rounded to 8-bit channels like the design sources.
    public func mixed(with other: QuillColor, amount: Double) -> QuillColor {
        func channel(_ a: Double, _ b: Double) -> Double {
            let value = (a * 255 + (b * 255 - a * 255) * amount).rounded()
            return value / 255
        }
        return QuillColor(
            red: channel(red, other.red),
            green: channel(green, other.green),
            blue: channel(blue, other.blue),
            alpha: alpha + (other.alpha - alpha) * amount
        )
    }

    /// This colour drawn over an opaque background.
    public func composited(over background: QuillColor) -> QuillColor {
        QuillColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha),
            alpha: 1
        )
    }

    /// WCAG 2 relative luminance of the opaque colour.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio. Translucent colours are first composited over `background`.
    public func contrastRatio(on background: QuillColor) -> Double {
        let opaqueBackground = background.alpha < 1 ? background.composited(over: .white) : background
        let foreground = alpha < 1 ? composited(over: opaqueBackground) : self
        let lighter = max(foreground.relativeLuminance, opaqueBackground.relativeLuminance)
        let darker = min(foreground.relativeLuminance, opaqueBackground.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// `#rrggbb`, with `@alpha` appended when translucent.
    public var description: String {
        let hex = [red, green, blue].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
        return alpha < 1 ? "#\(hex)@\(String(format: "%.2f", alpha))" : "#\(hex)"
    }
}
