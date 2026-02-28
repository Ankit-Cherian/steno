import Foundation

public actor StubAudioCaptureService: AudioCaptureService {
    private var queuedAudioURLs: [URL]

    public init(queuedAudioURLs: [URL] = []) {
        self.queuedAudioURLs = queuedAudioURLs
    }

    public func enqueue(audioURL: URL) {
        queuedAudioURLs.append(audioURL)
    }

    public func beginCapture(sessionID: SessionID) async throws {
        _ = sessionID
    }

    public func endCapture(sessionID: SessionID) async throws -> URL {
        _ = sessionID
        guard !queuedAudioURLs.isEmpty else {
            throw NSError(domain: "StubAudioCaptureService", code: 1)
        }
        return queuedAudioURLs.removeFirst()
    }

    public func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
    }
}

public struct FailingCleanupEngine: CleanupEngine, Sendable {
    public init() {}

    public func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        throw NSError(domain: "FailingCleanupEngine", code: 1)
    }
}

public actor CleanupCounter {
    private(set) public var calls = 0

    public init() {}

    public func increment() {
        calls += 1
    }

    public func value() -> Int {
        calls
    }
}

public struct CountingCleanupEngine: CleanupEngine, Sendable {
    public let counter: CleanupCounter

    public init(counter: CleanupCounter) {
        self.counter = counter
    }

    public func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        await counter.increment()
        return CleanTranscript(text: raw.text + " cleaned")
    }
}

public struct StaticTranscriptionEngine: TranscriptionEngine, Sendable {
    private let provider: @Sendable (URL, [String]) async throws -> RawTranscript

    public init(provider: @escaping @Sendable (URL, [String]) async throws -> RawTranscript) {
        self.provider = provider
    }

    public func transcribe(audioURL: URL, languageHints: [String]) async throws -> RawTranscript {
        try await provider(audioURL, languageHints)
    }
}
