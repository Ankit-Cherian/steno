import Foundation

/// A step of a dictation after its capture stops, reported as it finishes so each step can be
/// timed. A step carries no content: no words, app or device.
public enum DictationStep: Sendable, Equatable, CaseIterable {
    /// The recorder stopped and its audio file is finalized and checked.
    case captureClosed
    /// The audio is handed to the transcription engine.
    case transcriptionStarted
    /// The retained runtime was sent the recording.
    case helperRequested
    /// The retained runtime replied: it read the audio, ran VAD and decoded.
    case helperReplied
    /// The reply was parsed and recognizer artifacts were stripped from it.
    case artifactsStripped
    /// The engine returned the authoritative transcript.
    case transcribed
    /// Cleanup, snippets and spoken commands are applied.
    case cleanedUp
    /// The insertion chain returned.
    case inserted
    /// The dictation was written to History.
    case historySaved
    /// The dictation was written to the usage ledger.
    case usageRecorded
}

/// Receives each `DictationStep` as it finishes. Called from whichever task finished the step,
/// so it must be cheap and must not block.
public typealias DictationStepObserver = @Sendable (DictationStep) -> Void
