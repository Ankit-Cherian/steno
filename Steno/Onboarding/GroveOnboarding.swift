import StenoKit
import SwiftUI

// The setup guide in the Quiet design. These views draw what `OnboardingView` decides: the step,
// each permission's state and the first dictation's phase. No pager dots; one centred column.

/// The app icon, drawn by `BrandIconArtwork` exactly as the bundle's icon and the Dock icon are:
/// the tile with the voice quill.
struct GroveAppIconTile: View {
    var size: CGFloat = 96
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // The artwork's 1024 canvas holds the 824 tile and its shadow; the tile fills `size`.
        let canvas = size * 1024 / 824
        Group {
            if let image = Self.artwork(px: Int((canvas * displayScale).rounded())) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .frame(width: canvas, height: canvas)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @MainActor private static var cache: [Int: CGImage] = [:]

    @MainActor static func artwork(px: Int) -> CGImage? {
        if let image = cache[px] { return image }
        let tile = RoundedRectangle(cornerRadius: BrandIconArtwork.cornerRadius(px: CGFloat(px)), style: .continuous)
            .path(in: BrandIconArtwork.tileRect(px: CGFloat(px))).cgPath
        let image = BrandIconArtwork.image(px: px, colors: .green, tileShape: tile)
        cache[px] = image
        return image
    }
}

/// The column every step sits in: centred in the window, left-aligned text inside it.
enum GroveOnboardingMetrics {
    static let columnWidth: CGFloat = 520
    static let columnHeight: CGFloat = 470
}

struct GroveOnboardingColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: GroveOnboardingMetrics.columnWidth, alignment: .leading)
            .frame(height: GroveOnboardingMetrics.columnHeight, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Welcome

struct GroveOnboardingWelcome: View {
    var onStart: () -> Void = {}
    var nextName = ""
    @Environment(\.groveTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            GroveAppIconTile(size: 96).padding(.bottom, 26)
            Text("Steno")
                .groveFont(26, .semibold)
                .tracking(-0.3)
                .foregroundStyle(theme.inkColor)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            Text("Hold a key and speak. Your words appear where you’re typing.\nEverything is heard and written on this Mac.")
                .multilineTextAlignment(.center)
                .groveFont(14)
                .lineSpacing(3)
                .foregroundStyle(theme.ink2Color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 30)
            Button("Get Started", action: onStart)
                .buttonStyle(.grove(.primary, .large))
                .groveFocusEffectsOff()
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Continues to \(nextName)")
                .accessibilityIdentifier("onboarding.start")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Permissions

/// One permission row: a plain symbol, the name and why, and its state on the right.
struct GroveOnboardingPermissionRow: View {
    enum State: Equatable {
        case allowed
        /// The row being asked for: Allow…
        case allow
        /// Asked and refused: macOS has to be told in System Settings.
        case openSettings
        /// Not yet; names what comes first.
        case later(after: String)
    }

    /// The row's state from what macOS reports. Only the next permission still to allow is
    /// asked for; the ones after it say what they follow. Granted is granted, in any order.
    static func state(
        status: PermissionDiagnostics.AccessStatus, hasBeenAsked: Bool, isNext: Bool, nextTitle: String
    ) -> State {
        let presentation = PermissionRow.presentation(for: status, hasBeenAsked: hasBeenAsked)
        if presentation == .allowed { return .allowed }
        guard isNext else { return .later(after: nextTitle) }
        return presentation == .notAllowed ? .openSettings : .allow
    }

    let symbol: String
    let title: String
    let reason: String
    let state: State
    var onAllow: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    @Environment(\.groveTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .groveFont(17)
                .foregroundStyle(isLater ? theme.ink3Color : theme.ink2Color)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .groveFont(13, .semibold)
                    .foregroundStyle(isLater ? theme.ink3Color : theme.inkColor)
                Text(reason)
                    .groveFont(12)
                    .foregroundStyle(theme.ink3Color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isCurrent ? theme.inkColor.opacity(0.04) : .clear))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(spoken)")
    }

    private var isLater: Bool {
        if case .later = state { return true }
        return false
    }

    private var isCurrent: Bool {
        state == .allow || state == .openSettings
    }

    private var spoken: String {
        switch state {
        case .allowed: "allowed"
        case .allow: "not asked yet"
        case .openSettings: "not allowed"
        case .later(let first): "after \(first)"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .allowed:
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                Text("Allowed").groveFont(12, .medium)
            }
            .foregroundStyle(theme.accentColor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Allowed")
        case .allow:
            Button("Allow…", action: onAllow)
                .buttonStyle(.grove(.primary, .regular))
                .groveFocusEffectsOff()
                .accessibilityLabel("Allow \(title)")
        case .openSettings:
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    Text("Not allowed").groveFont(12, .medium)
                }
                .foregroundStyle(theme.cautionColor)
                Button("Open System Settings", action: onOpenSettings)
                    .buttonStyle(.grove(.outline, .regular))
                    .groveFocusEffectsOff()
                    .accessibilityLabel("Open System Settings for \(title)")
            }
        case .later(let first):
            Text("After \(first)")
                .groveFont(12)
                .foregroundStyle(theme.ink3Color)
        }
    }
}

