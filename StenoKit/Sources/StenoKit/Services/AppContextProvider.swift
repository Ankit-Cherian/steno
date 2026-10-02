#if os(macOS)
import AppKit
import Foundation

@MainActor
public enum AppContextProvider {
    public static func current() -> AppContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? "unknown"
        let appName = app?.localizedName ?? "Unknown"

        return AppContext.classified(bundleIdentifier: bundleID, appName: appName)
    }
}
#endif
