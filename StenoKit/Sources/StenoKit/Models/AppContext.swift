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