/// The permissions step: the three rows in order, and the speech model only when it is missing.
struct GrovePermissionsStep: View {
    struct Row: Identifiable {
        let permission: OnboardingPermission
        let state: GroveOnboardingPermissionRow.State
        var id: OnboardingPermission { permission }
    }

    let rows: [Row]
    let speechModelReady: Bool
    var onAllow: (OnboardingPermission) -> Void = { _ in }
    var onOpenSettings: (OnboardingPermission) -> Void = { _ in }
    var onOpenSpeechModelSettings: () -> Void = {}
    @Environment(\.groveTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Three permissions")
                .groveFont(20, .semibold)
                .foregroundStyle(theme.inkColor)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            Text("Steno asks for each one when you click Allow. You can change them later in System Settings.")
                .groveFont(13)
                .lineSpacing(2)
                .foregroundStyle(theme.ink2Color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 26)
            VStack(spacing: 6) {
                ForEach(rows) { row in
                    GroveOnboardingPermissionRow(
                        symbol: row.permission.symbolName,
                        title: row.permission.title,
                        reason: row.permission.reason,
                        state: row.state,
                        onAllow: { onAllow(row.permission) },
                        onOpenSettings: { onOpenSettings(row.permission) }
                    )
                }
                if !speechModelReady {
                    speechModelRow
                }
            }
        }
    }

    /// Not drawn in the lab: the one state where the included model is missing.
    private var speechModelRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu")
                .groveFont(17)
                .foregroundStyle(theme.ink2Color)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speech model").groveFont(13, .semibold).foregroundStyle(theme.inkColor)
                Text("Steno needs a speech model to dictate. Choose or download one in Settings.")
                    .groveFont(12)
                    .foregroundStyle(theme.ink3Color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    Text("Not found").groveFont(12, .medium)
                }
                .foregroundStyle(theme.cautionColor)
                Button("Open Settings", action: onOpenSpeechModelSettings)
                    .buttonStyle(.grove(.outline, .regular))
                    .groveFocusEffectsOff()
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

extension OnboardingPermission {
    var symbolName: String {
        switch self {
        case .microphone: "mic"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        }
    }

    /// Why Steno asks, in the quiet design's words. Accessibility says what it is not used for.
    var reason: String {
        switch self {
        case .microphone: "To hear you while you dictate."
        case .accessibility: "To insert your words where you’re typing. Steno reads nothing else on screen unless you turn on nearby-text continuation."
        case .inputMonitoring: "To notice the dictation key in any app. It sees that a key was pressed, never which one."
        }
    }
}

// MARK: - First dictation

