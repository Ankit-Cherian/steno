import Foundation

public struct AppContext: Sendable, Codable, Equatable {
    public var bundleIdentifier: String
    public var appName: String
    public var inputFieldDescription: String?
    public var isRemoteDesktop: Bool
    public var isIDE: Bool

    public init(
        bundleIdentifier: String,
        appName: String,
        inputFieldDescription: String? = nil,
        isRemoteDesktop: Bool = false,
        isIDE: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.inputFieldDescription = inputFieldDescription
        self.isRemoteDesktop = isRemoteDesktop
        self.isIDE = isIDE
    }
}

public extension AppContext {
    static let unknown = AppContext(bundleIdentifier: "unknown", appName: "Unknown")
}

public extension AppContext {
    /// Classifies an app from its bundle identifier. Live dictation and History's "Run cleanup
    /// again" both use this, so an entry is cleaned with the same profile both times. Matching is
    /// on whole dot-separated tokens of the bundle identifier, never on substrings or on the app's
    /// display name, so "WordPress" is not a remote-desktop client.
    static func classified(bundleIdentifier: String, appName: String) -> AppContext {
        let identifier = bundleIdentifier.lowercased()
        let tokens = Set(identifier.split(separator: ".").map(String.init))
        return AppContext(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            isRemoteDesktop: tokens.isDisjoint(with: remoteDesktopTokens) == false,
            isIDE: tokens.isDisjoint(with: ideTokens) == false || ideBundleIdentifiers.contains(identifier)
        )
    }

    /// Xcode, Visual Studio Code and every JetBrains IDE.
    private static let ideTokens: Set<String> = ["xcode", "vscode", "vscodeinsiders", "jetbrains"]
    /// An editor distributed under a generic packager identifier.
    private static let ideBundleIdentifiers: Set<String> = ["com.todesktop.230313mzl4w4u92"]
    /// Citrix, VMware, Parallels, Microsoft's Remote Desktop and Windows App, Apple Remote Desktop,
    /// and generic RDP clients.
    private static let remoteDesktopTokens: Set<String> = [
        "citrix", "vmware", "parallels", "rdc", "rdp", "remotedesktop",
    ]
}
