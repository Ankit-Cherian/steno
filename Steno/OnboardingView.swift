import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentStep: OnboardingStep = .welcome
    @State private var whisperCLIPath = ""
    @State private var modelPath = ""
    private let bundledRuntime = BundledWhisperRuntime.resolvedPaths()

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)

        VStack(spacing: 0) {
            HStack {
                Text("Steno")
                    .font(StenoDesign.heroSerif(size: 21))
                    .foregroundStyle(theme.text)
                Spacer()
                StenoBadge(text: "Onboarding", tone: .accent, theme: theme, compact: true)
            }
            .padding(.horizontal, 18)
            .frame(height: StenoDesign.titleBarHeight)
            .background(theme.titleBarGradient)

            Divider().overlay(theme.line)

            VStack(spacing: 0) {
                progressBar
                    .padding(.horizontal, StenoDesign.lg)
                    .padding(.top, StenoDesign.lg)

                Group {
                    switch currentStep {
                    case .welcome:
                        welcomeStep
                    case .permissions:
                        permissionsStep
                    case .whisperSetup:
                        whisperSetupStep
                    case .featureTour:
                        featureTourStep
                    }
                }
                .id(currentStep)
                .transition(stepTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, StenoDesign.xl)

                navigationBar
                    .padding(.horizontal, StenoDesign.lg)
                    .padding(.bottom, StenoDesign.lg)
            }
            .background(theme.shellGradient)
        }
        .frame(
            minWidth: StenoDesign.windowMinWidth,
            idealWidth: StenoDesign.windowIdealWidth,
            minHeight: StenoDesign.windowMinHeight,
            idealHeight: StenoDesign.windowIdealHeight
        )
        .background(theme.shellGradient)
        .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85, blendDuration: 0),
            value: currentStep
        )
        .onAppear {
            whisperCLIPath = controller.preferences.dictation.whisperCLIPath
            modelPath = controller.preferences.dictation.modelPath
        }
        .onChange(of: controller.preferences.dictation.whisperCLIPath) { newValue in
            whisperCLIPath = newValue
        }
        .onChange(of: controller.preferences.dictation.modelPath) { newValue in
            modelPath = newValue
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
                featureRow(icon: "lock.shield", title: "Private by default", detail: "Audio and transcript cleanup stay on your Mac.")
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

                Text(whisperSetupDescription)
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(StenoDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: StenoDesign.md) {
                if let recommendedModel = controller.recommendedWhisperModel {
                    recommendedModelCard(recommendedModel)
                }

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

            if bundledRuntime != nil {
                HStack(spacing: StenoDesign.xs) {
                    Image(systemName: "shippingbox.fill")
                        .font(StenoDesign.caption())
                    Text("This build includes Small by default. You can keep going now and still download a better model later in Settings \u{2192} Engine.")
                        .font(StenoDesign.caption())
                }
                .foregroundStyle(StenoDesign.textSecondary)
            }

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

    private var whisperSetupDescription: String {
        if bundledRuntime != nil {
            return "This build already includes a bundled whisper runtime and Small model. Based on your Mac, Steno may recommend downloading a better model before you continue dictating seriously."
        }

        return "Confirm the paths to your local whisper-cli binary and model file. For better silence and background-noise suppression, download the optional VAD model (see Settings \u{2192} Engine after setup)."
    }

    @ViewBuilder
    private func recommendedModelCard(_ option: WhisperModelOption) -> some View {
        VStack(alignment: .leading, spacing: StenoDesign.sm) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: StenoDesign.xxs) {
                    Text("Based on your Mac")
                        .font(StenoDesign.heading3())
                        .foregroundStyle(StenoDesign.textPrimary)

                    if let hardwareSummary = controller.currentHardwareSummary {
                        Text(hardwareSummary)
                            .font(StenoDesign.caption())
                            .foregroundStyle(StenoDesign.textSecondary)
                    }
                }

                Spacer()

                StenoBadge(
                    text: option.title,
                    tone: .accent,
                    theme: StenoDesign.theme(for: controller.preferences),
                    icon: "cpu",
                    compact: true
                )
            }

            Text(controller.recommendedWhisperModelNote ?? option.summary)
                .font(StenoDesign.subheadline())
                .foregroundStyle(StenoDesign.textSecondary)

            HStack(spacing: StenoDesign.sm) {
                if option.isInstalled {
                    Button(option.isActive ? "Using \(option.title)" : "Use \(option.title)") {
                        if !option.isActive {
                            controller.activateWhisperModel(option.modelID)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StenoDesign.accent)
                    .disabled(option.isActive)
                } else {
                    Button {
                        controller.downloadWhisperModel(option.modelID)
                    } label: {
                        if controller.activeModelDownloadID == option.modelID {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: StenoDesign.iconMD, height: StenoDesign.iconMD)
                        } else {
                            Text("Download \(option.title)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StenoDesign.accent)
                    .disabled(controller.activeModelDownloadID != nil)
                }

                Text("You can continue with bundled Small right now.")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
            }

            if !controller.modelDownloadMessage.isEmpty {
                Text(controller.modelDownloadMessage)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
            }
        }
        .cardStyle()
    }

    // MARK: - Step 4: Feature Tour

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
                tipRow(number: "2", text: "Set a hands-free toggle key in Settings")
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
        case .featureTour:
            return true
        }
    }

    private var canSkip: Bool {
        switch currentStep {
        case .welcome, .featureTour:
            return false
        case .permissions, .whisperSetup:
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
            controller.preferences.dictation.updateModelPath(modelPath)
        }

        controller.completeOnboarding()
    }
}

// MARK: - Onboarding Step Enum

private enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case permissions = 1
    case whisperSetup = 2
    case featureTour = 3
}
