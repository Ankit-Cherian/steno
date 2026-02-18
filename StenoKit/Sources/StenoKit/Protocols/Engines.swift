import Foundation

/// Manages microphone audio capture for dictation sessions.
///
/// Implementations handle platform-specific recording (e.g., AVFoundation on macOS).
public protocol AudioCaptureService: Sendable {
    /// Starts recording audio for the given session.
    func beginCapture(sessionID: SessionID) async throws

    /// Stops recording and returns the URL of the captured audio file.
    func endCapture(sessionID: SessionID) async throws -> URL

    /// Cancels an in-progress recording without producing output.
    func cancelCapture(sessionID: SessionID) async
}

/// Converts audio files to raw text transcripts using speech recognition.
public protocol TranscriptionEngine: Sendable {
    /// Transcribes the audio at the given URL, optionally using language hints.
    func transcribe(audioURL: URL, languageHints: [String]) async throws -> RawTranscript
}

/// Refines raw transcripts by applying style profiles, personal lexicon corrections, and filler word policies.
public protocol CleanupEngine: Sendable {
    /// Cleans up a raw transcript.
    ///
    /// - Parameters:
    ///   - raw: The raw transcript from the transcription engine.
    ///   - profile: Style profile to apply (capitalization, punctuation).
    ///   - lexicon: Personal lexicon for custom word corrections.
    ///   - tier: Controls cloud model selection for budget management.
    func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        tier: CloudModelTier
    ) async throws -> CleanTranscript
}

/// Provides system clipboard write access for text insertion fallback.
public protocol ClipboardService: Sendable {
    /// Copies the given text to the system clipboard.
    func setString(_ text: String) async throws
}

/// A strategy for inserting transcribed text into target applications.
public protocol InsertionTransport: Sendable {
    /// The insertion method this transport implements (direct typing, accessibility API, or clipboard).
    var method: InsertionMethod { get }

    /// Inserts the given text into the target application context.
    func insert(text: String, target: AppContext) async throws
}
