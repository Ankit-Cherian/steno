import AppKit
import StenoKit
import UniformTypeIdentifiers

/// Names and icons for apps that settings are scoped to, found by bundle ID.
@MainActor
enum AppIdentity {
    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// "All Apps" or "Only in Terminal", as the scope menu names them.
    static func scopeTitle(_ scope: Scope) -> String {
        switch scope {
        case .global: "All Apps"
        case .app(let bundleID): "Only in \(name(for: bundleID))"
        }
    }

    /// What the person did in the app chooser.
    enum AppChoice: Equatable {
        case cancelled
        /// An app was chosen, but its bundle declares no identifier Steno could scope settings to.
        case noIdentifier
        case app(String)
    }

    static let noIdentifierMessage = "That app has no identifier Steno can use."

    /// Asks for an app. Tests replace this so no open panel is shown.
    static var chooser: @MainActor () -> AppChoice = { chooseAppWithPanel() }

    static func chooseApp() -> AppChoice { chooser() }

    /// Reads the panel's answer: no URL is a cancelled panel, and a bundle without an identifier
    /// is a different thing from a cancelled panel.
    static func choice(forChosenAppAt url: URL?) -> AppChoice {
        guard let url else { return .cancelled }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else { return .noIdentifier }
        return .app(bundleID)
    }

    private static func chooseAppWithPanel() -> AppChoice {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return choice(forChosenAppAt: panel.runModal() == .OK ? panel.url : nil)
    }
}
