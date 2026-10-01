import Foundation

/// An error message paired with the Settings page that can fix it.
struct ErrorRecoveryTarget: Equatable {
    let message: String
    let section: SettingsSection
}

/// Chooses the Settings page that "Review settings" opens for the problems
/// shown on the Dictate tab.
enum SettingsRecovery {
    struct Context {
        var microphone: PermissionDiagnostics.AccessStatus
        var accessibility: PermissionDiagnostics.AccessStatus
        var inputMonitoring: PermissionDiagnostics.AccessStatus
        var lastError: String
        var lastErrorTarget: ErrorRecoveryTarget?
        var hotkeyMessage: String
    }

    static func section(for context: Context) -> SettingsSection {
        if context.microphone != .granted {
            return .permissions
        }
        if !context.lastError.isEmpty,
           let target = context.lastErrorTarget,
           target.message == context.lastError {
            return target.section
        }
        let shortcutPermissionsMissing = context.accessibility != .granted || context.inputMonitoring != .granted
        if !context.hotkeyMessage.isEmpty {
            return shortcutPermissionsMissing ? .permissions : .recording
        }
        // Inserting text needs Accessibility; without it that is the fix.
        return context.accessibility != .granted ? .permissions : .recording
    }
}
