import SwiftUI
import StenoKit

struct EngineSettingsSection: View {
    @Binding var preferences: AppPreferences
    let controller: DictationController
    @State private var testResult: String?
    @State private var testResultIsError = false
    @State private var isTesting = false

    var body: some View {
        settingsCard("Engine") {
            TextField("whisper-cli path", text: $preferences.dictation.whisperCLIPath)
                .textFieldStyle(.roundedBorder)
            if let error = whisperCLIPathError {
                Text(error)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.error)
            }

            TextField("Model path", text: $preferences.dictation.modelPath)
                .textFieldStyle(.roundedBorder)
            if let error = modelPathError {
                Text(error)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.error)
            }

            Stepper(value: $preferences.dictation.threadCount, in: 1...16) {
                Text("Thread count: \(preferences.dictation.threadCount)")
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

            do {
                let result = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: cliPath),
                    arguments: ["--help"],
                    standardOutput: FileHandle.nullDevice,
                    standardError: FileHandle.nullDevice
                )
                let success = result.terminationStatus == 0
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
                        testResult = "whisper-cli exited with code \(result.terminationStatus)."
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
