#if os(macOS)
import AppKit
import Foundation

@MainActor
public enum AppContextProvider {
    public static func current() -> AppContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? "unknown"
        let appName = app?.localizedName ?? "Unknown"

        let lowered = "\(bundleID) \(appName)".lowercased()
        let isIDE = lowered.contains("cursor")
            || lowered.contains("vscode")
            || lowered.contains("xcode")
            || lowered.contains("jetbrains")
        let isRemoteDesktop = lowered.contains("citrix")
            || lowered.contains("remote desktop")
            || lowered.contains("vmware")
            || lowered.contains("parallels")
            || lowered.contains("rdp")

        return AppContext(
            bundleIdentifier: bundleID,
            appName: appName,
            inputFieldDescription: nil,
            isRemoteDesktop: isRemoteDesktop,
            isIDE: isIDE
        )
    }
}
#endif
