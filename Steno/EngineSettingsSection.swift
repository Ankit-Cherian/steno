import SwiftUI
import StenoKit

struct EngineSettingsSection: View {
    @Binding var preferences: AppPreferences
    let controller: DictationController
    @State private var testResult: String?
    @State private var testResultIsError = false
    @State private var isTesting = false
    private let compatibilityService = try? WhisperCompatibilityService.bundled()

    var body: some View {
        settingsCard("Engine") {
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

            Toggle("Voice Activity Detection (VAD)", isOn: $preferences.dictation.vadEnabled)
                .font(StenoDesign.bodyEmphasis())

            if preferences.dictation.vadEnabled {
                TextField("VAD model path", text: $preferences.dictation.vadModelPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .truncationMode(.middle)
                if let error = vadModelPathError {
                    HStack(spacing: StenoDesign.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(StenoDesign.caption())
                        Text(error)
                            .font(StenoDesign.caption())
                    }
                    .foregroundStyle(StenoDesign.warning)
                }
            }

            HStack(spacing: StenoDesign.sm) {
                Button {
                    runTestSetup()
                } label: {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: StenoDesign.iconMD, height: StenoDesign.iconMD)
                    } else {
                        Text("Test Setup")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || whisperCLIPathError != nil || modelPathError != nil)
                .accessibilityLabel("Test whisper setup")

                if let result = testResult {
                    Text(result)
                        .font(StenoDesign.caption())
                        .foregroundStyle(testResultIsError ? StenoDesign.error : StenoDesign.success)
                }
            }
        }
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
                    Text(currentModelStatusText)
                        .font(StenoDesign.caption())
                        .foregroundStyle(currentModelStatusColor)
                }
            }
            .padding(.horizontal, StenoDesign.sm)
            .padding(.vertical, StenoDesign.sm)
            .background(StenoDesign.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
        }
    }

    private var whisperCLIPathError: String? {
        let path = preferences.dictation.whisperCLIPath
        guard !path.isEmpty else { return nil }
        return FileManager.default.fileExists(atPath: path) ? nil : "File not found at this path"
    }

    private var modelPathError: String? {
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
        let path = preferences.dictation.vadModelPath
        guard !path.isEmpty else {
            return "VAD model path is empty. Download with: ./models/download-vad-model.sh silero-v6.2.0"
        }
        if FileManager.default.fileExists(atPath: path) { return nil }
        return "VAD model not found. Dictation will work without it, but silence/noise suppression will be weaker. Download with: ./models/download-vad-model.sh silero-v6.2.0"
    }

    private var compatibilityAssessment: WhisperCompatibilityAssessment? {
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

    private func runTestSetup() {
        isTesting = true
        testResult = nil

        Task {
            // Check microphone permission
            let micStatus = PermissionDiagnostics.microphoneStatus()
            guard micStatus == .granted else {
                await MainActor.run {
                    testResult = "Microphone permission not granted."
                    testResultIsError = true
                    isTesting = false
                }
                return
            }

            // Test whisper-cli with --help
            let cliPath = preferences.dictation.whisperCLIPath
            let environment = WhisperRuntimeConfiguration.processEnvironment(
                whisperCLIPath: cliPath,
                modelPath: preferences.dictation.modelPath
            )

            do {
                let result = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: cliPath),
                    arguments: ["--help"],
                    environment: environment,
                    standardOutput: FileHandle.nullDevice,
                    standardError: nil
                )
                let success = result.terminationStatus == 0
                let stderr = String(data: result.standardError, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    if success {
                        testResult = "whisper-cli is working."
                        testResultIsError = false
                        // Auto-clear success after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if testResult == "whisper-cli is working." {
                                testResult = nil
                            }
                        }
                    } else {
                        if let stderr, !stderr.isEmpty {
                            testResult = "whisper-cli exited with code \(result.terminationStatus): \(stderr)"
                        } else {
                            testResult = "whisper-cli exited with code \(result.terminationStatus)."
                        }
                        testResultIsError = true
                    }
                    isTesting = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    testResult = "whisper-cli test cancelled."
                    testResultIsError = true
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Failed to run whisper-cli: \(error.localizedDescription)"
                    testResultIsError = true
                    isTesting = false
                }
            }
        }
    }
}
