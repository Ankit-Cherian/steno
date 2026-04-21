import SwiftUI
import StenoKit

private enum RecordHeroState {
    case idle
    case recording
    case transcribing
}

struct RecordTab: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var copied = false

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)
        let heroState = currentHeroState

        VStack(spacing: 0) {
            if hasError {
                errorBanner(theme: theme)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }

            VStack(spacing: 0) {
                topRail(theme: theme)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)

                heroArea(theme: theme, heroState: heroState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                hintStrip(theme: theme)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                composerDock(theme: theme)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
    }

    private var hasError: Bool {
        !controller.lastError.isEmpty || !controller.hotkeyRegistrationMessage.isEmpty
    }

    private var currentHeroState: RecordHeroState {
        if controller.recordingLifecycleState == .transcribing {
            return .transcribing
        }
        return controller.isRecording ? .recording : .idle
    }

    private var latestEntry: TranscriptEntry? {
        controller.recentEntries.first
    }

    private func topRail(theme: StenoTheme) -> some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Text("SESSION")
                    .font(StenoDesign.mono(size: 10, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(theme.textMuted)
                Text(Date.now.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(StenoDesign.mono(size: 11, weight: .regular))
                    .foregroundStyle(theme.textMuted)
                Text("·")
                    .font(StenoDesign.mono(size: 11, weight: .regular))
                    .foregroundStyle(theme.textMuted)
                Text(Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(StenoDesign.mono(size: 11, weight: .regular))
                    .foregroundStyle(theme.textMuted)
            }

            Spacer()

            HStack(spacing: 16) {
                InlineMeterView(label: "MIC", value: micMeterValue, theme: theme)
                InlineMeterView(label: "VAD", value: vadMeterValue, theme: theme)
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .medium))
                    Text("Whisper · \(StenoDesign.whisperModelDisplayName(for: controller.preferences.dictation.modelPath))")
                        .font(StenoDesign.subheadline())
                }
                .foregroundStyle(theme.textMuted)
            }
        }
    }

    private func heroArea(theme: StenoTheme, heroState: RecordHeroState) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldAnimateContinuously(heroState: heroState))) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let preciseElapsed = preciseElapsed(at: context.date)

            ZStack {
                if heroState == .recording {
                    VStack(spacing: 4) {
                        Text(timerText(for: preciseElapsed))
                            .font(StenoDesign.mono(size: 22, weight: .medium))
                            .foregroundStyle(theme.accent)
                        Text(".\(tenthsText(for: preciseElapsed))")
                            .font(StenoDesign.mono(size: 13, weight: .regular))
                            .foregroundStyle(theme.accent.opacity(0.62))
                    }
                    .padding(.top, 18)
                    .frame(maxHeight: .infinity, alignment: .top)
                }

                ZStack(alignment: .topTrailing) {
                    if controller.preferences.appearance.recordHeroStyle == .ring {
                        RingHeroView(
                            state: heroState,
                            theme: theme,
                            phase: phase,
                            reduceMotion: reduceMotion,
                            onToggle: toggleRecord
                        )
                    } else {
                        PillHeroView(
                            state: heroState,
                            theme: theme,
                            phase: phase,
                            reduceMotion: reduceMotion,
                            onToggle: toggleRecord
                        )
                    }

                    if showsCancelControl {
                        RecordingCancelButton(theme: theme) {
                            controller.cancelActiveRecording()
                        }
                        .padding(.top, controller.preferences.appearance.recordHeroStyle == .ring ? 22 : 10)
                        .padding(.trailing, controller.preferences.appearance.recordHeroStyle == .ring ? 44 : 34)
                    }
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 18)
        }
    }

    private func hintStrip(theme: StenoTheme) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 16) {
                HintChip(theme: theme, label: "Hold to talk", keys: ["⌥"])
                HintChip(theme: theme, label: "Hands-free", keys: [controller.preferences.hotkeys.handsFreeGlobalKeyCode.flatMap(keyLabel(for:)) ?? "F5"])
                HintChip(theme: theme, label: "Clear", keys: ["⌘", "⌫"])
            }

            Spacer()

            StenoBadge(
                text: "Local · 0 bytes uploaded",
                tone: .neutral,
                theme: theme,
                icon: "circle.fill",
                compact: true
            )
        }
        .font(StenoDesign.subheadline())
        .foregroundStyle(theme.textMuted)
    }

    private func composerDock(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("LAST TRANSCRIPT")
                    .font(StenoDesign.mono(size: 10, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(theme.textMuted)

                if let latestEntry {
                    StenoBadge(
                        text: StenoDesign.appDisplayName(for: latestEntry.appBundleID),
                        tone: .neutral,
                        theme: theme,
                        icon: "circle.fill",
                        compact: true
                    )

                    StenoBadge(
                        text: copied ? "Copied" : "\(StenoDesign.timeText(for: latestEntry.createdAt)) · \(StenoDesign.relativeDateText(for: latestEntry.createdAt))",
                        tone: copied ? .amber : .neutral,
                        theme: theme,
                        icon: copied ? "checkmark" : "clock",
                        compact: true
                    )
                }

                Spacer()

                if let latestEntry {
                    Text("\(wordCount(for: latestEntry)) words · \(durationText(for: latestEntry.durationMS))")
                        .font(StenoDesign.mono(size: 10, weight: .regular))
                        .foregroundStyle(theme.textMuted)

                    Button {
                        controller.copyEntry(latestEntry)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        Label("Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .ghost))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .overlay(theme.line)

            Text(dockBodyText)
                .font(StenoDesign.body())
                .foregroundStyle(theme.text)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .background(theme.cardGradient)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: theme.accentGlow.opacity(0.18), radius: 24, x: 0, y: -10)
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(theme.accent)
                .frame(width: 42, height: 1)
                .shadow(color: theme.accentGlow, radius: 12)
                .padding(.leading, 16)
        }
    }

    private func errorBanner(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !controller.hotkeyRegistrationMessage.isEmpty {
                Text(controller.hotkeyRegistrationMessage)
                    .font(StenoDesign.caption())
                    .foregroundStyle(theme.danger)
            }

            if !controller.lastError.isEmpty {
                Text(controller.lastError)
                    .font(StenoDesign.caption())
                    .foregroundStyle(theme.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.danger.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.danger.opacity(0.28), lineWidth: StenoDesign.borderThin)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var dockBodyText: String {
        if let latestEntry {
            let text = latestEntry.cleanText.isEmpty ? latestEntry.rawText : latestEntry.cleanText
            return text.isEmpty ? emptyStateHint : text
        }
        return emptyStateHint
    }

    private var emptyStateHint: String {
        if controller.microphonePermissionStatus == .denied {
            return "Microphone access denied. Grant access in Settings to start dictating."
        }

        if controller.microphonePermissionStatus == .unknown {
            return "Grant microphone access to start dictating."
        }

        if let hotkey = controller.preferences.hotkeys.handsFreeGlobalKeyCode.flatMap(keyLabel(for:)) {
            return "Hold Option to dictate, or press \(hotkey) for hands-free."
        }

        return "Hold Option to start dictating."
    }

    private var micMeterValue: Double {
        controller.isRecording ? 0.72 : 0.06
    }

    private var vadMeterValue: Double {
        controller.isRecording ? 0.84 : 0.08
    }

    private func shouldAnimateContinuously(heroState: RecordHeroState) -> Bool {
        !reduceMotion && heroState == .recording
    }

    private func preciseElapsed(at date: Date) -> TimeInterval {
        guard let startedAt = controller.recordingStartedAt else {
            return controller.recordingElapsed
        }
        return max(0, date.timeIntervalSince(startedAt))
    }

    private func timerText(for interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func tenthsText(for interval: TimeInterval) -> String {
        String(Int((interval * 10).rounded(.down)) % 10)
    }

    private func durationText(for durationMS: Int) -> String {
        guard durationMS > 0 else { return "0s" }
        let seconds = Int(round(Double(durationMS) / 1000))
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }

    private func wordCount(for entry: TranscriptEntry) -> Int {
        let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
        return text.split(whereSeparator: \.isWhitespace).count
    }

    private func toggleRecord() {
        guard controller.recordingLifecycleState != .transcribing else { return }
        controller.toggleHandsFree()
    }

    private var showsCancelControl: Bool {
        switch controller.recordingLifecycleState {
        case .recordingHandsFree, .recordingPressToTalk:
            return true
        case .idle, .transcribing:
            return false
        }
    }

    private func keyLabel(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 122: return "F1"
        case 120: return "F2"
        case 160: return "F3"
        case 131: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        default: return nil
        }
    }
}

private struct RecordingCancelButton: View {
    let theme: StenoTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textDim)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(theme.isLight ? 0.84 : 0.08))
                .overlay(
                    Circle()
                        .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
                )
                .clipShape(Circle())
                .contentShape(Circle())
                .shadow(color: .black.opacity(theme.isLight ? 0.12 : 0.28), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel dictation")
        .help("Cancel and discard this transcript")
    }
}

private struct InlineMeterView: View {
    let label: String
    let value: Double
    let theme: StenoTheme

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(StenoDesign.mono(size: 10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(theme.textMuted)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(theme.isLight ? 0.55 : 0.06))
                    .frame(width: 46, height: 3)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.accent.opacity(0.45), theme.accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, 46 * value), height: 3)
            }
        }
    }
}

