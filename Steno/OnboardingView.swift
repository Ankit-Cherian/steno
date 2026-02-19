import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentStep: OnboardingStep = .welcome
    @State private var whisperCLIPath = ""
    @State private var modelPath = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            progressBar
                .padding(.horizontal, StenoDesign.lg)
                .padding(.top, StenoDesign.lg)

            // Step content
            Group {
                switch currentStep {
                case .welcome:
                    welcomeStep
                case .permissions:
                    permissionsStep
                case .whisperSetup:
                    whisperSetupStep
                case .apiKey:
                    apiKeyStep
                case .featureTour:
                    featureTourStep
                }
            }
            .id(currentStep)
            .transition(stepTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, StenoDesign.xl)

            // Navigation bar
            navigationBar
                .padding(.horizontal, StenoDesign.lg)
                .padding(.bottom, StenoDesign.lg)
        }
        .frame(
            minWidth: StenoDesign.windowMinWidth,
            idealWidth: StenoDesign.windowIdealWidth,
            minHeight: StenoDesign.windowMinHeight,
            idealHeight: StenoDesign.windowIdealHeight
        )
        .background(StenoDesign.background)
        .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85, blendDuration: 0),
            value: currentStep
        )
        .onAppear {
            whisperCLIPath = controller.preferences.dictation.whisperCLIPath
            modelPath = controller.preferences.dictation.modelPath
            apiKey = controller.openAIAPIKey
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: StenoDesign.xs) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                RoundedRectangle(cornerRadius: StenoDesign.radiusTiny)
                    .fill(step.rawValue <= currentStep.rawValue ? StenoDesign.accent : StenoDesign.border)
                    .frame(height: StenoDesign.xs)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: StenoDesign.animationNormal),
                        value: currentStep
                    )
            }
        }
        .accessibilityLabel("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    // MARK: - Step Transition

    private var stepTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: StenoDesign.xl) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 72))
                .foregroundStyle(StenoDesign.accent)
                .accessibilityHidden(true)

            VStack(spacing: StenoDesign.sm) {
                Text("Welcome to Steno")
                    .font(StenoDesign.heading1())
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Private dictation that types into your active app")
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(StenoDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: StenoDesign.md) {
                featureRow(icon: "lock.shield", title: "Private by default", detail: "Audio stays on your Mac. Only transcript text can go to cloud cleanup if you opt in.")
                featureRow(icon: "bolt", title: "Fast", detail: "Whisper.cpp transcribes locally in seconds.")
                featureRow(icon: "text.cursor", title: "Works across apps", detail: "Types or pastes into editors, terminals, and most text fields.")
            }
            .cardStyle()

            Spacer()
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: StenoDesign.md) {
            Image(systemName: icon)
                .font(.system(size: StenoDesign.iconLG))
                .foregroundStyle(StenoDesign.accent)
                .frame(width: StenoDesign.xl)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: StenoDesign.xxs) {
                Text(title)
                    .font(StenoDesign.bodyEmphasis())
                    .foregroundStyle(StenoDesign.textPrimary)
                Text(detail)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
            }
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: StenoDesign.lg) {
            Spacer()

            VStack(spacing: StenoDesign.sm) {
                Text("Permissions")
                    .font(StenoDesign.heading1())
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Steno needs a few permissions to work properly.")
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(StenoDesign.textSecondary)
            }

            VStack(spacing: StenoDesign.sm) {
                PermissionStatusCard(
                    title: "Microphone",
                    description: "Required to capture audio for transcription.",
                    status: controller.microphonePermissionStatus,
                    onRequest: { controller.requestMicrophonePermission() },
                    onOpenSettings: { controller.openMicrophoneSettings() }
                )

                PermissionStatusCard(
                    title: "Accessibility",
                    description: "Lets Steno type or paste into the app you're using.",
                    status: controller.accessibilityPermissionStatus,
                    onRequest: { controller.requestAccessibilityPermission() },
                    onOpenSettings: { controller.openAccessibilitySettings() }
                )

                PermissionStatusCard(
                    title: "Input Monitoring",
                    description: "Lets Steno detect global hotkeys while other apps are focused.",
                    status: controller.inputMonitoringPermissionStatus,
                    onRequest: { controller.requestInputMonitoringPermission() },
                    onOpenSettings: { controller.openInputMonitoringSettings() }
                )
            }

            if controller.microphonePermissionStatus != .granted {
                Text("Microphone access is required to continue.")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.warning)
            }

            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermissionStatuses()
        }
    }

    // MARK: - Step 3: Whisper Setup

    private var whisperSetupStep: some View {
        VStack(spacing: StenoDesign.lg) {
            Spacer()

            VStack(spacing: StenoDesign.sm) {
                Text("Local Transcription Setup")
                    .font(StenoDesign.heading1())
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Confirm the paths to your local whisper-cli binary and model file.")
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(StenoDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: StenoDesign.md) {
                VStack(alignment: .leading, spacing: StenoDesign.xs) {
                    Text("whisper-cli path")
                        .font(StenoDesign.bodyEmphasis())
                        .foregroundStyle(StenoDesign.textPrimary)
                    TextField("Path to whisper-cli binary", text: $whisperCLIPath)
                        .textFieldStyle(.roundedBorder)
                    pathValidationLabel(valid: whisperCLIPathValid)
                }

                VStack(alignment: .leading, spacing: StenoDesign.xs) {
                    Text("Model path")
                        .font(StenoDesign.bodyEmphasis())
                        .foregroundStyle(StenoDesign.textPrimary)
                    TextField("Path to model file", text: $modelPath)
                        .textFieldStyle(.roundedBorder)
                    pathValidationLabel(valid: modelPathValid)
                }
            }
            .cardStyle()

            Spacer()
        }
    }

    private var whisperCLIPathValid: Bool {
        FileManager.default.fileExists(atPath: whisperCLIPath)
    }

    private var modelPathValid: Bool {
        FileManager.default.fileExists(atPath: modelPath)
    }

    private func pathValidationLabel(valid: Bool) -> some View {
        HStack(spacing: StenoDesign.xs) {
            Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(StenoDesign.caption())
                .foregroundStyle(valid ? StenoDesign.success : StenoDesign.error)
            Text(valid ? "File found" : "File not found")
                .font(StenoDesign.caption())
                .foregroundStyle(valid ? StenoDesign.success : StenoDesign.error)
        }
    }

    // MARK: - Step 4: API Key

    private var apiKeyStep: some View {
        VStack(spacing: StenoDesign.lg) {
            Spacer()

            VStack(spacing: StenoDesign.sm) {
                Text("OpenAI API Key")
                    .font(StenoDesign.heading1())
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Cloud text cleanup is optional. Steno works fully in local-only mode without it.")
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(StenoDesign.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: StenoDesign.md) {
                VStack(alignment: .leading, spacing: StenoDesign.xs) {
                    Text("API Key (optional)")
                        .font(StenoDesign.bodyEmphasis())
                        .foregroundStyle(StenoDesign.textPrimary)
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                Text("If provided, Steno sends transcript text (never audio) to OpenAI for cleanup. You can change this later in Settings.")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
            }
            .cardStyle()

            Spacer()
        }
    }

    // MARK: - Step 5: Feature Tour

    private var featureTourStep: some View {
        VStack(spacing: StenoDesign.xl) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(StenoDesign.success)
                .accessibilityHidden(true)

            VStack(spacing: StenoDesign.sm) {
                Text("You're all set!")
                    .font(StenoDesign.heading1())
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Here are a few tips to get started.")
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(StenoDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: StenoDesign.md) {
                tipRow(number: "1", text: "Hold Option to dictate (press-to-talk)")
                tipRow(number: "2", text: "Press F18 to toggle hands-free mode")
                tipRow(number: "3", text: "Check the History tab for past transcripts")
            }
            .cardStyle()

            Spacer()
        }
    }

    private func tipRow(number: String, text: String) -> some View {
        HStack(spacing: StenoDesign.md) {
            Text(number)
                .font(StenoDesign.bodyEmphasis())
                .foregroundStyle(.white)
                .frame(width: StenoDesign.xl, height: StenoDesign.xl)
                .background(StenoDesign.accent)
                .clipShape(Circle())
                .accessibilityHidden(true)

            Text(text)
                .font(StenoDesign.body())
                .foregroundStyle(StenoDesign.textPrimary)
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    goBack()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Go to previous step")
            }

            Spacer()

            if currentStep != .welcome && currentStep != .featureTour && canSkip {
                Button("Skip") {
                    goForward()
                }
                .buttonStyle(.plain)
                .foregroundStyle(StenoDesign.textSecondary)
                .accessibilityLabel("Skip this step")
            }

            if currentStep == .featureTour {
                Button("Get Started") {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .tint(StenoDesign.accent)
                .accessibilityLabel("Finish onboarding and start using Steno")
            } else {
                Button("Continue") {
                    goForward()
                }
                .buttonStyle(.borderedProminent)
                .tint(StenoDesign.accent)
                .disabled(!canContinue)
                .accessibilityLabel("Continue to next step")
            }
        }
    }

    // MARK: - Navigation Logic

    private var canContinue: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .permissions:
            return controller.microphonePermissionStatus == .granted
        case .whisperSetup:
            return whisperCLIPathValid && modelPathValid
        case .apiKey:
            return true
        case .featureTour:
            return true
        }
    }

    private var canSkip: Bool {
        switch currentStep {
        case .welcome, .featureTour:
            return false
        case .permissions, .whisperSetup, .apiKey:
            return true
        }
    }

    private func goForward() {
        guard let nextIndex = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = nextIndex
    }

    private func goBack() {
        guard let prevIndex = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prevIndex
    }

    private func completeOnboarding() {
        // Save paths if changed
        if whisperCLIPath != controller.preferences.dictation.whisperCLIPath {
            controller.preferences.dictation.whisperCLIPath = whisperCLIPath
        }
        if modelPath != controller.preferences.dictation.modelPath {
            controller.preferences.dictation.modelPath = modelPath
        }

        // Save API key if provided
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty && trimmedKey != controller.openAIAPIKey {
            controller.openAIAPIKey = trimmedKey
            controller.saveAPIKey()
        }

        controller.completeOnboarding()
    }
}

// MARK: - Onboarding Step Enum

private enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case permissions = 1
    case whisperSetup = 2
    case apiKey = 3
    case featureTour = 4
}
