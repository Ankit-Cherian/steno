import Foundation

/// How long a test waits for something that must happen. Only a broken behavior
/// reaches it: on a loaded machine a one-second timer has been seen to fire
/// after 47 s, so a short ceiling fails tests whose behavior is correct.
let eventualityCeiling: Duration = .seconds(120)

/// Waits until `condition` holds, or returns false at `eventualityCeiling`.
func eventually(
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + eventualityCeiling
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// `eventually` for state owned by the main actor.
@MainActor
func eventuallyOnMain(
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + eventualityCeiling
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
