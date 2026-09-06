import SwiftUI

struct PermissionsSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: StenoDesign.lg) {
            settingsCardWithSubtitle(
                "App access",
                subtitle: "Changes are managed by macOS and take effect immediately."
            ) {
                PermissionStatusCard(
                    title: "Microphone",
                    description: "Required to capture audio for transcription.",
                    status: controller.microphonePermissionStatus,
                    onRequest: { controller.requestMicrophonePermission() },
                    onOpenSettings: { controller.openMicrophoneSettings() }
                )

                Divider()

                PermissionStatusCard(
                    title: "Accessibility",
                    description: "Lets Steno type or paste into the app you're using.",
                    status: controller.accessibilityPermissionStatus,
                    onRequest: { controller.requestAccessibilityPermission() },
                    onOpenSettings: { controller.openAccessibilitySettings() }
                )

                Divider()

                PermissionStatusCard(
                    title: "Input Monitoring",
                    description: "Lets Steno detect global hotkeys while other apps are focused.",
                    status: controller.inputMonitoringPermissionStatus,
                    onRequest: { controller.requestInputMonitoringPermission() },
                    onOpenSettings: { controller.openInputMonitoringSettings() }
                )
            }

            HStack(spacing: StenoDesign.md) {
                Image(systemName: allPermissionsGranted ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(StenoDesign.textSecondary)

                Text(allPermissionsGranted ? "All permissions are allowed. You can change access at any time in System Settings." : "Review the permissions above. Microphone access is needed to record; the other permissions support shortcuts and text insertion.")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("Check again") {
                    controller.refreshPermissionStatuses()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, StenoDesign.md)
            .padding(.vertical, StenoDesign.md)
            .background(StenoDesign.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: StenoDesign.radiusSmall)
                    .stroke(StenoDesign.border, lineWidth: StenoDesign.borderThin)
            )
        }
    }
    private var allPermissionsGranted: Bool {
        controller.microphonePermissionStatus == .granted
            && controller.accessibilityPermissionStatus == .granted
            && controller.inputMonitoringPermissionStatus == .granted
    }

}
