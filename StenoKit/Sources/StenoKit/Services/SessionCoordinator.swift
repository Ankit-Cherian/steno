import Foundation

enum LiveCumulativeHypothesisReplacementReason: Sendable, Equatable {
    case noProvableOverlap
    case cumulativeLimitReached
}

enum LiveCumulativeHypothesisFailureReason: Sendable, Equatable {
    case invalidRollingWindow
    case oversizedRollingWindow
}

enum LiveCumulativeHypothesisAssembly: Sendable, Equatable {
    case accepted(String)
    case replacementWindow(
        text: String,
        reason: LiveCumulativeHypothesisReplacementReason
    )
    case unavailable(reason: LiveCumulativeHypothesisFailureReason)
}

private enum LiveHypothesisAssemblyError: Error {
    case unavailable(LiveCumulativeHypothesisFailureReason)
}

/// Bounded reconstruction for a decoder whose raw hypothesis is a rolling
/// window. It accepts ordinary revisions while they retain the reducer's stable
/// prefix, stitches only through a strong exact overlap at text boundaries,
/// and explicitly starts a replacement window when safe continuity is no
/// longer provable. Invalid or oversized raw input remains a hard failure.
struct LiveCumulativeHypothesisAssembler: Sendable {
    static let maximumUTF8Bytes = 16 * 1_024
    private static let minimumOverlapGraphemes = 24
    private static let minimumOverlapWords = 4

    private(set) var cumulativeText = ""

    mutating func assemble(
        rollingText: String,
        stablePrefix: String
    ) -> LiveCumulativeHypothesisAssembly {
        guard rollingText.contains(where: { !$0.isWhitespace }) else {
            return .unavailable(reason: .invalidRollingWindow)
        }
        guard rollingText.utf8.count <= Self.maximumUTF8Bytes else {
            return .unavailable(reason: .oversizedRollingWindow)
        }
        if cumulativeText.isEmpty || stablePrefix.isEmpty || rollingText.hasPrefix(stablePrefix) {
            cumulativeText = rollingText
            return .accepted(rollingText)
        }

        guard let overlap = strongestExactOverlap(
            cumulative: cumulativeText,
            rolling: rollingText
        ) else {
            cumulativeText = rollingText
            return .replacementWindow(
                text: rollingText,
                reason: .noProvableOverlap
            )
        }
        let candidate = cumulativeText + rollingText[overlap...]
        guard candidate.hasPrefix(stablePrefix) else {
            cumulativeText = rollingText
            return .replacementWindow(
                text: rollingText,
                reason: .noProvableOverlap
            )
        }
        guard candidate.utf8.count <= Self.maximumUTF8Bytes else {
            cumulativeText = rollingText
            return .replacementWindow(
                text: rollingText,
                reason: .cumulativeLimitReached
            )
        }
        cumulativeText = candidate
        return .accepted(candidate)
    }

    private func strongestExactOverlap(
        cumulative: String,
        rolling: String
    ) -> String.Index? {
        var candidateStart = cumulative.startIndex
        var best: (graphemes: Int, rollingEnd: String.Index)?
        while candidateStart < cumulative.endIndex {
            guard isTextBoundary(in: cumulative, at: candidateStart) else {
                candidateStart = cumulative.index(after: candidateStart)
                continue
            }
            let suffix = cumulative[candidateStart...]
            if rolling.hasPrefix(suffix) {
                let graphemes = suffix.count
                let rollingEnd = rolling.index(rolling.startIndex, offsetBy: graphemes)
                if graphemes >= Self.minimumOverlapGraphemes,
                   isTextBoundary(in: rolling, at: rollingEnd),
                   wordCount(in: suffix) >= Self.minimumOverlapWords,
                   (best == nil || graphemes > best!.graphemes) {
                    best = (graphemes, rollingEnd)
                }
            }
            candidateStart = cumulative.index(after: candidateStart)
        }
        return best?.rollingEnd
    }

    private func isTextBoundary(in text: String, at index: String.Index) -> Bool {
        guard index != text.startIndex, index != text.endIndex else { return true }
        let previous = text[text.index(before: index)]
        let current = text[index]
        return !previous.isLetter && !previous.isNumber
            || !current.isLetter && !current.isNumber
    }

    private func wordCount(in text: Substring) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }
}

public struct SessionStartOptions: Sendable, Equatable {
    public var controllerGeneration: UUID
    public var livePreviewEnabled: Bool
    public var nearbyContextEnabled: Bool
    public var languageHints: [String]

    public init(
        controllerGeneration: UUID = UUID(),
        livePreviewEnabled: Bool = false,
        nearbyContextEnabled: Bool = false,
        languageHints: [String] = ["en-US"]
    ) {
        self.controllerGeneration = controllerGeneration
        self.livePreviewEnabled = livePreviewEnabled
        self.nearbyContextEnabled = nearbyContextEnabled
        self.languageHints = languageHints
    }

    public static var disabled: SessionStartOptions {
        SessionStartOptions()
    }
}

