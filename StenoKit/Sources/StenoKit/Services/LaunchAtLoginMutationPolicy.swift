/// What ServiceManagement reports for the app's login item.
public enum LaunchAtLoginSystemStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound

    /// Registered with macOS, including an item waiting for the user's approval.
    public var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }
}

public enum LaunchAtLoginMutationDecision: Equatable, Sendable {
    case skip
    case setEnabled(Bool)
}

public enum LaunchAtLoginNotice: Equatable, Sendable {
    /// Registered, but macOS shows it as off until the user allows it in Login Items.
    case needsApproval
    /// Registration did not take effect; carries the system's reason when known.
    case failed(String?)
}

public struct LaunchAtLoginOutcome: Equatable, Sendable {
    public let preference: Bool
    public let notice: LaunchAtLoginNotice?

    public init(preference: Bool, notice: LaunchAtLoginNotice?) {
        self.preference = preference
        self.notice = notice
    }
}

public enum LaunchAtLoginMutationPolicy {
    /// Registers or unregisters only when the user changed the setting and
    /// macOS doesn't already match it.
    public static func decision(
        systemStatus: LaunchAtLoginSystemStatus,
        requestedPreference: Bool,
        previousPreference: Bool
    ) -> LaunchAtLoginMutationDecision {
        guard requestedPreference != previousPreference,
              requestedPreference != systemStatus.isRegistered
        else {
            return .skip
        }
        return .setEnabled(requestedPreference)
    }

    /// The setting to save is what macOS reports after the change, so On is
    /// never saved for a registration that didn't happen.
    public static func outcome(
        requestedPreference: Bool,
        statusAfter: LaunchAtLoginSystemStatus,
        errorDescription: String?
    ) -> LaunchAtLoginOutcome {
        let preference = statusAfter.isRegistered
        if preference != requestedPreference {
            return .init(preference: preference, notice: .failed(errorDescription))
        }
        if statusAfter == .requiresApproval {
            return .init(preference: preference, notice: .needsApproval)
        }
        return .init(preference: preference, notice: nil)
    }
}
