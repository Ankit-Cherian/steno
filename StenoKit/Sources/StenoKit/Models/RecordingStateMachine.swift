import Foundation

public enum RecordingMode: String, Sendable, Codable, Equatable {
    case pressToTalk
    case handsFree
}

public enum RecordingLifecycleState: String, Sendable, Codable, Equatable {
    case idle
    case recordingPressToTalk
    case recordingHandsFree
    case transcribing
}

public enum RecordingTransition: Sendable, Equatable {
    case start(mode: RecordingMode)
    case stop(mode: RecordingMode)
    case ignore(reason: String)
}

public struct RecordingStateMachine: Sendable, Equatable {
    public private(set) var state: RecordingLifecycleState

    public init(initialState: RecordingLifecycleState = .idle) {
        self.state = initialState
    }

    public mutating func handleOptionKeyDown() -> RecordingTransition {
        switch state {
        case .idle:
            state = .recordingPressToTalk
            return .start(mode: .pressToTalk)
        case .recordingPressToTalk:
            return .ignore(reason: "Already recording with Option hold-to-talk.")
        case .recordingHandsFree:
            return .ignore(reason: "Hands-free recording is active.")
        case .transcribing:
            return .ignore(reason: "Still transcribing the previous session.")
        }
    }

    public mutating func handleOptionKeyUp() -> RecordingTransition {
        switch state {
        case .recordingPressToTalk:
            state = .transcribing
            return .stop(mode: .pressToTalk)
        case .idle:
            return .ignore(reason: "No active Option recording.")
        case .recordingHandsFree:
            return .ignore(reason: "Hands-free recording is active.")
        case .transcribing:
            return .ignore(reason: "Still transcribing the previous session.")
        }
    }

    public mutating func handleHandsFreeToggle() -> RecordingTransition {
        switch state {
        case .idle:
            state = .recordingHandsFree
            return .start(mode: .handsFree)
        case .recordingHandsFree:
            state = .transcribing
            return .stop(mode: .handsFree)
        case .recordingPressToTalk:
            return .ignore(reason: "Option hold-to-talk is active.")
        case .transcribing:
            return .ignore(reason: "Still transcribing the previous session.")
        }
    }

    public mutating func markTranscriptionCompleted() {
        state = .idle
    }

    public mutating func markTranscriptionFailed() {
        state = .idle
    }
}
