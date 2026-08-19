import Foundation

public enum RetainedWhisperRuntimeError: Error, LocalizedError, Equatable {
    case shutDown
    case invalidResponse
    case helperUnavailable
    case unsupportedConfiguration
    case staleResponse

    public var errorDescription: String? {
        switch self {
        case .shutDown:
            return "The retained transcription runtime has shut down."
        case .invalidResponse:
            return "The retained transcription runtime returned an invalid response."
        case .helperUnavailable:
            return "The retained transcription runtime is unavailable."
        case .unsupportedConfiguration:
            return "The retained transcription runtime does not support this configuration."
        case .staleResponse:
            return "The retained transcription runtime returned a stale response."
        }
    }
}

/// A terminal authoritative-final failure that has already consumed the
/// retained engine's one allowed canonical CLI fallback.
///
/// Callers must surface this error and must not retry the same canonical audio
/// through `transcribe(audioURL:request:)`. The retained engine also enforces
/// that contract for the lifetime of the engine instance.
public enum LiveTranscriptionFinalizationError: Error, LocalizedError, Equatable, Sendable {
    case authoritativeFallbackExhausted

    public var errorDescription: String? {
        "The authoritative transcription failed after its final local fallback was attempted."
    }
}

public struct RetainedWhisperTranscriptionConfiguration: Sendable, Equatable {
    public var helperExecutableURL: URL
    public var modelPath: URL
    public var threadCount: Int
    public var vadModelPath: URL?
    public var suppressNonSpeechTokens: Bool
    public var suppressRegex: String?
    public var beamSize: Int
    public var bestOf: Int
    public var modelLoadTimeout: Duration
    public var inferenceTimeout: Duration
    public var environment: [String: String]?

    public init(
        helperExecutableURL: URL,
        modelPath: URL,
        threadCount: Int,
        vadModelPath: URL?,
        suppressNonSpeechTokens: Bool,
        suppressRegex: String?,
        beamSize: Int = 5,
        bestOf: Int = 5,
        modelLoadTimeout: Duration = .seconds(120),
        inferenceTimeout: Duration = .seconds(180),
        environment: [String: String]? = nil
    ) {
        self.helperExecutableURL = helperExecutableURL
        self.modelPath = modelPath
        self.threadCount = max(1, threadCount)
        self.vadModelPath = vadModelPath
        self.suppressNonSpeechTokens = suppressNonSpeechTokens
        self.suppressRegex = suppressRegex
        self.beamSize = max(1, beamSize)
        self.bestOf = max(1, bestOf)
        self.modelLoadTimeout = modelLoadTimeout > .zero ? modelLoadTimeout : .seconds(120)
        self.inferenceTimeout = inferenceTimeout > .zero ? inferenceTimeout : .seconds(180)
        self.environment = environment
    }

    fileprivate var loadIdentity: LoadIdentity {
        LoadIdentity(
            helper: FileIdentity(url: helperExecutableURL),
            model: FileIdentity(url: modelPath),
            vad: vadModelPath.map(FileIdentity.init(url:))
        )
    }

    fileprivate struct LoadIdentity: Sendable, Equatable {
        var helper: FileIdentity
        var model: FileIdentity
        var vad: FileIdentity?
    }

    fileprivate struct FileIdentity: Sendable, Equatable {
        var canonicalPath: String
        var fileSize: UInt64?
        var modificationTime: Date?

        init(url: URL) {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            canonicalPath = resolved.path
            let values = try? resolved.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            fileSize = values?.fileSize.map(UInt64.init)
            modificationTime = values?.contentModificationDate
        }
    }
}

struct WhisperRuntimeRequest: Sendable {
    var id: UUID
    var generation: UInt64
    var audioURL: URL
    var language: String
    var prompt: String?
    var threadCount: Int
    var suppressNonSpeechTokens: Bool
    var suppressRegex: String?
    var vadModelPath: URL?
    var beamSize: Int
    var bestOf: Int
}

protocol WhisperRuntimeSession: Sendable {
    func transcribe(_ request: WhisperRuntimeRequest) async throws -> Data
    func shutdown() async
}

