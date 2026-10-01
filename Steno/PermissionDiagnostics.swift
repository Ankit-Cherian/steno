import AppKit
import AVFoundation
import ApplicationServices
import Foundation

struct PermissionStatusSnapshot: Equatable {
    var microphone: PermissionDiagnostics.AccessStatus
    var accessibility: PermissionDiagnostics.AccessStatus
    var inputMonitoring: PermissionDiagnostics.AccessStatus

    @MainActor
    static func current() -> PermissionStatusSnapshot {
        .init(
            microphone: PermissionDiagnostics.microphoneStatus(),
            accessibility: PermissionDiagnostics.accessibilityStatus(),
            inputMonitoring: PermissionDiagnostics.inputMonitoringStatus()
        )
    }
}

struct PermissionDiagnostics {
    enum AccessStatus: String {
        case granted = "Granted"
        case denied = "Denied"
        case unknown = "Unknown"
    }

    static func microphoneStatus() -> AccessStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    static func accessibilityStatus() -> AccessStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    static func inputMonitoringStatus() -> AccessStatus {
        CGPreflightListenEventAccess() ? .granted : .denied
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoringPermission() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }
        _ = CGRequestListenEventAccess()
        // The request call may return before user action. Check preflight later.
        return false
    }

    /// The System Settings list that grants each permission.
    enum PrivacyPane: CaseIterable {
        case microphone
        case accessibility
        case inputMonitoring

        var settingsURL: URL {
            let anchor = switch self {
            case .microphone: "Privacy_Microphone"
            case .accessibility: "Privacy_Accessibility"
            case .inputMonitoring: "Privacy_ListenEvent"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    static func openAccessibilitySettings() {
        openPrivacyPane(.accessibility)
    }

    static func openMicrophoneSettings() {
        openPrivacyPane(.microphone)
    }

    static func openInputMonitoringSettings() {
        openPrivacyPane(.inputMonitoring)
    }

    static func openPrivacyPane(_ pane: PrivacyPane) {
        if !NSWorkspace.shared.open(pane.settingsURL) {
            openPrivacySecuritySettings()
        }
    }

    static func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func currentAppBundlePath() -> String {
        Bundle.main.bundleURL.path
    }

    private static func openPrivacySecuritySettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.settings.PrivacySecurity")
    }

    private static func openSettingsURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
