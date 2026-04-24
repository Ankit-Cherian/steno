import Testing
@testable import StenoKit

@Test("disabled cold launch does not mutate ServiceManagement")
func disabledColdLaunchDoesNotMutateServiceManagement() {
    #expect(
        LaunchAtLoginMutationPolicy.decision(
            currentPreference: false,
            requestedPreference: false,
            userInitiated: false
        ) == .skip
    )
}

@Test("user toggle requests the selected launch-at-login state")
func userToggleRequestsSelectedLaunchAtLoginState() {
    #expect(
        LaunchAtLoginMutationPolicy.decision(
            currentPreference: false,
            requestedPreference: true,
            userInitiated: true
        ) == .setEnabled(true)
    )
    #expect(
        LaunchAtLoginMutationPolicy.decision(
            currentPreference: true,
            requestedPreference: false,
            userInitiated: true
        ) == .setEnabled(false)
    )
}

@Test("non-user disabled failures do not produce warnings")
func nonUserDisabledFailuresDoNotProduceWarnings() {
    #expect(
        LaunchAtLoginMutationPolicy.warningMessage(
            requestedPreference: false,
            userInitiated: false,
            errorDescription: "Unable to update launch at login"
        ) == nil
    )
}