protocol WhisperRuntimeSessionFactory: Sendable {
    func makeSession(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> any WhisperRuntimeSession
}

public actor RetainedWhisperTranscriptionEngine: LiveTranscriptionEngine {
    private enum LiveLifecyclePhase: Equatable {
        case starting
        case active
        case finishing
        case cancelling
    }

    private struct PendingRequest {
        var id: UUID
        var audioURL: URL
        var request: TranscriptionRequest
        var continuation: CheckedContinuation<RawTranscript, Error>
    }

    private var configuration: RetainedWhisperTranscriptionConfiguration
    private let sessionFactory: any WhisperRuntimeSessionFactory
    private let fallback: any TranscriptionEngine
    private var session: (any WhisperRuntimeSession)?
    private var sessionIdentity: RetainedWhisperTranscriptionConfiguration.LoadIdentity?
    private var sessionShutdownTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var liveSessionIdentity: LiveTranscriptionSession?
    private var liveRuntimeSession: (any WhisperStreamingRuntimeSession)?
    private var liveLifecyclePhase: LiveLifecyclePhase?
    private var isLiveAppendInFlight = false
    private var isLiveHypothesisInFlight = false
    private var failedLiveSession: LiveTranscriptionSession?
    private var exhaustedCanonicalFinals: Set<String> = []
    private var pendingOrder: [UUID] = []
    private var pending: [UUID: PendingRequest] = [:]
    private var activeRequestID: UUID?
    private var activeTask: Task<Void, Never>?
    private var isShutDown = false
    private var isShutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var isRuntimeTransitioning = false
    private var runtimeTransitionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        configuration: RetainedWhisperTranscriptionConfiguration,
        sessionFactory: any WhisperRuntimeSessionFactory,
        fallback: any TranscriptionEngine
    ) {
        self.configuration = configuration
        self.sessionFactory = sessionFactory
        self.fallback = fallback
    }

    public init(
        configuration: RetainedWhisperTranscriptionConfiguration,
        fallback: any TranscriptionEngine
    ) {
        self.configuration = configuration
        self.sessionFactory = ProcessWhisperStreamingRuntimeSessionFactory()
        self.fallback = fallback
    }

