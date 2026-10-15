import SwiftUI
import StenoKit

struct EngineSettingsSection: View {
    @Binding var preferences: AppPreferences
    let controller: DictationController
    var hasUnsavedChanges = false
    @State private var setupCheckStages: [WhisperSetupCheckStage] = []
    @State private var isTesting = false
    @State private var showsAdvanced = false
    @Environment(\.quillTheme) private var theme
    private let compatibilityService = try? WhisperCompatibilityService.bundled()

    init(
        preferences: Binding<AppPreferences>,
        controller: DictationController,
        hasUnsavedChanges: Bool = false
    ) {
        _preferences = preferences
        self.controller = controller
        self.hasUnsavedChanges = hasUnsavedChanges
    }

    #if DEBUG
    init(
        preferences: Binding<AppPreferences>,
        controller: DictationController,
        previewSetupCheckStages: [WhisperSetupCheckStage]
    ) {
        self.init(preferences: preferences, controller: controller)
        _setupCheckStages = State(initialValue: previewSetupCheckStages)
        _showsAdvanced = State(initialValue: true)
    }
    #endif

    static let intro = "Turns your recording into text on this Mac. Steno goes online only to download a model, and checks each download against the published file. A download starts right away, isn’t part of unsaved changes, and switches Steno to that model when it finishes."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .engine, intro: Self.intro)
            HStack(spacing: 16) {
                Text(hardwareLine)
                    .settingsFont(.caption)
                    .foregroundStyle(theme.ink3)
                    .accessibilityLabel("This Mac: \(hardwareLine)")
            }
            .padding(.top, -4)
            .padding(.bottom, 6)
            SettingsCard {
                ForEach(controller.whisperModelOptions) { option in
                    modelRow(option)
                }
            }
            if let message = generalModelMessage {
                SettingsFootnote(
                    text: message,
                    systemImage: controller.modelDownloadMessageIsError ? "exclamationmark.triangle" : nil
                )
                .foregroundStyle(controller.modelDownloadMessageIsError ? theme.caution : theme.ink3)
            }
            SettingsCard {
                SettingsToggleRow(
                    label: "Skip silence",
                    help: "Uses the included voice-detection model so pauses and background noise aren’t transcribed.",
                    isOn: $preferences.dictation.vadEnabled
                )
                testSetupRow
                advancedRow
            }
            .padding(.top, 8)
        }
    }

    // MARK: Models

    private func modelRow(_ option: WhisperModelOption) -> some View {
        SettingsRow(
            label: option.title,
            help: Self.description(for: option.modelID)
        ) {
            badges(for: option)
        } control: {
            HStack(spacing: 8) {
                modelAction(option)
                if option.source == .downloaded {
                    downloadedModelMenu(for: option)
                }
            }
        }
    }

    /// Badges sit after the model name on its first line.
    @ViewBuilder
    private func badges(for option: WhisperModelOption) -> some View {
        HStack(spacing: 6) {
            if option.source == .bundled {
                ModelBadge(text: "Included", isAccent: false)
            }
            if option.isRecommended {
                ModelBadge(text: "Recommended for this Mac", isAccent: true)
            }
        }
    }

    @ViewBuilder
    private func modelAction(_ option: WhisperModelOption) -> some View {
        if controller.activeModelDownloadID == option.modelID {
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink2)
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
                    .frame(width: 240)
                    .accessibilityLabel("Downloading \(option.title)")
            }
        } else if option.isActive {
            SettingsStatusLabel(text: "In use", tone: .ok)
        } else if failedDownloadID == option.modelID {
            HStack(spacing: 8) {
                SettingsStatusLabel(text: "The download didn’t finish", tone: .caution)
                Button("Try Again") { controller.downloadWhisperModel(option.modelID) }
                    .settingsButton(.secondary)
                    .disabled(controller.activeModelDownloadID != nil)
            }
        } else if option.isInstalled {
            Button("Use") { controller.activateWhisperModel(option.modelID) }
                .settingsButton(.secondary)
                .disabled(hasUnsavedChanges || controller.activeModelDownloadID != nil)
                .help(hasUnsavedChanges ? "Save or discard your changes before switching models." : "")
                .accessibilityLabel("Use \(option.title)")
        } else {
            Button("Download") { controller.downloadWhisperModel(option.modelID) }
                .settingsButton(.secondary)
                .disabled(controller.activeModelDownloadID != nil)
                .accessibilityLabel("Download \(option.title)")
        }
    }

    private func downloadedModelMenu(for option: WhisperModelOption) -> some View {
        Menu {
            Button("Download Again") { controller.downloadWhisperModel(option.modelID) }
            Button("Remove", role: .destructive) { controller.removeDownloadedModel(option.modelID) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(theme.ink3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(hasUnsavedChanges || controller.activeModelDownloadID != nil)
        .help("Download \(option.title) again or remove it")
        .accessibilityLabel("More actions for \(option.title)")
    }

    /// The model whose last download failed, read from the failure message.
    private var failedDownloadID: WhisperModelID? {
        guard controller.modelDownloadMessageIsError else { return nil }
        return WhisperModelID.allCases.first {
            controller.modelDownloadMessage.hasPrefix("Couldn't download \(WhisperModelCatalog.title(for: $0)).")
        }
    }

    /// Model messages that aren't already shown on a row.
    private var generalModelMessage: String? {
        let message = controller.modelDownloadMessage
        guard !message.isEmpty, failedDownloadID == nil, controller.activeModelDownloadID == nil else { return nil }
        return message
    }

    static func description(for modelID: WhisperModelID) -> String {
        switch modelID {
        case .baseEn: "Lightest download, lowest quality · 148 MB"
        case .smallEn: "Balanced speed and accuracy · 488 MB"
        case .mediumEn: "Better accuracy, larger download · 1.5 GB"
        case .largeV3Turbo: "Best quality, biggest download · 1.6 GB"
        }
    }

    private var hardwareLine: String {
        if controller.isIsolatedPreview { return "Apple M3 Pro · 18 GB memory" }
        guard let profile = WhisperCompatibilityService.currentHardwareProfile() else { return "Unknown Mac" }
        return "\(Self.chipName(profile.chipClass)) · \(profile.memoryGB) GB memory"
    }

    /// "m3-pro" reads as "Apple M3 Pro".
    static func chipName(_ chip: AppleSiliconChipClass) -> String {
        let words = chip.rawValue.split(separator: "-").map { word in
            word.count <= 2 ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }
        return "Apple " + words.joined(separator: " ")
    }

    // MARK: Test and advanced

    private var testSetupRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: "Test setup", help: "Transcribes a one-second test clip with these settings.") {
                Button {
                    runTestSetup()
                } label: {
                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test")
                    }
                }
                .settingsButton(.secondary)
                .disabled(isTesting || controller.isRecording || whisperCLIPathError != nil || modelPathError != nil)
                .accessibilityLabel(isTesting ? "Testing setup" : "Test setup")
            }
            if !setupCheckStages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(setupCheckStages.enumerated()), id: \.offset) { _, stage in
                        setupCheckRow(stage)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var advancedRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showsAdvanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Advanced").settingsFont(.label).foregroundStyle(theme.ink)
                        Text("Tool and model paths, thread count. For troubleshooting.")
                            .settingsFont(.caption)
                            .foregroundStyle(theme.ink3)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink3)
            .accessibilityLabel("Advanced")
            .accessibilityValue(showsAdvanced ? "Expanded" : "Collapsed")
            .padding(.vertical, 12)
            if showsAdvanced {
                advancedFields
                    .padding(.bottom, 16)
            }
        }
    }

    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            pathField("whisper-cli path", text: $preferences.dictation.whisperCLIPath, error: whisperCLIPathError)
            pathField("Model path", text: modelPathBinding, error: modelPathError)
            Stepper(value: $preferences.dictation.threadCount, in: 1...16) {
                Text("Thread count: \(preferences.dictation.threadCount)")
                    .settingsFont(.body)
            }
            // The label beside the arrows is not their name for VoiceOver.
            .accessibilityLabel("Thread count")
            if preferences.dictation.vadEnabled {
                pathField("Voice detection model path", text: $preferences.dictation.vadModelPath, error: nil)
                if let error = vadModelPathError {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SettingsCautionLine(text: error)
                        if let includedVADPath {
                            Button("Use Included Model") {
                                preferences.dictation.vadModelPath = includedVADPath
                            }
                            .settingsButton(.secondary)
                            .fixedSize()
                        }
                    }
                }
            }
            if let status = compatibilityText {
                Text(status)
                    .settingsFont(.caption)
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pathField(_ title: String, text: Binding<String>, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).settingsFont(.caption).foregroundStyle(theme.ink2)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .truncationMode(.middle)
                .labelsHidden()
                .accessibilityLabel(title)
            if let error {
                SettingsCautionLine(text: error)
            }
        }
    }

    private var compatibilityText: String? {
        guard let assessment = compatibilityAssessment else { return nil }
        let modelLabel = assessment.currentModelStatus.modelID.map { WhisperModelCatalog.title(for: $0) }
            ?? StenoDesign.whisperModelDisplayName(for: preferences.dictation.modelPath)
        switch assessment.currentModelStatus.level {
        case .validated:
            return "\(modelLabel) is validated for this Mac. \(assessment.currentModelStatus.reason)"
        case .warning:
            return "\(modelLabel) hasn’t been validated for this Mac. \(assessment.currentModelStatus.reason)"
        case .custom:
            return "\(modelLabel) is a custom model. \(assessment.currentModelStatus.reason)"
        }
    }

    private var whisperCLIPathError: String? {
        guard !controller.isIsolatedPreview else { return nil }
        let path = preferences.dictation.whisperCLIPath
        guard !path.isEmpty else { return nil }
        return FileManager.default.fileExists(atPath: path) ? nil : "File not found at this path"
    }

    private var modelPathError: String? {
        guard !controller.isIsolatedPreview else { return nil }
        let path = preferences.dictation.modelPath
        guard !path.isEmpty else { return nil }
        return FileManager.default.fileExists(atPath: path) ? nil : "File not found at this path"
    }

    private var modelPathBinding: Binding<String> {
        Binding(
            get: { preferences.dictation.modelPath },
            set: { preferences.dictation.updateModelPath($0) }
        )
    }

    private var vadModelPathError: String? {
        guard !controller.isIsolatedPreview else { return nil }
        return Self.vadModelPathMessage(
            path: preferences.dictation.vadModelPath,
            fileExists: FileManager.default.fileExists(atPath:),
            includedModelAvailable: includedVADPath != nil
        )
    }

    private var includedVADPath: String? {
        guard !controller.isIsolatedPreview else { return nil }
        return BundledWhisperRuntime.resolvedPaths()?.vadModelPath
    }

    static func vadModelPathMessage(
        path: String,
        fileExists: (String) -> Bool,
        includedModelAvailable: Bool
    ) -> String? {
        let fix = includedModelAvailable
            ? "Enter the path to a voice-detection model file, or use the included one."
            : "Enter the path to a voice-detection model file, or turn off Skip silence."
        guard !path.isEmpty else {
            return "No voice-detection model is set. \(fix)"
        }
        if fileExists(path) { return nil }
        return "Voice-detection model not found. Dictation still works, but silence and background noise are filtered less. \(fix)"
    }

    private var compatibilityAssessment: WhisperCompatibilityAssessment? {
        guard !controller.isIsolatedPreview else { return nil }
        guard let compatibilityService else { return nil }
        return compatibilityService.assessment(
            forModelPath: preferences.dictation.modelPath,
            hardwareProfile: WhisperCompatibilityService.currentHardwareProfile()
        )
    }

    private func setupCheckRow(_ stage: WhisperSetupCheckStage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: setupCheckSymbol(stage.outcome))
                .font(.system(size: 11))
                .foregroundStyle(setupCheckColor(stage.outcome))
                .accessibilityHidden(true)
            Text(stage.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.ink)
            Text(stage.detail)
                .settingsFont(.caption)
                .foregroundStyle(stage.outcome == .failed ? theme.caution : theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title), \(setupCheckOutcomeName(stage.outcome)). \(stage.detail)")
    }

    private func setupCheckSymbol(_ outcome: WhisperSetupCheckStage.Outcome) -> String {
        switch outcome {
        case .passed: "checkmark"
        case .failed: "exclamationmark.triangle"
        case .skipped: "minus"
        }
    }

    private func setupCheckColor(_ outcome: WhisperSetupCheckStage.Outcome) -> Color {
        switch outcome {
        case .passed: theme.ok
        case .failed: theme.caution
        case .skipped: theme.ink3
        }
    }

    private func setupCheckOutcomeName(_ outcome: WhisperSetupCheckStage.Outcome) -> String {
        switch outcome {
        case .passed: "passed"
        case .failed: "failed"
        case .skipped: "skipped"
        }
    }

    private func runTestSetup() {
        isTesting = true
        setupCheckStages = []
        let draft = preferences
        Task {
            setupCheckStages = await controller.runSetupCheck(preferences: draft)
            isTesting = false
        }
    }
}

/// A status word after a model name.
private struct ModelBadge: View {
    let text: String
    let isAccent: Bool
    @Environment(\.quillTheme) private var theme

    /// No chips on rows: status is a coloured word.
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: isAccent ? .medium : .regular))
            .foregroundStyle(isAccent ? theme.accent : theme.ink3)
    }
}
