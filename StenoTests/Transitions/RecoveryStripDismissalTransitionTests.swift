import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// A strip that was dismissed stays hidden for that occurrence of its problem only: a new
/// failure, or a permission that is lost again, shows it again.
@Suite("Recovery strip dismissal transitions", .serialized)
@MainActor
struct RecoveryStripDismissalTransitionTests {
    typealias F = TransitionFixtures

    private func host(_ controller: DictationController) -> TransitionHost {
        TransitionHost(controller: controller) { ContentView() }
    }

    private func isOnToday(_ host: TransitionHost) -> Bool { host.node(identifier: "today.start") != nil }

    private func says(_ host: TransitionHost, _ text: String) -> Bool {
        host.node { $0.text.contains(text) } != nil
    }

    @Test("The same dictation failure shows its strip again after an earlier one was dismissed")
    func repeatedFailureShowsAgain() async throws {
        let session = try await WindowDictation.make()
        defer { Task { await session.close() } }
        let message = "The speech model could not be loaded"
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }

        for round in 0..<3 {
            await session.coordinator.failNextTranscription(message + ".")
            try await host.press("Dictate")
            try await host.press("Stop and copy")
            #expect(await host.settle(timeout: .seconds(8)) { says(host, message) }, "round \(round): no strip: \(host.names().prefix(12))")
            // The strip stays until it is dismissed.
            #expect(await host.settle(timeout: .seconds(6)) { isOnToday(host) }, "round \(round): Today did not go back to its stage")
            #expect(says(host, message), "round \(round): the strip went by itself")
            try await host.press("Dismiss")
            #expect(await host.settle { !says(host, message) }, "round \(round): Dismiss left the strip")
        }
    }

    @Test("A dismissed failure stays hidden while it stands, and its message coming back after the error cleared shows it")
    func failureStaysHiddenUntilItClears() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }
        let message = "Steno couldn’t start the speech model. Check Speech Model in Settings."

        controller.lastError = message
        #expect(await host.settle { says(host, "couldn’t start the speech model") })
        try await host.press("Dismiss")
        #expect(await host.settle { !says(host, "couldn’t start the speech model") })

        // Something else changes while the error stands: it stays dismissed.
        controller.hotkeyRegistrationMessage = ""
        controller.microphonePermissionStatus = .granted
        await host.settle()
        #expect(!says(host, "couldn’t start the speech model"), "the dismissed error came back with the same error standing")

        // The next recording clears the error, and a new failure with the same words is new.
        controller.lastError = ""
        await host.settle()
        controller.lastError = message
        #expect(await host.settle { says(host, "couldn’t start the speech model") }, "a new failure stayed hidden: \(host.names().prefix(10))")
    }

    @Test("A dismissed permission strip comes back when the permission is lost again after it was granted")
    func permissionStripReturns() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        await host.settle { isOnToday(host) }

        controller.accessibilityPermissionStatus = .denied
        controller.inputMonitoringPermissionStatus = .denied
        #expect(await host.settle { says(host, "Accessibility access is off") && says(host, "Input Monitoring is off") })
        let accessibilityDismissal = try #require(host.nodes(named: "Dismiss").first)
        #expect(accessibilityDismissal.press())
        #expect(await host.settle { !says(host, "Accessibility access is off") })

        // Still denied: the dismissal holds, and the other strip is untouched.
        await host.settle()
        #expect(!says(host, "Accessibility access is off"))
        #expect(says(host, "Input Monitoring is off"))

        controller.accessibilityPermissionStatus = .granted
        await host.settle()
        #expect(!says(host, "Accessibility access is off"))
        controller.accessibilityPermissionStatus = .denied
        #expect(await host.settle { says(host, "Accessibility access is off") }, "the strip stayed hidden after the permission was lost again")
        #expect(says(host, "Input Monitoring is off"))
    }
}