    public func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        guard !isShutDown else {
            throw RetainedWhisperRuntimeError.shutDown
        }
        guard !isRuntimeTransitioning,
              liveSessionIdentity == nil,
              failedLiveSession == nil,
              activeRequestID == nil,
              pending.isEmpty
        else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }

        let configuration = self.configuration
        guard configuration.vadModelPath != nil else {
            // A provisional hypothesis is display-eligible only when the
            // configured local VAD can attest speech for that exact decode.
            // Final-only retained and CLI transcription remain available.
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        let requestGeneration = generation
        let pendingIdentity = LiveTranscriptionSession(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            runtimeGeneration: requestGeneration,
            runtimeIdentity: .pending
        )

        // Reserve the identity before loading or starting the helper. Actor
        // reentrancy must never admit a second live stream while this method is
        // suspended.
        liveSessionIdentity = pendingIdentity
        liveLifecyclePhase = .starting

        do {
            let runtimeSession = try await activeSession(for: configuration)
            guard let streamingSession = runtimeSession as? any WhisperStreamingRuntimeSession else {
                throw RetainedWhisperRuntimeError.unsupportedConfiguration
            }
            try Task.checkCancellation()
            guard liveSessionIdentity == pendingIdentity,
                  liveLifecyclePhase == .starting,
                  generation == requestGeneration,
                  !isShutDown,
                  !isRuntimeTransitioning
            else {
                throw CancellationError()
            }

            let runtimeIdentity = try await streamingSession.startStream(
                id: sessionID,
                generation: requestGeneration,
                configuration: streamConfiguration(for: request, configuration: configuration)
            )
            try Task.checkCancellation()
            guard liveSessionIdentity == pendingIdentity,
                  liveLifecyclePhase == .starting,
                  generation == requestGeneration,
                  !isShutDown,
                  !isRuntimeTransitioning
            else {
                await streamingSession.cancelStream(
                    id: sessionID,
                    generation: requestGeneration
                )
                throw CancellationError()
            }

            let identity = LiveTranscriptionSession(
                sessionID: sessionID,
                controllerGeneration: controllerGeneration,
                runtimeGeneration: requestGeneration,
                runtimeIdentity: runtimeIdentity
            )
            liveSessionIdentity = identity
            liveRuntimeSession = streamingSession
            liveLifecyclePhase = .active
            return identity
        } catch {
            let stillOwned = liveSessionIdentity == pendingIdentity
            if stillOwned {
                liveSessionIdentity = nil
                liveRuntimeSession = nil
                liveLifecyclePhase = nil
                isLiveAppendInFlight = false
                isLiveHypothesisInFlight = false
            }

            if !isUnsupportedStreamingCapability(error) {
                await invalidateSession()
            }
            if stillOwned {
                startNextIfNeeded()
            }
            throw error
        }
    }

    public func appendLiveAudio(
        _ frame: LivePCMFrame,
        session requestedSession: LiveTranscriptionSession
    ) async throws {
        guard frame.pcmS16LE.count.isMultiple(of: MemoryLayout<Int16>.size),
              let sampleCount = UInt32(exactly: frame.sampleCount)
        else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        let chunk = try WhisperStreamAudioChunk(
            sequence: frame.sequenceNumber,
            sampleOffset: frame.sampleOffset,
            sampleCount: sampleCount,
            samplesS16LE: frame.pcmS16LE
        )
        let runtime = try activeStreamingSession(for: requestedSession, phase: .active)
        guard !isLiveAppendInFlight else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        isLiveAppendInFlight = true

        do {
            try await runtime.append(
                chunk,
                streamID: requestedSession.sessionID,
                generation: requestedSession.runtimeGeneration
            )
            try Task.checkCancellation()
            guard liveSessionIdentity == requestedSession,
                  liveLifecyclePhase == .active,
                  generation == requestedSession.runtimeGeneration
            else {
                throw CancellationError()
            }
            isLiveAppendInFlight = false
        } catch {
            isLiveAppendInFlight = false
            if liveSessionIdentity == requestedSession,
               (liveLifecyclePhase == .finishing || liveLifecyclePhase == .cancelling) {
                throw error
            }
            await failLiveSessionIfCurrent(requestedSession)
            throw error
        }
    }

    public func requestLiveHypothesis(
        session requestedSession: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        let runtime = try activeStreamingSession(for: requestedSession, phase: .active)
        guard !isLiveAppendInFlight, !isLiveHypothesisInFlight else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        isLiveHypothesisInFlight = true

        do {
            let hypothesis = try await runtime.requestHypothesis(
                streamID: requestedSession.sessionID,
                generation: requestedSession.runtimeGeneration,
                revision: revision,
                watermark: decodedAudioWatermark
            )
            try Task.checkCancellation()
            guard liveSessionIdentity == requestedSession,
                  liveLifecyclePhase == .active,
                  generation == requestedSession.runtimeGeneration
            else {
                throw CancellationError()
            }
            let event = LiveTranscriptionEvent(
                session: requestedSession,
                revision: hypothesis.revision,
                decodedAudioWatermark: hypothesis.watermark,
                emittedAtMonotonicNanos: hypothesis.monotonicNanoseconds,
                fullHypothesisText: hypothesis.text,
                speechEvidence: hypothesis.speechEvidence
            )
            isLiveHypothesisInFlight = false
            return event
        } catch {
            isLiveHypothesisInFlight = false
            if liveSessionIdentity == requestedSession,
               (liveLifecyclePhase == .finishing || liveLifecyclePhase == .cancelling) {
                throw error
            }
            await failLiveSessionIfCurrent(requestedSession)
            throw error
        }
    }

    public func finishLiveTranscription(
        session requestedSession: LiveTranscriptionSession,
        canonicalAudioURL: URL,
        streamSummary: LivePCMStreamSummary,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        guard !isShutDown else {
            throw RetainedWhisperRuntimeError.shutDown
        }
        let sampleByteCount = UInt64(MemoryLayout<Int16>.size)
        guard streamSummary.byteCount.isMultiple(of: sampleByteCount),
              streamSummary.byteCount / sampleByteCount == streamSummary.sampleCount
        else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }

        // A failed append or provisional decode deliberately invalidates the
        // helper. The matching canonical final remains eligible for exactly one
        // CLI fallback without retrying that unhealthy helper.
        if failedLiveSession == requestedSession,
           generation == requestedSession.runtimeGeneration {
            failedLiveSession = nil
            return try await performLiveFallbackFinal(
                session: requestedSession,
                audioURL: canonicalAudioURL,
                request: request,
                generation: requestedSession.runtimeGeneration
            )
        }

        let runtime = try activeStreamingSession(for: requestedSession, phase: .active)
        let configuration = self.configuration
        liveLifecyclePhase = .finishing

        do {
            let data = try await runtime.finishStream(
                id: requestedSession.sessionID,
                generation: requestedSession.runtimeGeneration,
                request: WhisperStreamFinishRequest(
                    canonicalAudioURL: canonicalAudioURL,
                    expectedSampleCount: streamSummary.sampleCount,
                    audioFNV1a64: streamSummary.fnv1a64,
                    configuration: streamConfiguration(for: request, configuration: configuration)
                )
            )
            try Task.checkCancellation()
            guard liveSessionIdentity == requestedSession,
                  liveLifecyclePhase == .finishing,
                  generation == requestedSession.runtimeGeneration
            else {
                throw CancellationError()
            }
            guard let transcript = WhisperTranscriptDecoder.decodeRichJSON(data) else {
                throw RetainedWhisperRuntimeError.invalidResponse
            }

            liveSessionIdentity = nil
            liveRuntimeSession = nil
            liveLifecyclePhase = nil
            isLiveAppendInFlight = false
            isLiveHypothesisInFlight = false
            failedLiveSession = nil
            startNextIfNeeded()
            return transcript
        } catch is CancellationError {
            await failLiveSessionIfCurrent(requestedSession, allowFallback: false)
            throw CancellationError()
        } catch {
            let shouldFallback = liveSessionIdentity == requestedSession
                && liveLifecyclePhase == .finishing
                && generation == requestedSession.runtimeGeneration
                && !isShutDown
            await failLiveSessionIfCurrent(requestedSession, allowFallback: false)
            guard shouldFallback else {
                throw CancellationError()
            }
            return try await performLiveFallbackFinal(
                session: requestedSession,
                audioURL: canonicalAudioURL,
                request: request,
                generation: requestedSession.runtimeGeneration
            )
        }
    }

    public func cancelLiveTranscription(session requestedSession: LiveTranscriptionSession) async {
        if failedLiveSession == requestedSession {
            failedLiveSession = nil
            startNextIfNeeded()
            return
        }
        guard liveSessionIdentity == requestedSession else { return }
        let runtime = liveRuntimeSession
        liveLifecyclePhase = .cancelling
        if let runtime {
            await runtime.cancelStream(
                id: requestedSession.sessionID,
                generation: requestedSession.runtimeGeneration
            )
        }
        if liveSessionIdentity == requestedSession {
            liveSessionIdentity = nil
            liveRuntimeSession = nil
            liveLifecyclePhase = nil
            isLiveAppendInFlight = false
            isLiveHypothesisInFlight = false
            startNextIfNeeded()
        }
    }

    public func transcribe(
        audioURL: URL,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        guard !exhaustedCanonicalFinals.contains(canonicalAudioKey(audioURL)) else {
            throw LiveTranscriptionFinalizationError.authoritativeFallbackExhausted
        }
        let id = UUID()
        try Task.checkCancellation()

        let transcript = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    PendingRequest(
                        id: id,
                        audioURL: audioURL,
                        request: request,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancel(requestID: id)
            }
        }
        try Task.checkCancellation()
        return transcript
    }

    public func updateConfiguration(
        _ newConfiguration: RetainedWhisperTranscriptionConfiguration
    ) async {
        guard !isShutDown else { return }
        await beginRuntimeTransition()
        guard !isShutDown else {
            endRuntimeTransition()
            return
        }
        let configurationChanged = newConfiguration != configuration
        let identityChanged = newConfiguration.loadIdentity != configuration.loadIdentity
        configuration = newConfiguration
        if identityChanged {
            generation &+= 1
            await cancelOutstandingRequests()
            await cancelActiveLiveStream()
            await invalidateSession()
        } else if configurationChanged, liveSessionIdentity != nil {
            await cancelActiveLiveStream()
            generation &+= 1
        }
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
        await beginRuntimeTransition()
        generation &+= 1
        await cancelOutstandingRequests()
        await cancelActiveLiveStream()
        await invalidateSession()
        await fallback.shutdown()
        endRuntimeTransition()
        isShutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func unloadRetainedResources() async {
        guard !isShutDown else { return }
        await beginRuntimeTransition()
        guard !isShutDown else {
            endRuntimeTransition()
            return
        }
        generation &+= 1
        await cancelOutstandingRequests()
        await cancelActiveLiveStream()
        await invalidateSession()
        endRuntimeTransition()
    }

    /// Loads the retained runtime without performing inference.
    ///
    /// Production transcription remains lazy; this explicit preparation hook exists so
    /// benchmark tooling can measure model loading separately from the first inference.
    public func prepareRetainedResources() async throws {
        guard !isShutDown else {
            throw RetainedWhisperRuntimeError.shutDown
        }

        await beginRuntimeTransition()
        defer { endRuntimeTransition() }

        guard !isShutDown else {
            throw RetainedWhisperRuntimeError.shutDown
        }
        guard activeRequestID == nil,
              pending.isEmpty,
              liveSessionIdentity == nil,
              failedLiveSession == nil
        else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }

        let hadCompatibleSession = session != nil && sessionIdentity == configuration.loadIdentity
        do {
            _ = try await activeSession(for: configuration)
            try Task.checkCancellation()
        } catch {
            if !hadCompatibleSession {
                await invalidateSession()
            }
            throw error
        }
    }

    private func enqueue(_ request: PendingRequest) {
        if isShutDown {
            request.continuation.resume(throwing: RetainedWhisperRuntimeError.shutDown)
            return
        }
        pending[request.id] = request
        pendingOrder.append(request.id)
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard !isShutDown,
              !isRuntimeTransitioning,
              activeRequestID == nil,
              liveSessionIdentity == nil
        else { return }

        while let id = pendingOrder.first {
            pendingOrder.removeFirst()
            guard pending[id] != nil else { continue }
            activeRequestID = id
            let task = Task { [weak self] in
                guard let self else { return }
                let result: Result<RawTranscript, Error>
                do {
                    result = .success(try await self.execute(requestID: id))
                } catch {
                    result = .failure(error)
                }
                await self.finish(requestID: id, result: result)
            }
            activeTask = task
            return
        }
    }

    private func execute(requestID: UUID) async throws -> RawTranscript {
        guard let pendingRequest = pending[requestID], activeRequestID == requestID else {
            throw RetainedWhisperRuntimeError.staleResponse
        }
        try Task.checkCancellation()

        let requestGeneration = generation
        let configuration = self.configuration

        if let failedSession = failedLiveSession {
            if failedSession.runtimeGeneration == requestGeneration {
                failedLiveSession = nil
                return try await performFallbackFinal(
                    audioURL: pendingRequest.audioURL,
                    request: pendingRequest.request,
                    generation: requestGeneration,
                    requestID: requestID
                )
            }
            failedLiveSession = nil
        }

        do {
            let runtimeSession = try await activeSession(for: configuration)
            try Task.checkCancellation()
            guard activeRequestID == requestID, generation == requestGeneration else {
                throw RetainedWhisperRuntimeError.staleResponse
            }

            let runtimeRequest = WhisperRuntimeRequest(
                id: requestID,
                generation: requestGeneration,
                audioURL: pendingRequest.audioURL,
                language: normalizedLanguage(from: pendingRequest.request.languageHints.first),
                prompt: WhisperRuntimeConfiguration.buildPrompt(for: pendingRequest.request),
                threadCount: configuration.threadCount,
                suppressNonSpeechTokens: configuration.suppressNonSpeechTokens,
                suppressRegex: configuration.suppressRegex,
                vadModelPath: configuration.vadModelPath,
                beamSize: configuration.beamSize,
                bestOf: configuration.bestOf
            )

            let data = try await runtimeSession.transcribe(runtimeRequest)
            try Task.checkCancellation()
            guard activeRequestID == requestID, generation == requestGeneration else {
                throw RetainedWhisperRuntimeError.staleResponse
            }
            guard let transcript = WhisperTranscriptDecoder.decodeRichJSON(data) else {
                throw RetainedWhisperRuntimeError.invalidResponse
            }
            return transcript
        } catch is CancellationError {
            beginSessionShutdown()
            throw CancellationError()
        } catch RetainedWhisperRuntimeError.staleResponse {
            throw CancellationError()
        } catch {
            await invalidateSession()
            try Task.checkCancellation()
            guard activeRequestID == requestID, generation == requestGeneration else {
                throw CancellationError()
            }
            let transcript = try await fallback.transcribe(
                audioURL: pendingRequest.audioURL,
                request: pendingRequest.request
            )
            try Task.checkCancellation()
            guard activeRequestID == requestID, generation == requestGeneration else {
                throw CancellationError()
            }
            return transcript
        }
    }

    private func activeSession(
        for configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> any WhisperRuntimeSession {
        let identity = configuration.loadIdentity
        if let session, sessionIdentity == identity {
            return session
        }

        if session != nil {
            beginSessionShutdown()
        }
        await waitForSessionShutdown()

        let created = try await sessionFactory.makeSession(configuration: configuration)
        do {
            try Task.checkCancellation()
        } catch {
            await created.shutdown()
            throw error
        }
        guard !isShutDown else {
            await created.shutdown()
            throw RetainedWhisperRuntimeError.shutDown
        }
        session = created
        sessionIdentity = identity
        return created
    }

    private func finish(
        requestID: UUID,
        result: Result<RawTranscript, Error>
    ) {
        guard activeRequestID == requestID,
              let request = pending.removeValue(forKey: requestID)
        else {
            return
        }

        activeRequestID = nil
        activeTask = nil
        request.continuation.resume(with: result)
        startNextIfNeeded()
    }

    private func cancel(requestID: UUID) {
        if activeRequestID == requestID {
            activeTask?.cancel()
            return
        }

        if let request = pending.removeValue(forKey: requestID) {
            pendingOrder.removeAll { $0 == requestID }
            request.continuation.resume(throwing: CancellationError())
            return
        }

    }

    private func cancelOutstandingRequests() async {
        activeTask?.cancel()
        let task = activeTask

        let queuedIDs = pendingOrder.filter { $0 != activeRequestID }
        pendingOrder.removeAll { $0 != activeRequestID }
        for id in queuedIDs {
            if let request = pending.removeValue(forKey: id) {
                request.continuation.resume(throwing: CancellationError())
            }
        }

        await task?.value
    }

    private func invalidateSession() async {
        beginSessionShutdown()
        await waitForSessionShutdown()
    }

    private func activeStreamingSession(
        for requestedSession: LiveTranscriptionSession,
        phase: LiveLifecyclePhase
    ) throws -> any WhisperStreamingRuntimeSession {
        guard !isShutDown,
              !isRuntimeTransitioning,
              generation == requestedSession.runtimeGeneration,
              liveSessionIdentity == requestedSession,
              liveLifecyclePhase == phase,
              let liveRuntimeSession
        else {
            throw RetainedWhisperRuntimeError.staleResponse
        }
        return liveRuntimeSession
    }

    private func failLiveSessionIfCurrent(
        _ requestedSession: LiveTranscriptionSession,
        allowFallback: Bool = true
    ) async {
        guard liveSessionIdentity == requestedSession else { return }
        liveSessionIdentity = nil
        liveRuntimeSession = nil
        liveLifecyclePhase = nil
        isLiveAppendInFlight = false
        isLiveHypothesisInFlight = false
        if allowFallback, generation == requestedSession.runtimeGeneration, !isShutDown {
            failedLiveSession = requestedSession
        }
        await invalidateSession()
        startNextIfNeeded()
    }

    private func cancelActiveLiveStream() async {
        guard let identity = liveSessionIdentity else {
            failedLiveSession = nil
            return
        }
        if let liveRuntimeSession {
            liveLifecyclePhase = .cancelling
            await liveRuntimeSession.cancelStream(
                id: identity.sessionID,
                generation: identity.runtimeGeneration
            )
        }
        if liveSessionIdentity == identity {
            liveSessionIdentity = nil
            liveRuntimeSession = nil
            liveLifecyclePhase = nil
            isLiveAppendInFlight = false
            isLiveHypothesisInFlight = false
        }
        if failedLiveSession == identity {
            failedLiveSession = nil
        }
    }

    private func performFallbackFinal(
        audioURL: URL,
        request: TranscriptionRequest,
        generation requestGeneration: UInt64,
        requestID: UUID? = nil
    ) async throws -> RawTranscript {
        let transcript = try await fallback.transcribe(audioURL: audioURL, request: request)
        try Task.checkCancellation()
        guard !isShutDown, generation == requestGeneration else {
            throw CancellationError()
        }
        if let requestID {
            guard activeRequestID == requestID else {
                throw CancellationError()
            }
        }
        return transcript
    }

    private func performLiveFallbackFinal(
        session: LiveTranscriptionSession,
        audioURL: URL,
        request: TranscriptionRequest,
        generation requestGeneration: UInt64
    ) async throws -> RawTranscript {
        guard session.runtimeGeneration == requestGeneration else {
            throw CancellationError()
        }
        let key = canonicalAudioKey(audioURL)
        exhaustedCanonicalFinals.insert(key)

        do {
            let transcript = try await performFallbackFinal(
                audioURL: audioURL,
                request: request,
                generation: requestGeneration
            )
            exhaustedCanonicalFinals.remove(key)
            return transcript
        } catch is CancellationError {
            // Cancellation is already terminal for the owning coordinator task.
            // Keep the tombstone because the fallback may have crossed its
            // inference commit point before cancellation was observed.
            throw CancellationError()
        } catch {
            // Do not expose the fallback's implementation error as a retryable
            // live-stream failure. The canonical final has exhausted its one
            // allowed fallback and is now terminal.
            throw LiveTranscriptionFinalizationError.authoritativeFallbackExhausted
        }
    }

    private func canonicalAudioKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func streamConfiguration(
        for request: TranscriptionRequest,
        configuration: RetainedWhisperTranscriptionConfiguration
    ) -> WhisperStreamConfiguration {
        WhisperStreamConfiguration(
            language: normalizedLanguage(from: request.languageHints.first),
            prompt: WhisperRuntimeConfiguration.buildPrompt(for: request),
            threadCount: configuration.threadCount,
            suppressNonSpeechTokens: configuration.suppressNonSpeechTokens,
            suppressRegex: configuration.suppressRegex,
            vadModelPath: configuration.vadModelPath,
            beamSize: configuration.beamSize,
            bestOf: configuration.bestOf
        )
    }

    private func isUnsupportedStreamingCapability(_ error: Error) -> Bool {
        guard let runtimeError = error as? RetainedWhisperRuntimeError else { return false }
        return runtimeError == .unsupportedConfiguration
    }

    private func beginSessionShutdown() {
        guard let session else {
            sessionIdentity = nil
            return
        }
        self.session = nil
        sessionIdentity = nil
        let previousShutdown = sessionShutdownTask
        sessionShutdownTask = Task {
            await previousShutdown?.value
            await session.shutdown()
        }
    }

    private func waitForSessionShutdown() async {
        guard let shutdownTask = sessionShutdownTask else { return }
        await shutdownTask.value
        sessionShutdownTask = nil
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
            startNextIfNeeded()
            return
        }

        let next = runtimeTransitionWaiters.removeFirst()
        next.resume()
    }

    private func normalizedLanguage(from hint: String?) -> String {
        guard let hint else { return "en" }
        let lower = hint.lowercased()
        if lower == "en-us" || lower == "en" {
            return "en"
        }
        if lower.contains("-") {
            return String(lower.split(separator: "-").first ?? "en")
        }
        return lower.isEmpty ? "en" : lower
    }
}
