import SwiftUI
import StenoKit

struct RecordTab: View {
    @EnvironmentObject private var controller: DictationController
    @ScaledMetric(relativeTo: .largeTitle) private var displayPointSize: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var transcriptPointSize: CGFloat = 21
    var onOpenSettings: (SettingsSection) -> Void = { _ in }
    var onOpenHistory: () -> Void = {}

    private var isProcessing: Bool { controller.recordingLifecycleState == .transcribing }
    private var latestEntry: TranscriptEntry? { controller.recentEntries.first }
    private var needsMicrophone: Bool { controller.microphonePermissionStatus != .granted }

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("DICTATE")
                            .font(StenoDesign.mono(size: 10, weight: .semibold))
                            .tracking(1.5)
                        Spacer()
                        Label("On this Mac", systemImage: "lock")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(theme.textDim)
                    if !controller.lastError.isEmpty || !controller.hotkeyRegistrationMessage.isEmpty {
                        recoveryNotice(theme: theme)
                    }
                    dictationLayout(theme: theme, availableSize: geometry.size)

                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func dictationLayout(theme: StenoTheme, availableSize: CGSize) -> some View {
        switch StenoDesign.direction {
        case .signal:
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 26) {
                    captureHeader(theme: theme)
                    recordingControls(theme: theme)
                    shortcutSection(theme: theme)
                }
                .frame(width: min(350, max(285, (availableSize.width - 92) * 0.45)), alignment: .leading)
                transcriptSurface(theme: theme, availableHeight: availableSize.height)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .manuscript:
            ManuscriptDictationLayout(header: captureHeader(theme: theme), controls: recordingControls(theme: theme),
                shortcuts: shortcutSection(theme: theme), transcript: transcriptSurface(theme: theme, availableHeight: availableSize.height),
                theme: theme, availableSize: availableSize)
        case .current:
            CurrentDictationLayout(header: captureHeader(theme: theme), controls: recordingControls(theme: theme),
                shortcuts: shortcutSection(theme: theme), transcript: transcriptSurface(theme: theme, availableHeight: availableSize.height),
                theme: theme, availableSize: availableSize)
        }
    }

    private func captureHeader(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(captureTitle)
                .font(StenoDesign.display(size: min(displayPointSize, 68)))
                .tracking(StenoDesign.direction == .signal ? -2.2 : -1.5)
                .lineSpacing(-3)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(captureExplanation)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var captureActionText: String {
        isProcessing ? "Transcribing" : controller.isRecording ? "Stop & transcribe" : needsMicrophone ? "Review permissions" : "Start dictation"
    }

    private func recordingControls(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if needsMicrophone && !controller.isRecording && !isProcessing {
                    onOpenSettings(.permissions)
                } else if controller.isRecording {
                    controller.stopRecording()
                } else {
                    controller.toggleHandsFree()
                }
            } label: {
                if StenoDesign.direction == .signal {
                    HStack(spacing: 16) {
                        captureGlyph
                        VStack(alignment: .leading, spacing: 7) {
                            Text(captureActionText).font(.system(size: 15, weight: .semibold))
                            controlDetail
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                    .contentShape(Rectangle())
                } else {
                    VStack(spacing: 12) {
                        captureGlyph
                        Text(captureActionText)
                            .font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if controller.isRecording { controlDetail }
                    }
                    .padding(18)
                    .frame(width: 156, height: 156)
                    .contentShape(Circle())
                }
            }
            .buttonStyle(StenoCaptureButtonStyle(theme: theme, isRecording: controller.isRecording,
                heroStyle: controller.preferences.appearance.recordHeroStyle))
            .disabled(isProcessing)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityIdentifier("record.primary")
            if controller.isRecording {
                Button("Cancel recording", role: .cancel) { controller.cancelActiveRecording() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .help("Discard this recording without inserting text")
            }
        }
        .frame(maxWidth: .infinity, alignment: StenoDesign.direction == .signal ? .leading : .center)
    }

    @ViewBuilder
    private var captureGlyph: some View {
        if isProcessing {
            ProgressView().controlSize(.small).accessibilityHidden(true)
        } else {
            Image(systemName: controller.isRecording ? "stop.fill" : needsMicrophone ? "mic.slash" : "mic")
                .font(.system(size: StenoDesign.direction == .signal ? 27 : 31, weight: .medium))
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var controlDetail: some View {
        if controller.isRecording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsedText(at: context.date))
                    .font(StenoDesign.mono(size: 12)).monospacedDigit()
            }
        } else {
            Text(isProcessing ? "Recording has stopped" : needsMicrophone ? "Microphone access needed" : "Hands-free")
                .font(.system(size: 12))
        }
    }

    private func shortcutSection(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            shortcutGuide(theme: theme)
            if !controller.isRecording && !isProcessing && controller.status != "Idle" && !controller.status.isEmpty {
                Label(controller.status, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel("Last activity: \(controller.status)")
            }
            Text("Audio and transcription stay on your Mac.")
                .font(.system(size: 11)).foregroundStyle(theme.textDim)
        }
    }

    private var captureTitle: String {
        if StenoDesign.direction == .signal {
            if isProcessing { return "PREPARING\nYOUR TEXT." }
            if controller.isRecording { return "LISTENING." }
            if needsMicrophone { return "SET UP\nYOUR MIC." }
            return "READY TO\nDICTATE."
        }
        if isProcessing { return "Preparing your\ntranscript." }
        if controller.isRecording { return "Listening." }
        if needsMicrophone { return "Set up\nyour mic." }
        return "Ready to\ndictate."
    }

    private var captureExplanation: String {
        if isProcessing { return "Preparing your final transcript locally. Your microphone is no longer recording." }
        if controller.isRecording { return "Speak naturally. Stop to insert your words, or cancel to discard this recording." }
        if needsMicrophone { return "Allow microphone access to start your first dictation." }
        return "Hold a shortcut in the app you're writing in, or start a hands-free dictation here."
    }

    private func shortcutGuide(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("From any app").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Recording settings") { onOpenSettings(.recording) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            if controller.preferences.hotkeys.optionPressToTalkEnabled {
                shortcutRow(key: "Option", instruction: "Hold to speak. Release to finish.", theme: theme)
            }
            if let key = controller.preferences.hotkeys.handsFreeGlobalKeyCode.flatMap(keyLabel(for:)) {
                shortcutRow(key: key, instruction: "Press to start. Press again to finish.", theme: theme)
            }
            if !controller.preferences.hotkeys.optionPressToTalkEnabled && controller.preferences.hotkeys.handsFreeGlobalKeyCode == nil {
                Text("Global shortcuts are off. Set one in Recording settings to dictate without opening Steno.")
                    .font(.system(size: 13)).foregroundStyle(theme.textDim)
            }
        }
    }

    private func shortcutRow(key: String, instruction: String, theme: StenoTheme) -> some View {
        HStack(spacing: 14) {
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 68)
                .padding(.vertical, 5)
                .background(theme.ink2)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.lineStrong, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(instruction).font(.system(size: 13)).foregroundStyle(theme.textDim)
        }
        .accessibilityElement(children: .combine)
    }

    private func transcriptSurface(theme: StenoTheme, availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("LATEST TRANSCRIPT")
                    .font(StenoDesign.mono(size: 10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(theme.textDim)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: onOpenHistory) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open History")
                .help("Open History")
            }
            if let entry = latestEntry {
                ScrollView {
                    Text(entry.cleanText.isEmpty ? entry.rawText : entry.cleanText)
                        .font(StenoDesign.reading(size: min(transcriptPointSize, 34)))
                        .tracking(-0.25)
                        .lineSpacing(7)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: StenoDesign.direction == .signal ? max(220, min(430, availableHeight - 290)) : max(140, min(280, availableHeight - 440)))
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label(outcomeLabel(entry.insertionStatus), systemImage: outcomeSymbol(entry.insertionStatus))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(entry.insertionStatus == .failed ? theme.danger : theme.text)
                    Text("\(StenoDesign.appDisplayName(for: entry.appBundleID)) · \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.insertionStatus == .failed || entry.insertionStatus == .copiedOnly {
                        Text("Copy and paste these words where you need them.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textDim)
                    }
                }
                Button { controller.pasteEntry(entry) } label: {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(theme.textDim)
                    .padding(.top, 18)
                Text("Your next words\nstart here.")
                    .font(.system(size: 26, weight: .medium))
                    .tracking(-0.6)
                    .lineSpacing(3)
                Text("After dictation, your completed text appears here and in History. Steno inserts it into the app you were using.")
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 24)
                Divider()
                Label("Only completed dictations are saved", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, minHeight: StenoDesign.direction == .signal ? 370 : 0, alignment: .topLeading)
        .padding(StenoDesign.direction == .signal ? 24 : 0)
        .background(StenoDesign.direction == .signal ? theme.ink2 : .clear)
        .clipShape(RoundedRectangle(cornerRadius: StenoDesign.direction == .signal ? 12 : 0))
    }

    private func recoveryNotice(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Something needs your attention", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
            if !controller.lastError.isEmpty { Text(controller.lastError).textSelection(.enabled) }
            if !controller.hotkeyRegistrationMessage.isEmpty { Text(controller.hotkeyRegistrationMessage) }
            Button("Review settings") { onOpenSettings(needsMicrophone ? .permissions : .recording) }
                .buttonStyle(.link)
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.amberSoft)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.amber, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func elapsedText(at date: Date) -> String {
        let elapsed = controller.recordingStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? controller.recordingElapsed
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func outcomeLabel(_ status: InsertionStatus) -> String {
        switch status {
        case .inserted: return "Inserted"
        case .copiedOnly: return "Copied to clipboard"
        case .failed: return "Insertion failed"
        case .noSpeech: return "No speech detected"
        }
    }

    private func outcomeSymbol(_ status: InsertionStatus) -> String {
        switch status {
        case .inserted: return "checkmark.circle"
        case .copiedOnly: return "doc.on.clipboard"
        case .failed: return "exclamationmark.circle"
        case .noSpeech: return "mic.slash"
        }
    }

    private func keyLabel(for keyCode: UInt16) -> String? {
        let codes: [UInt16] = [122, 120, 160, 131, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        return codes.firstIndex(of: keyCode).map { "F\($0 + 1)" }
    }
}

private struct StenoCaptureButtonStyle: ButtonStyle {
    let theme: StenoTheme
    let isRecording: Bool
    let heroStyle: StenoRecordHeroStyle
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var cornerRadius: CGFloat {
        switch StenoDesign.direction {
        case .signal: return isRecording ? 22 : heroStyle == .ring ? 44 : 10
        case .manuscript: return isRecording ? 46 : 78
        case .current: return isRecording ? 30 : heroStyle == .ring ? 78 : 52
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? theme.accentInk : theme.textDim)
            .background(isEnabled ? theme.accent : theme.ink3)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(theme.text.opacity(isHovered && isEnabled ? 0.16 : 0), lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isRecording)
            .onHover { isHovered = $0 }
    }
}
