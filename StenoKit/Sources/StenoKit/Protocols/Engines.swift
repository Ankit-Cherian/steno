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

    /// Returns the canonical capture file while recording is active, when the
    /// implementation can safely expose it for bounded read-only tailing.
    ///
    /// The URL continues to be owned by the capture service. Callers must not
    /// mutate, move, or delete the file and must treat `nil` as live preview
    /// being unavailable without affecting final capture.
    func canonicalCaptureURL(sessionID: SessionID) async -> URL?
}

public extension AudioCaptureService {
    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        _ = sessionID
        return nil
    }
}

/// Session-scoped authority to close canonical press-to-talk capture without
/// waiting for unrelated coordinator setup. The operation is idempotent: the
/// coordinator and its controller consume the same cached capture result.
public struct PressToTalkCaptureStopCapability: Sendable {
    public let sessionID: SessionID
    private let stopOperation: @Sendable () async throws -> Void
    private let cancelOperation: @Sendable () async -> Void
    private let markStopRequestedOperation: @Sendable () -> Void

    public init(
        sessionID: SessionID,
        stopOperation: @escaping @Sendable () async throws -> Void,
        cancelOperation: (@Sendable () async -> Void)? = nil,
        markStopRequestedOperation: @escaping @Sendable () -> Void = {}
    ) {
        self.sessionID = sessionID
        self.stopOperation = stopOperation
        self.cancelOperation = cancelOperation ?? {
            try? await stopOperation()
        }
        self.markStopRequestedOperation = markStopRequestedOperation
    }

    public func stopCapture() async throws {
        try await stopOperation()
    }

    public func cancelCapture() async {
        await cancelOperation()
    }

    public func markStopRequested() {
        markStopRequestedOperation()
    }
}

/// Converts audio files to raw text transcripts using speech recognition.
public protocol TranscriptionEngine: Sendable {
    /// Transcribes the audio at the given URL using dynamic request context.
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript

    /// Releases retained runtime resources. Implementations without retained state
    /// use the default no-op implementation.
    func shutdown() async

    /// Drops warm, reloadable resources without permanently shutting the engine down.
    func unloadRetainedResources() async
}

public extension TranscriptionEngine {
    func shutdown() async {}
    func unloadRetainedResources() async {}
}

/// Optional retained-runtime capability for local provisional transcription.
///
/// Implementations must keep hypotheses ephemeral, use the same resident model
/// as authoritative transcription, and derive the final result from the
/// completed canonical WAV rather than provisional text.
public protocol LiveTranscriptionEngine: TranscriptionEngine {
    func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession

    func appendLiveAudio(
        _ frame: LivePCMFrame,
        session: LiveTranscriptionSession
    ) async throws

    func requestLiveHypothesis(
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent

    func finishLiveTranscription(
        session: LiveTranscriptionSession,
        canonicalAudioURL: URL,
        streamSummary: LivePCMStreamSummary,
        request: TranscriptionRequest
    ) async throws -> RawTranscript

    func cancelLiveTranscription(session: LiveTranscriptionSession) async
}

/// Refines raw transcripts by applying style profiles, personal lexicon corrections, and filler word policies.
public protocol CleanupEngine: Sendable {
    /// Cleans up a raw transcript.
    ///
    /// - Parameters:
    ///   - raw: The raw transcript from the transcription engine.
    ///   - profile: Style profile to apply (capitalization, punctuation).
    ///   - lexicon: Personal lexicon for custom word corrections.
    func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
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
    ///
    /// A transport must honor cancellation before its first external side effect.
    /// After that commit point it must finish the complete insertion and return
    /// success, so callers never observe a partially inserted transcript.
    func insert(text: String, target: AppContext) async throws
}
