import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Suite("Onboarding state")
struct OnboardingStateTests {
    @Test("The first-dictation step follows the controller", arguments: [
        ("waiting", OnboardingDictationPhase.waiting),
        ("hold", .listening(handsFree: false)),
        ("handsFree", .listening(handsFree: true)),
        ("transcribing", .transcribing),
        ("noSpeech", .noSpeech),
        ("micOff", .microphoneOff),
        ("done", .done),
    ])
    func phases(name: String, expected: OnboardingDictationPhase) {
        let entry = name == "done"
            ? TranscriptEntry(createdAt: Date(), appBundleID: "x", rawText: "Hi", cleanText: "Hi", durationMS: 1, audioURL: nil, insertionStatus: .copiedOnly)
            : nil
        let lifecycle: RecordingLifecycleState = switch name {
        case "hold": .recordingPressToTalk
        case "handsFree": .recordingHandsFree
        case "transcribing": .transcribing
        default: .idle
        }
        let phase = OnboardingDictationPhase.derive(
            entry: entry,
            microphone: name == "micOff" ? .denied : .granted,
            lifecycle: lifecycle,
            isRecording: lifecycle == .recordingPressToTalk || lifecycle == .recordingHandsFree,
            status: name == "noSpeech" ? "No speech detected." : "Ready"
        )
        #expect(phase == expected)
    }

    @Test("Permissions show nothing missing before macOS has asked")
    func permissionPresentation() {
        #expect(PermissionRow.presentation(for: .granted, hasBeenAsked: false) == .allowed)
        #expect(PermissionRow.presentation(for: .denied, hasBeenAsked: false) == .ask)
        #expect(PermissionRow.presentation(for: .unknown, hasBeenAsked: false) == .ask)
        #expect(PermissionRow.presentation(for: .denied, hasBeenAsked: true) == .notAllowed)
        #expect(PermissionRow.presentation(for: .unknown, hasBeenAsked: true) == .notAsked)
    }

    @Test("The quiet permissions step asks for one permission at a time, in order")
    func quietPermissionStates() {
        typealias Row = GroveOnboardingPermissionRow
        // Allowed stays allowed whatever the order.
        #expect(Row.state(status: .granted, hasBeenAsked: false, isNext: false, nextTitle: "Accessibility") == .allowed)
        // The next one is asked for; nothing shows as missing before macOS has asked.
        #expect(Row.state(status: .denied, hasBeenAsked: false, isNext: true, nextTitle: "Accessibility") == .allow)
        #expect(Row.state(status: .unknown, hasBeenAsked: true, isNext: true, nextTitle: "Microphone") == .allow)
        // Asked and refused: macOS has to be told in System Settings.
        #expect(Row.state(status: .denied, hasBeenAsked: true, isNext: true, nextTitle: "Microphone") == .openSettings)
        // The rest wait, and name what they follow.
        #expect(Row.state(status: .denied, hasBeenAsked: false, isNext: false, nextTitle: "Accessibility") == .later(after: "Accessibility"))
    }

    @Test("Margin times use the 24-hour clock")
    func clock() {
        let date = Date(timeIntervalSince1970: 1_791_224_640) // 18:24 UTC
        #expect(ClockTime.string(date, timeZone: TimeZone(identifier: "UTC")!) == "18:24")
    }
}