public enum LiveTranscriptUnavailableReason: Sendable, Equatable {
    case canonicalCaptureUnavailable
    case runtimeUnavailable
    case streamFailed
}

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
    private static let minimumLiveHypothesisAdvanceSamples: UInt64 = 3_200

    private final class CaptureStopRequestFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var requestedAt: ContinuousClock.Instant?

        func markRequested(at instant: ContinuousClock.Instant) -> ContinuousClock.Instant {
            lock.withLock {
                if let requestedAt {
                    return requestedAt
                }
                requestedAt = instant
                return instant
            }
        }

        var isRequested: Bool {
            lock.withLock { requestedAt != nil }
        }
    }

    private struct CaptureStopReceipt: Sendable {
        var audioURL: URL
        var monotonicEndedAt: ContinuousClock.Instant
    }

    private enum CaptureStopOutcome: Sendable {
        case captured(CaptureStopReceipt)
        case failed(String)
    }

    private actor CaptureStopGate {
        private let captureService: any AudioCaptureService
        private let sessionID: SessionID
        private nonisolated let monotonicNow: @Sendable () -> ContinuousClock.Instant
        private nonisolated let requestFlag = CaptureStopRequestFlag()
        private var stopTask: Task<CaptureStopOutcome, Never>?
        private var outcome: CaptureStopOutcome?
        private var isCancelled = false
        private var didDisposeCapturedFile = false

        init(
            captureService: any AudioCaptureService,
            sessionID: SessionID,
            monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant
        ) {
            self.captureService = captureService
            self.sessionID = sessionID
            self.monotonicNow = monotonicNow
        }

        func stop() async throws -> CaptureStopReceipt {
            let monotonicEndedAt = requestFlag.markRequested(at: monotonicNow())
            if isCancelled {
                throw CancellationError()
            }
            if let outcome {
                return try Self.value(from: outcome)
            }

            let task: Task<CaptureStopOutcome, Never>
            if let stopTask {
                task = stopTask
            } else {
                let captureService = self.captureService
                let sessionID = self.sessionID
                let created = Task<CaptureStopOutcome, Never> {
                    do {
                        return CaptureStopOutcome.captured(
                            CaptureStopReceipt(
                                audioURL: try await captureService.endCapture(sessionID: sessionID),
                                monotonicEndedAt: monotonicEndedAt
                            )
                        )
                    } catch {
                        return CaptureStopOutcome.failed(error.localizedDescription)
                    }
                }
                stopTask = created
                task = created
            }

            let resolved = await task.value
            if outcome == nil {
                outcome = resolved
                stopTask = nil
            }
            guard !isCancelled else {
                disposeCapturedFileIfNeeded(from: resolved)
                throw CancellationError()
            }
            return try Self.value(from: resolved)
        }

        func cancel() async {
            _ = requestFlag.markRequested(at: monotonicNow())
            guard !isCancelled else { return }
            isCancelled = true

            if let outcome {
                await disposeOrCancelCapture(from: outcome)
                return
            }
            if let stopTask {
                let resolved = await stopTask.value
                outcome = resolved
                self.stopTask = nil
                await disposeOrCancelCapture(from: resolved)
                return
            }
            await captureService.cancelCapture(sessionID: sessionID)
        }

        func hasReceivedStopRequest() -> Bool {
            isCancelled || stopTask != nil || outcome != nil
        }

        nonisolated func markStopRequested() {
            _ = requestFlag.markRequested(at: monotonicNow())
        }

        nonisolated var hasSynchronousStopRequest: Bool {
            requestFlag.isRequested
        }

        private func disposeCapturedFileIfNeeded(from outcome: CaptureStopOutcome) {
            guard !didDisposeCapturedFile,
                  case .captured(let receipt) = outcome else { return }
            didDisposeCapturedFile = true
            try? FileManager.default.removeItem(at: receipt.audioURL)
        }

        private func disposeOrCancelCapture(from outcome: CaptureStopOutcome) async {
            switch outcome {
            case .captured:
                disposeCapturedFileIfNeeded(from: outcome)
            case .failed:
                await captureService.cancelCapture(sessionID: sessionID)
            }
        }

        private static func value(
            from outcome: CaptureStopOutcome
        ) throws -> CaptureStopReceipt {
            switch outcome {
            case .captured(let receipt):
                return receipt
            case .failed(let message):
                throw CaptureStopFailure(message: message)
            }
        }
    }

    private struct CaptureStopFailure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private final class LiveAppendActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var activeAppendCount = 0

        var isIdle: Bool {
            lock.withLock { activeAppendCount == 0 }
        }

        func begin() {
            lock.withLock { activeAppendCount += 1 }
        }

        func end() {
            lock.withLock {
                precondition(activeAppendCount > 0)
                activeAppendCount -= 1
            }
        }
    }

    #if os(macOS)
    private struct PreparedEditorCapture: Sendable {
        var handle: EditorTargetHandle?
        var continuationContext: ContinuationContextState
    }
    #endif

    private struct LivePipeline: Sendable {
        struct PendingHypothesis: Sendable {
            var watermark: UInt64
        }

        var identity: LiveTranscriptionSession
        var streamer: CanonicalWAVFrameStreamer
        var appendActivity = LiveAppendActivity()
        var pumpTask: Task<Void, Never>?
        var hypothesisTask: Task<Void, Never>?
        var pendingHypothesis: PendingHypothesis?
        var reducer: ProvisionalTranscriptReducer
        var request: TranscriptionRequest
        var revision: UInt64 = 0
        var decodedAudioWatermark: UInt64 = 0
        var hypothesisSchedulingEvaluationWatermark: UInt64 = 0
        var lastHypothesisWatermark: UInt64 = 0
        var hypothesisAssembler = LiveCumulativeHypothesisAssembler()
        var failed = false
        var unavailableNotified = false
    }

    private struct ActiveSession: Sendable {
        var appContext: AppContext
        var startedAt: Date
        var monotonicStartedAt: ContinuousClock.Instant
        var commitAuthorization: InsertionCommitAuthorization
        var captureStopGate: CaptureStopGate
        var livePipeline: LivePipeline?
        var setupTasks: [Task<Void, Never>]
        #if os(macOS)
        var editorTarget: EditorTargetHandle?
        var continuationContext: ContinuationContextState
        #endif
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
    private let liveSnapshotHandler: @Sendable (LiveTranscriptionSnapshot) async -> Void
    private let liveUnavailableHandler: @Sendable (SessionID, LiveTranscriptUnavailableReason) async -> Void
    #if os(macOS)
    private let editorTargetCapture: @Sendable (AppContext) -> Result<EditorTargetHandle, EditorTargetUnavailableReason>
    #endif

    private var activeSessions: [SessionID: ActiveSession] = [:]
    private var capturedSessions: [SessionID: CapturedSession] = [:]
    private var commitAuthorizations: [SessionID: InsertionCommitAuthorization] = [:]
    #if os(macOS)
    private var pendingEditorCaptures: [SessionID: PreparedEditorCapture] = [:]
    #endif
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
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        liveSnapshotHandler: @escaping @Sendable (LiveTranscriptionSnapshot) async -> Void = { _ in },
        liveUnavailableHandler: @escaping @Sendable (SessionID, LiveTranscriptUnavailableReason) async -> Void = { _, _ in },
        editorTargetCapture: @escaping @Sendable (AppContext) -> Result<EditorTargetHandle, EditorTargetUnavailableReason> = EditorTargetHandle.capture
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
        self.liveSnapshotHandler = liveSnapshotHandler
        self.liveUnavailableHandler = liveUnavailableHandler
        #if os(macOS)
        self.editorTargetCapture = editorTargetCapture
        #endif
    }

    @discardableResult
    public func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        try await startPressToTalk(appContext: appContext, options: .disabled)
    }

    @discardableResult
    public func startPressToTalk(
        appContext: AppContext,
        options: SessionStartOptions
    ) async throws -> SessionID {
        try await startPressToTalkWithCaptureStopCapability(
            appContext: appContext,
            options: options,
            captureStarted: { (_: PressToTalkCaptureStopCapability) in }
        )
    }

    @discardableResult
    public func startPressToTalk(
        appContext: AppContext,
        options: SessionStartOptions,
        captureStarted: @Sendable (SessionID) -> Void
    ) async throws -> SessionID {
        try await startPressToTalkWithCaptureStopCapability(
            appContext: appContext,
            options: options,
            captureStarted: { capability in
                captureStarted(capability.sessionID)
            }
        )
    }

    @discardableResult
    public func startPressToTalkWithCaptureStopCapability(
        appContext: AppContext,
        options: SessionStartOptions,
        captureStarted: @Sendable (PressToTalkCaptureStopCapability) -> Void
    ) async throws -> SessionID {
        guard !isShutDown, !isRuntimeTransitioning else {
            throw isShutDown
                ? SessionCoordinatorError.shutDown
                : SessionCoordinatorError.runtimeUnavailable
        }
        let lifecycleGeneration = runtimeLifecycleGeneration
        let sessionID = SessionID()
        try await captureService.beginCapture(sessionID: sessionID)
        do {
            try Task.checkCancellation()
        } catch {
            await captureService.cancelCapture(sessionID: sessionID)
            throw error
        }
        guard !isShutDown,
              !isRuntimeTransitioning,
              runtimeLifecycleGeneration == lifecycleGeneration
        else {
            await captureService.cancelCapture(sessionID: sessionID)
            throw isShutDown
                ? SessionCoordinatorError.shutDown
                : SessionCoordinatorError.runtimeUnavailable
        }
        let commitAuthorization = InsertionCommitAuthorization()
        let captureStopGate = CaptureStopGate(
            captureService: captureService,
            sessionID: sessionID,
            monotonicNow: monotonicNow
        )
        activeSessions[sessionID] = ActiveSession(
            appContext: appContext,
            startedAt: now(),
            monotonicStartedAt: monotonicNow(),
            commitAuthorization: commitAuthorization,
            captureStopGate: captureStopGate,
            livePipeline: nil,
            setupTasks: [],
            editorTarget: nil,
            continuationContext: .unavailable
        )
        commitAuthorizations[sessionID] = commitAuthorization

        // Capture and session ownership are established before the controller
        // enqueues any display or overlay work. The callback must remain
        // synchronous and nonblocking so exact target binding can proceed
        // immediately on this actor.
        captureStarted(PressToTalkCaptureStopCapability(
            sessionID: sessionID,
            stopOperation: {
                _ = try await captureStopGate.stop()
            },
            cancelOperation: {
                await captureStopGate.cancel()
            },
            markStopRequestedOperation: {
                captureStopGate.markStopRequested()
            }
        ))

        // Audio is already running. Bind the exact focused field synchronously
        // before start returns; only bounded context reads are deferred.
        var setupTasks: [Task<Void, Never>] = []
        if options.nearbyContextEnabled {
            let result = editorTargetCapture(appContext)
            if case .success(let handle) = result {
                activeSessions[sessionID]?.editorTarget = handle
            }
            guard !Task.isCancelled,
                  !captureStopGate.hasSynchronousStopRequest,
                  !(await captureStopGate.hasReceivedStopRequest()),
                  activeSessions[sessionID] != nil else {
                return sessionID
            }
            let allowsContext = Self.supportsAutomaticContinuation(
                appContext: appContext,
                languageHints: options.languageHints
            )
            setupTasks.append(Task.detached { [weak self] in
                let prepared = await Self.prepareEditorCapture(
                    result,
                    allowsContext: allowsContext
                )
                await self?.installEditorCapture(
                    prepared,
                    sessionID: sessionID
                )
            })
        }
        guard !Task.isCancelled,
              !captureStopGate.hasSynchronousStopRequest,
              !(await captureStopGate.hasReceivedStopRequest()),
              activeSessions[sessionID] != nil else {
            return sessionID
        }
        if options.livePreviewEnabled {
            setupTasks.append(Task.detached { [weak self] in
                await self?.prepareLivePipeline(
                    sessionID: sessionID,
                    appContext: appContext,
                    options: options
                )
            })
        }
        activeSessions[sessionID]?.setupTasks = setupTasks
        return sessionID
    }

    func liveHypothesisSchedulingEvaluationWatermark(
        sessionID: SessionID
    ) -> UInt64? {
        activeSessions[sessionID]?.livePipeline?.hypothesisSchedulingEvaluationWatermark
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

        // Stop scheduling provisional work immediately. Cancellation is not
        // awaited here: canonical capture closes first, and the caller can
        // release media before final inference begins in completePressToTalk.
        // The active-session removal is the stop signal. Do not cancel an
        // in-flight preview call: finish must be allowed to supersede it without
        // turning an ordinary stop into runtime-failure fallback.

        endingSessionIDs.insert(sessionID)
        defer {
            endingSessionIDs.remove(sessionID)
            cancelledEndingSessionIDs.remove(sessionID)
            #if os(macOS)
            if capturedSessions[sessionID] == nil {
                pendingEditorCaptures.removeValue(forKey: sessionID)
            }
            #endif
        }

        let captureStopReceipt = try await active.captureStopGate.stop()
        let audioURL = captureStopReceipt.audioURL
        if cancelledEndingSessionIDs.contains(sessionID) {
            await active.captureStopGate.cancel()
            throw CancellationError()
        }
        let captureDurationMS = Self.durationMilliseconds(
            from: active.monotonicStartedAt,
            to: captureStopReceipt.monotonicEndedAt
        )
        var capturedActive = active
        #if os(macOS)
        if let prepared = pendingEditorCaptures.removeValue(forKey: sessionID) {
            capturedActive.editorTarget = prepared.handle
            capturedActive.continuationContext = prepared.continuationContext
        }
        #endif
        capturedSessions[sessionID] = CapturedSession(
            active: capturedActive,
            audioURL: audioURL,
            captureDurationMS: captureDurationMS
        )
    }

    /// Transcribes and inserts audio whose capture has already ended.
    public func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String] = ["en-US"]
    ) async throws -> InsertResult {
        guard let pendingCaptured = capturedSessions[sessionID] else {
            throw SessionCoordinatorError.sessionNotFound
        }
        // Context binding may still be finishing after capture closed. Waiting
        // here cannot delay media resume, and lets a very short dictation retain
        // the same exact-target safety as a longer one.
        for task in pendingCaptured.active.setupTasks {
            await task.value
        }
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
            commitAuthorizations.removeValue(forKey: sessionID)
        }
        try checkCompletionOwnership(sessionID: sessionID)
        let request: TranscriptionRequest
        if let frozenLiveRequest = active.livePipeline?.request {
            request = frozenLiveRequest
        } else {
            request = TranscriptionRequest(
                languageHints: languageHints,
                appContext: active.appContext,
                hotTerms: await lexiconService.hotTerms(for: active.appContext, limit: 8)
            )
        }
        try checkCompletionOwnership(sessionID: sessionID)
        var rawTranscript = try await authoritativeTranscript(
            captured: captured,
            request: request,
            sessionID: sessionID
        )
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

        // Capture what the user actually dictated before a command or snippet
        // trigger can transform it into a different insertion payload.
        let spokenText = rawTranscript.text
        let continuationPolicy = DictationContinuationPolicy()
        let directivePlan = continuationPolicy.prepareDirective(in: rawTranscript.text)
        var cleanupTranscript = rawTranscript
        cleanupTranscript.text = directivePlan.textForCleanup
        cleanupTranscript.text = await snippetService.apply(
            to: cleanupTranscript.text,
            appContext: active.appContext
        )
        let historyRawText = directivePlan.kind == .none
            ? cleanupTranscript.text
            : rawTranscript.text
        try checkCompletionOwnership(sessionID: sessionID)

        let profile = await styleProfileService.resolve(for: active.appContext)
        try checkCompletionOwnership(sessionID: sessionID)
        let lexicon = await lexiconService.snapshot(for: active.appContext)
        try checkCompletionOwnership(sessionID: sessionID)

        let cleanupResult = try await prepareCleanTranscript(
            raw: cleanupTranscript,
            profile: profile,
            lexicon: lexicon,
            appContext: active.appContext
        )
        try checkCompletionOwnership(sessionID: sessionID)

        var cleanedTranscript = cleanupResult.transcript
        cleanedTranscript.text = continuationPolicy.applyDirective(
            directivePlan,
            toCleanedText: cleanedTranscript.text
        )
        if directivePlan.kind != .none {
            cleanedTranscript.edits.append(TranscriptEdit(
                kind: .commandTransform,
                from: spokenText,
                to: cleanedTranscript.text
            ))
        }

        #if os(macOS)
        let validatedContext = await revalidatedContinuationContext(for: active)
        try checkCompletionOwnership(sessionID: sessionID)
        let protectedTerms = Self.protectedTerms(request: request, lexicon: lexicon)
        let insertionPayload = continuationPolicy.shapeInsertionPayload(
            cleanedText: cleanedTranscript.text,
            context: validatedContext,
            protectedTerms: protectedTerms
        ).text
        try checkCompletionOwnership(sessionID: sessionID)
        let insertionCommitAuthorization = active.commitAuthorization
        var insertResult = await withTaskCancellationHandler {
            await insertionService.insert(
                text: insertionPayload,
                target: active.appContext,
                editorTarget: active.editorTarget,
                clipboardRecoveryText: cleanedTranscript.text,
                commitAuthorization: insertionCommitAuthorization
            )
        } onCancel: {
            // UI cancellation cancels the completion task directly. Invalidate
            // the same process-local authorization synchronously so an AX or
            // CGEvent commit cannot slip through while the insertion await is
            // suspended. A transport that already committed retains its
            // exactly-once owner-completes semantics.
            insertionCommitAuthorization.invalidate()
        }
        #else
        var insertResult = await insertionService.insert(
            text: cleanedTranscript.text,
            target: active.appContext
        )
        #endif
        let insertionCommitted = insertResult.status == .inserted || insertResult.status == .copiedOnly
        if !insertionCommitted {
            try checkCompletionOwnership(sessionID: sessionID)
        }
        insertResult.cleanupOutcome = cleanupResult.outcome

        let entry = TranscriptEntry(
            createdAt: active.startedAt,
            appBundleID: active.appContext.bundleIdentifier,
            rawText: historyRawText,
            cleanText: cleanedTranscript.text,
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
                edits: cleanedTranscript.edits,
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

    private func prepareLivePipeline(
        sessionID: SessionID,
        appContext: AppContext,
        options: SessionStartOptions
    ) async {
        guard !captureStopWasRequested(sessionID: sessionID) else { return }
        guard let liveEngine = transcriptionEngine as? any LiveTranscriptionEngine else {
            await notifyLiveUnavailable(
                sessionID: sessionID,
                reason: .runtimeUnavailable
            )
            return
        }
        guard let audioURL = await captureService.canonicalCaptureURL(sessionID: sessionID),
              activeSessions[sessionID] != nil,
              !captureStopWasRequested(sessionID: sessionID),
              let streamer = try? CanonicalWAVFrameStreamer(
                  sessionID: sessionID,
                  audioURL: audioURL,
                  maximumFramesPerPoll: 1
              ) else {
            await notifyLiveUnavailable(
                sessionID: sessionID,
                reason: .canonicalCaptureUnavailable
            )
            return
        }

        let request = TranscriptionRequest(
            languageHints: options.languageHints,
            appContext: appContext,
            hotTerms: await lexiconService.hotTerms(for: appContext, limit: 8)
        )
        guard activeSessions[sessionID] != nil,
              !captureStopWasRequested(sessionID: sessionID) else { return }

        do {
            let identity = try await liveEngine.startLiveTranscription(
                sessionID: sessionID,
                controllerGeneration: options.controllerGeneration,
                request: request
            )
            guard activeSessions[sessionID] != nil,
                  !captureStopWasRequested(sessionID: sessionID),
                  identity.sessionID == sessionID,
                  identity.controllerGeneration == options.controllerGeneration else {
                await liveEngine.cancelLiveTranscription(session: identity)
                return
            }

            activeSessions[sessionID]?.livePipeline = LivePipeline(
                identity: identity,
                streamer: streamer,
                reducer: ProvisionalTranscriptReducer(session: identity),
                request: request
            )
            let pump = Task { [weak self] in
                guard let self else { return }
                await self.runLivePump(sessionID: sessionID)
            }
            activeSessions[sessionID]?.livePipeline?.pumpTask = pump
        } catch is CancellationError {
            return
        } catch {
            guard !captureStopWasRequested(sessionID: sessionID) else { return }
            await notifyLiveUnavailable(
                sessionID: sessionID,
                reason: .runtimeUnavailable
            )
        }
    }

    private func runLivePump(sessionID: SessionID) async {
        while !Task.isCancelled {
            guard !captureStopWasRequested(sessionID: sessionID),
                  let streamer = activeSessions[sessionID]?.livePipeline?.streamer else {
                return
            }
            guard activeSessions[sessionID]?.livePipeline?.failed == false else { return }

            do {
                let poll = try await streamer.poll(sessionID: sessionID)
                try await processLiveFrames(poll.frames, sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch {
                await failLivePipeline(sessionID: sessionID)
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    private func processLiveFrames(
        _ frames: [LivePCMFrame],
        sessionID: SessionID
    ) async throws {
        guard !frames.isEmpty,
              !captureStopWasRequested(sessionID: sessionID),
              let liveEngine = transcriptionEngine as? any LiveTranscriptionEngine else {
            return
        }
        guard activeSessions[sessionID]?.livePipeline?.failed == false else { return }

        for frame in frames {
            try Task.checkCancellation()
            guard !captureStopWasRequested(sessionID: sessionID),
                  let pipeline = activeSessions[sessionID]?.livePipeline else {
                throw CancellationError()
            }
            let identity = pipeline.identity
            let appendActivity = pipeline.appendActivity
            appendActivity.begin()
            defer { appendActivity.end() }
            try await liveEngine.appendLiveAudio(frame, session: identity)
            try Task.checkCancellation()
            guard !captureStopWasRequested(sessionID: sessionID),
                  activeSessions[sessionID]?.livePipeline?.identity == identity else {
                throw CancellationError()
            }
            activeSessions[sessionID]?.livePipeline?.decodedAudioWatermark =
                frame.sampleOffset + UInt64(frame.sampleCount)
        }

        guard !captureStopWasRequested(sessionID: sessionID),
              let pipeline = activeSessions[sessionID]?.livePipeline else {
            return
        }
        activeSessions[sessionID]?.livePipeline?.hypothesisSchedulingEvaluationWatermark =
            pipeline.decodedAudioWatermark
        guard pipeline.decodedAudioWatermark >= pipeline.lastHypothesisWatermark
                + Self.minimumLiveHypothesisAdvanceSamples else {
            return
        }
        let pending = LivePipeline.PendingHypothesis(
            watermark: pipeline.decodedAudioWatermark
        )
        guard pipeline.hypothesisTask == nil else {
            activeSessions[sessionID]?.livePipeline?.pendingHypothesis = pending
            return
        }
        launchLiveHypothesis(pending, sessionID: sessionID)
    }

    private func launchLiveHypothesis(
        _ pending: LivePipeline.PendingHypothesis,
        sessionID: SessionID
    ) {
        guard !captureStopWasRequested(sessionID: sessionID),
              var pipeline = activeSessions[sessionID]?.livePipeline,
              !pipeline.failed,
              pipeline.hypothesisTask == nil else {
            return
        }
        let identity = pipeline.identity
        let revision = pipeline.revision &+ 1
        pipeline.revision = revision
        pipeline.lastHypothesisWatermark = pending.watermark
        pipeline.pendingHypothesis = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLiveHypothesis(
                sessionID: sessionID,
                identity: identity,
                revision: revision,
                watermark: pending.watermark
            )
        }
        pipeline.hypothesisTask = task
        activeSessions[sessionID]?.livePipeline = pipeline
    }

    private func performLiveHypothesis(
        sessionID: SessionID,
        identity: LiveTranscriptionSession,
        revision: UInt64,
        watermark: UInt64
    ) async {
        guard !captureStopWasRequested(sessionID: sessionID),
              let liveEngine = transcriptionEngine as? any LiveTranscriptionEngine else { return }
        do {
            let received = try await liveEngine.requestLiveHypothesis(
                session: identity,
                revision: revision,
                decodedAudioWatermark: watermark
            )
            try Task.checkCancellation()
            guard !captureStopWasRequested(sessionID: sessionID),
                  var current = activeSessions[sessionID]?.livePipeline,
                  current.identity == identity else {
                return
            }

            let isCorrelatedResponse = received.kind == .hypothesis
                && received.session == identity
                && received.revision == revision
                && received.decodedAudioWatermark == watermark
            let snapshot = current.reducer.snapshot
            let hasOrderingRejection = snapshot.lastAcceptedRevision.map {
                received.revision <= $0
            } == true
                || snapshot.decodedAudioWatermark.map {
                    received.decodedAudioWatermark < $0
                } == true
                || snapshot.emittedAtMonotonicNanos.map {
                    received.emittedAtMonotonicNanos < $0
                } == true
            let isSuppressedWithoutText = received.speechEvidence != .speechDetected
                || !received.fullHypothesisText.contains(where: { !$0.isWhitespace })

            // Correlation, ordering, and no-speech decisions never need the
            // rolling-window assembler. Reduce them first so rejected or
            // suppressed payloads cannot become reconstruction history.
            if !isCorrelatedResponse || hasOrderingRejection || isSuppressedWithoutText {
                var candidateReducer = current.reducer
                let reduction = candidateReducer.reduce(received)
                current.hypothesisTask = nil

                if isCorrelatedResponse {
                    // Exact correlated ordering rejections and suppressed
                    // hypotheses retain reducer counters/order watermarks.
                    current.reducer = candidateReducer
                } else if case .rejected = reduction.outcome {
                    // Preserve reducer rejection telemetry when its own
                    // identity/order checks reject an uncorrelated response.
                    current.reducer = candidateReducer
                }

                activeSessions[sessionID]?.livePipeline = current
                resumePendingLiveHypothesis(sessionID: sessionID, identity: identity)
                return
            }

            var candidateAssembler = current.hypothesisAssembler
            let assembledText: String
            let replacesContinuityWindow: Bool
            switch candidateAssembler.assemble(
                rollingText: received.fullHypothesisText,
                stablePrefix: current.reducer.snapshot.stablePrefix
            ) {
            case .accepted(let text):
                assembledText = text
                replacesContinuityWindow = false
            case .replacementWindow(let text, _):
                assembledText = text
                replacesContinuityWindow = true
            case .unavailable(let reason):
                throw LiveHypothesisAssemblyError.unavailable(reason)
            }
            let event = LiveTranscriptionEvent(
                kind: received.kind,
                session: received.session,
                revision: received.revision,
                decodedAudioWatermark: received.decodedAudioWatermark,
                emittedAtMonotonicNanos: received.emittedAtMonotonicNanos,
                fullHypothesisText: assembledText,
                speechEvidence: received.speechEvidence
            )
            var candidateReducer = current.reducer
            if replacesContinuityWindow {
                candidateReducer.beginContinuityWindowReplacement()
            }
            let reduction = candidateReducer.reduce(event)
            if reduction.outcome == .accepted {
                current.reducer = candidateReducer
                current.hypothesisAssembler = candidateAssembler
            } else if !replacesContinuityWindow {
                // Preserve existing rejection telemetry without committing a
                // speculative continuity reset.
                current.reducer = candidateReducer
            }
            current.hypothesisTask = nil
            activeSessions[sessionID]?.livePipeline = current
            if reduction.outcome == .accepted,
               !captureStopWasRequested(sessionID: sessionID) {
                await liveSnapshotHandler(reduction.snapshot)
            }
            // Read pending state after the callback suspension so any newer
            // watermark replaces the older descriptor. Active ownership is
            // required here, so ordinary stop never launches queued preview.
            resumePendingLiveHypothesis(sessionID: sessionID, identity: identity)
        } catch is CancellationError {
            if activeSessions[sessionID]?.livePipeline?.identity == identity {
                activeSessions[sessionID]?.livePipeline?.hypothesisTask = nil
            }
        } catch {
            if activeSessions[sessionID]?.livePipeline?.identity == identity {
                activeSessions[sessionID]?.livePipeline?.hypothesisTask = nil
                await failLivePipeline(sessionID: sessionID)
            }
        }
    }

    private func resumePendingLiveHypothesis(
        sessionID: SessionID,
        identity: LiveTranscriptionSession
    ) {
        guard let latest = activeSessions[sessionID]?.livePipeline,
              latest.identity == identity,
              let pending = latest.pendingHypothesis else {
            return
        }
        launchLiveHypothesis(pending, sessionID: sessionID)
    }

    private func failLivePipeline(sessionID: SessionID) async {
        guard !captureStopWasRequested(sessionID: sessionID),
              var pipeline = activeSessions[sessionID]?.livePipeline,
              !pipeline.failed else { return }
        pipeline.failed = true
        let shouldNotify = !pipeline.unavailableNotified
        pipeline.unavailableNotified = true
        activeSessions[sessionID]?.livePipeline = pipeline
        // Keep the identity and canonical stream alive. A retained engine marks
        // a failed preview internally and uses finishLiveTranscription to route
        // the completed WAV through its exactly-once authoritative fallback.
        if shouldNotify {
            await liveUnavailableHandler(sessionID, .streamFailed)
        }
    }

    private func notifyLiveUnavailable(
        sessionID: SessionID,
        reason: LiveTranscriptUnavailableReason
    ) async {
        guard activeSessions[sessionID] != nil,
              !captureStopWasRequested(sessionID: sessionID) else { return }
        await liveUnavailableHandler(sessionID, reason)
    }

    private func captureStopWasRequested(sessionID: SessionID) -> Bool {
        guard let active = activeSessions[sessionID] else { return true }
        return active.captureStopGate.hasSynchronousStopRequest
    }

    private func authoritativeTranscript(
        captured: CapturedSession,
        request: TranscriptionRequest,
        sessionID: SessionID
    ) async throws -> RawTranscript {
        guard let live = captured.active.livePipeline,
              let liveEngine = transcriptionEngine as? any LiveTranscriptionEngine else {
            return try await transcriptionEngine.transcribe(
                audioURL: captured.audioURL,
                request: request
            )
        }

        try checkCompletionOwnership(sessionID: sessionID)

        var completedSummary: LivePCMStreamSummary?
        do {
            // The pump may have already handed one canonical frame to the
            // runtime when capture closes. Give a healthy append a short,
            // content-free grace period to acknowledge before tail draining,
            // so finalization never races a second append. A stuck append must
            // not delay normal stop indefinitely; after the grace period the
            // runtime's exactly-once final path owns fail-closed fallback.
            let pumpAppendIsIdle = try await waitForLiveAppendIdle(
                live.appendActivity,
                sessionID: sessionID
            )
            var poll = try await live.streamer.finalize(sessionID: sessionID)
            var drainIterations = 0
            var acceptsTailAppends = pumpAppendIsIdle
            drainLoop: while true {
                for frame in poll.frames {
                    try checkCompletionOwnership(sessionID: sessionID)
                    if acceptsTailAppends {
                        do {
                            try await liveEngine.appendLiveAudio(frame, session: live.identity)
                        } catch {
                            // The live engine owns failed-stream fallback. Keep
                            // draining for byte-exact summary, then finish once.
                            acceptsTailAppends = false
                        }
                    }
                }
                switch poll.state {
                case .finalized(let finalizedSummary):
                    completedSummary = finalizedSummary
                    break drainLoop
                case .draining, .streaming, .waitingForHeader:
                    drainIterations += 1
                    guard drainIterations <= 4_096 else {
                        throw CanonicalWAVFrameStreamerError.inconsistentDataSize
                    }
                    poll = try await live.streamer.drain(sessionID: sessionID)
                case .cancelled, .staleSession:
                    throw CancellationError()
                }
            }
        } catch is CancellationError {
            await liveEngine.cancelLiveTranscription(session: live.identity)
            throw CancellationError()
        } catch {
            await liveEngine.cancelLiveTranscription(session: live.identity)
            try checkCompletionOwnership(sessionID: sessionID)
            return try await transcriptionEngine.transcribe(
                audioURL: captured.audioURL,
                request: request
            )
        }

        try checkCompletionOwnership(sessionID: sessionID)
        guard let summary = completedSummary else {
            throw CanonicalWAVFrameStreamerError.inconsistentDataSize
        }
        // From this ownership transfer onward, no coordinator fallback is
        // legal: the live engine either returns its authoritative result or its
        // single internal canonical fallback error propagates to the caller.
        return try await liveEngine.finishLiveTranscription(
            session: live.identity,
            canonicalAudioURL: captured.audioURL,
            streamSummary: summary,
            request: live.request
        )
    }

    private func waitForLiveAppendIdle(
        _ activity: LiveAppendActivity,
        sessionID: SessionID
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(150))
        while !activity.isIdle {
            try checkCompletionOwnership(sessionID: sessionID)
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    #if os(macOS)
    private nonisolated static func prepareEditorCapture(
        _ result: Result<EditorTargetHandle, EditorTargetUnavailableReason>,
        allowsContext: Bool
    ) async -> PreparedEditorCapture {
        guard !Task.isCancelled else {
            return PreparedEditorCapture(
                handle: nil,
                continuationContext: .unavailable
            )
        }
        switch result {
        case .failure:
            return PreparedEditorCapture(
                handle: nil,
                continuationContext: .unavailable
            )
        case .success(let handle):
            guard allowsContext,
                  supportsAutomaticContinuationSurface(metadata: handle.metadata) else {
                return PreparedEditorCapture(
                    handle: handle,
                    continuationContext: .unavailable
                )
            }
            let contextResult = await handle.context()
            guard !Task.isCancelled else {
                return PreparedEditorCapture(
                    handle: nil,
                    continuationContext: .unavailable
                )
            }
            switch contextResult {
            case .unavailable:
                return PreparedEditorCapture(
                    handle: handle,
                    continuationContext: .unavailable
                )
            case .available(let context):
                return PreparedEditorCapture(
                    handle: handle,
                    continuationContext: .validated(ContinuationContextSnapshot(
                        targetIdentityToken: handle.targetIdentityToken.uuidString,
                        leadingText: context.prefix,
                        trailingText: context.suffix,
                        boundaryStyle: continuationBoundaryStyle(
                            leadingText: context.prefix,
                            trailingText: context.suffix
                        )
                    ))
                )
            }
        }
    }

    private func installEditorCapture(
        _ prepared: PreparedEditorCapture,
        sessionID: SessionID
    ) {
        if activeSessions[sessionID] != nil {
            activeSessions[sessionID]?.editorTarget = prepared.handle
            activeSessions[sessionID]?.continuationContext = prepared.continuationContext
            return
        }
        if capturedSessions[sessionID] != nil {
            capturedSessions[sessionID]?.active.editorTarget = prepared.handle
            capturedSessions[sessionID]?.active.continuationContext = prepared.continuationContext
            return
        }
        if endingSessionIDs.contains(sessionID) {
            pendingEditorCaptures[sessionID] = prepared
        }
    }

    private func revalidatedContinuationContext(for active: ActiveSession) async -> ContinuationContextState {
        guard let handle = active.editorTarget else { return .unavailable }
        switch await handle.revalidate() {
        case .success:
            break
        case .failure(let reason):
            return Self.isTargetCompromised(reason) ? .drifted : .unavailable
        }
        guard case .validated = active.continuationContext else { return .unavailable }
        switch await handle.context() {
        case .available:
            return active.continuationContext
        case .unavailable(let reason):
            return Self.isTargetCompromised(reason) ? .drifted : .unavailable
        }
    }
    #endif

    private static func supportsAutomaticContinuation(
        appContext: AppContext,
        languageHints: [String]
    ) -> Bool {
        let supportedOrdinaryProseBundleIDs: Set<String> = [
            "com.apple.mail",
            "com.apple.notes",
            "com.apple.textedit",
        ]
        guard appContext != .unknown,
              !appContext.isIDE,
              !appContext.isRemoteDesktop,
              let language = languageHints.first?.lowercased(),
              language == "en" || language.hasPrefix("en-") || language.hasPrefix("en_"),
              supportedOrdinaryProseBundleIDs.contains(
                  appContext.bundleIdentifier.lowercased()
              ) else {
            return false
        }
        return true
    }

    private nonisolated static func supportsAutomaticContinuationSurface(
        metadata: EditorTargetMetadata
    ) -> Bool {
        guard !metadata.isProtected,
              metadata.subrole == nil else {
            return false
        }
        switch metadata.role {
        case "AXTextArea", "AXTextField":
            return true
        default:
            return false
        }
    }

    private enum ContinuationBoundaryScriptSignal: Equatable {
        case latin
        case number
        case eastAsianWithoutInterwordSpacing
        case thaiWithoutInterwordSpacing
        case ambiguous
    }

    /// Classifies only the nearest word-bearing grapheme on either side of the
    /// insertion point. English language preference plus a Latin boundary is
    /// positive evidence for interword spacing. Mixed or unrecognized scripts
    /// remain unknown; no-space behavior requires matching evidence on both
    /// sides of the boundary.
    nonisolated static func continuationBoundaryStyle(
        leadingText: String,
        trailingText: String
    ) -> ContinuationBoundaryStyle {
        let signals = [
            nearestBoundarySignalBeforeInsertion(in: leadingText),
            nearestBoundarySignalAfterInsertion(in: trailingText),
        ].compactMap { $0 }

        guard !signals.isEmpty,
              !signals.contains(.ambiguous) else {
            return .unknown
        }
        if signals.contains(.latin),
           signals.allSatisfy({ $0 == .latin || $0 == .number }) {
            return .usesInterwordSpacing
        }
        if signals.count == 2,
           signals.allSatisfy({ $0 == .eastAsianWithoutInterwordSpacing }) {
            return .doesNotUseInterwordSpacing
        }
        if signals.count == 2,
           signals.allSatisfy({ $0 == .thaiWithoutInterwordSpacing }) {
            return .doesNotUseInterwordSpacing
        }
        return .unknown
    }

    private nonisolated static func nearestBoundarySignalBeforeInsertion(
        in text: String
    ) -> ContinuationBoundaryScriptSignal? {
        for grapheme in text.reversed() where !isBoundarySeparator(grapheme) {
            return boundaryScriptSignal(for: grapheme)
        }
        return nil
    }

    private nonisolated static func nearestBoundarySignalAfterInsertion(
        in text: String
    ) -> ContinuationBoundaryScriptSignal? {
        for grapheme in text where !isBoundarySeparator(grapheme) {
            return boundaryScriptSignal(for: grapheme)
        }
        return nil
    }

    private nonisolated static func isBoundarySeparator(_ grapheme: Character) -> Bool {
        grapheme.isWhitespace || grapheme.isPunctuation
    }

    private nonisolated static func boundaryScriptSignal(
        for grapheme: Character
    ) -> ContinuationBoundaryScriptSignal {
        var signal: ContinuationBoundaryScriptSignal?
        for scalar in grapheme.unicodeScalars {
            if isCombiningMark(scalar) || isVariationSelector(scalar) {
                continue
            }
            let candidate: ContinuationBoundaryScriptSignal
            if isLatinScalar(scalar) {
                candidate = .latin
            } else if scalar.properties.numericType != nil {
                candidate = .number
            } else if isEastAsianNoSpacingScalar(scalar) {
                candidate = .eastAsianWithoutInterwordSpacing
            } else if isThaiScalar(scalar) {
                candidate = .thaiWithoutInterwordSpacing
            } else {
                return .ambiguous
            }
            if let signal, signal != candidate {
                return .ambiguous
            }
            signal = candidate
        }
        return signal ?? .ambiguous
    }

    private nonisolated static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private nonisolated static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value)
            || (0xE0100...0xE01EF).contains(scalar.value)
    }

    private nonisolated static func isLatinScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x00D6, 0x00D8...0x00F6, 0x00F8...0x024F,
             0x1D00...0x1DBF, 0x1E00...0x1EFF,
             0xA720...0xA7FF, 0xAB30...0xAB6F,
             0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return true
        default:
            return false
        }
    }

    private nonisolated static func isEastAsianNoSpacingScalar(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FFF, 0x3040...0x312F, 0x31A0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFF66...0xFF9D, 0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    private nonisolated static func isThaiScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x0E00...0x0E7F).contains(scalar.value)
    }

    private nonisolated static func isTargetCompromised(
        _ reason: EditorTargetUnavailableReason
    ) -> Bool {
        switch reason {
        case .applicationUnavailable,
             .applicationNotFrontmost,
             .bundleIdentifierMismatch,
             .processIdentityUnavailable,
             .focusedWindowUnavailable,
             .focusedElementUnavailable,
             .secureOrProtectedElement,
             .targetChanged:
            return true
        case .accessibilityPermissionMissing,
             .unsupportedElement,
             .selectionUnavailable,
             .malformedSelection,
             .characterCountUnavailable,
             .parameterizedTextUnavailable,
             .selectedTextNotSettable,
             .cancelled,
             .timedOut,
             .accessibilityError:
            return false
        }
    }

    private static func protectedTerms(
        request: TranscriptionRequest,
        lexicon: PersonalLexicon
    ) -> Set<String> {
        var terms = Set(request.hotTerms)
        for entry in lexicon.entries {
            terms.insert(entry.term)
            terms.insert(entry.preferred)
            terms.formUnion(entry.aliases)
        }
        return terms
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
        commitAuthorizations[sessionID]?.invalidate()
        var captureStopGate: CaptureStopGate?
        if let active = activeSessions.removeValue(forKey: sessionID) {
            captureStopGate = active.captureStopGate
            for task in active.setupTasks { task.cancel() }
            active.livePipeline?.pumpTask?.cancel()
            active.livePipeline?.hypothesisTask?.cancel()
            if let live = active.livePipeline,
               let engine = transcriptionEngine as? any LiveTranscriptionEngine {
                await live.streamer.cancel(sessionID: sessionID)
                await engine.cancelLiveTranscription(session: live.identity)
            }
        }
        if endingSessionIDs.contains(sessionID) {
            cancelledEndingSessionIDs.insert(sessionID)
        }
        #if os(macOS)
        pendingEditorCaptures.removeValue(forKey: sessionID)
        #endif
        if let captured = capturedSessions.removeValue(forKey: sessionID) {
            captureStopGate = captured.active.captureStopGate
            for task in captured.active.setupTasks { task.cancel() }
            captured.active.livePipeline?.pumpTask?.cancel()
            captured.active.livePipeline?.hypothesisTask?.cancel()
            if let live = captured.active.livePipeline,
               let engine = transcriptionEngine as? any LiveTranscriptionEngine {
                _ = await live.streamer.cancel(sessionID: sessionID)
                await engine.cancelLiveTranscription(session: live.identity)
            }
        }
        if completingSessionIDs.contains(sessionID) {
            cancelledCompletingSessionIDs.insert(sessionID)
        }
        commitAuthorizations.removeValue(forKey: sessionID)
        if let captureStopGate {
            await captureStopGate.cancel()
        } else if !endingSessionIDs.contains(sessionID),
                  !completingSessionIDs.contains(sessionID) {
            await captureService.cancelCapture(sessionID: sessionID)
        }
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
        for authorization in commitAuthorizations.values {
            authorization.invalidate()
        }
        commitAuthorizations.removeAll()
        let active = Array(activeSessions)
        activeSessions.removeAll()
        let captured = Array(capturedSessions)
        // Clear every actor-owned session registry before the first await.
        // Otherwise unload/shutdown cancellation can suspend in a helper call
        // and let a reentrant completion claim the same captured session.
        capturedSessions.removeAll()
        #if os(macOS)
        pendingEditorCaptures.removeAll()
        #endif
        cancelledEndingSessionIDs.formUnion(endingSessionIDs)
        cancelledCompletingSessionIDs.formUnion(completingSessionIDs)

        for (sessionID, captured) in captured {
            for task in captured.active.setupTasks { task.cancel() }
            captured.active.livePipeline?.pumpTask?.cancel()
            captured.active.livePipeline?.hypothesisTask?.cancel()
            if let live = captured.active.livePipeline,
               let engine = transcriptionEngine as? any LiveTranscriptionEngine {
                _ = await live.streamer.cancel(sessionID: sessionID)
                await engine.cancelLiveTranscription(session: live.identity)
            }
            await captured.active.captureStopGate.cancel()
        }

        for (sessionID, session) in active {
            for task in session.setupTasks { task.cancel() }
            session.livePipeline?.pumpTask?.cancel()
            session.livePipeline?.hypothesisTask?.cancel()
            if let live = session.livePipeline,
               let engine = transcriptionEngine as? any LiveTranscriptionEngine {
                await live.streamer.cancel(sessionID: sessionID)
                await engine.cancelLiveTranscription(session: live.identity)
            }
        }
        for (_, session) in active {
            await session.captureStopGate.cancel()
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
