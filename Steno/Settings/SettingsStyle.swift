import SwiftUI

// MARK: - Text roles

/// A text role in the Settings type, system font: title 20 semibold, label 13 medium, body 13,
/// caption 12, heading (a section label inside a pane) 12 semibold, mono (numbers) 11 with
/// tabular digits.
private struct SettingsFontModifier: ViewModifier {
    let role: QuillTypeStyle

    func body(content: Content) -> some View {
        switch role {
        case .display, .title: content.groveFont(20, .semibold)
        case .dictation: content.groveFont(15)
        case .body: content.groveFont(13)
        case .label: content.groveFont(13, .medium)
        case .caption: content.groveFont(12)
        case .heading: content.groveFont(12, .semibold)
        case .mono: content.groveFont(11).monospacedDigit()
        }
    }
}

extension View {
    /// A text role of the Settings type.
    func settingsFont(_ role: QuillTypeStyle) -> some View {
        modifier(SettingsFontModifier(role: role))
    }
}

// MARK: - Buttons

enum SettingsButtonKind: Sendable {
    /// The one main action: accent fill.
    case primary
    /// A raised pill with a soft outline.
    case secondary
    /// Text only, in secondary ink.
    case quiet
}

private struct SettingsButtonStyleModifier: ViewModifier {
    let kind: SettingsButtonKind
    let small: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch kind {
        case .primary:
            content.buttonStyle(.grove(.primary, small ? .small : .regular)).groveFocusEffectsOff()
        case .secondary:
            content.buttonStyle(.grove(.outline, small ? .small : .regular)).groveFocusEffectsOff()
        case .quiet:
            content.buttonStyle(.grove(.ghost, small ? .small : .regular)).groveFocusEffectsOff()
        }
    }
}

extension View {
    /// A Settings button. `small` is the size used in rows.
    func settingsButton(_ kind: SettingsButtonKind, small: Bool = true) -> some View {
        modifier(SettingsButtonStyleModifier(kind: kind, small: small))
    }

    /// The padding of a row that is not a `SettingsRow`: on the plain ground, with no side inset.
    func settingsRowInset(vertical: CGFloat = 11) -> some View {
        padding(.vertical, vertical)
    }
}

// MARK: - Section names and symbols

extension SettingsSection {
    /// The page and sidebar name: title case, as drawn.
    var groveTitle: String {
        switch self {
        case .engine: "Speech Model"
        case .corrections: "Word Corrections"
        case .shortcuts: "Text Shortcuts"
        case .output: "Inserting Text"
        default: title
        }
    }

    /// The sidebar symbol. Recording is the waveform and Microphone the mic.
    var groveSymbolName: String {
        switch self {
        case .recording: "waveform"
        case .microphone: "mic"
        case .engine: "cpu"
        case .media: "speaker.wave.2"
        case .cleanup: "wand.and.stars"
        case .corrections: "character.cursor.ibeam"
        case .shortcuts: "text.badge.plus"
        case .output: "arrow.right.to.line"
        case .permissions: "lock"
        case .appearance: "circle.lefthalf.filled"
        case .general: "gearshape"
        }
    }
}
