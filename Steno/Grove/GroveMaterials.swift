import AppKit
import StenoKit
import SwiftUI

// MARK: - Forest glass

/// The anchor material of Grove: a vertical forest gradient with a 1 pt highlight along the top
/// edge and a mint rim. In dark mode a working surface gets a stronger mint rim so it separates
/// from the dark ground. Increase Contrast strengthens the rim; Reduce Transparency draws a
/// solid forest instead of the gradient.
struct ForestGlass<S: InsettableShape>: View {
    let shape: S
    /// Adds the stronger dark-mode rim for surfaces that sit on the ground rather than on glass.
    var isWorkingSurface = true
    @Environment(\.groveTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let rim = rimOpacity
        shape
            .fill(reduceTransparency ? AnyShapeStyle(theme.forestMid.color) : AnyShapeStyle(theme.forestGradient))
            .overlay(
                // The 1 pt highlight: bright at the top edge, gone by a third of the way down.
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: theme.cream.opacity(theme.increaseContrast ? 0.34 : 0.2).color, location: 0),
                            .init(color: .clear, location: 0.35)
                        ],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .overlay(shape.strokeBorder(theme.mint.opacity(rim).color, lineWidth: 1))
    }

    private var rimOpacity: Double {
        if theme.increaseContrast { return 0.5 }
        return theme.isDark && isWorkingSurface ? 0.28 : 0.18
    }
}

extension View {
    /// Fills the background with forest glass in a rounded rectangle.
    func forestGlass(cornerRadius: CGFloat, isWorkingSurface: Bool = true) -> some View {
        background(ForestGlass(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                               isWorkingSurface: isWorkingSurface))
    }
}

// MARK: - Cards

/// A lift under a surface: a blurred, inset copy of its shape pushed down, so the shadow shows
/// under the surface and not around its top edge (a drop shadow with a negative spread).
struct GroveLift: View {
    var cornerRadius: CGFloat
    /// How far the shadow shape is drawn inside the surface's edge.
    var inset: CGFloat = 24
    var blur: CGFloat = 15
    var offset: CGFloat = 10
    var opacity: Double = 0.5
    @Environment(\.groveTheme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.shadowTintColor.opacity(theme.isDark ? min(1, opacity * 1.5) : opacity))
            .padding(inset)
            .blur(radius: blur)
            .offset(y: offset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A raised card: the raised fill, a soft outline, and a quiet lift.
struct GroveCardBackground: View {
    var radius: CGFloat = 16
    var lift = true
    @Environment(\.groveTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(theme.raisedColor)
            .overlay(shape.strokeBorder(theme.ringColor, lineWidth: 1))
            .background { if lift { GroveLift(cornerRadius: radius) } }
    }
}

// MARK: - Buttons

enum GroveButtonKind: Sendable {
    /// Accent fill.
    case primary
    /// Raised fill with an ink outline.
    case outline
    /// No fill, secondary ink.
    case ghost
    /// Cream fill with forest text, for forest glass.
    case cream
    /// A soft cream wash with cream text, for forest glass.
    case soft
    /// The error colour, for the confirm button of a destructive dialog.
    case danger
}

enum GroveButtonSize: Sendable {
    /// 32 pt tall, 13 pt text.
    case large
    /// 28 pt, 13 pt text.
    case regular
    /// 26 pt, 12 pt text.
    case small

    var height: CGFloat {
        switch self { case .large: 32; case .regular: 28; case .small: 26 }
    }

    var fontSize: CGFloat {
        switch self { case .large: 13; case .regular: 13; case .small: 12 }
    }

    var horizontalPadding: CGFloat {
        switch self { case .large: 16; case .regular: 13; case .small: 11 }
    }
}

/// Pill buttons for the Grove window. The radius is half the height.
struct GroveButtonStyle: ButtonStyle {
    var kind: GroveButtonKind = .outline
    var size: GroveButtonSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, size: size)
    }

    struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: GroveButtonKind
        let size: GroveButtonSize
        @Environment(\.groveTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityShowButtonShapes) private var showShapes

        var body: some View {
            // A circular corner: a continuous one at half the height draws stray edges on the outline.
            let shape = RoundedRectangle(cornerRadius: size.height / 2, style: .circular)
            configuration.label
                .labelStyle(GroveLabelStyle(spacing: size == .large ? 7 : 6))
                .font(.system(size: size.fontSize, weight: kind == .primary || kind == .cream ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, size.horizontalPadding)
                .frame(minHeight: size.height)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.10 : 0)))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
        }

        private var foreground: Color {
            switch kind {
            case .primary: theme.onAccentColor
            case .outline: theme.inkColor
            case .ghost: theme.ink2Color
            case .cream: theme.onCreamColor
            case .soft: theme.creamColor
            case .danger: theme.isDark ? theme.onAccentColor : .white
            }
        }

        private var fill: Color {
            switch kind {
            case .primary: theme.accentColor
            case .outline: theme.raisedColor
            case .ghost: configuration.isPressed ? theme.wellColor : .clear
            case .cream: theme.creamColor
            case .soft: theme.cream.opacity(0.12).color
            case .danger: theme.errorColor
            }
        }

        private var border: Color {
            switch kind {
            case .outline: theme.increaseContrast ? theme.ink3Color : theme.ringColor
            case .ghost: showShapes ? theme.ink3Color : .clear
            case .soft: theme.increaseContrast ? theme.cream.opacity(0.7).color : .clear
            default: .clear
            }
        }
    }
}

/// The ring on a keyboard-focused control. Only macOS 14 and later switch the system effect off
/// (see `groveFocusEffectsOff`), so only there does this draw.
struct KeyboardFocusRing: ViewModifier {
    var isFocused: Bool
    var cornerRadius: CGFloat
    /// The control sits on forest glass: cream and soft buttons only ever do.
    var onGlass = false

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.modifier(GroveFocusRing(isFocused: isFocused, cornerRadius: cornerRadius, onGlass: onGlass))
        } else {
            content
        }
    }
}

private struct GroveLabelStyle: LabelStyle {
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension PrimitiveButtonStyle where Self == GroveFocusedButtonStyle<GroveButtonStyle> {
    /// A pill, with the keyboard focus ring around it: mint on forest glass, where cream and soft
    /// buttons sit.
    static func grove(_ kind: GroveButtonKind = .outline, _ size: GroveButtonSize = .regular) -> Self {
        GroveFocusedButtonStyle(look: GroveButtonStyle(kind: kind, size: size), cornerRadius: size.height / 2,
                                onGlass: kind == .cream || kind == .soft)
    }
}

// MARK: - Small parts

/// A key as printed on a keyboard, such as "⌥ Option" or "F18".
struct GroveKeycap: View {
    let key: String
    @Environment(\.groveTheme) private var theme

    init(_ key: String) { self.key = key }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.ink2Color)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(shape.fill(theme.wellColor))
            .overlay(shape.strokeBorder(theme.increaseContrast ? theme.ink3Color : theme.ringColor, lineWidth: 1))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Keycap.spokenName(for: key))
    }
}

/// The app's own icon, looked up once per bundle ID; a quiet glyph when it is not installed.
@MainActor
enum GroveAppIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

struct GroveAppIcon: View {
    let bundleID: String
    var size: CGFloat = 20
    @Environment(\.groveTheme) private var theme

    var body: some View {
        Group {
            if let image = GroveAppIcons.image(for: bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(theme.wellColor)
                    .overlay(
                        Image(systemName: "app.dashed")
                            .font(.system(size: size * 0.55))
                            .foregroundStyle(theme.ink3Color)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