/// The practice box and the lines around it. The box stays where it is in every phase; the
/// mark above the title appears only when the dictation is done, in space kept for it.
struct GroveOnboardingFirstDictation: View {
    let phase: OnboardingDictationPhase
    let entry: TranscriptEntry?
    let handsFreeKeyName: String?
    /// Hold Option is on in Settings › Recording.
    var optionHold = true
    var onOpenMicrophoneSettings: () -> Void = {}
    @Environment(\.groveTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let boxHeight: CGFloat = 110

    private var isDone: Bool { phase == .done }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                Color.clear
                if isDone {
                    GroveQuill(motion: .written, colors: .flat(barbs: theme.accent.opacity(0.7).nsColor, shaft: theme.accent.nsColor))
                        .frame(width: 40, height: 40)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .frame(height: 40)
            .padding(.bottom, 14)
            Text(isDone ? "That’s your first dictation" : "Try it here")
                .groveFont(20, .semibold)
                .foregroundStyle(theme.inkColor)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            subtitle
                .groveFont(13)
                .frame(minHeight: 22, alignment: .topLeading)
                .padding(.bottom, 14)
            box
            Text(noteUnderBox)
                .groveFont(12)
                .foregroundStyle(theme.ink3Color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    // MARK: Subtitle

    @ViewBuilder
    private var subtitle: some View {
        if isDone {
            doneSubtitle
        } else if let start = Self.start(optionHold: optionHold, handsFreeKeyName: handsFreeKeyName) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(start.before)
                    GroveKeycap(start.key)
                    Text(start.after)
                }
                .foregroundStyle(theme.ink2Color)
                .fixedSize()
                Text("\(start.before) \(start.key) \(start.after)")
                    .foregroundStyle(theme.ink2Color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(Self.shortcutsOff)
                .foregroundStyle(theme.ink2Color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The practice line around its key: hold Option when that shortcut is on, otherwise press
    /// the hands-free key. Nil when neither shortcut is on.
    static func start(optionHold: Bool, handsFreeKeyName: String?) -> (before: String, key: String, after: String)? {
        if optionHold { return ("Click the box, hold", "⌥ Option", "and say a sentence. Let go when you’re done.") }
        guard let key = handsFreeKeyName else { return nil }
        return ("Click the box, press", key, "and say a sentence. Press it again when you’re done.")
    }

    static let shortcutsOff = "Shortcuts are off. Turn one on in Settings › Recording to try it here."

    /// What VoiceOver says about the empty box.
    static func waitingLabel(optionHold: Bool, handsFreeKeyName: String?) -> String {
        if optionHold { return "First dictation. Hold Option and speak." }
        guard let key = handsFreeKeyName else { return "First dictation. " + shortcutsOff }
        return "First dictation. Press \(key) and speak."
    }

    /// After a capture with no speech: holding longer helps only when Option is held.
    static func noSpeechText(optionHold: Bool) -> String {
        optionHold
            ? "No speech detected. Hold ⌥ a moment longer and speak at your normal volume."
            : "No speech detected. Speak at your normal volume and try again."
    }

    /// "Heard and written in 1.1 seconds, on this Mac." with the measured time; the number is
    /// left out when the dictation has none.
    private var doneSubtitle: some View {
        Group {
            if let seconds = Self.secondsText(for: entry) {
                Text("Heard and written in ").foregroundColor(theme.ink2Color)
                    + Text(seconds).foregroundColor(theme.inkColor).fontWeight(.medium)
                    + Text(", on this Mac.").foregroundColor(theme.ink2Color)
            } else {
                Text("Heard and written on this Mac.").foregroundColor(theme.ink2Color)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// From the request to stop to the text being written, as the dictation's record keeps it.
    static func secondsText(for entry: TranscriptEntry?) -> String? {
        guard let milliseconds = entry?.record?.endToEndMS, milliseconds > 0 else { return nil }
        let seconds = Double(milliseconds) / 1000
        return seconds < 10 ? String(format: "%.1f seconds", seconds) : "\(Int(seconds.rounded())) seconds"
    }

    private var noteUnderBox: String {
        switch phase {
        case .listening(handsFree: true):
            let key = handsFreeKeyName ?? "the hands-free key"
            return "Listening. Press \(key) again when you’re done."
        case .done:
            return "Use the same key in any app. Every dictation is saved in History."
        default:
            return "While you speak, Steno shows a small island at the top of your screen."
        }
    }

    // MARK: Box

    private var box: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(theme.inkColor.opacity(0.04))
            shape.strokeBorder(borderColor, lineWidth: 1)
            boxContent
                .padding(16)
        }
        .frame(height: Self.boxHeight)
        .accessibilityElement(children: .contain)
    }

    private var borderColor: Color {
        if isDone { return theme.accent.opacity(0.45).color }
        return theme.increaseContrast ? theme.ink3Color : theme.inkColor.opacity(0.08)
    }

    @ViewBuilder
    private var boxContent: some View {
        switch phase {
        case .done:
            let text = entry?.cleanText ?? ""
            Text(text)
                .groveFont(15)
                .lineSpacing(3)
                .foregroundStyle(theme.inkColor)
                .groveTextDirection(rightToLeft: GrovePreviewText.isRightToLeft(text))
        case .listening:
            HStack(spacing: 8) {
                Circle().fill(theme.accentColor).frame(width: 7, height: 7)
                Text("Listening…").groveFont(15).foregroundStyle(theme.ink2Color)
            }
            .accessibilityElement(children: .combine)
        case .transcribing:
            Text("Transcribing…").groveFont(15).foregroundStyle(theme.ink2Color)
        case .noSpeech:
            Label(Self.noSpeechText(optionHold: optionHold), systemImage: "mic")
                .groveFont(13)
                .foregroundStyle(theme.ink2Color)
                .fixedSize(horizontal: false, vertical: true)
        case .microphoneOff:
            VStack(alignment: .leading, spacing: 10) {
                Label("Microphone access is off, so Steno can’t hear you.", systemImage: "mic.slash")
                    .groveFont(13)
                    .foregroundStyle(theme.cautionColor)
                Button("Open System Settings", action: onOpenMicrophoneSettings)
                    .buttonStyle(.grove(.outline, .small))
                    .groveFocusEffectsOff()
            }
        case .waiting:
            HStack(spacing: 0) {
                Rectangle().fill(theme.accentColor).frame(width: 1.5, height: 18).accessibilityHidden(true)
                Text(" Your words appear here").groveFont(15).foregroundStyle(theme.ink3Color)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.waitingLabel(optionHold: optionHold, handsFreeKeyName: handsFreeKeyName))
        }
    }
}

// MARK: - Buttons

/// Continue while a permission is still open: a muted pill, still available.
struct GroveMutedPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration)
    }

    private struct Pill: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.groveTheme) private var theme

        var body: some View {
            let shape = Capsule()
            configuration.label
                .groveFont(13, .medium)
                .foregroundStyle(theme.ink2Color)
                .padding(.horizontal, 18)
                .frame(minHeight: 32)
                .background(shape.fill(theme.inkColor.opacity(configuration.isPressed ? 0.10 : 0.06)))
                .contentShape(shape)
        }
    }
}
