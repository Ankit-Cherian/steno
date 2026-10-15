import SwiftUI

struct PermissionsSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .permissions, intro: "macOS manages these. Changes take effect right away.")
            SettingsCard {
                PermissionRow(
                    title: "Microphone",
                    detail: "To hear you while you dictate.",
                    status: controller.microphonePermissionStatus,
                    onRequest: { controller.requestMicrophonePermission() },
                    onOpenSettings: { controller.openMicrophoneSettings() }
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "To insert your words where you’re typing. Steno doesn’t read the rest of your screen.",
                    status: controller.accessibilityPermissionStatus,
                    onRequest: { controller.requestAccessibilityPermission() },
                    onOpenSettings: { controller.openAccessibilitySettings() }
                )
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Lets Steno’s shortcuts work while other apps are in front. For Hold Option, Steno notices that a key or mouse button was pressed, never which one.",
                    status: controller.inputMonitoringPermissionStatus,
                    onRequest: { controller.requestInputMonitoringPermission() },
                    onOpenSettings: { controller.openInputMonitoringSettings() }
                )
            }
            HStack(spacing: 12) {
                Text("Dictation needs only Microphone. Shortcuts and inserting need the others.")
                    .settingsFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Check Again") {
                    controller.refreshPermissionStatuses()
                }
                .settingsButton(.secondary)
            }
            .modifier(SecondaryInk())
            .padding(.top, 14)
        }
        .onAppear {
            controller.refreshPermissionStatuses(reinstallHotkeysOnlyIfChanged: true)
        }
    }
}

private struct SecondaryInk: ViewModifier {
    @Environment(\.quillTheme) private var theme
    func body(content: Content) -> some View { content.foregroundStyle(theme.ink2) }
}

/// One permission: what it's for, its state from macOS, and the one action that changes it.
struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionDiagnostics.AccessStatus
    /// Whether macOS has asked yet, when that is knowable; otherwise an unknown status counts as not asked.
    var hasBeenAsked = true
    /// The first row still to allow gets the filled button.
    var isNextToAllow = true
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        SettingsRow(label: title, help: detail) {
            switch Self.presentation(for: status, hasBeenAsked: hasBeenAsked) {
            case .allowed:
                SettingsStatusLabel(text: "Allowed", tone: .ok)
            case .notAllowed:
                HStack(spacing: 10) {
                    SettingsStatusLabel(text: "Not allowed", tone: .caution)
                    Button("Open System Settings", action: onOpenSettings)
                        .settingsButton(.secondary)
                }
            case .notAsked:
                HStack(spacing: 10) {
                    SettingsStatusLabel(text: "Not asked yet", tone: .quiet)
                    allowButton
                }
            case .ask:
                allowButton
            }
        }
        .accessibilityLabel("\(title), \(Self.presentation(for: status, hasBeenAsked: hasBeenAsked).spoken)")
    }

    @ViewBuilder
    private var allowButton: some View {
        if isNextToAllow {
            Button("Allow…", action: onRequest).settingsButton(.primary)
        } else {
            Button("Allow…", action: onRequest).settingsButton(.secondary)
        }
    }

    enum Presentation: Equatable {
        case allowed
        case notAllowed
        /// Settings: macOS hasn't asked yet.
        case notAsked
        /// Onboarding: nothing shows as missing before macOS has asked.
        case ask

        var spoken: String {
            switch self {
            case .allowed: "allowed"
            case .notAllowed: "not allowed"
            case .notAsked, .ask: "not asked yet"
            }
        }
    }

    /// Settings shows "Not asked yet" for an undetermined status; onboarding passes
    /// `hasBeenAsked: false` so a status macOS can't report as undetermined still offers Allow.
    static func presentation(for status: PermissionDiagnostics.AccessStatus, hasBeenAsked: Bool) -> Presentation {
        switch status {
        case .granted: .allowed
        case .unknown: hasBeenAsked ? .notAsked : .ask
        case .denied: hasBeenAsked ? .notAllowed : .ask
        }
    }
}
