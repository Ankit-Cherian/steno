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
                StenoBadge(text: "Onboarding", tone: .accent, theme: theme, compact: true)
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
            reduceMotion ? nil : .easeOut(duration: StenoDesign.direction == .current ? 0.24 : 0.2),
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

    @ViewBuilder
    private func onboardingLayout(theme: StenoTheme) -> some View {
        switch StenoDesign.direction {
        case .signal:
            VStack(spacing: 0) {
                progressBar.padding(.horizontal, 32).padding(.top, 24)
                ScrollView {
                    stepContent
                        .padding(32)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Divider()
                navigationBar.padding(.horizontal, 32).padding(.bottom, 20)
            }
            .background(theme.ink0)
        case .manuscript:
            ManuscriptOnboardingLayout(progress: progressBar, content: stepContent, navigation: navigationBar, theme: theme)
        case .current:
            CurrentOnboardingLayout(progress: progressBar, content: stepContent, navigation: navigationBar, theme: theme)
        }
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
        HStack(spacing: StenoDesign.xs) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                VStack(alignment: .leading, spacing: 8) {
                Text(step.title).font(.system(size: 12, weight: step == currentStep ? .semibold : .regular))
                    .foregroundStyle(step == currentStep ? StenoDesign.textPrimary : StenoDesign.textSecondary)
                RoundedRectangle(cornerRadius: StenoDesign.radiusTiny)
                    .fill(step.rawValue <= currentStep.rawValue ? StenoDesign.theme(for: controller.preferences).accent : StenoDesign.border)
                    .frame(height: StenoDesign.xs)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: StenoDesign.animationNormal),
                        value: currentStep
                    )
                }
            }
        }
        .accessibilityLabel("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
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
        VStack(spacing: StenoDesign.xl) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(StenoDesign.theme(for: controller.preferences).accent)
                .accessibilityHidden(true)

            VStack(spacing: StenoDesign.sm) {
                StenoPageTitle("Welcome to Steno")
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Private dictation that types into your active app")
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(StenoDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: StenoDesign.md) {
                featureRow(icon: "lock.shield", title: "Private by default", detail: "Audio and transcript cleanup stay on your Mac.")
                featureRow(icon: "bolt", title: "Choose your pace", detail: "Pick a local speech model to balance speed and accuracy.")
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
            }
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: StenoDesign.lg) {
            Spacer()

            VStack(spacing: StenoDesign.sm) {
                StenoPageTitle("Permissions")
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Allow the access needed to record and insert dictation.")
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
                Text("Allow microphone access to start dictating. You can also finish setup later.")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.warning)
            }

            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !controller.isIsolatedPreview else { return }
            controller.refreshPermissionStatuses()
        }
    }

    // MARK: - Step 3: Whisper Setup

    private var whisperSetupStep: some View {
        VStack(spacing: StenoDesign.lg) {
            Spacer()

            VStack(spacing: StenoDesign.sm) {
                Text("Choose your speech model")
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

                DisclosureGroup("Custom model setup", isExpanded: $showAdvancedSetup) {
                VStack(alignment: .leading, spacing: 16) {
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
                .padding(.top, 12)
                }
            }
            .cardStyle()

            if bundledRuntime != nil {
                HStack(spacing: StenoDesign.xs) {
                    Image(systemName: "shippingbox.fill")
                        .font(StenoDesign.caption())
                    Text("This build includes Small by default. You can keep going now and still download a better model later in Settings \u{2192} Speech model.")
                        .font(StenoDesign.caption())
                }
                .foregroundStyle(StenoDesign.textSecondary)
            }

            Spacer()
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
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: StenoDesign.iconMD, height: StenoDesign.iconMD)
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
        VStack(spacing: StenoDesign.xl) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(StenoDesign.success)
                .accessibilityHidden(true)

            VStack(spacing: StenoDesign.sm) {
                StenoPageTitle("Your first dictation")
                    .foregroundStyle(StenoDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Open an app and click where you want your words to go.")
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(StenoDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: StenoDesign.md) {
                tipRow(number: "1", text: "Hold Option to dictate (press-to-talk)")
                tipRow(number: "2", text: "Speak naturally. Release Option to finish and insert your words.")
                tipRow(number: "3", text: "Find your completed dictations in History, ready to copy.")
                tipRow(number: "4", text: "In Recording settings, choose a hands-free key and optional live preview.")
            }
            .cardStyle()

            Spacer()
        }
    }

    private func tipRow(number: String, text: String) -> some View {
        HStack(spacing: StenoDesign.md) {
            Text(number)
                .font(StenoDesign.bodyEmphasis())
                .foregroundStyle(StenoDesign.theme(for: controller.preferences).accentInk)
                .frame(width: StenoDesign.xl, height: StenoDesign.xl)
                .background(StenoDesign.theme(for: controller.preferences).accent)
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
                Button("Set up later") {
                    goForward()
                }
                .buttonStyle(.plain)
                .foregroundStyle(StenoDesign.textSecondary)
                .accessibilityLabel("Skip this step")
            }

            if currentStep == .featureTour {
                Button("Open Steno") {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .tint(StenoDesign.theme(for: controller.preferences).accent)
                .accessibilityLabel("Finish onboarding and start using Steno")
            } else {
                Button("Continue") {
                    goForward()
                }
                .buttonStyle(.borderedProminent)
                .tint(StenoDesign.theme(for: controller.preferences).accent)
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

    var title: String {
        switch self {
        case .welcome: return "1 · Welcome"
        case .permissions: return "2 · Permissions"
        case .whisperSetup: return "3 · Speech model"
        case .featureTour: return "4 · First dictation"
        }
    }
}
