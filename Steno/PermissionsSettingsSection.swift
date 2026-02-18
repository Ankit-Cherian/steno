import SwiftUI

struct PermissionsSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        settingsCard("Permissions") {
            PermissionStatusCard(
                title: "Microphone",
                description: "Required to capture audio for transcription.",
                status: controller.microphonePermissionStatus,
                onRequest: { controller.requestMicrophonePermission() },
                onOpenSettings: { controller.openMicrophoneSettings() }
            )

            PermissionStatusCard(
                title: "Accessibility",
                description: "Enables direct text insertion into apps.",
                status: controller.accessibilityPermissionStatus,
                onRequest: { controller.requestAccessibilityPermission() },
                onOpenSettings: { controller.openAccessibilitySettings() }
            )

            PermissionStatusCard(
                title: "Input Monitoring",
                description: "Allows global hotkey for hands-free dictation.",
                status: controller.inputMonitoringPermissionStatus,
                onRequest: { controller.requestInputMonitoringPermission() },
                onOpenSettings: { controller.openInputMonitoringSettings() }
            )
        }
    }
}