private struct HintChip: View {
    let theme: StenoTheme
    let label: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
            ForEach(keys, id: \.self) { key in
                StenoKeyCapsule(text: key, theme: theme)
            }
        }
    }
}

private struct PillHeroView: View {
    let state: RecordHeroState
    let theme: StenoTheme
    let phase: TimeInterval
    let reduceMotion: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 28) {
            Button {
                onToggle()
            } label: {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(state == .recording ? theme.accent : theme.heroIdleFill)
                            .frame(width: 56, height: 56)
                            .shadow(color: state == .recording ? theme.accentGlow : .clear, radius: 18)

                        if state == .recording {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(theme.accentInk)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: state == .transcribing ? "waveform.badge.magnifyingglass" : "mic")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(theme.text)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(primaryText)
                            .font(StenoDesign.heroSerif(size: 22))
                            .foregroundStyle(theme.heroText)
                        Text(secondaryText)
                            .font(StenoDesign.mono(size: 10, weight: .medium))
                            .tracking(1.8)
                            .foregroundStyle(theme.heroSubtext)
                    }
                }
                .padding(.horizontal, 28)
                .frame(height: 96)
                .background(
                    ZStack {
                        LinearGradient(
                            colors: [theme.heroSurfaceStart, theme.heroSurfaceEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        RadialGradient(
                            colors: [Color.white.opacity(0.14), .clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 150
                        )
                    }
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(theme.heroOutline, lineWidth: StenoDesign.borderThin)
                )
                .clipShape(Capsule(style: .continuous))
                .shadow(color: .black.opacity(theme.isLight ? 0.18 : 0.35), radius: 24, x: 0, y: 18)
                .shadow(color: theme.accentGlow.opacity(state == .recording ? 0.35 : 0.12), radius: 38, x: 0, y: 0)
            }
            .buttonStyle(PressableButtonStyle())

            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !shouldAnimate)) { context in
                let samples = waveformSamples(at: context.date.timeIntervalSinceReferenceDate)
                Canvas { graphicsContext, size in
                    let barWidth: CGFloat = 2
                    let gap: CGFloat = 3
                    let totalWidth = CGFloat(samples.count) * barWidth + CGFloat(samples.count - 1) * gap
                    let startX = (size.width - totalWidth) / 2

                    for (index, value) in samples.enumerated() {
                        let barHeight = CGFloat(max(3, value * 64))
                        let rect = CGRect(
                            x: startX + CGFloat(index) * (barWidth + gap),
                            y: (size.height - barHeight) / 2,
                            width: barWidth,
                            height: barHeight
                        )
                        let color = state == .recording ? theme.accent.opacity(0.42 + (0.58 * value)) : theme.textDim.opacity(0.34)
                        graphicsContext.fill(RoundedRectangle(cornerRadius: 1.2).path(in: rect), with: .color(color))
                    }
                }
                .frame(width: 280, height: 96)
                .background(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(theme.isLight ? 0.96 : 0.03),
                            Color.white.opacity(theme.isLight ? 0.88 : 0.01)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var shouldAnimate: Bool {
        !reduceMotion && state == .recording
    }

    private var primaryText: String {
        switch state {
        case .idle:
            return "Press to record"
        case .recording:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        }
    }

    private var secondaryText: String {
        switch state {
        case .idle:
            return "OR HOLD ⌥ ANYWHERE"
        case .recording:
            return "SPEAK NATURALLY — PAUSE TO FINISH"
        case .transcribing:
            return "PLEASE WAIT"
        }
    }

    private func waveformSamples(at phase: TimeInterval) -> [Double] {
        (0..<56).map { index in
            if state != .recording {
                return 0.08 + (Double(index % 3) * 0.01)
            }
            let value = 0.35 + 0.58 * abs(sin(phase * 2.8 + Double(index) * 0.38))
            return reduceMotion ? min(value, 0.55) : value
        }
    }
}

private struct RingHeroView: View {
    let state: RecordHeroState
    let theme: StenoTheme
    let phase: TimeInterval
    let reduceMotion: Bool
    let onToggle: () -> Void

    var body: some View {
        ZStack {
            ambientGlow
            dialCanvas
            centerButton
        }
    }

    private var ambientGlow: some View {
        Group {
            if state == .recording {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.accentGlow.opacity(0.36), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 170
                        )
                    )
                    .frame(width: 320, height: 320)
                    .blur(radius: 12)
            }
        }
    }

    private var dialCanvas: some View {
        Canvas { graphicsContext, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            drawTicks(in: &graphicsContext, center: center)
            drawDashedRing(in: &graphicsContext, center: center)
            drawInnerRing(in: &graphicsContext, center: center)
        }
        .frame(width: 380, height: 380)
    }

    private var centerButton: some View {
        Button {
            onToggle()
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(coreFill)
                        .frame(width: 56, height: 56)
                        .shadow(color: state == .recording ? theme.accentGlow : .clear, radius: 20)
                    coreGlyph
                }

                Text(statusText)
                    .font(StenoDesign.mono(size: 10, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(state == .recording ? theme.accent : theme.textMuted)
            }
            .frame(width: 180, height: 180)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [theme.heroOrbSurfaceStart, theme.heroOrbSurfaceEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [Color.white.opacity(0.12), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 120
                    )
                }
            )
            .overlay(
                Circle()
                    .stroke(theme.heroOutline, lineWidth: StenoDesign.borderThin)
            )
            .clipShape(Circle())
            .scaleEffect(coreScale)
            .shadow(color: .black.opacity(theme.isLight ? 0.18 : 0.38), radius: 30, x: 0, y: 20)
            .shadow(color: theme.accentGlow.opacity(state == .recording ? 0.36 : 0.10), radius: 44, x: 0, y: 0)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var coreFill: Color {
        state == .recording ? theme.accent : theme.heroIdleFill
    }

    @ViewBuilder
    private var coreGlyph: some View {
        if state == .recording {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(theme.accentInk)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: state == .transcribing ? "waveform.badge.magnifyingglass" : "mic")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.text)
        }
    }

    private var statusText: String {
        switch state {
        case .recording:
            return "CAPTURING"
        case .transcribing:
            return "PROCESSING"
        case .idle:
            return "IDLE"
        }
    }

    private var coreScale: CGFloat {
        guard state == .recording, !reduceMotion else { return 1 }
        return 1 + CGFloat(0.04 * ((sin(phase * 2) + 1) / 2))
    }

    private func drawTicks(in context: inout GraphicsContext, center: CGPoint) {
        let outerRadius: CGFloat = 168
        let ticks = 60

        for index in 0..<ticks {
            let angle = (Double(index) / Double(ticks)) * .pi * 2 - (.pi / 2)
            let start = CGPoint(
                x: center.x + cos(angle) * 150,
                y: center.y + sin(angle) * 150
            )
            let end = CGPoint(
                x: center.x + cos(angle) * outerRadius,
                y: center.y + sin(angle) * outerRadius
            )
            let isActive = state == .recording && ((sin(phase * 2 + Double(index) * 0.25) + 1) / 2) > 0.45

            var tick = Path()
            tick.move(to: start)
            tick.addLine(to: end)
            context.stroke(
                tick,
                with: .color(isActive ? theme.accent : theme.lineStrong),
                lineWidth: 1.5
            )
        }
    }

    private func drawDashedRing(in context: inout GraphicsContext, center: CGPoint) {
        let ringRadius: CGFloat = 148
        let dashPath = Path(ellipseIn: CGRect(
            x: center.x - ringRadius,
            y: center.y - ringRadius,
            width: ringRadius * 2,
            height: ringRadius * 2
        ))

        context.stroke(
            dashPath,
            with: .color(theme.accent.opacity(state == .recording ? 0.65 : 0.18)),
            style: StrokeStyle(
                lineWidth: 1,
                lineCap: .round,
                dash: [2, 4],
                dashPhase: reduceMotion || state != .recording ? 0 : -phase * 18
            )
        )
    }

    private func drawInnerRing(in context: inout GraphicsContext, center: CGPoint) {
        let rect = CGRect(
            x: center.x - 120,
            y: center.y - 120,
            width: 240,
            height: 240
        )
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(theme.lineStrong),
            lineWidth: 0.5
        )
    }
}
