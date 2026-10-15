import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The first-run guide in every state a person meets: each permission as it is asked for and
/// changes, a missing speech model, and a first dictation from waiting to its words, with the
/// no-speech and microphone-off answers, Skip for Now and Start Dictating.
@Suite("Onboarding coverage transitions", .serialized)
@MainActor
struct OnboardingCoverageTransitionTests {
    typealias F = TransitionFixtures

    private func host(_ controller: DictationController, step: Int) -> TransitionHost {
        TransitionHost(controller: controller) { OnboardingView(initialStep: step) }
    }

    private func says(_ host: TransitionHost, _ prefix: String) -> Bool {
        host.node { $0.text.hasPrefix(prefix) } != nil
    }

    @Test("Permissions: only the next one can be asked for, Allow… turns to Open System Settings once asked, and each turns Allowed when granted")
    func permissionsInTurn() async throws {
        let controller = F.sampleController()
        controller.microphonePermissionStatus = .unknown
        controller.accessibilityPermissionStatus = .denied
        controller.inputMonitoringPermissionStatus = .denied
        let host = host(controller, step: 1)
        defer { host.close() }
        #expect(await host.settle { host.node(named: "Microphone, not asked yet") != nil }, "\(host.names())")
        #expect(host.node(named: "Allow Microphone") != nil)
        #expect(host.node(named: "Accessibility, after Microphone") != nil, "\(host.names())")
        #expect(host.node(named: "Allow Accessibility") == nil, "a permission out of turn can be asked for")

        controller.microphonePermissionStatus = .granted
        #expect(await host.settle { host.node(named: "Microphone, allowed") != nil })
        #expect(await host.settle { host.node(named: "Allow Accessibility") != nil }, "Accessibility did not take its turn: \(host.names())")
        try await host.press("Allow Accessibility")
        #expect(await host.settle { host.node(named: "Accessibility, not allowed") != nil && host.node(named: "Open System Settings for Accessibility") != nil },
                "asking left \(host.names())")

        controller.accessibilityPermissionStatus = .granted
        #expect(await host.settle { host.node(named: "Allow Input Monitoring") != nil })
        controller.inputMonitoringPermissionStatus = .granted
        #expect(await host.settle { host.node(named: "Input Monitoring, allowed") != nil })
        #expect(host.node { $0.name.hasPrefix("Allow ") } == nil)
        #expect(host.node(named: "Continue to First dictation")?.isEnabled == true)
    }

    @Test("Microphone access turned off shows Open System Settings on its row, and turned on shows Allowed")
    func microphoneDeniedRow() async throws {
        let controller = F.sampleController()
        controller.microphonePermissionStatus = .denied
        let host = host(controller, step: 1)
        defer { host.close() }
        #expect(await host.settle { host.node(named: "Microphone, not allowed") != nil }, "\(host.names())")
        #expect(host.node(named: "Open System Settings for Microphone") != nil)
        controller.microphonePermissionStatus = .granted
        #expect(await host.settle { host.node(named: "Microphone, allowed") != nil && host.node(named: "Open System Settings for Microphone") == nil })
    }

    @Test("With no speech model, the permissions step says so and offers Open Settings")
    func missingSpeechModel() async throws {
        let session = try await WindowDictation.make()
        defer { Task { await session.close() } }
        session.controller.preferences.dictation.modelPath = "/nonexistent/Steno/ggml-missing.bin"
        let host = host(session.controller, step: 1)
        defer { host.close() }
        #expect(await host.settle { says(host, "Steno needs a speech model to dictate.") }, "\(host.names())")
        #expect(host.node(named: "Open Settings") != nil)
    }

    @Test("The first dictation goes waiting, listening, transcribing, then shows its words, and Start Dictating finishes setup")
    func firstDictation() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "Hello from my first dictation.", status: .inserted))
        defer { Task { await session.close() } }
        session.controller.preferences.general.showOnboarding = true
        await session.coordinator.hold()
        let host = host(session.controller, step: 2)
        defer { host.close() }
        #expect(await host.settle { host.node { $0.name.hasPrefix("First dictation.") } != nil }, "not waiting: \(host.names())")

        session.controller.toggleHandsFree()
        #expect(await host.settle { says(host, "Listening") }, "not listening: \(host.names())")
        session.controller.stopRecording()
        #expect(await host.settle { says(host, "Transcribing") }, "not transcribing: \(host.names())")
        await session.coordinator.release()
        #expect(await host.settle { says(host, "That’s your first dictation") }, "no result: \(host.names())")
        #expect(host.node { $0.text.contains("Hello from my first dictation") } != nil)
        #expect(host.node(named: "Skip the first dictation and finish setup") == nil)

        try await host.press("Start dictating, finish setup")
        #expect(await host.settle { !session.controller.preferences.general.showOnboarding }, "setup did not finish")
    }

    @Test("No speech on the first dictation says how to try again")
    func firstDictationNoSpeech() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "", status: .noSpeech))
        defer { Task { await session.close() } }
        let host = host(session.controller, step: 2)
        defer { host.close() }
        await host.settle { host.node { $0.name.hasPrefix("First dictation.") } != nil }
        session.controller.toggleHandsFree()
        await host.settle { says(host, "Listening") }
        session.controller.stopRecording()
        #expect(await host.settle { says(host, "No speech detected.") }, "\(host.names())")
    }

    @Test("A no-speech result left from before the step does not open the practice step as a failed attempt")
    func firstDictationIgnoresEarlierNoSpeech() async throws {
        let controller = F.sampleController([])
        controller.status = "No speech detected."
        let host = host(controller, step: 1)
        defer { host.close() }
        #expect(await host.settle { host.node(named: "Continue to First dictation") != nil }, "\(host.names())")
        try await host.press("Continue to First dictation")
        #expect(await host.settle { host.node { $0.name.hasPrefix("First dictation.") } != nil }, "\(host.names())")
        #expect(!says(host, "No speech detected."), "\(host.names())")
    }

    @Test("Microphone off on the first dictation says Steno can’t hear, and offers Open System Settings")
    func firstDictationMicrophoneOff() async throws {
        // No History: the sample's are dated at set times of today, which are later than now
        // before mid-morning and would read as a first dictation made on this step.
        let controller = F.sampleController([])
        let host = host(controller, step: 2)
        defer { host.close() }
        await host.settle { host.node { $0.name.hasPrefix("First dictation.") } != nil }
        controller.microphonePermissionStatus = .denied
        #expect(await host.settle { says(host, "Microphone access is off, so Steno can’t hear you.") }, "\(host.names())")
        #expect(host.node(named: "Open System Settings") != nil)
    }

    @Test("Skip for Now finishes setup without a dictation")
    func skipForNow() async throws {
        let session = try await WindowDictation.make()
        defer { Task { await session.close() } }
        session.controller.preferences.general.showOnboarding = true
        let host = host(session.controller, step: 2)
        defer { host.close() }
        await host.settle { host.node(named: "Skip the first dictation and finish setup") != nil }
        try await host.press("Skip the first dictation and finish setup")
        #expect(await host.settle { !session.controller.preferences.general.showOnboarding })
    }
}
