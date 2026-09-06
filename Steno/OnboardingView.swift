import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentStep: OnboardingStep = .welcome
    @State private var whisperCLIPath = ""
    @State private var modelPath = ""
    @State private var showAdvancedSetup = false
    private var bundledRuntime: BundledWhisperRuntime.ResolvedPaths? {
        controller.isIsolatedPreview ? nil : BundledWhisperRuntime.resolvedPaths()
    }

    init(initialStep: Int = 0) {
        _currentStep = State(initialValue: OnboardingStep(rawValue: initialStep) ?? .welcome)
    }

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)

        VStack(spacing: 0) {
            HStack {
                Color.clear.frame(width: 64, height: 1)
                Text("Steno")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Text("Setup")
                    .font(StenoDesign.caption())
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 18)
            .frame(height: StenoDesign.titleBarHeight)
            .background(theme.titleBarGradient)

            Divider().overlay(theme.line)

            onboardingLayout(theme: theme)

        }
        .frame(
            minWidth: StenoDesign.windowMinWidth,
            idealWidth: StenoDesign.windowIdealWidth,
            minHeight: StenoDesign.windowMinHeight,
            idealHeight: StenoDesign.windowIdealHeight
        )
        .background(theme.ink0)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: currentStep
        )
        .onAppear {
            whisperCLIPath = controller.preferences.dictation.whisperCLIPath
            modelPath = controller.preferences.dictation.modelPath
            showAdvancedSetup = !whisperCLIPathValid || !modelPathValid
        }
        .onChange(of: controller.preferences.dictation.whisperCLIPath) { newValue in
            whisperCLIPath = newValue
        }
        .onChange(of: controller.preferences.dictation.modelPath) { newValue in
            modelPath = newValue
        }
    }

    private func onboardingLayout(theme: StenoTheme) -> some View {
        ManuscriptOnboardingLayout(
            progress: progressBar,
            content: stepContent,
            navigation: navigationBar,
            theme: theme
        )
    }

    private var stepContent: some View {
        Group {
            switch currentStep {
            case .welcome: welcomeStep
            case .permissions: permissionsStep
            case .whisperSetup: whisperSetupStep
            case .featureTour: featureTourStep
            }
        }
        .id(currentStep)
        .transition(stepTransition)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        let theme = StenoDesign.theme(for: controller.preferences)

        return HStack(spacing: StenoDesign.md) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                VStack(alignment: .leading, spacing: 10) {
                    Text(step.title)
                        .font(.system(size: 12, weight: step == currentStep ? .semibold : .regular))
                        .foregroundStyle(step == currentStep ? theme.text : theme.textDim)
                        .lineLimit(1)

                    RoundedRectangle(cornerRadius: StenoDesign.radiusTiny)
                        .fill(step.rawValue <= currentStep.rawValue ? theme.accent : theme.line)
                        .frame(height: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count): \(currentStep.name)")
    }

    // MARK: - Step Transition

    private var stepTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .opacity.combined(with: .offset(y: 7))
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeading(
                "Welcome to Steno",
                description: "Private dictation that types into your active app."
            )

            VStack(alignment: .leading, spacing: StenoDesign.lg) {
                featureRow(icon: "lock.shield", title: "Private by default", detail: "Audio and transcript cleanup stay on your Mac.")
                Divider().overlay(StenoDesign.border)
                featureRow(icon: "bolt", title: "Choose your pace", detail: "Pick a local speech model to balance speed and accuracy.")
                Divider().overlay(StenoDesign.border)
                featureRow(icon: "text.cursor", title: "Works across apps", detail: "Types or pastes into editors, terminals, and most text fields.")
            }
        }
    }

    private func stepHeading(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: StenoDesign.sm) {
            StenoPageTitle(title)
                .foregroundStyle(StenoDesign.textPrimary)

            Text(description)
                .font(StenoDesign.subheadline())
                .foregroundStyle(StenoDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: StenoDesign.md) {
            Image(systemName: icon)
                .font(.system(size: StenoDesign.iconLG))
                .foregroundStyle(StenoDesign.theme(for: controller.preferences).accent)
                .frame(width: StenoDesign.xl)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: StenoDesign.xxs) {
                Text(title)
                    .font(StenoDesign.bodyEmphasis())
                    .foregroundStyle(StenoDesign.textPrimary)
                Text(detail)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: StenoDesign.lg) {
            stepHeading(
                "Permissions",
                description: "Allow the access needed to record and insert dictation."
            )

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
                    title: "Input monitoring",
                    description: "Lets Steno detect global hotkeys while other apps are focused.",
                    status: controller.inputMonitoringPermissionStatus,
                    onRequest: { controller.requestInputMonitoringPermission() },
                    onOpenSettings: { controller.openInputMonitoringSettings() }
                )
            }

            if controller.microphonePermissionStatus != .granted {
                Label("Allow microphone access to start dictating. You can also finish setup later.", systemImage: "info.circle")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !controller.isIsolatedPreview else { return }
            controller.refreshPermissionStatuses()
        }
    }

    // MARK: - Step 3: Whisper Setup

    private var whisperSetupStep: some View {
        VStack(alignment: .leading, spacing: StenoDesign.lg) {
            stepHeading("Choose your speech model", description: whisperSetupDescription)

            VStack(alignment: .leading, spacing: StenoDesign.md) {
                if let recommendedModel = controller.recommendedWhisperModel {
                    recommendedModelCard(recommendedModel)
                }

                DisclosureGroup("Custom model setup", isExpanded: $showAdvancedSetup) {
                    VStack(alignment: .leading, spacing: StenoDesign.md) {
                        VStack(alignment: .leading, spacing: StenoDesign.xs) {
                            Text("whisper-cli path")
                                .font(StenoDesign.bodyEmphasis())
                                .foregroundStyle(StenoDesign.textPrimary)
                            TextField("Path to whisper-cli binary", text: $whisperCLIPath)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("whisper-cli path")
                            pathValidationLabel(valid: whisperCLIPathValid)
                        }

                        VStack(alignment: .leading, spacing: StenoDesign.xs) {
                            Text("Model path")
                                .font(StenoDesign.bodyEmphasis())
                                .foregroundStyle(StenoDesign.textPrimary)
                            TextField("Path to model file", text: $modelPath)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Model path")
                            pathValidationLabel(valid: modelPathValid)
                        }
                    }
                    .padding(.top, StenoDesign.sm)
                }
                .font(StenoDesign.bodyEmphasis())
                .cardStyle()
            }

            if bundledRuntime != nil {
                Label("Small is included and ready to use. You can choose another model later in Settings \u{2192} Speech model.", systemImage: "shippingbox")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whisperCLIPathValid: Bool {
        controller.isIsolatedPreview || FileManager.default.fileExists(atPath: whisperCLIPath)
    }

    private var modelPathValid: Bool {
        controller.isIsolatedPreview || FileManager.default.fileExists(atPath: modelPath)
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
            return "The included Small model is ready to use. You can choose a larger local model for a different balance of speed and accuracy."
        }

        return "Choose a recommended model or review your custom model files. You can change the model later in Speech model settings."
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
                    .tint(StenoDesign.theme(for: controller.preferences).accent)
                    .disabled(option.isActive)
                } else {
                    Button {
                        controller.downloadWhisperModel(option.modelID)
                    } label: {
                        if controller.activeModelDownloadID == option.modelID {
                            HStack(spacing: StenoDesign.xs) {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: StenoDesign.iconMD, height: StenoDesign.iconMD)
                                    .accessibilityHidden(true)
                                Text("Downloading \(option.title)…")
                            }
                        } else {
                            Text("Download \(option.title)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StenoDesign.theme(for: controller.preferences).accent)
                    .disabled(controller.activeModelDownloadID != nil)
                }

                if bundledRuntime != nil {
                    Text("You can continue with the included Small model.")
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.textSecondary)
                }
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
        VStack(alignment: .leading, spacing: 28) {
            stepHeading(
                "Your first dictation",
                description: "Open an app and click where you want your words to go."
            )

            VStack(alignment: .leading, spacing: StenoDesign.lg) {
                tipRow(number: "1", text: "Hold Option to dictate (press-to-talk).")
                tipRow(number: "2", text: "Speak naturally. Release Option to finish and insert your words.")
                tipRow(number: "3", text: "Find your completed dictations in History, ready to copy.")
                tipRow(number: "4", text: "In Recording settings, choose a hands-free key and optional live preview.")
            }
        }
    }

    private func tipRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: StenoDesign.md) {
            Text(number)
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(StenoDesign.theme(for: controller.preferences).accent)
                .frame(width: 24, alignment: .leading)

            Text(text)
                .font(StenoDesign.body())
                .foregroundStyle(StenoDesign.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    goBack()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("[", modifiers: .command)
                .help("Previous step (Command-[)")
                .accessibilityLabel("Go to previous step")
            }

            Spacer()

            if currentStep != .welcome && currentStep != .featureTour && canSkip {
                Button("Set up later") {
                    goForward()
                }
                .buttonStyle(.bordered)
                .help("Continue setup without completing this step")
                .accessibilityLabel("Set up \(currentStep.name.lowercased()) later")
            }

            if currentStep == .featureTour {
                Button("Open Steno") {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .tint(StenoDesign.theme(for: controller.preferences).accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Finish onboarding and start using Steno")
            } else {
                Button("Continue") {
                    goForward()
                }
                .buttonStyle(.borderedProminent)
                .tint(StenoDesign.theme(for: controller.preferences).accent)
                .disabled(!canContinue)
                .keyboardShortcut(.defaultAction)
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

    var title: String { "\(rawValue + 1) · \(name)" }

    var name: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .whisperSetup: return "Speech model"
        case .featureTour: return "First dictation"
        }
    }
}
