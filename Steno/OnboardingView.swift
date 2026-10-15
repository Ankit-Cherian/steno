import StenoKit
import SwiftUI

/// First-run guide: Welcome, Permissions (with the speech model), and a first dictation that ends on
/// "You're set up". The dictation is not inserted anywhere; its History entry is shown instead.
struct OnboardingView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: OnboardingStep
    /// When the first-dictation step opened; the first History entry after it is the result.
    @State private var firstDictationStartedAt: Date?
    /// Whether a dictation has been tried on the first-dictation step; the controller's status
    /// can still hold the result of one made before the step opened.
    @State private var attemptedOnFirstDictationStep = false
    @State private var previewEntry: TranscriptEntry?
    /// Accessibility and Input Monitoring report only allowed or not, so Allow… stays until asked here.
    @State private var askedPermissions: Set<OnboardingPermission> = []

    /// `previewTriedDictation` renders the first-dictation step as if a dictation had been tried
    /// there, for render tests of its results.
    init(initialStep: Int = 0, previewFirstDictation: TranscriptEntry? = nil, previewTriedDictation: Bool = false) {
        _step = State(initialValue: OnboardingStep(rawValue: min(max(initialStep, 0), 2)) ?? .welcome)
        _previewEntry = State(initialValue: previewFirstDictation)
        _attemptedOnFirstDictationStep = State(initialValue: previewTriedDictation)
    }

    var body: some View {
        content
            .frame(
                minWidth: StenoDesign.windowMinWidth,
                idealWidth: StenoDesign.windowIdealWidth,
                minHeight: StenoDesign.windowMinHeight,
                idealHeight: StenoDesign.windowIdealHeight
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step)
            .onAppear { markFirstDictationStartIfNeeded() }
            .onChange(of: step) { _ in markFirstDictationStartIfNeeded() }
            .onChange(of: controller.recordingLifecycleState) { state in
                if step == .firstDictation, state != .idle { attemptedOnFirstDictationStep = true }
            }
    }

    /// One centred column per step and a quiet footer, with no pager dots.
    private var content: some View {
        GroveSettingsContent(accent: controller.preferences.appearance.accent) {
            VStack(spacing: 0) {
                GroveOnboardingColumn {
                    groveStep
                        .id(step)
                        .transition(reduceMotion ? .identity : .opacity)
                }
                .padding(.horizontal, 44)
                .padding(.top, step == .welcome ? 0 : 30)
                if step != .welcome {
                    groveFooter
                        .frame(height: 32)
                        .frame(maxWidth: GroveOnboardingMetrics.columnWidth)
                        .padding(.horizontal, 44)
                        .padding(.bottom, 28)
                }
            }
        }
    }

    @ViewBuilder
    private var groveStep: some View {
        switch step {
        case .welcome:
            GroveOnboardingWelcome(onStart: goForward, nextName: step.next?.name ?? "")
        case .permissions:
            grovePermissions
        case .firstDictation:
            GroveOnboardingFirstDictation(
                phase: phase,
                entry: firstDictation,
                handsFreeKeyName: HandsFreeKeyName.name(for: controller.preferences.hotkeys.handsFreeGlobalKeyCode),
                optionHold: controller.preferences.hotkeys.optionPressToTalkEnabled,
                onOpenMicrophoneSettings: { controller.openMicrophoneSettings() }
            )
        }
    }

    private var grovePermissions: some View {
        GrovePermissionsStep(
            rows: OnboardingPermission.allCases.map { permission in
                GrovePermissionsStep.Row(
                    permission: permission,
                    state: grovePermissionState(permission)
                )
            },
            speechModelReady: speechModelReady,
            onAllow: { request($0) },
            onOpenSettings: { openSettings(for: $0) },
            onOpenSpeechModelSettings: { SettingsRouter.shared.open(.engine) }
        )
        .onAppear { controller.refreshPermissionStatuses(reinstallHotkeysOnlyIfChanged: true) }
    }

    private func status(of permission: OnboardingPermission) -> PermissionDiagnostics.AccessStatus {
        switch permission {
        case .microphone: controller.microphonePermissionStatus
        case .accessibility: controller.accessibilityPermissionStatus
        case .inputMonitoring: controller.inputMonitoringPermissionStatus
        }
    }

    /// Microphone reports undetermined and denied apart; the other two report only allowed or
    /// not, so Allow… stays until they have been asked here.
    private func hasBeenAsked(_ permission: OnboardingPermission) -> Bool {
        permission == .microphone || askedPermissions.contains(permission)
    }

    private func grovePermissionState(_ permission: OnboardingPermission) -> GroveOnboardingPermissionRow.State {
        GroveOnboardingPermissionRow.state(
            status: status(of: permission),
            hasBeenAsked: hasBeenAsked(permission),
            isNext: nextToAllow == permission,
            nextTitle: nextToAllow?.title ?? ""
        )
    }

    private func request(_ permission: OnboardingPermission) {
        switch permission {
        case .microphone:
            controller.requestMicrophonePermission()
        case .accessibility:
            askedPermissions.insert(.accessibility)
            controller.requestAccessibilityPermission()
        case .inputMonitoring:
            askedPermissions.insert(.inputMonitoring)
            controller.requestInputMonitoringPermission()
        }
    }

    private func openSettings(for permission: OnboardingPermission) {
        switch permission {
        case .microphone: controller.openMicrophoneSettings()
        case .accessibility: controller.openAccessibilitySettings()
        case .inputMonitoring: controller.openInputMonitoringSettings()
        }
    }

    private var allPermissionsGranted: Bool { nextToAllow == nil }

    private var groveFooter: some View {
        HStack(spacing: 18) {
            switch step {
            case .welcome:
                EmptyView()
            case .permissions:
                Button("Back") { goBack() }
                    .buttonStyle(.groveText)
                    .groveFocusEffectsOff()
                    .padding(.leading, -8)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Previous step (⌘[)")
                Spacer()
                Group {
                    if allPermissionsGranted {
                        Button("Continue") { goForward() }
                            .buttonStyle(.grove(.primary, .large))
                            .groveFocusEffectsOff()
                    } else {
                        Button("Continue") { goForward() }
                            .buttonStyle(GroveFocusedButtonStyle(look: GroveMutedPillStyle(), cornerRadius: 16))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Continue to \(step.next?.name ?? "")")
            case .firstDictation:
                Button("Back") { goBack() }
                    .buttonStyle(.groveText)
                    .groveFocusEffectsOff()
                    .padding(.leading, -8)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Previous step (⌘[)")
                if firstDictation == nil {
                    Button("Skip for Now") { controller.completeOnboarding() }
                        .buttonStyle(.groveText)
                        .groveFocusEffectsOff()
                        .accessibilityLabel("Skip the first dictation and finish setup")
                }
                Spacer()
                if firstDictation != nil {
                    Button("Start Dictating") { controller.completeOnboarding() }
                        .buttonStyle(.grove(.primary, .large))
                        .groveFocusEffectsOff()
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Start dictating, finish setup")
                }
            }
        }
    }

    /// The first permission still to allow, which gets the filled button.
    private var nextToAllow: OnboardingPermission? {
        if controller.microphonePermissionStatus != .granted { return .microphone }
        if controller.accessibilityPermissionStatus != .granted { return .accessibility }
        if controller.inputMonitoringPermissionStatus != .granted { return .inputMonitoring }
        return nil
    }

    private var speechModelReady: Bool {
        controller.isIsolatedPreview || FileManager.default.fileExists(atPath: controller.preferences.dictation.modelPath)
    }

    // MARK: First dictation

    /// The History entry this step's dictation created.
    private var firstDictation: TranscriptEntry? {
        if let previewEntry { return previewEntry }
        guard step == .firstDictation, let start = firstDictationStartedAt,
              let latest = controller.recentEntries.first, latest.createdAt >= start
        else { return nil }
        return latest
    }

    private var phase: OnboardingDictationPhase {
        OnboardingDictationPhase.derive(
            entry: firstDictation,
            microphone: controller.microphonePermissionStatus,
            lifecycle: controller.recordingLifecycleState,
            isRecording: controller.isRecording,
            status: attemptedOnFirstDictationStep ? controller.status : ""
        )
    }

    private func goForward() {
        if let next = step.next { step = next }
    }

    private func goBack() {
        if let previous = OnboardingStep(rawValue: step.rawValue - 1) { step = previous }
    }

    private func markFirstDictationStartIfNeeded() {
        if step == .firstDictation, firstDictationStartedAt == nil {
            firstDictationStartedAt = Date()
        }
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case firstDictation

    var name: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Permissions"
        case .firstDictation: "First dictation"
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
}

enum OnboardingPermission: Hashable, CaseIterable {
    case microphone, accessibility, inputMonitoring

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }
}

/// Where the first dictation is, from the controller's state.
enum OnboardingDictationPhase: Equatable {
    case waiting
    case listening(handsFree: Bool)
    case transcribing
    case noSpeech
    case microphoneOff
    case done

    static func derive(
        entry: TranscriptEntry?,
        microphone: PermissionDiagnostics.AccessStatus,
        lifecycle: RecordingLifecycleState,
        isRecording: Bool,
        status: String
    ) -> OnboardingDictationPhase {
        if entry != nil { return .done }
        switch lifecycle {
        case .recordingPressToTalk: return .listening(handsFree: false)
        case .recordingHandsFree: return .listening(handsFree: true)
        case .transcribing: return .transcribing
        case .idle: break
        }
        if isRecording { return .listening(handsFree: false) }
        if microphone == .denied { return .microphoneOff }
        if status == "No speech detected." { return .noSpeech }
        return .waiting
    }
}
