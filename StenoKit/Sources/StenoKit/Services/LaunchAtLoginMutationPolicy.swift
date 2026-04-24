public enum LaunchAtLoginMutationDecision: Equatable, Sendable {
    case skip
    case setEnabled(Bool)
}

public enum LaunchAtLoginMutationPolicy {
    public static func decision(
        currentPreference: Bool,
        requestedPreference: Bool,
        userInitiated: Bool
    ) -> LaunchAtLoginMutationDecision {
        guard userInitiated, currentPreference != requestedPreference else {
            return .skip
        }

        return .setEnabled(requestedPreference)
    }

    public static func warningMessage(
        requestedPreference: Bool,
        userInitiated: Bool,
        errorDescription: String
    ) -> String? {
        guard userInitiated else {
            return nil
        }

        return errorDescription
    }
}
