import SwiftUI

struct PermissionsSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: StenoDesign.lg) {
            settingsCardWithSubtitle(
                "Permissions",
                subtitle: "Grant these once. Steno only reads what you explicitly record."
            ) {
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

            HStack(spacing: StenoDesign.md) {
                Image(systemName: "sparkles")
                    .foregroundStyle(StenoDesign.accent)

                Text("You're fully set up. Steno can capture, transcribe, and insert text without further prompts.")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)

                Spacer()

                Button("Re-check") {
                    controller.refreshPermissionStatuses()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, StenoDesign.md)
            .padding(.vertical, StenoDesign.md)
            .background(StenoDesign.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: StenoDesign.radiusSmall)
                    .stroke(StenoDesign.accent.opacity(0.18), lineWidth: StenoDesign.borderThin)
            )
        }
    }
}
