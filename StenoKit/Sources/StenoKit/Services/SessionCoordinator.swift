import Foundation

public enum SessionCoordinatorError: Error, LocalizedError {
    case sessionNotFound
    case runtimeUnavailable
    case shutDown

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found"
        case .runtimeUnavailable:
            return "The dictation runtime is temporarily unavailable"
        case .shutDown:
            return "The dictation runtime has shut down"
        }
    }
}

public actor SessionCoordinator {
    private struct ActiveSession: Sendable {
        var appContext: AppContext
        var startedAt: Date
        var monotonicStartedAt: ContinuousClock.Instant
    }

    private struct CapturedSession: Sendable {
        var active: ActiveSession
        var audioURL: URL
        var captureDurationMS: Int
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
    private let usageRecorder: (any UsageAnalyticsRecording)?
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    private var activeSessions: [SessionID: ActiveSession] = [:]
    private var capturedSessions: [SessionID: CapturedSession] = [:]
    private var endingSessionIDs: Set<SessionID> = []
    private var cancelledEndingSessionIDs: Set<SessionID> = []
    private var completingSessionIDs: Set<SessionID> = []
    private var cancelledCompletingSessionIDs: Set<SessionID> = []
    private var isShutDown = false
    private var isShutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var isRuntimeTransitioning = false
    private var runtimeTransitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var runtimeLifecycleGeneration: UInt64 = 0
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
        fallbackCleanupEngine: CleanupEngine = RuleBasedCleanupEngine(),
        usageRecorder: (any UsageAnalyticsRecording)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
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
        self.usageRecorder = usageRecorder
        self.now = now
        self.monotonicNow = monotonicNow
    }

    @discardableResult
    public func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        guard !isShutDown, !isRuntimeTransitioning else {
            throw isShutDown
                ? SessionCoordinatorError.shutDown
                : SessionCoordinatorError.runtimeUnavailable
        }
        let lifecycleGeneration = runtimeLifecycleGeneration
        let sessionID = SessionID()
        try await captureService.beginCapture(sessionID: sessionID)
        guard !isShutDown,
              !isRuntimeTransitioning,
              runtimeLifecycleGeneration == lifecycleGeneration
        else {
            await captureService.cancelCapture(sessionID: sessionID)
            throw isShutDown
                ? SessionCoordinatorError.shutDown
                : SessionCoordinatorError.runtimeUnavailable
        }
        activeSessions[sessionID] = ActiveSession(
            appContext: appContext,
            startedAt: now(),
            monotonicStartedAt: monotonicNow()
        )
        return sessionID
    }

    public func stopPressToTalk(sessionID: SessionID, languageHints: [String] = ["en-US"]) async throws -> InsertResult {
        try await endPressToTalkCapture(sessionID: sessionID)
        return try await completePressToTalk(
            sessionID: sessionID,
            languageHints: languageHints
        )
    }

    /// Ends microphone capture without waiting for transcription or insertion.
    public func endPressToTalkCapture(sessionID: SessionID) async throws {
        // Remove session before the first await so actor reentrancy cannot process
        // the same session twice while transcription/cleanup are in flight.
        guard let active = activeSessions.removeValue(forKey: sessionID) else {
            throw SessionCoordinatorError.sessionNotFound
        }

        endingSessionIDs.insert(sessionID)
        defer {
            endingSessionIDs.remove(sessionID)
            cancelledEndingSessionIDs.remove(sessionID)
        }

        let monotonicEndedAt = monotonicNow()
        let audioURL = try await captureService.endCapture(sessionID: sessionID)
        if cancelledEndingSessionIDs.contains(sessionID) {
            try? FileManager.default.removeItem(at: audioURL)
            throw CancellationError()
        }
        let captureDurationMS = Self.durationMilliseconds(
            from: active.monotonicStartedAt,
            to: monotonicEndedAt
        )
        capturedSessions[sessionID] = CapturedSession(
            active: active,
            audioURL: audioURL,
            captureDurationMS: captureDurationMS
        )
    }

    /// Transcribes and inserts audio whose capture has already ended.
    public func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String] = ["en-US"]
    ) async throws -> InsertResult {
        guard let captured = capturedSessions.removeValue(forKey: sessionID) else {
            throw SessionCoordinatorError.sessionNotFound
        }

        let active = captured.active
        let audioURL = captured.audioURL
        defer { try? FileManager.default.removeItem(at: audioURL) }
        completingSessionIDs.insert(sessionID)
        defer {
            completingSessionIDs.remove(sessionID)
            cancelledCompletingSessionIDs.remove(sessionID)
        }
        try checkCompletionOwnership(sessionID: sessionID)
        let request = TranscriptionRequest(
            languageHints: languageHints,
            appContext: active.appContext,
            hotTerms: await lexiconService.hotTerms(for: active.appContext, limit: 8)
        )
        try checkCompletionOwnership(sessionID: sessionID)
        var rawTranscript = try await transcriptionEngine.transcribe(audioURL: audioURL, request: request)
        try checkCompletionOwnership(sessionID: sessionID)

        if rawTranscript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return noSpeechResult()
        }

        if let sanitizedPromptContamination = sanitizePromptContamination(
            rawTranscript,
            request: request
        ) {
            if sanitizedPromptContamination.isEmpty {
                return noSpeechResult()
            }
            rawTranscript.text = sanitizedPromptContamination
        }

        // Capture what the user actually dictated before a snippet trigger can
        // expand into a much longer block of inserted text.
        let spokenText = rawTranscript.text
        rawTranscript.text = await snippetService.apply(to: rawTranscript.text, appContext: active.appContext)
        try checkCompletionOwnership(sessionID: sessionID)

        let profile = await styleProfileService.resolve(for: active.appContext)
        try checkCompletionOwnership(sessionID: sessionID)
        let lexicon = await lexiconService.snapshot(for: active.appContext)
        try checkCompletionOwnership(sessionID: sessionID)

        let cleanupResult = try await prepareCleanTranscript(
            raw: rawTranscript,
            profile: profile,
            lexicon: lexicon,
            appContext: active.appContext
        )
        try checkCompletionOwnership(sessionID: sessionID)

        var insertResult = await insertionService.insert(text: cleanupResult.transcript.text, target: active.appContext)
        let insertionCommitted = insertResult.status == .inserted || insertResult.status == .copiedOnly
        if !insertionCommitted {
            try checkCompletionOwnership(sessionID: sessionID)
        }
        insertResult.cleanupOutcome = cleanupResult.outcome

        let entry = TranscriptEntry(
            createdAt: active.startedAt,
            appBundleID: active.appContext.bundleIdentifier,
            rawText: rawTranscript.text,
            cleanText: cleanupResult.transcript.text,
            durationMS: rawTranscript.durationMS,
            // Audio artifacts are ephemeral; do not persist paths that are deleted on return.
            audioURL: nil,
            insertionStatus: insertResult.status
        )
        try await historyStore.append(entry: entry)
        if !insertionCommitted {
            try checkCompletionOwnership(sessionID: sessionID)
        }

        if let usageRecorder {
            let event = UsageEvent.live(
                from: entry,
                captureDurationMS: captured.captureDurationMS,
                edits: cleanupResult.transcript.edits,
                spokenText: spokenText
            )
            do {
                try await usageRecorder.record(event: event)
            } catch {
                StenoKitDiagnostics.logger.error("Usage analytics event write failed.")
                insertResult.usageAnalyticsWarning = "This session’s exact usage details couldn’t be saved. Insights may show an estimate."
            }
        }

        return insertResult
    }

    private func noSpeechResult() -> InsertResult {
        InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    private static func durationMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: end).components
        let milliseconds = (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        let rounded = milliseconds.rounded()
        guard rounded < Double(Int.max) else { return Int.max }
        return Int(rounded)
    }

    public func cancel(sessionID: SessionID) async {
        activeSessions.removeValue(forKey: sessionID)
        if endingSessionIDs.contains(sessionID) {
            cancelledEndingSessionIDs.insert(sessionID)
        }
        if let captured = capturedSessions.removeValue(forKey: sessionID) {
            try? FileManager.default.removeItem(at: captured.audioURL)
        }
        if completingSessionIDs.contains(sessionID) {
            cancelledCompletingSessionIDs.insert(sessionID)
        }
        await captureService.cancelCapture(sessionID: sessionID)
    }

    private func checkCompletionOwnership(sessionID: SessionID) throws {
        try Task.checkCancellation()
        guard completingSessionIDs.contains(sessionID),
              !cancelledCompletingSessionIDs.contains(sessionID)
        else {
            throw CancellationError()
        }
    }

    public func setHandsFreeEnabled(_ enabled: Bool) {
        isHandsFreeEnabled = enabled
    }

    public func unloadTranscriptionRuntime() async {
        guard !isShutDown else { return }
        runtimeLifecycleGeneration &+= 1
        await beginRuntimeTransition()
        guard !isShutDown else {
            endRuntimeTransition()
            return
        }
        await cancelAllSessions()
        await transcriptionEngine.unloadRetainedResources()
        endRuntimeTransition()
    }

    public func shutdown() async {
        if isShutDown {
            guard !isShutdownComplete else { return }
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        }
        isShutDown = true
        runtimeLifecycleGeneration &+= 1
        await beginRuntimeTransition()
        await cancelAllSessions()
        await transcriptionEngine.shutdown()
        endRuntimeTransition()
        isShutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelAllSessions() async {
        let activeIDs = Array(activeSessions.keys)
        activeSessions.removeAll()
        for captured in capturedSessions.values {
            try? FileManager.default.removeItem(at: captured.audioURL)
        }
        capturedSessions.removeAll()
        cancelledEndingSessionIDs.formUnion(endingSessionIDs)
        cancelledCompletingSessionIDs.formUnion(completingSessionIDs)

        for sessionID in activeIDs {
            await captureService.cancelCapture(sessionID: sessionID)
        }
    }

    private func beginRuntimeTransition() async {
        if !isRuntimeTransitioning {
            isRuntimeTransitioning = true
            return
        }

        await withCheckedContinuation { continuation in
            runtimeTransitionWaiters.append(continuation)
        }
    }

    private func endRuntimeTransition() {
        if runtimeTransitionWaiters.isEmpty {
            isRuntimeTransitioning = false
            return
        }

        let next = runtimeTransitionWaiters.removeFirst()
        next.resume()
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

    private func sanitizePromptContamination(
        _ transcript: RawTranscript,
        request: TranscriptionRequest
    ) -> String? {
        let trimmed = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard containsPromptMetadataLabel(trimmed) else { return nil }

        let promptFragments = WhisperRuntimeConfiguration.promptFragments(for: request)
        guard promptFragments.isEmpty == false else { return nil }

        let normalizedTranscript = normalizePromptComparable(trimmed)
        guard normalizedTranscript.isEmpty == false else { return nil }

        let normalizedPrompt = normalizePromptComparable(promptFragments.joined(separator: " "))
        let normalizedFragments = promptFragments.map(normalizePromptComparable).filter { !$0.isEmpty }

        if normalizedTranscript == normalizedPrompt || normalizedFragments.contains(normalizedTranscript) {
            return ""
        }

        let transcriptTokens = Set(normalizedTranscript.split(separator: " ").map(String.init))
        let promptTokens = Set(normalizedPrompt.split(separator: " ").map(String.init))
        if transcriptTokens.isEmpty == false && transcriptTokens.isSubset(of: promptTokens) {
            return ""
        }

        guard metadataLabelCount(in: trimmed) >= 2 else {
            return nil
        }

        let strippedLabels = stripPromptMetadataLabels(from: trimmed)
        let normalizedStripped = normalizePromptComparable(strippedLabels)
        guard normalizedStripped.isEmpty == false else { return "" }

        let strippedTokens = Set(normalizedStripped.split(separator: " ").map(String.init))
        if strippedTokens.isEmpty == false && strippedTokens.isSubset(of: promptTokens) {
            return ""
        }

        return strippedLabels == trimmed ? nil : strippedLabels
    }

    private func containsPromptMetadataLabel(_ text: String) -> Bool {
        text.range(
            of: #"(^|[.!?]\s*)(language|app|terms)\s*:"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func normalizePromptComparable(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func metadataLabelCount(in text: String) -> Int {
        let pattern = try? NSRegularExpression(
            pattern: #"(^|[.!?]\s*)(language|app|terms)\s*:"#,
            options: [.caseInsensitive]
        )
        let fullRange = NSRange(text.startIndex..., in: text)
        return pattern?.numberOfMatches(in: text, options: [], range: fullRange) ?? 0
    }

    private func stripPromptMetadataLabels(from text: String) -> String {
        text
            .replacingOccurrences(
                of: #"(^|[.!?]\s*)(language|app|terms)\s*:\s*"#,
                with: "$1",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
