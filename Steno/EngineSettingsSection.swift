import SwiftUI
import StenoKit

struct EngineSettingsSection: View {
    @Binding var preferences: AppPreferences
    let controller: DictationController
    var hasUnsavedChanges = false
    @State private var setupCheckStages: [WhisperSetupCheckStage] = []
    @State private var isTesting = false
    @State private var showsAdvanced = false
    private let compatibilityService = try? WhisperCompatibilityService.bundled()

    init(preferences: Binding<AppPreferences>, controller: DictationController, hasUnsavedChanges: Bool = false) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsCard("Available models") { modelLibraryPanel }
            DisclosureGroup("Advanced setup and diagnostics", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("whisper-cli path", text: $preferences.dictation.whisperCLIPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .truncationMode(.middle)
                    if let error = whisperCLIPathError {
                        Text(error)
                            .font(StenoDesign.caption())
                            .foregroundStyle(StenoDesign.error)
                    }

                    TextField("Model path", text: modelPathBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .truncationMode(.middle)
                    if let error = modelPathError {
                        Text(error)
                            .font(StenoDesign.caption())
                            .foregroundStyle(StenoDesign.error)
                    }

                    Stepper(value: $preferences.dictation.threadCount, in: 1...16) {
                        Text("Thread count: \(preferences.dictation.threadCount)")
                    }

                    compatibilityPanel

                    Divider()

                    Toggle("Voice activity detection (VAD)", isOn: $preferences.dictation.vadEnabled)
                        .font(StenoDesign.bodyEmphasis())

                    if preferences.dictation.vadEnabled {
                        TextField("VAD model path", text: $preferences.dictation.vadModelPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .truncationMode(.middle)
                        if let error = vadModelPathError {
                            HStack(alignment: .firstTextBaseline, spacing: StenoDesign.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(StenoDesign.caption())
                                    .accessibilityHidden(true)
                                Text(error)
                                    .font(StenoDesign.caption())
                                    .fixedSize(horizontal: false, vertical: true)
                                if let includedVADPath {
                                    Spacer(minLength: StenoDesign.sm)
                                    Button("Use included model") {
                                        preferences.dictation.vadModelPath = includedVADPath
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .fixedSize()
                                }
                            }
                            .foregroundStyle(StenoDesign.warning)
                        }
                    }

                    VStack(alignment: .leading, spacing: StenoDesign.sm) {
                        HStack(spacing: StenoDesign.sm) {
                            Button {
                                runTestSetup()
                            } label: {
                                if isTesting {
                                    HStack(spacing: StenoDesign.xs) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .frame(width: StenoDesign.iconMD, height: StenoDesign.iconMD)
                                            .accessibilityHidden(true)
                                        Text("Testing…")
                                    }
                                } else {
                                    Text("Test setup")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTesting || controller.isRecording || whisperCLIPathError != nil || modelPathError != nil)
                            .accessibilityLabel(isTesting ? "Testing setup" : "Test setup")

                            Text("Transcribes a one-second test clip with these settings.")
                                .font(StenoDesign.caption())
                                .foregroundStyle(StenoDesign.textSecondary)
                        }

                        if !setupCheckStages.isEmpty {
                            VStack(alignment: .leading, spacing: StenoDesign.xs) {
                                ForEach(Array(setupCheckStages.enumerated()), id: \.offset) { _, stage in
                                    setupCheckRow(stage)
                                }
                            }
                        }
                    }
                }
            .padding(.top, 16)
            }
        }
    }

    @ViewBuilder
    private var modelLibraryPanel: some View {
        VStack(alignment: .leading, spacing: StenoDesign.sm) {
            Text("Start with the included Small model, then download Medium or Large V3 Turbo here when your Mac can handle them.")
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)

            if hasUnsavedChanges {
                Text("Save or discard your pending changes before switching models.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            ForEach(controller.whisperModelOptions) { option in
                HStack(alignment: .center, spacing: StenoDesign.md) {
                    VStack(alignment: .leading, spacing: StenoDesign.xxs) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(option.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(StenoDesign.textPrimary)

                            HStack(spacing: 6) {
                                if option.isRecommended {
                                    StenoBadge(
                                        text: "Recommended",
                                        tone: .accent,
                                        theme: StenoDesign.theme(for: preferences),
                                        compact: true
                                    )
                                }

                                if option.source == .bundled {
                                    StenoBadge(
                                        text: "Included",
                                        tone: .neutral,
                                        theme: StenoDesign.theme(for: preferences),
                                        compact: true
                                    )
                                } else if option.source == .downloaded {
                                    StenoBadge(
                                        text: "Downloaded",
                                        tone: .neutral,
                                        theme: StenoDesign.theme(for: preferences),
                                        compact: true
                                    )
                                }
                            }
                        }

                        Text(option.summary)
                            .font(StenoDesign.caption())
                            .foregroundStyle(StenoDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    if option.source == .downloaded {
                        downloadedModelMenu(for: option)
                    }

                    if option.isActive && controller.activeModelDownloadID != option.modelID {
                        Label("Using", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(StenoDesign.textSecondary)
                            .fixedSize()
                    } else {
                        Button {
                            controller.handleWhisperModelAction(for: option)
                        } label: {
                            if controller.activeModelDownloadID == option.modelID {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: StenoDesign.iconMD, height: StenoDesign.iconMD)
                            } else {
                                Text(buttonLabel(for: option))
                            }
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .accessibilityLabel(
                            controller.activeModelDownloadID == option.modelID
                                ? "Downloading \(option.title)"
                                : "\(buttonLabel(for: option)) \(option.title)"
                        )
                        .disabled(hasUnsavedChanges || option.isActive || (controller.activeModelDownloadID != nil && controller.activeModelDownloadID != option.modelID))
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(StenoDesign.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
            }

            if !controller.modelDownloadMessage.isEmpty {
                ModelActionMessage(
                    message: controller.modelDownloadMessage,
                    isError: controller.modelDownloadMessageIsError
                )
            }
        }
    }

    private func downloadedModelMenu(for option: WhisperModelOption) -> some View {
        Menu {
            Button("Download again") {
                controller.downloadWhisperModel(option.modelID)
            }
            Button("Remove", role: .destructive) {
                controller.removeDownloadedModel(option.modelID)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(StenoDesign.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(hasUnsavedChanges || controller.activeModelDownloadID != nil)
        .help("Download \(option.title) again or remove it")
        .accessibilityLabel("More actions for \(option.title)")
    }

    @ViewBuilder
    private var compatibilityPanel: some View {
        if let assessment = compatibilityAssessment {
            VStack(alignment: .leading, spacing: StenoDesign.sm) {
                if let hardwareProfile = assessment.hardwareProfile {
                    Text("Detected hardware: \(hardwareProfile.chipClass.displayName) · \(hardwareProfile.memoryGB)GB unified memory")
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.textSecondary)
                } else {
                    Text("Detected hardware: unavailable")
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.warning)
                }

                if let recommendedRow = assessment.recommendedRow {
                    VStack(alignment: .leading, spacing: StenoDesign.xxs) {
                        Text("Recommended model: \(recommendedRow.modelID.displayName)")
                            .font(StenoDesign.callout())
                            .foregroundStyle(StenoDesign.textPrimary)
                        Text(recommendedRow.notes)
                            .font(StenoDesign.caption())
                            .foregroundStyle(StenoDesign.textSecondary)
                    }
                } else {
                    Text("No curated recommendation is available for this hardware tier yet.")
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.warning)
                }

                HStack(alignment: .top, spacing: StenoDesign.xs) {
                    Image(systemName: compatibilityIconName)
                        .font(StenoDesign.caption())
                        .foregroundStyle(currentModelStatusColor)
                    Text(currentModelStatusText)
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.textSecondary)
                }
            }
            .padding(.horizontal, StenoDesign.sm)
            .padding(.vertical, StenoDesign.sm)
            .background(StenoDesign.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
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
            : "Enter the path to a voice-detection model file, or turn off voice activity detection."
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

    private var currentModelStatusText: String {
        guard let assessment = compatibilityAssessment else {
            return "Compatibility matrix unavailable."
        }

        let modelLabel = assessment.currentModelStatus.modelID?.displayName
            ?? StenoDesign.whisperModelDisplayName(for: preferences.dictation.modelPath)

        switch assessment.currentModelStatus.level {
        case .validated:
            return "Current model \(modelLabel) is validated for this hardware tier. \(assessment.currentModelStatus.reason)"
        case .warning:
            if assessment.recommendedRow?.modelID == assessment.currentModelStatus.modelID {
                return "Current model \(modelLabel) matches the recommended default for this hardware tier, but it has not completed release signoff yet. \(assessment.currentModelStatus.reason)"
            }
            return "Current model \(modelLabel) is outside the validated matrix for this hardware tier. \(assessment.currentModelStatus.reason)"
        case .custom:
            return "Current model \(modelLabel) is custom or unclassified. \(assessment.currentModelStatus.reason)"
        }
    }

    private var currentModelStatusColor: Color {
        guard let assessment = compatibilityAssessment else {
            return StenoDesign.warning
        }

        switch assessment.currentModelStatus.level {
        case .validated:
            return StenoDesign.success
        case .warning, .custom:
            return StenoDesign.warning
        }
    }

    private var compatibilityIconName: String {
        guard let assessment = compatibilityAssessment else {
            return "exclamationmark.triangle.fill"
        }

        switch assessment.currentModelStatus.level {
        case .validated:
            return "checkmark.seal.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    private func buttonLabel(for option: WhisperModelOption) -> String {
        if option.isInstalled {
            return option.isActive ? "Using" : "Use"
        }
        return "Download"
    }

    private func setupCheckRow(_ stage: WhisperSetupCheckStage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: StenoDesign.xs) {
            Image(systemName: setupCheckSymbol(stage.outcome))
                .font(StenoDesign.caption())
                .foregroundStyle(setupCheckColor(stage.outcome))
                .accessibilityHidden(true)
            Text(stage.title)
                .font(StenoDesign.caption().weight(.medium))
                .foregroundStyle(StenoDesign.textPrimary)
            Text(stage.detail)
                .font(StenoDesign.caption())
                .foregroundStyle(stage.outcome == .failed ? StenoDesign.error : StenoDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title), \(setupCheckOutcomeName(stage.outcome)). \(stage.detail)")
    }

    private func setupCheckSymbol(_ outcome: WhisperSetupCheckStage.Outcome) -> String {
        switch outcome {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func setupCheckColor(_ outcome: WhisperSetupCheckStage.Outcome) -> Color {
        switch outcome {
        case .passed: return StenoDesign.success
        case .failed: return StenoDesign.error
        case .skipped: return StenoDesign.textSecondary
        }
    }

    private func setupCheckOutcomeName(_ outcome: WhisperSetupCheckStage.Outcome) -> String {
        switch outcome {
        case .passed: return "passed"
        case .failed: return "failed"
        case .skipped: return "skipped"
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
