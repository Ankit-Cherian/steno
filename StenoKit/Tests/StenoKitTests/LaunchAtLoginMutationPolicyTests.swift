import Testing
@testable import StenoKit

@Test("disabled cold launch does not mutate ServiceManagement")
func disabledColdLaunchDoesNotMutateServiceManagement() {
    #expect(
        LaunchAtLoginMutationPolicy.decision(
            systemStatus: .notRegistered,
            requestedPreference: false,
            previousPreference: false
        ) == .skip
    )
}

@Test("user toggle requests the selected launch-at-login state")
func userToggleRequestsSelectedLaunchAtLoginState() {
    #expect(
        LaunchAtLoginMutationPolicy.decision(
            systemStatus: .notRegistered,
            requestedPreference: true,
            previousPreference: false
        ) == .setEnabled(true)
    )
    #expect(
        LaunchAtLoginMutationPolicy.decision(
            systemStatus: .enabled,
            requestedPreference: false,
            previousPreference: true
        ) == .setEnabled(false)
    )
}

@Test("A save that doesn't change the toggle never registers or unregisters")
func unchangedToggleSkips() {
    #expect(
        LaunchAtLoginMutationPolicy.decision(
            systemStatus: .notRegistered,
            requestedPreference: true,
            previousPreference: true
        ) == .skip
    )
}

@Test("Turning on an item macOS already holds for approval doesn't register it again")
func requiresApprovalCountsAsRegistered() {
    #expect(
        LaunchAtLoginMutationPolicy.decision(
            systemStatus: .requiresApproval,
            requestedPreference: true,
            previousPreference: false
        ) == .skip
    )
    #expect(
        LaunchAtLoginMutationPolicy.decision(
            systemStatus: .requiresApproval,
            requestedPreference: false,
            previousPreference: true
        ) == .setEnabled(false)
    )
}

@Test("On is kept only when macOS reports Steno registered")
func outcomeFollowsSystemStatus() {
    #expect(LaunchAtLoginMutationPolicy.outcome(requestedPreference: true, statusAfter: .enabled, errorDescription: nil)
        == .init(preference: true, notice: nil))
    #expect(LaunchAtLoginMutationPolicy.outcome(requestedPreference: true, statusAfter: .requiresApproval, errorDescription: nil)
        == .init(preference: true, notice: .needsApproval))
    #expect(LaunchAtLoginMutationPolicy.outcome(requestedPreference: true, statusAfter: .notRegistered, errorDescription: "Operation not permitted")
        == .init(preference: false, notice: .failed("Operation not permitted")))
    #expect(LaunchAtLoginMutationPolicy.outcome(requestedPreference: true, statusAfter: .notFound, errorDescription: nil)
        == .init(preference: false, notice: .failed(nil)))
    #expect(LaunchAtLoginMutationPolicy.outcome(requestedPreference: false, statusAfter: .notRegistered, errorDescription: nil)
        == .init(preference: false, notice: nil))
    #expect(LaunchAtLoginMutationPolicy.outcome(requestedPreference: false, statusAfter: .enabled, errorDescription: "Busy")
        == .init(preference: true, notice: .failed("Busy")))
}
