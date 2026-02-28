import Foundation

public enum SessionCoordinatorError: Error, LocalizedError {
    case sessionNotFound

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found"
        }
    }
}

public actor SessionCoordinator {
    private struct ActiveSession: Sendable {
        var appContext: AppContext
        var startedAt: Date
    }

    private struct CleanupExecutionResult: Sendable {
        var transcript: CleanTranscript
        var outcome: CleanupOutcome
    }

    private let captureService: AudioCaptureService
    private let transcriptionEngine: TranscriptionEngine
    private let cleanupEngine: CleanupEngine
    private let fallbackCleanupEngine: CleanupEngine
    private let insertionService: InsertionServiceProtocol
    private let historyStore: HistoryStoreProtocol
    private let lexiconService: PersonalLexiconService
    private let styleProfileService: StyleProfileService
    private let snippetService: SnippetService

    private var activeSessions: [SessionID: ActiveSession] = [:]
    private(set) var isHandsFreeEnabled: Bool = false

    public init(
        captureService: AudioCaptureService,
        transcriptionEngine: TranscriptionEngine,
        cleanupEngine: CleanupEngine,
        insertionService: InsertionServiceProtocol,
        historyStore: HistoryStoreProtocol,
        lexiconService: PersonalLexiconService,
        styleProfileService: StyleProfileService,
        snippetService: SnippetService = SnippetService(),
        fallbackCleanupEngine: CleanupEngine = RuleBasedCleanupEngine()
    ) {
        self.captureService = captureService
        self.transcriptionEngine = transcriptionEngine
        self.cleanupEngine = cleanupEngine
        self.insertionService = insertionService
        self.historyStore = historyStore
        self.lexiconService = lexiconService
        self.styleProfileService = styleProfileService
        self.snippetService = snippetService
        self.fallbackCleanupEngine = fallbackCleanupEngine
    }

    @discardableResult
    public func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        let sessionID = SessionID()
        try await captureService.beginCapture(sessionID: sessionID)
        activeSessions[sessionID] = ActiveSession(appContext: appContext, startedAt: Date())
        return sessionID
    }

    public func stopPressToTalk(sessionID: SessionID, languageHints: [String] = ["en-US"]) async throws -> InsertResult {
        guard let active = activeSessions.removeValue(forKey: sessionID) else {
            throw SessionCoordinatorError.sessionNotFound
        }

        let audioURL = try await captureService.endCapture(sessionID: sessionID)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        var rawTranscript = try await transcriptionEngine.transcribe(audioURL: audioURL, languageHints: languageHints)

        rawTranscript.text = await snippetService.apply(to: rawTranscript.text, appContext: active.appContext)

        let profile = await styleProfileService.resolve(for: active.appContext)
        let lexicon = await lexiconService.snapshot(for: active.appContext)

        let cleanupResult = try await prepareCleanTranscript(
            raw: rawTranscript,
            profile: profile,
            lexicon: lexicon,
            appContext: active.appContext
        )

        var insertResult = await insertionService.insert(text: cleanupResult.transcript.text, target: active.appContext)
        insertResult.cleanupOutcome = cleanupResult.outcome

        let entry = TranscriptEntry(
            appBundleID: active.appContext.bundleIdentifier,
            rawText: rawTranscript.text,
            cleanText: cleanupResult.transcript.text,
            // Audio artifacts are ephemeral; do not persist paths that are deleted on return.
            audioURL: nil,
            insertionStatus: insertResult.status
        )
        try await historyStore.append(entry: entry)

        return insertResult
    }

    public func cancel(sessionID: SessionID) async {
        activeSessions.removeValue(forKey: sessionID)
        await captureService.cancelCapture(sessionID: sessionID)
    }

    public func setHandsFreeEnabled(_ enabled: Bool) {
        isHandsFreeEnabled = enabled
    }

    private func prepareCleanTranscript(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        appContext: AppContext
    ) async throws -> CleanupExecutionResult {
        if profile.commandPolicy == .passthrough,
           appContext.isIDE,
           raw.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return CleanupExecutionResult(
                transcript: CleanTranscript(text: raw.text),
                outcome: CleanupOutcome(source: .localOnly)
            )
        }

        do {
            let cleaned = try await cleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)
            return CleanupExecutionResult(
                transcript: cleaned,
                outcome: CleanupOutcome(source: .localSuccess)
            )
        } catch {
            var fallback = try await fallbackCleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)
            let warning = "Primary cleanup unavailable, used local fallback."
            fallback.uncertaintyFlags.append(warning)
            return CleanupExecutionResult(
                transcript: fallback,
                outcome: CleanupOutcome(source: .localFallback, warning: warning)
            )
        }
    }
}
