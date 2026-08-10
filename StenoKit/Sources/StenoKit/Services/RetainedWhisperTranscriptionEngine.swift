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

public actor RetainedWhisperTranscriptionEngine: TranscriptionEngine {
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
        self.sessionFactory = ProcessWhisperRuntimeSessionFactory()
        self.fallback = fallback
    }

    public func transcribe(
        audioURL: URL,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
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
        let identityChanged = newConfiguration.loadIdentity != configuration.loadIdentity
        configuration = newConfiguration
        if identityChanged {
            generation &+= 1
            await cancelOutstandingRequests()
            await invalidateSession()
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
        guard activeRequestID == nil, pending.isEmpty else {
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
        guard !isShutDown, !isRuntimeTransitioning, activeRequestID == nil else { return }

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
