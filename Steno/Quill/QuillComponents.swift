import SwiftUI

// MARK: - Status pill

/// The window's status, always a word. Hidden on Today.
enum QuillStatusPillState: Sendable, Equatable {
    case ready
    case listening(elapsedSeconds: Int)
    case transcribing
    case microphoneOff
    case copyOnly
    /// Input Monitoring is off: the key that no longer works in other apps, or nil when the
    /// pill speaks of shortcuts in general.
    case shortcutKeyOff(String?)
    case noSpeechModel
    case downloading(percent: Int)

    var title: String {
        switch self {
        case .ready: "Ready"
        case .listening(let seconds): "Listening \(Self.elapsed(seconds))"
        case .transcribing: "Transcribing"
        case .microphoneOff: "Microphone off"
        case .copyOnly: "Copy only"
        case .shortcutKeyOff(let key): key.map { "\($0) key off" } ?? "Shortcuts off"
        case .noSpeechModel: "No speech model"
        case .downloading(let percent): "Downloading \(max(0, min(100, percent)))%"
        }
    }

    /// Problems that limit dictation; shown in caution.
    var isProblem: Bool {
        switch self {
        case .microphoneOff, .copyOnly, .shortcutKeyOff, .noSpeechModel: true
        default: false
        }
    }

    func dotColor(in theme: QuillTheme) -> Color {
        switch self {
        case .ready: theme.ok
        case .listening, .transcribing: theme.accent
        case .downloading: theme.ink3
        default: theme.caution
        }
    }

    static func elapsed(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The toolbar status: a dot and a word. When it has an action, clicking opens what fixes it;
/// otherwise it is static text.
struct StatusPill: View {
    let state: QuillStatusPillState
    var action: (() -> Void)?
    @Environment(\.quillTheme) private var theme

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(StatusPillButtonStyle(border: theme.controlBorder.opacity(0.5), pressedFill: theme.well))
                .accessibilityLabel("Status")
                .accessibilityValue(state.title)
                .accessibilityHint("Opens the setting that fixes it")
        } else {
            StatusPillButtonStyle(border: theme.rule, pressedFill: theme.well).frame(content)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Status")
                .accessibilityValue(state.title)
        }
    }

    private var content: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.dotColor(in: theme))
                .frame(width: 7, height: 7)
            Text(state.title)
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(state.isProblem ? theme.caution : theme.ink2)
                .lineLimit(1)
        }
    }
}

private struct StatusPillButtonStyle: ButtonStyle {
    let border: Color
    let pressedFill: Color

    func makeBody(configuration: Configuration) -> some View {
        frame(configuration.label, pressed: configuration.isPressed)
    }

    /// The pill's shape around any label, pressed or not.
    func frame<Label: View>(_ label: Label, pressed: Bool = false) -> some View {
        label
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(pressed ? pressedFill : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(border, lineWidth: 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 13))
    }
}

// MARK: - Keys

/// How a key as printed on the keyboard, such as "F18" or "⌘V", reads aloud.
enum Keycap {
    /// "⌘V" reads as "Command V".
    static func spokenName(for key: String) -> String {
        let names: [Character: String] = ["⌘": "Command", "⌥": "Option", "⌃": "Control", "⇧": "Shift", "⏎": "Return", "⎋": "Escape"]
        var words: [String] = []
        var rest = ""
        for character in key {
            if let name = names[character] {
                words.append(name)
            } else {
                rest.append(character)
            }
        }
        if !rest.isEmpty { words.append(rest) }
        return words.joined(separator: " ")
    }
}
