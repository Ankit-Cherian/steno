import SwiftUI
import StenoKit

struct RecordTab: View {
    @EnvironmentObject private var controller: DictationController
    @ScaledMetric(relativeTo: .largeTitle) private var displayPointSize: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var transcriptPointSize: CGFloat = 20
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
                    if !controller.lastError.isEmpty || !controller.hotkeyRegistrationMessage.isEmpty {
                        recoveryNotice(theme: theme)
                    }
                    dictationLayout(theme: theme, availableSize: geometry.size)

                }
                .frame(maxWidth: 960, alignment: .topLeading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private func dictationLayout(theme: StenoTheme, availableSize: CGSize) -> some View {
        ManuscriptDictationLayout(header: captureHeader(theme: theme), controls: recordingControls(theme: theme),
            shortcuts: shortcutSection(theme: theme), transcript: transcriptSurface(theme: theme, availableHeight: availableSize.height),
            theme: theme, availableSize: availableSize)
    }

    private func captureHeader(theme: StenoTheme) -> some View {
        VStack(alignment: .center, spacing: 12) {
            Text(captureTitle)
                .font(StenoDesign.display(size: min(displayPointSize, 56)))
                .tracking(-0.8)
                .multilineTextAlignment(.center)
                .lineSpacing(1)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if isProcessing || controller.isRecording || needsMicrophone {
                Text(captureExplanation)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var captureActionText: String {
        isProcessing ? "Transcribing" : controller.isRecording ? "Stop & transcribe" : needsMicrophone ? "Review permissions" : "Start dictation"
    }

    private func recordingControls(theme: StenoTheme) -> some View {
        VStack(alignment: .center, spacing: 12) {
            Button {
                if needsMicrophone && !controller.isRecording && !isProcessing {
                    onOpenSettings(.permissions)
                } else if controller.isRecording {
                    controller.stopRecording()
                } else {
                    controller.toggleHandsFree()
                }
            } label: {
                HStack(spacing: 12) {
                    captureGlyph
                    Text(captureActionText)
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.isRecording { controlDetail }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
                .frame(minWidth: 200, minHeight: 56)
                .contentShape(Capsule())

            }
            .buttonStyle(StenoCaptureButtonStyle(theme: theme, isRecording: controller.isRecording))
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
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var captureGlyph: some View {
        if isProcessing {
            ProgressView().controlSize(.small).accessibilityHidden(true)
        } else {
            Image(systemName: controller.isRecording ? "stop.fill" : needsMicrophone ? "mic.slash" : "mic")
                .font(.system(size: 21, weight: .medium))
                .frame(width: 24, height: 24)
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
        VStack(alignment: .center, spacing: 12) {
            shortcutGuide(theme: theme)
            if !controller.isRecording && !isProcessing && controller.status != "Idle" && controller.status != "Ready" && !controller.status.isEmpty {
                Label(controller.status, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel("Last activity: \(controller.status)")
            }
        }
    }

    private var captureTitle: String {
        if isProcessing { return "Preparing your text" }
        if controller.isRecording { return "Listening" }
        if needsMicrophone { return "Set up your mic" }
        return "Ready to dictate"
    }

    private var captureExplanation: String {
        if isProcessing { return "Finishing transcription. Your microphone is off." }
        if controller.isRecording { return "Speak naturally. Stop to insert your words, or cancel to discard this recording." }
        if needsMicrophone { return "Allow microphone access to start your first dictation." }
        return "Hold a shortcut in the app you're writing in, or start a hands-free dictation here."
    }

    private func shortcutGuide(theme: StenoTheme) -> some View {
        VStack(alignment: .center, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { shortcutRows(theme: theme) }
                VStack(alignment: .center, spacing: 10) { shortcutRows(theme: theme) }
            }
            if !controller.preferences.hotkeys.optionPressToTalkEnabled && controller.preferences.hotkeys.handsFreeGlobalKeyCode == nil {
                Text("Global shortcuts are off. Set one in Recording settings to dictate without opening Steno.")
                    .font(.system(size: 13)).foregroundStyle(theme.textDim)
                    .multilineTextAlignment(.center)
            }
            Button("Recording settings") { onOpenSettings(.recording) }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func shortcutRows(theme: StenoTheme) -> some View {
        if controller.preferences.hotkeys.optionPressToTalkEnabled {
            shortcutRow(key: "Option", instruction: "Hold to speak. Release to finish.", theme: theme)
        }
        if let key = controller.preferences.hotkeys.handsFreeGlobalKeyCode.flatMap(keyLabel(for:)) {
            shortcutRow(key: key, instruction: "Press to start or finish.", theme: theme)
        }
    }

    private func shortcutRow(key: String, instruction: String, theme: StenoTheme) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 54)
                .padding(.vertical, 5)
                .background(theme.ink2)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.lineStrong, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(instruction).font(.system(size: 13)).foregroundStyle(theme.textDim)
        }
        .accessibilityElement(children: .combine)
    }

    private func transcriptSurface(theme: StenoTheme, availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Latest transcript")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textDim)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let entry = latestEntry {
                    Button { controller.pasteEntry(entry) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy transcript")
                }
                Button(action: onOpenHistory) {
                    Label("History", systemImage: "arrow.up.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open History")
                .help("Open History")
            }
            if let entry = latestEntry {
                BoundedTranscriptText(
                    text: entry.cleanText.isEmpty ? entry.rawText : entry.cleanText,
                    pointSize: min(transcriptPointSize, 34),
                    maximumHeight: max(96, min(180, availableHeight - 480))
                )
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
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(theme.textDim)
                    .padding(.top, 18)
                Text("No transcript yet")
                    .font(StenoDesign.reading(size: 24))
                    .tracking(-0.6)
                    .lineSpacing(3)
                Text("Start a dictation to see your transcript.")
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func recoveryNotice(theme: StenoTheme) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                recoveryMessage.frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
                recoveryAction
            }
            VStack(alignment: .leading, spacing: 12) {
                recoveryMessage
                recoveryAction
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.amberSoft)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.amber, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var recoveryMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Something needs your attention", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
            if !controller.lastError.isEmpty { Text(controller.lastError).textSelection(.enabled) }
            if !controller.hotkeyRegistrationMessage.isEmpty { Text(controller.hotkeyRegistrationMessage) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recoveryAction: some View {
        Button("Review settings") { onOpenSettings(needsMicrophone ? .permissions : .recording) }
            .buttonStyle(.bordered)
            .fixedSize()
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

private struct BoundedTranscriptText: View {
    let text: String
    let pointSize: CGFloat
    let maximumHeight: CGFloat
    @State private var metrics = TranscriptTextMetrics()

    private var viewportHeight: CGFloat {
        guard metrics.contentHeight > 0 else { return min(96, maximumHeight) }
        guard metrics.contentHeight > maximumHeight else { return metrics.contentHeight }
        let lineAdvance = metrics.twoLineHeight - metrics.oneLineHeight
        guard metrics.oneLineHeight > 0, lineAdvance > 0 else { return maximumHeight }
        let additionalLines = max(0, floor((maximumHeight - metrics.oneLineHeight) / lineAdvance))
        return metrics.oneLineHeight + additionalLines * lineAdvance
    }

    var body: some View {
        ScrollView {
            styledText(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: TranscriptMetricsPreferenceKey.self,
                            value: TranscriptTextMetrics(contentHeight: geometry.size.height))
                    }
                }
        }
        .frame(height: viewportHeight)
        .background(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 0) {
                styledText("Ag")
                    .fixedSize()
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: TranscriptMetricsPreferenceKey.self,
                                value: TranscriptTextMetrics(oneLineHeight: geometry.size.height))
                        }
                    }
                styledText("Ag\nAg")
                    .fixedSize()
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: TranscriptMetricsPreferenceKey.self,
                                value: TranscriptTextMetrics(twoLineHeight: geometry.size.height))
                        }
                    }
            }
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .onPreferenceChange(TranscriptMetricsPreferenceKey.self) { metrics = $0 }
    }

    private func styledText(_ value: String) -> some View {
        Text(value)
            .font(StenoDesign.reading(size: pointSize))
            .tracking(-0.25)
            .lineSpacing(7)
    }
}

private struct TranscriptTextMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var oneLineHeight: CGFloat = 0
    var twoLineHeight: CGFloat = 0
}

private struct TranscriptMetricsPreferenceKey: PreferenceKey {
    static let defaultValue = TranscriptTextMetrics()
    static func reduce(value: inout TranscriptTextMetrics, nextValue: () -> TranscriptTextMetrics) {
        let next = nextValue()
        value.contentHeight = max(value.contentHeight, next.contentHeight)
        value.oneLineHeight = max(value.oneLineHeight, next.oneLineHeight)
        value.twoLineHeight = max(value.twoLineHeight, next.twoLineHeight)
    }
}

private struct StenoCaptureButtonStyle: ButtonStyle {
    let theme: StenoTheme
    let isRecording: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? theme.accentInk : theme.textDim)
            .background(isEnabled ? theme.accent : theme.ink3)
            .clipShape(Capsule())
            .overlay(Capsule()
                .strokeBorder(theme.text.opacity(isHovered && isEnabled ? 0.16 : 0), lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isRecording)
            .onHover { isHovered = $0 }
    }
}
