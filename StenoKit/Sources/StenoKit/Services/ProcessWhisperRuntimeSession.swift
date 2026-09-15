#if os(macOS)
import CryptoKit
import Darwin
import Foundation

enum WhisperRuntimeProtocol {
    static let magic: UInt32 = 0x5354_5752
    static let version: UInt16 = 1
    static let maximumPayloadBytes = 64 * 1024 * 1024

    enum Operation: UInt16 {
        case load = 1
        case ready = 2
        case transcribe = 3
        case result = 4
        case error = 5
        case shutdown = 6
        case stopped = 7
        case cancelled = 8
    }

    struct Frame {
        var operation: Operation
        var requestID: UUID
        var generation: UInt64
        var payload: Data

        func encoded() throws -> Data {
            guard payload.count <= maximumPayloadBytes else {
                throw RetainedWhisperRuntimeError.invalidResponse
            }

            var data = Data()
            data.reserveCapacity(36 + payload.count)
            data.appendBigEndian(magic)
            data.appendBigEndian(version)
            data.appendBigEndian(operation.rawValue)
            data.appendUUID(requestID)
            data.appendBigEndian(generation)
            data.appendBigEndian(UInt32(payload.count))
            data.append(payload)
            return data
        }
    }

    static func decodeFrame(from handle: FileHandle) throws -> Frame {
        let header = try handle.readExactly(36)
        var reader = FrameDataReader(data: header)
        guard try reader.readUInt32() == magic,
              try reader.readUInt16() == version,
              let operation = Operation(rawValue: try reader.readUInt16())
        else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        let requestID = try reader.readUUID()
        let generation = try reader.readUInt64()
        let payloadLength = Int(try reader.readUInt32())
        guard payloadLength <= maximumPayloadBytes else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        let payload = try handle.readExactly(payloadLength)
        return Frame(
            operation: operation,
            requestID: requestID,
            generation: generation,
            payload: payload
        )
    }

    static func loadPayload(modelPath: URL) throws -> Data {
        var payload = Data()
        try payload.appendBoundedString(modelPath.path)
        return payload
    }

    static func transcriptionPayload(for request: WhisperRuntimeRequest) throws -> Data {
        var payload = Data()
        payload.appendBigEndian(UInt32(request.threadCount))
        payload.appendBigEndian(UInt32(request.beamSize))
        payload.appendBigEndian(UInt32(request.bestOf))
        let vocabularyPrompt = whisperVocabularyPrompt(
            prompt: request.prompt,
            vocabularyPrompt: request.vocabularyPrompt
        )
        var flags: UInt32 = 0
        if request.suppressNonSpeechTokens { flags |= 1 << 0 }
        if request.vadModelPath != nil { flags |= 1 << 1 }
        if vocabularyPrompt != nil { flags |= 1 << 2 }
        payload.appendBigEndian(flags)
        try payload.appendBoundedString(request.audioURL.path)
        try payload.appendBoundedString(request.language)
        try payload.appendOptionalBoundedString(request.prompt)
        try payload.appendOptionalBoundedString(request.suppressRegex)
        try payload.appendOptionalBoundedString(request.vadModelPath?.path)
        if let vocabularyPrompt {
            try payload.appendBoundedString(vocabularyPrompt)
        }
        return payload
    }
}

enum WhisperPipeSafety {
    static func suppressSIGPIPE(on fileDescriptor: Int32) throws {
        guard fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw RetainedWhisperRuntimeError.helperUnavailable
        }
    }
}

enum WhisperProcessExitWaiter {
    // Foundation can briefly retain a stale `isRunning` value after its child
    // has already been killed and reaped. Never convert that stale state into
    // an unbounded `waitUntilExit()` during application shutdown.
    static func wait(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        while isRunning: @escaping @Sendable () -> Bool
    ) async {
        await Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while isRunning(), clock.now < deadline {
                let remaining = clock.now.duration(to: deadline)
                try? await Task.sleep(for: min(pollInterval, remaining))
            }
        }.value
    }
}

private enum WhisperChildProcessEscalation {
    static func forceKillIfStillOwned(_ pid: pid_t) {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == 0 {
                // A zero result proves this PID is still our live child, so it
                // cannot have been recycled for an unrelated process.
                _ = kill(pid, SIGKILL)
                return
            }
            if result == -1, errno == EINTR {
                continue
            }
            // A positive result reaped the exited child. ECHILD means
            // Foundation already reaped it. Neither state authorizes a signal.
            return
        }
    }
}

enum WhisperRuntimeWatchdog {
    private static let maximumRecognizedCaptureSeconds = 6 * 60 * 60.0

    static func inferenceTimeout(minimum: Duration, audioURL: URL) -> Duration {
        guard let audioSeconds = pcmWaveDurationSeconds(at: audioURL),
              audioSeconds > 0,
              audioSeconds <= maximumRecognizedCaptureSeconds
        else {
            return minimum
        }

        let durationAwareMilliseconds = Int64(ceil((audioSeconds * 2 + 60) * 1_000))
        return max(minimum, .milliseconds(durationAwareMilliseconds))
    }

    private static func pcmWaveDurationSeconds(at audioURL: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: audioURL) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 1_048_576),
              header.count >= 44,
              header.prefix(4) == Data("RIFF".utf8),
              header.subdata(in: 8..<12) == Data("WAVE".utf8)
        else {
            return nil
        }

        var byteRate: UInt32?
        var dataByteCount: UInt32?
        var dataStartOffset: Int?
        var offset = 12
        while offset + 8 <= header.count {
            let identifier = header.subdata(in: offset..<(offset + 4))
            guard let chunkByteCount = littleEndianUInt32(header, at: offset + 4) else {
                return nil
            }
            let payloadOffset = offset + 8

            if identifier == Data("fmt ".utf8) {
                guard chunkByteCount >= 16,
                      Int(chunkByteCount) <= header.count - payloadOffset,
                      let formatTag = littleEndianUInt16(header, at: payloadOffset),
                      let channelCount = littleEndianUInt16(header, at: payloadOffset + 2),
                      let sampleRate = littleEndianUInt32(header, at: payloadOffset + 4),
                      let parsedByteRate = littleEndianUInt32(header, at: payloadOffset + 8),
                      let blockAlignment = littleEndianUInt16(header, at: payloadOffset + 12),
                      let bitsPerSample = littleEndianUInt16(header, at: payloadOffset + 14),
                      formatTag == 1,
                      channelCount == 1,
                      sampleRate == 16_000,
                      blockAlignment == 2,
                      bitsPerSample == 16,
                      UInt64(parsedByteRate) == UInt64(sampleRate) * UInt64(blockAlignment)
                else {
                    return nil
                }
                byteRate = parsedByteRate
            } else if identifier == Data("data".utf8) {
                dataByteCount = chunkByteCount
                dataStartOffset = payloadOffset
                break
            }

            let paddedByteCount = Int(chunkByteCount) + Int(chunkByteCount % 2)
            guard paddedByteCount <= Int.max - payloadOffset else { return nil }
            offset = payloadOffset + paddedByteCount
        }

        guard let byteRate, byteRate > 0,
              let dataByteCount,
              let dataStartOffset,
              let attributes = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value >= UInt64(dataStartOffset) + UInt64(dataByteCount)
        else {
            return nil
        }
        return Double(dataByteCount) / Double(byteRate)
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}

struct ProcessWhisperRuntimeSessionFactory: WhisperRuntimeSessionFactory {
    func makeSession(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> any WhisperRuntimeSession {
        guard FileManager.default.isExecutableFile(atPath: configuration.helperExecutableURL.path),
              FileManager.default.fileExists(atPath: configuration.modelPath.path)
        else {
            throw RetainedWhisperRuntimeError.helperUnavailable
        }
        if let vadModelPath = configuration.vadModelPath,
           !FileManager.default.fileExists(atPath: vadModelPath.path) {
            throw RetainedWhisperRuntimeError.helperUnavailable
        }

        return try await ProcessWhisperRuntimeSession.start(configuration: configuration)
    }
}

private struct ProcessWhisperRuntimeSession: WhisperRuntimeSession {
    let state: WhisperHelperProcessState
    let inferenceTimeout: Duration

    static func start(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> ProcessWhisperRuntimeSession {
        let state = try WhisperHelperProcessState(configuration: configuration)
        do {
            let requestID = UUID()
            let frame = WhisperRuntimeProtocol.Frame(
                operation: .load,
                requestID: requestID,
                generation: 0,
                payload: try WhisperRuntimeProtocol.loadPayload(modelPath: configuration.modelPath)
            )
            let response = try await state.exchange(
                frame,
                timeout: configuration.modelLoadTimeout
            )
            guard response.operation == .ready,
                  response.requestID == requestID,
                  response.generation == 0
            else {
                throw RetainedWhisperRuntimeError.invalidResponse
            }
            return ProcessWhisperRuntimeSession(
                state: state,
                inferenceTimeout: configuration.inferenceTimeout
            )
        } catch {
            await state.shutdown()
            throw error
        }
    }

    func transcribe(_ request: WhisperRuntimeRequest) async throws -> Data {
        let frame = WhisperRuntimeProtocol.Frame(
            operation: .transcribe,
            requestID: request.id,
            generation: request.generation,
            payload: try WhisperRuntimeProtocol.transcriptionPayload(for: request)
        )
        let response = try await state.exchange(
            frame,
            timeout: WhisperRuntimeWatchdog.inferenceTimeout(
                minimum: inferenceTimeout,
                audioURL: request.audioURL
            )
        )
        guard response.requestID == request.id,
              response.generation == request.generation
        else {
            throw RetainedWhisperRuntimeError.staleResponse
        }

        switch response.operation {
        case .result:
            return response.payload
        case .cancelled:
            throw CancellationError()
        case .error:
            var reader = FrameDataReader(data: response.payload)
            if response.payload.count == 4, (try? reader.readUInt32()) == 6 {
                throw RetainedWhisperRuntimeError.vadIntegrityFailure
            }
            throw RetainedWhisperRuntimeError.invalidResponse
        default:
            throw RetainedWhisperRuntimeError.invalidResponse
        }
    }

    func shutdown() async {
        await state.shutdown()
    }
}

private final class WhisperHelperProcessState: @unchecked Sendable {
    private let stateLock = NSLock()
    private let exchangeLock = NSLock()
    // Pipe reads can outlive an exchange deadline; keep them off the cooperative executor.
    private let exchangeQueue = DispatchQueue(label: "steno.runtime.exchange", qos: .userInitiated)
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var isTerminated = false

    init(configuration: RetainedWhisperTranscriptionConfiguration) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        do {
            try WhisperPipeSafety.suppressSIGPIPE(
                on: inputPipe.fileHandleForWriting.fileDescriptor
            )
        } catch {
            try? inputPipe.fileHandleForReading.close()
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            throw error
        }
        let process = Process()
        process.executableURL = configuration.helperExecutableURL
        process.arguments = ["--protocol-version", "1"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        var environment = configuration.environment ?? WhisperRuntimeConfiguration.processEnvironment(
            whisperCLIPath: configuration.helperExecutableURL.path,
            modelPath: configuration.modelPath.path
        )
        environment["STENO_PARENT_PID"] = String(getpid())
        process.environment = environment

        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            throw RetainedWhisperRuntimeError.helperUnavailable
        }

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
    }

    func exchange(
        _ frame: WhisperRuntimeProtocol.Frame,
        timeout: Duration
    ) async throws -> WhisperRuntimeProtocol.Frame {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: WhisperRuntimeProtocol.Frame.self) { group in
                group.addTask { [self] in
                    try await withCheckedThrowingContinuation { continuation in
                        exchangeQueue.async { [self] in
                            continuation.resume(with: Result { try blockingExchange(frame) })
                        }
                    }
                }
                group.addTask { [self] in
                    try await Task.sleep(for: timeout)
                    terminate()
                    throw RetainedWhisperRuntimeError.helperUnavailable
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else {
                    throw RetainedWhisperRuntimeError.helperUnavailable
                }
                return response
            }
        } onCancel: { [self] in
            terminate()
        }
    }

    func shutdown() async {
        let shouldRequestGracefulShutdown: Bool = stateLock.withLock {
            !isTerminated && process.isRunning
        }

        var gracefulShutdownAcknowledged = false
        if shouldRequestGracefulShutdown {
            let frame = WhisperRuntimeProtocol.Frame(
                operation: .shutdown,
                requestID: UUID(),
                generation: 0,
                payload: Data()
            )
            gracefulShutdownAcknowledged = await withTaskGroup(of: Bool.self) { group in
                group.addTask { [self] in
                    guard let response = try? await exchange(
                        frame,
                        timeout: .milliseconds(250)
                    ) else { return false }
                    return response.operation == .stopped
                        && response.requestID == frame.requestID
                        && response.generation == frame.generation
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(250))
                    return false
                }
                let acknowledged = await group.next() ?? false
                group.cancelAll()
                return acknowledged
            }
        }

        if gracefulShutdownAcknowledged {
            for _ in 0..<25 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        terminate()
        await WhisperProcessExitWaiter.wait { [process] in process.isRunning }
        closeHandles()
    }

    private func blockingExchange(
        _ frame: WhisperRuntimeProtocol.Frame
    ) throws -> WhisperRuntimeProtocol.Frame {
        exchangeLock.lock()
        defer { exchangeLock.unlock() }

        guard stateLock.withLock({ !isTerminated && process.isRunning }) else {
            throw RetainedWhisperRuntimeError.helperUnavailable
        }

        do {
            try input.write(contentsOf: frame.encoded())
            return try WhisperRuntimeProtocol.decodeFrame(from: output)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw RetainedWhisperRuntimeError.helperUnavailable
        }
    }

    private func terminate() {
        let pid: pid_t? = stateLock.withLock {
            guard !isTerminated else { return nil }
            isTerminated = true
            try? input.close()
            guard process.isRunning else { return nil }
            process.terminate()
            return process.processIdentifier
        }

        guard let pid, pid > 0 else {
            closeHandles()
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            WhisperChildProcessEscalation.forceKillIfStillOwned(pid)
        }
    }

    private func closeHandles() {
        try? input.close()
        try? output.close()
    }
}

/// The vocabulary prompt only travels alongside a non-empty initial prompt,
/// because the helper verifies prompt-conditioned output and has nothing to
/// verify otherwise.
func whisperVocabularyPrompt(prompt: String?, vocabularyPrompt: String?) -> String? {
    guard let prompt, !prompt.isEmpty,
          let vocabularyPrompt, !vocabularyPrompt.isEmpty else { return nil }
    return vocabularyPrompt
}

// MARK: - Streaming runtime protocol (v2)

/// Immutable recognition settings attached to a streaming capture.
///
/// Audio is always 16 kHz, mono, signed 16-bit little-endian PCM. Editor
/// context is deliberately not part of this type or the helper protocol.
struct WhisperStreamConfiguration: Sendable, Equatable {
    var language: String
    var prompt: String?
    var vocabularyPrompt: String?
    var threadCount: Int
    var suppressNonSpeechTokens: Bool
    var suppressRegex: String?
    var vadModelPath: URL?
    var beamSize: Int
    var bestOf: Int

    init(
        language: String,
        prompt: String?,
        vocabularyPrompt: String? = nil,
        threadCount: Int,
        suppressNonSpeechTokens: Bool,
        suppressRegex: String?,
        vadModelPath: URL?,
        beamSize: Int,
        bestOf: Int
    ) {
        self.language = language
        self.prompt = prompt
        self.vocabularyPrompt = vocabularyPrompt
        self.threadCount = max(1, threadCount)
        self.suppressNonSpeechTokens = suppressNonSpeechTokens
        self.suppressRegex = suppressRegex
        self.vadModelPath = vadModelPath
        self.beamSize = max(1, beamSize)
        self.bestOf = max(1, bestOf)
    }
}

struct WhisperStreamAudioChunk: Sendable, Equatable {
    static let maximumSampleCount = 16_384

    var sequence: UInt64
    var sampleOffset: UInt64
    var sampleCount: UInt32
    var samplesS16LE: Data

    init(
        sequence: UInt64,
        sampleOffset: UInt64,
        sampleCount: UInt32,
        samplesS16LE: Data
    ) throws {
        guard sampleCount > 0,
              sampleCount <= Self.maximumSampleCount,
              samplesS16LE.count == Int(sampleCount) * MemoryLayout<Int16>.size
        else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        self.sequence = sequence
        self.sampleOffset = sampleOffset
        self.sampleCount = sampleCount
        self.samplesS16LE = samplesS16LE
    }
}

struct WhisperStreamHypothesis: Sendable, Equatable {
    var revision: UInt64
    var watermark: UInt64
    var monotonicNanoseconds: UInt64
    var speechEvidence: LiveTranscriptionSpeechEvidence = .unknown
    var text: String
}

struct WhisperStreamFinishRequest: Sendable, Equatable {
    var canonicalAudioURL: URL
    var expectedSampleCount: UInt64
    var audioFNV1a64: UInt64
    var configuration: WhisperStreamConfiguration
}

protocol WhisperStreamingRuntimeSession: WhisperRuntimeSession {
    func startStream(
        id: UUID,
        generation: UInt64,
        configuration: WhisperStreamConfiguration
    ) async throws -> LiveTranscriptionRuntimeIdentity
    func append(
        _ chunk: WhisperStreamAudioChunk,
        streamID: UUID,
        generation: UInt64
    ) async throws
    func requestHypothesis(
        streamID: UUID,
        generation: UInt64,
        revision: UInt64,
        watermark: UInt64
    ) async throws -> WhisperStreamHypothesis
    func finishStream(
        id: UUID,
        generation: UInt64,
        request: WhisperStreamFinishRequest
    ) async throws -> Data
    func cancelStream(id: UUID, generation: UInt64) async
    func shutdown() async
}

struct ProcessWhisperStreamingRuntimeSessionFactory: WhisperRuntimeSessionFactory {
    func makeSession(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> any WhisperRuntimeSession {
        guard FileManager.default.isExecutableFile(atPath: configuration.helperExecutableURL.path),
              FileManager.default.fileExists(atPath: configuration.modelPath.path)
        else {
            throw RetainedWhisperRuntimeError.helperUnavailable
        }
        if let vadModelPath = configuration.vadModelPath,
           !FileManager.default.fileExists(atPath: vadModelPath.path) {
            throw RetainedWhisperRuntimeError.helperUnavailable
        }
        return try await ProcessWhisperStreamingRuntimeSession.start(configuration: configuration)
    }

    func makeStreamingSession(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> any WhisperStreamingRuntimeSession {
        let session = try await makeSession(configuration: configuration)
        guard let streaming = session as? any WhisperStreamingRuntimeSession else {
            throw RetainedWhisperRuntimeError.helperUnavailable
        }
        return streaming
    }
}

enum WhisperStreamingRuntimeProtocol {
    static let magic: UInt32 = 0x5354_5752
    static let version: UInt16 = 2
    static let headerByteCount = 36
    static let maximumPayloadBytes = 64 * 1024 * 1024
    static let maximumTextBytes = 16 * 1024
    static let maximumIdentityPayloadBytes = 512
    static let identitySchemaVersion: UInt32 = 2
    static let streamingCapability: UInt32 = 1 << 0
    static let identityAcknowledgementCapability: UInt32 = 1 << 1
    static let cooperativeCancellationCapability: UInt32 = 1 << 2
    static let terminalAcknowledgementCapability: UInt32 = 1 << 3
    static let previewSpeechEvidenceCapability: UInt32 = 1 << 4
    static let correlatedErrorCapability: UInt32 = 1 << 5
    static let asrContextTelemetryCapability: UInt32 = 1 << 6
    static let requiredCapabilities = streamingCapability
        | identityAcknowledgementCapability
        | cooperativeCancellationCapability
        | terminalAcknowledgementCapability
        | previewSpeechEvidenceCapability
        | correlatedErrorCapability
        | asrContextTelemetryCapability

    private static let maximumIdentityBytes = 128

    enum Operation: UInt16, Sendable {
        case load = 1
        case ready = 2
        case transcribe = 3
        case result = 4
        case error = 5
        case shutdown = 6
        case stopped = 7
        case cancelled = 8
        case streamStart = 9
        case streamStarted = 10
        case audioAppend = 11
        case audioAccepted = 12
        case streamDecode = 13
        case hypothesis = 14
        case streamFinish = 15
        case finalResult = 16
        case streamCancel = 17
    }

    struct Frame: Sendable {
        var operation: Operation
        var requestID: UUID
        var generation: UInt64
        var payload: Data

        func encoded() throws -> Data {
            guard payload.count <= maximumPayloadBytes else {
                throw RetainedWhisperRuntimeError.unsupportedConfiguration
            }
            var data = Data()
            data.reserveCapacity(headerByteCount + payload.count)
            data.appendBigEndian(magic)
            data.appendBigEndian(version)
            data.appendBigEndian(operation.rawValue)
            data.appendUUID(requestID)
            data.appendBigEndian(generation)
            data.appendBigEndian(UInt32(payload.count))
            data.append(payload)
            return data
        }
    }

    static func decodeFrame(from handle: FileHandle) throws -> Frame {
        let header = try handle.readExactly(headerByteCount)
        var reader = FrameDataReader(data: header)
        guard try reader.readUInt32() == magic,
              try reader.readUInt16() == version,
              let operation = Operation(rawValue: try reader.readUInt16())
        else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        let requestID = try reader.readUUID()
        let generation = try reader.readUInt64()
        let payloadLength = Int(try reader.readUInt32())
        guard let operationPayloadLimit = responsePayloadLimit(for: operation),
              payloadLength <= operationPayloadLimit
        else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        return Frame(
            operation: operation,
            requestID: requestID,
            generation: generation,
            payload: try handle.readExactly(payloadLength)
        )
    }

    static func loadPayload(
        modelPath: URL,
        identity: LiveTranscriptionRuntimeIdentity
    ) throws -> Data {
        var payload = Data()
        try payload.appendBoundedString(modelPath.path)
        try payload.appendBoundedString(identity.runtimeIdentifier)
        try payload.appendBoundedString(identity.modelIdentifier)
        try payload.appendBoundedString(identity.vadIdentifier ?? "")
        return payload
    }

    private static func responsePayloadLimit(for operation: Operation) -> Int? {
        switch operation {
        case .ready, .streamStarted:
            return maximumIdentityPayloadBytes
        case .stopped, .cancelled:
            return 0
        case .error:
            return 16
        case .audioAccepted:
            return 16
        case .hypothesis:
            return 32 + maximumTextBytes
        case .result, .finalResult:
            return maximumPayloadBytes
        case .load, .transcribe, .shutdown, .streamStart, .audioAppend,
             .streamDecode, .streamFinish, .streamCancel:
            return nil
        }
    }

    static func streamConfigurationPayload(
        _ configuration: WhisperStreamConfiguration,
        identity: LiveTranscriptionRuntimeIdentity
    ) throws -> Data {
        guard configuration.threadCount <= Int(UInt32.max),
              configuration.beamSize <= Int(UInt32.max),
              configuration.bestOf <= Int(UInt32.max),
              try configuration.vadModelPath.map({ try fileIdentityToken($0) }) == identity.vadIdentifier
        else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        var payload = Data()
        payload.appendBigEndian(UInt32(configuration.threadCount))
        payload.appendBigEndian(UInt32(configuration.beamSize))
        payload.appendBigEndian(UInt32(configuration.bestOf))
        let vocabularyPrompt = whisperVocabularyPrompt(
            prompt: configuration.prompt,
            vocabularyPrompt: configuration.vocabularyPrompt
        )
        var flags: UInt32 = 0
        if configuration.suppressNonSpeechTokens { flags |= 1 << 0 }
        if configuration.vadModelPath != nil { flags |= 1 << 1 }
        if vocabularyPrompt != nil { flags |= 1 << 2 }
        payload.appendBigEndian(flags)
        try payload.appendBoundedString(configuration.language)
        try payload.appendOptionalBoundedString(configuration.prompt)
        try payload.appendOptionalBoundedString(configuration.suppressRegex)
        try payload.appendOptionalBoundedString(configuration.vadModelPath?.path)
        try payload.appendBoundedString(identity.vadIdentifier ?? "")
        if let vocabularyPrompt {
            try payload.appendBoundedString(vocabularyPrompt)
        }
        return payload
    }

    static func appendPayload(_ chunk: WhisperStreamAudioChunk) -> Data {
        var payload = Data()
        payload.reserveCapacity(20 + chunk.samplesS16LE.count)
        payload.appendBigEndian(chunk.sequence)
        payload.appendBigEndian(chunk.sampleOffset)
        payload.appendBigEndian(chunk.sampleCount)
        payload.append(chunk.samplesS16LE)
        return payload
    }

    static func decodePayload(revision: UInt64, watermark: UInt64) -> Data {
        var payload = Data()
        payload.appendBigEndian(revision)
        payload.appendBigEndian(watermark)
        return payload
    }

    static func finishPayload(
        _ request: WhisperStreamFinishRequest,
        identity: LiveTranscriptionRuntimeIdentity
    ) throws -> Data {
        var payload = Data()
        payload.appendBigEndian(request.expectedSampleCount)
        payload.appendBigEndian(request.audioFNV1a64)
        try payload.appendBoundedString(request.canonicalAudioURL.path)
        payload.append(try streamConfigurationPayload(request.configuration, identity: identity))
        return payload
    }

    static func parseIdentity(_ payload: Data) throws -> LiveTranscriptionRuntimeIdentity {
        guard payload.count <= maximumIdentityPayloadBytes else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        var reader = FrameDataReader(data: payload)
        guard try reader.readUInt32() == identitySchemaVersion,
              try reader.readUInt32() & requiredCapabilities == requiredCapabilities
        else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        let runtime = try reader.readString(maximumByteCount: maximumIdentityBytes)
        let model = try reader.readString(maximumByteCount: maximumIdentityBytes)
        let vad = try reader.readString(maximumByteCount: maximumIdentityBytes)
        let currentASRContextCount = try reader.readUInt32()
        let peakASRContextCount = try reader.readUInt32()
        guard reader.remainingByteCount == 0,
              isOpaqueIdentity(runtime),
              isOpaqueIdentity(model),
              vad.isEmpty || isOpaqueIdentity(vad),
              currentASRContextCount <= peakASRContextCount
        else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        return LiveTranscriptionRuntimeIdentity(
            protocolVersion: version,
            runtimeIdentifier: runtime,
            modelIdentifier: model,
            vadIdentifier: vad.isEmpty ? nil : vad,
            currentASRContextCount: currentASRContextCount,
            peakASRContextCount: peakASRContextCount
        )
    }

    static func expectedIdentity(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) throws -> LiveTranscriptionRuntimeIdentity {
        LiveTranscriptionRuntimeIdentity(
            protocolVersion: version,
            runtimeIdentifier: UUID().uuidString.lowercased(),
            modelIdentifier: try fileIdentityToken(configuration.modelPath),
            vadIdentifier: try configuration.vadModelPath.map { try fileIdentityToken($0) },
            currentASRContextCount: 0,
            peakASRContextCount: 0
        )
    }

    static func hasExpectedConfiguration(
        _ observed: LiveTranscriptionRuntimeIdentity,
        expected: LiveTranscriptionRuntimeIdentity
    ) -> Bool {
        observed.protocolVersion == expected.protocolVersion
            && observed.runtimeIdentifier == expected.runtimeIdentifier
            && observed.modelIdentifier == expected.modelIdentifier
            && observed.vadIdentifier == expected.vadIdentifier
    }

    static func hasSingleResidentASRContext(
        _ identity: LiveTranscriptionRuntimeIdentity
    ) -> Bool {
        identity.currentASRContextCount == 1
            && identity.peakASRContextCount == 1
    }

    private static func fileIdentityToken(_ url: URL) throws -> String {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date
        else {
            throw RetainedWhisperRuntimeError.helperUnavailable
        }
        let source = "\(canonical.path.utf8.count):\(canonical.path)|\(size)|\(modified.timeIntervalSince1970.bitPattern)"
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isOpaqueIdentity(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumIdentityBytes
        else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    static func parseAccepted(_ payload: Data) throws -> (sequence: UInt64, watermark: UInt64) {
        guard payload.count == 16 else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        var reader = FrameDataReader(data: payload)
        return (try reader.readUInt64(), try reader.readUInt64())
    }

    static func parseHypothesis(_ payload: Data) throws -> WhisperStreamHypothesis {
        var reader = FrameDataReader(data: payload)
        let revision = try reader.readUInt64()
        let watermark = try reader.readUInt64()
        let monotonicNanoseconds = try reader.readUInt64()
        let speechEvidence: LiveTranscriptionSpeechEvidence
        switch try reader.readUInt32() {
        case 0: speechEvidence = .unknown
        case 1: speechEvidence = .noSpeechDetected
        case 2: speechEvidence = .speechDetected
        default: throw RetainedWhisperRuntimeError.invalidResponse
        }
        let textByteCount = Int(try reader.readUInt32())
        guard textByteCount <= maximumTextBytes,
              reader.remainingByteCount == textByteCount
        else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        let textData = try reader.readData(textByteCount)
        guard let text = String(data: textData, encoding: .utf8) else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        return WhisperStreamHypothesis(
            revision: revision,
            watermark: watermark,
            monotonicNanoseconds: monotonicNanoseconds,
            speechEvidence: speechEvidence,
            text: text
        )
    }

    struct CorrelatedError: Sendable {
        var category: UInt32
        var failedOperation: Operation
        var discriminator: UInt64?
    }

    static func parseCorrelatedError(_ payload: Data) -> CorrelatedError? {
        guard payload.count == 16 else { return nil }
        var reader = FrameDataReader(data: payload)
        guard let category = try? reader.readUInt32(),
              (1...6).contains(category),
              let operationRawValue = try? reader.readUInt16(),
              let operation = Operation(rawValue: operationRawValue),
              isRequestOperation(operation),
              (try? reader.readUInt16()) == 0,
              let rawDiscriminator = try? reader.readUInt64(),
              reader.remainingByteCount == 0
        else { return nil }
        return CorrelatedError(
            category: category,
            failedOperation: operation,
            discriminator: rawDiscriminator == UInt64.max ? nil : rawDiscriminator
        )
    }

    private static func isRequestOperation(_ operation: Operation) -> Bool {
        switch operation {
        case .load, .transcribe, .shutdown, .streamStart, .audioAppend,
             .streamDecode, .streamFinish, .streamCancel:
            return true
        case .ready, .result, .error, .stopped, .cancelled, .streamStarted,
             .audioAccepted, .hypothesis, .finalResult:
            return false
        }
    }

    static func isLegacyErrorPayload(_ payload: Data) -> Bool {
        guard payload.count == 4 else { return false }
        var reader = FrameDataReader(data: payload)
        guard let category = try? reader.readUInt32() else { return false }
        return (1...6).contains(category)
    }

    static func responseDiscriminator(for frame: Frame) -> UInt64? {
        guard frame.operation == .audioAccepted || frame.operation == .hypothesis,
              frame.payload.count >= 8
        else { return nil }
        var reader = FrameDataReader(data: frame.payload)
        return try? reader.readUInt64()
    }
}

private actor ProcessWhisperStreamingRuntimeSession: WhisperStreamingRuntimeSession {
    private struct AppendAcknowledgement: Hashable {
        var id: UUID
        var generation: UInt64
        var sequence: UInt64
        var watermark: UInt64
    }

    private enum Phase: Equatable {
        case idle
        case starting(id: UUID, generation: UInt64)
        case active(id: UUID, generation: UInt64, nextSequence: UInt64, watermark: UInt64, revision: UInt64)
        case appending(
            id: UUID,
            generation: UInt64,
            sequence: UInt64,
            watermark: UInt64,
            expectedWatermark: UInt64,
            revision: UInt64
        )
        case oneShot(id: UUID, generation: UInt64)
        case finishing(id: UUID, generation: UInt64)
        case cancelling(id: UUID, generation: UInt64)
        case shutDown
    }

    private let state: WhisperStreamingHelperProcessState
    private let inferenceTimeout: Duration
    private let runtimeIdentity: LiveTranscriptionRuntimeIdentity
    private var phase: Phase = .idle
    private var previewInFlightRevision: UInt64?
    private var appendAcknowledgementExpectedDuringFinish: AppendAcknowledgement?
    private var finalizedAppendAcknowledgements: Set<AppendAcknowledgement> = []

    static func start(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> ProcessWhisperStreamingRuntimeSession {
        let state = try WhisperStreamingHelperProcessState(configuration: configuration)
        do {
            let expectedIdentity = try WhisperStreamingRuntimeProtocol.expectedIdentity(
                configuration: configuration
            )
            let requestID = UUID()
            let response = try await state.exchange(
                .init(
                    operation: .load,
                    requestID: requestID,
                    generation: 0,
                    payload: try WhisperStreamingRuntimeProtocol.loadPayload(
                        modelPath: configuration.modelPath,
                        identity: expectedIdentity
                    )
                ),
                expecting: .ready,
                discriminator: nil,
                timeout: configuration.modelLoadTimeout
            )
            let readyIdentity = try WhisperStreamingRuntimeProtocol.parseIdentity(response.payload)
            guard response.requestID == requestID,
                  response.generation == 0,
                  WhisperStreamingRuntimeProtocol.hasExpectedConfiguration(
                    readyIdentity,
                    expected: expectedIdentity
                  ),
                  WhisperStreamingRuntimeProtocol.hasSingleResidentASRContext(readyIdentity)
            else {
                throw RetainedWhisperRuntimeError.staleResponse
            }
            return ProcessWhisperStreamingRuntimeSession(
                state: state,
                inferenceTimeout: configuration.inferenceTimeout,
                runtimeIdentity: readyIdentity
            )
        } catch {
            await state.shutdown()
            throw error
        }
    }

    private init(
        state: WhisperStreamingHelperProcessState,
        inferenceTimeout: Duration,
        runtimeIdentity: LiveTranscriptionRuntimeIdentity
    ) {
        self.state = state
        self.inferenceTimeout = inferenceTimeout
        self.runtimeIdentity = runtimeIdentity
    }

    func transcribe(_ request: WhisperRuntimeRequest) async throws -> Data {
        guard phase == .idle else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        phase = .oneShot(id: request.id, generation: request.generation)
        do {
            let response = try await state.exchange(
                .init(
                    operation: .transcribe,
                    requestID: request.id,
                    generation: request.generation,
                    payload: try WhisperRuntimeProtocol.transcriptionPayload(for: request)
                ),
                expecting: .result,
                discriminator: nil,
                timeout: WhisperRuntimeWatchdog.inferenceTimeout(
                    minimum: inferenceTimeout,
                    audioURL: request.audioURL
                ),
                terminateOnCancellation: true
            )
            guard phase == .oneShot(id: request.id, generation: request.generation),
                  response.requestID == request.id,
                  response.generation == request.generation
            else {
                throw RetainedWhisperRuntimeError.staleResponse
            }
            phase = .idle
            return response.payload
        } catch {
            if phase == .oneShot(id: request.id, generation: request.generation) {
                phase = .idle
            }
            throw error
        }
    }

    func startStream(
        id: UUID,
        generation: UInt64,
        configuration: WhisperStreamConfiguration
    ) async throws -> LiveTranscriptionRuntimeIdentity {
        guard phase == .idle else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        phase = .starting(id: id, generation: generation)
        do {
            let response = try await state.exchange(
                .init(
                    operation: .streamStart,
                    requestID: id,
                    generation: generation,
                    payload: try WhisperStreamingRuntimeProtocol.streamConfigurationPayload(
                        configuration,
                        identity: runtimeIdentity
                    )
                ),
                expecting: .streamStarted,
                discriminator: nil,
                timeout: .seconds(5)
            )
            let streamIdentity = try WhisperStreamingRuntimeProtocol.parseIdentity(response.payload)
            guard phase == .starting(id: id, generation: generation),
                  response.requestID == id,
                  response.generation == generation,
                  WhisperStreamingRuntimeProtocol.hasExpectedConfiguration(
                    streamIdentity,
                    expected: runtimeIdentity
                  ),
                  WhisperStreamingRuntimeProtocol.hasSingleResidentASRContext(streamIdentity)
            else {
                throw RetainedWhisperRuntimeError.staleResponse
            }
            phase = .active(id: id, generation: generation, nextSequence: 0, watermark: 0, revision: 0)
            return streamIdentity
        } catch {
            if phase == .starting(id: id, generation: generation) { phase = .idle }
            throw error
        }
    }

    func append(
        _ chunk: WhisperStreamAudioChunk,
        streamID: UUID,
        generation: UInt64
    ) async throws {
        guard case let .active(id, activeGeneration, nextSequence, watermark, revision) = phase,
              id == streamID,
              activeGeneration == generation,
              chunk.sequence == nextSequence,
              chunk.sampleOffset == watermark
        else {
            throw RetainedWhisperRuntimeError.staleResponse
        }
        let expectedWatermark = try adding(UInt64(chunk.sampleCount), to: watermark)
        let acknowledgement = AppendAcknowledgement(
            id: id,
            generation: activeGeneration,
            sequence: nextSequence,
            watermark: expectedWatermark
        )
        phase = .appending(
            id: id,
            generation: activeGeneration,
            sequence: nextSequence,
            watermark: watermark,
            expectedWatermark: expectedWatermark,
            revision: revision
        )
        do {
            let response = try await state.exchange(
                .init(
                    operation: .audioAppend,
                    requestID: streamID,
                    generation: generation,
                    payload: WhisperStreamingRuntimeProtocol.appendPayload(chunk)
                ),
                expecting: .audioAccepted,
                discriminator: chunk.sequence,
                timeout: .seconds(5)
            )
            let accepted = try WhisperStreamingRuntimeProtocol.parseAccepted(response.payload)
            guard accepted.sequence == chunk.sequence,
                  accepted.watermark == expectedWatermark,
                  case let .appending(
                    currentID,
                    currentGeneration,
                    currentSequence,
                    currentWatermark,
                    currentExpectedWatermark,
                    currentRevision
                  ) = phase,
                  currentID == id,
                  currentGeneration == activeGeneration,
                  currentSequence == nextSequence,
                  currentWatermark == watermark,
                  currentExpectedWatermark == expectedWatermark,
                  currentRevision == revision
            else {
                if phase == .finishing(id: id, generation: activeGeneration),
                   accepted.sequence == chunk.sequence,
                   accepted.watermark == expectedWatermark {
                    // Finish was serialized after this append frame. Preserve
                    // the terminal phase while allowing the accepted append to
                    // complete successfully for its caller.
                    if appendAcknowledgementExpectedDuringFinish == acknowledgement {
                        appendAcknowledgementExpectedDuringFinish = nil
                    }
                    return
                }
                if accepted.sequence == chunk.sequence,
                   accepted.watermark == expectedWatermark,
                   finalizedAppendAcknowledgements.remove(acknowledgement) != nil {
                    // AudioAccepted is framed before FinalResult, but their
                    // waiting tasks can re-enter this actor in either order.
                    // A successful matching final preserves this exact receipt
                    // so a delayed append continuation is not made stale.
                    return
                }
                throw RetainedWhisperRuntimeError.staleResponse
            }
            phase = .active(
                id: id,
                generation: activeGeneration,
                nextSequence: nextSequence &+ 1,
                watermark: expectedWatermark,
                revision: revision
            )
        } catch {
            if appendAcknowledgementExpectedDuringFinish == acknowledgement {
                appendAcknowledgementExpectedDuringFinish = nil
            }
            finalizedAppendAcknowledgements.remove(acknowledgement)
            if phase == .appending(
                id: id,
                generation: activeGeneration,
                sequence: nextSequence,
                watermark: watermark,
                expectedWatermark: expectedWatermark,
                revision: revision
            ) {
                phase = .active(
                    id: id,
                    generation: activeGeneration,
                    nextSequence: nextSequence,
                    watermark: watermark,
                    revision: revision
                )
            }
            throw error
        }
    }

    func requestHypothesis(
        streamID: UUID,
        generation: UInt64,
        revision: UInt64,
        watermark: UInt64
    ) async throws -> WhisperStreamHypothesis {
        guard case let .active(id, activeGeneration, nextSequence, acceptedWatermark, lastRevision) = phase,
              id == streamID,
              activeGeneration == generation,
              revision > lastRevision,
              watermark == acceptedWatermark,
              previewInFlightRevision == nil
        else {
            throw RetainedWhisperRuntimeError.staleResponse
        }
        // Reserve the revision before suspension. The caller coalesces newer
        // requests while this one is active; sending multiple requests would
        // leave a superseded helper response without an acknowledgement.
        previewInFlightRevision = revision
        defer {
            if previewInFlightRevision == revision { previewInFlightRevision = nil }
        }
        phase = .active(
            id: id,
            generation: activeGeneration,
            nextSequence: nextSequence,
            watermark: acceptedWatermark,
            revision: revision
        )
        let response = try await state.exchange(
            .init(
                operation: .streamDecode,
                requestID: streamID,
                generation: generation,
                payload: WhisperStreamingRuntimeProtocol.decodePayload(
                    revision: revision,
                    watermark: watermark
                )
            ),
            expecting: .hypothesis,
            discriminator: revision,
            timeout: inferenceTimeout
        )
        let hypothesis = try WhisperStreamingRuntimeProtocol.parseHypothesis(response.payload)
        let phaseStillOwnsHypothesis: Bool
        switch phase {
        case .active(let currentID, let currentGeneration, _, _, let currentRevision):
            phaseStillOwnsHypothesis = currentID == id
                && currentGeneration == activeGeneration
                && currentRevision == revision
        case .appending(
            let currentID,
            let currentGeneration,
            _,
            _,
            _,
            let currentRevision
        ):
            // Audio append is independent of the inference worker. A preview
            // for the prior accepted watermark remains valid while the next
            // ordered chunk waits for AudioAccepted.
            phaseStillOwnsHypothesis = currentID == id
                && currentGeneration == activeGeneration
                && currentRevision == revision
        default:
            phaseStillOwnsHypothesis = false
        }
        guard hypothesis.revision == revision,
              hypothesis.watermark == acceptedWatermark,
              runtimeIdentity.vadIdentifier != nil || hypothesis.speechEvidence == .unknown,
              phaseStillOwnsHypothesis
        else {
            throw RetainedWhisperRuntimeError.staleResponse
        }
        return hypothesis
    }

    func finishStream(
        id: UUID,
        generation: UInt64,
        request: WhisperStreamFinishRequest
    ) async throws -> Data {
        let expectedWatermark: UInt64
        let pendingAppendAcknowledgement: AppendAcknowledgement?
        switch phase {
        case .active(let activeID, let activeGeneration, _, let watermark, _)
            where activeID == id && activeGeneration == generation:
            expectedWatermark = watermark
            pendingAppendAcknowledgement = nil
        case .appending(
            let activeID,
            let activeGeneration,
            let sequence,
            _,
            let pendingWatermark,
            _
        ) where activeID == id && activeGeneration == generation:
            expectedWatermark = pendingWatermark
            pendingAppendAcknowledgement = .init(
                id: activeID,
                generation: activeGeneration,
                sequence: sequence,
                watermark: pendingWatermark
            )
        default:
            throw RetainedWhisperRuntimeError.staleResponse
        }
        guard request.expectedSampleCount == expectedWatermark else {
            throw RetainedWhisperRuntimeError.staleResponse
        }
        appendAcknowledgementExpectedDuringFinish = pendingAppendAcknowledgement
        phase = .finishing(id: id, generation: generation)
        state.supersedeHypotheses(requestID: id, generation: generation)
        do {
            let response = try await state.exchange(
                .init(
                    operation: .streamFinish,
                    requestID: id,
                    generation: generation,
                    payload: try WhisperStreamingRuntimeProtocol.finishPayload(
                        request,
                        identity: runtimeIdentity
                    )
                ),
                expecting: .finalResult,
                discriminator: nil,
                timeout: WhisperRuntimeWatchdog.inferenceTimeout(
                    minimum: inferenceTimeout,
                    audioURL: request.canonicalAudioURL
                )
            )
            guard phase == .finishing(id: id, generation: generation) else {
                throw RetainedWhisperRuntimeError.staleResponse
            }
            if let acknowledgement = appendAcknowledgementExpectedDuringFinish {
                finalizedAppendAcknowledgements.insert(acknowledgement)
                appendAcknowledgementExpectedDuringFinish = nil
            }
            phase = .idle
            return response.payload
        } catch {
            if phase == .finishing(id: id, generation: generation) {
                appendAcknowledgementExpectedDuringFinish = nil
                phase = .idle
            }
            throw error
        }
    }

    func cancelStream(id: UUID, generation: UInt64) async {
        let matchesActiveStream: Bool
        switch phase {
        case .starting(let activeID, let activeGeneration),
             .active(let activeID, let activeGeneration, _, _, _),
             .appending(let activeID, let activeGeneration, _, _, _, _),
             .finishing(let activeID, let activeGeneration):
            matchesActiveStream = activeID == id && activeGeneration == generation
        default:
            matchesActiveStream = false
        }
        guard matchesActiveStream else { return }
        appendAcknowledgementExpectedDuringFinish = nil
        phase = .cancelling(id: id, generation: generation)
        state.supersedeHypotheses(requestID: id, generation: generation)
        state.supersedeFinalResult(requestID: id, generation: generation)
        do {
            _ = try await state.exchange(
                .init(
                    operation: .streamCancel,
                    requestID: id,
                    generation: generation,
                    payload: Data()
                ),
                expecting: .cancelled,
                discriminator: nil,
                timeout: .seconds(2)
            )
        } catch {
            // Cancellation is best-effort. A timeout already marks an unhealthy
            // helper unavailable; an acknowledged cancel keeps it retained.
        }
        if phase == .cancelling(id: id, generation: generation) {
            phase = .idle
        }
    }

    func shutdown() async {
        guard phase != .shutDown else { return }
        appendAcknowledgementExpectedDuringFinish = nil
        finalizedAppendAcknowledgements.removeAll()
        phase = .shutDown
        await state.shutdown()
    }

    private func adding(_ value: UInt64, to base: UInt64) throws -> UInt64 {
        let (result, overflow) = base.addingReportingOverflow(value)
        guard !overflow else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        return result
    }
}

private struct WhisperStreamingResponseMatch: Sendable {
    var requestID: UUID
    var generation: UInt64
    var requestOperation: WhisperStreamingRuntimeProtocol.Operation
    var operation: WhisperStreamingRuntimeProtocol.Operation
    var discriminator: UInt64?

    func matches(_ frame: WhisperStreamingRuntimeProtocol.Frame) -> Bool {
        guard frame.requestID == requestID, frame.generation == generation else { return false }
        guard frame.operation == operation else { return false }
        guard let discriminator else { return true }
        return WhisperStreamingRuntimeProtocol.responseDiscriminator(for: frame) == discriminator
    }

    func matches(_ error: WhisperStreamingRuntimeProtocol.CorrelatedError) -> Bool {
        guard requestOperation == error.failedOperation else { return false }
        guard let errorDiscriminator = error.discriminator else { return true }
        return discriminator == errorDiscriminator
    }
}

private final class WhisperStreamingPendingResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<WhisperStreamingRuntimeProtocol.Frame, Error>?
    private var continuation: CheckedContinuation<WhisperStreamingRuntimeProtocol.Frame, Error>?

    func wait() async throws -> WhisperStreamingRuntimeProtocol.Frame {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<WhisperStreamingRuntimeProtocol.Frame, Error>? = lock.withLock {
                if let result = self.result { return result }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func resolve(_ result: Result<WhisperStreamingRuntimeProtocol.Frame, Error>) {
        let continuation: CheckedContinuation<WhisperStreamingRuntimeProtocol.Frame, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class WhisperStreamingResponseRegistry: @unchecked Sendable {
    struct Registration: Sendable {
        var token: UUID
        var pending: WhisperStreamingPendingResponse
    }

    private struct Entry {
        var match: WhisperStreamingResponseMatch
        var pending: WhisperStreamingPendingResponse
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func register(_ match: WhisperStreamingResponseMatch) throws -> Registration {
        let token = UUID()
        let pending = WhisperStreamingPendingResponse()
        try lock.withLock {
            guard entries.count < 64 else {
                throw RetainedWhisperRuntimeError.helperUnavailable
            }
            entries[token] = Entry(match: match, pending: pending)
        }
        return Registration(token: token, pending: pending)
    }

    func receive(_ frame: WhisperStreamingRuntimeProtocol.Frame) {
        if frame.operation == .error {
            let correlatedError = WhisperStreamingRuntimeProtocol.parseCorrelatedError(frame.payload)
            let isLegacyError = WhisperStreamingRuntimeProtocol.isLegacyErrorPayload(frame.payload)
            let pending: [WhisperStreamingPendingResponse] = lock.withLock {
                let matchingTokens: [UUID] = entries.compactMap { token, entry -> UUID? in
                    guard entry.match.requestID == frame.requestID,
                          entry.match.generation == frame.generation
                    else { return nil }
                    if let correlatedError {
                        return entry.match.matches(correlatedError) ? token : nil
                    }
                    // A four-byte Error is retained only for the pre-negotiation
                    // Load exchange. Any other legacy or malformed Error fails
                    // the stream identity closed instead of risking a hang.
                    return isLegacyError || correlatedError == nil ? token : nil
                }
                return matchingTokens.compactMap { entries.removeValue(forKey: $0)?.pending }
            }
            let error: RetainedWhisperRuntimeError = correlatedError?.category == 6
                ? .vadIntegrityFailure
                : .invalidResponse
            for response in pending {
                response.resolve(.failure(error))
            }
            return
        }
        let pending: WhisperStreamingPendingResponse? = lock.withLock {
            guard let match = entries.first(where: { $0.value.match.matches(frame) }) else {
                return nil
            }
            entries.removeValue(forKey: match.key)
            return match.value.pending
        }
        guard let pending else { return }
        pending.resolve(.success(frame))
    }

    func fail(token: UUID, with error: Error) {
        let pending = lock.withLock { entries.removeValue(forKey: token)?.pending }
        pending?.resolve(.failure(error))
    }

    func failAll(with error: Error) {
        let pending: [WhisperStreamingPendingResponse] = lock.withLock {
            let values = entries.values.map(\.pending)
            entries.removeAll()
            return values
        }
        for response in pending { response.resolve(.failure(error)) }
    }

    func failMatching(
        requestID: UUID,
        generation: UInt64,
        operation: WhisperStreamingRuntimeProtocol.Operation,
        with error: Error
    ) {
        let pending: [WhisperStreamingPendingResponse] = lock.withLock {
            let matchingTokens = entries.compactMap { token, entry in
                entry.match.requestID == requestID
                    && entry.match.generation == generation
                    && entry.match.operation == operation ? token : nil
            }
            return matchingTokens.compactMap { entries.removeValue(forKey: $0)?.pending }
        }
        for response in pending { response.resolve(.failure(error)) }
    }
}

private final class WhisperStreamingHelperProcessState: @unchecked Sendable {
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let registry = WhisperStreamingResponseRegistry()
    private var isTerminated = false
    // An idle helper leaves this read blocked until a frame or EOF arrives.
    private let readerQueue = DispatchQueue(label: "steno.runtime.streaming-reader", qos: .userInitiated)

    init(configuration: RetainedWhisperTranscriptionConfiguration) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        do {
            try WhisperPipeSafety.suppressSIGPIPE(on: inputPipe.fileHandleForWriting.fileDescriptor)
        } catch {
            try? inputPipe.fileHandleForReading.close()
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            throw error
        }

        let process = Process()
        process.executableURL = configuration.helperExecutableURL
        process.arguments = ["--protocol-version", "2"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        var environment = configuration.environment ?? WhisperRuntimeConfiguration.processEnvironment(
            whisperCLIPath: configuration.helperExecutableURL.path,
            modelPath: configuration.modelPath.path
        )
        environment["STENO_PARENT_PID"] = String(getpid())
        process.environment = environment

        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            throw RetainedWhisperRuntimeError.helperUnavailable
        }

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        readerQueue.async { [weak self] in
            self?.readResponsesUntilEOF()
        }
    }

    func exchange(
        _ frame: WhisperStreamingRuntimeProtocol.Frame,
        expecting operation: WhisperStreamingRuntimeProtocol.Operation,
        discriminator: UInt64?,
        timeout: Duration,
        terminateOnCancellation: Bool = false
    ) async throws -> WhisperStreamingRuntimeProtocol.Frame {
        try Task.checkCancellation()
        let registration = try registry.register(
            .init(
                requestID: frame.requestID,
                generation: frame.generation,
                requestOperation: frame.operation,
                operation: operation,
                discriminator: discriminator
            )
        )
        do {
            try write(frame)
        } catch {
            registry.fail(token: registration.token, with: error)
            throw error
        }

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: WhisperStreamingRuntimeProtocol.Frame.self) { group in
                group.addTask { try await registration.pending.wait() }
                group.addTask { [weak self] in
                    try await Task.sleep(for: timeout)
                    self?.registry.fail(
                        token: registration.token,
                        with: RetainedWhisperRuntimeError.helperUnavailable
                    )
                    self?.terminate()
                    throw RetainedWhisperRuntimeError.helperUnavailable
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else {
                    throw RetainedWhisperRuntimeError.helperUnavailable
                }
                return response
            }
        } onCancel: { [weak self, registry] in
            registry.fail(token: registration.token, with: CancellationError())
            if terminateOnCancellation {
                self?.terminate()
            }
        }
    }

    func shutdown() async {
        let shouldRequestShutdown = stateLock.withLock { !isTerminated && process.isRunning }
        if shouldRequestShutdown {
            let id = UUID()
            _ = try? await exchange(
                .init(operation: .shutdown, requestID: id, generation: 0, payload: Data()),
                expecting: .stopped,
                discriminator: nil,
                timeout: .milliseconds(250)
            )
        }
        terminate()
        await WhisperProcessExitWaiter.wait { [process] in process.isRunning }
        closeHandles()
    }

    func supersedeHypotheses(requestID: UUID, generation: UInt64) {
        registry.failMatching(
            requestID: requestID,
            generation: generation,
            operation: .hypothesis,
            with: RetainedWhisperRuntimeError.staleResponse
        )
    }

    func supersedeFinalResult(requestID: UUID, generation: UInt64) {
        registry.failMatching(
            requestID: requestID,
            generation: generation,
            operation: .finalResult,
            with: RetainedWhisperRuntimeError.staleResponse
        )
    }

    private func write(_ frame: WhisperStreamingRuntimeProtocol.Frame) throws {
        try writeLock.withLock {
            guard stateLock.withLock({ !isTerminated && process.isRunning }) else {
                throw RetainedWhisperRuntimeError.helperUnavailable
            }
            do {
                try input.write(contentsOf: frame.encoded())
            } catch {
                throw RetainedWhisperRuntimeError.helperUnavailable
            }
        }
    }

    private func readResponsesUntilEOF() {
        do {
            while stateLock.withLock({ !isTerminated }) {
                let frame = try WhisperStreamingRuntimeProtocol.decodeFrame(from: output)
                registry.receive(frame)
            }
        } catch {
            registry.failAll(with: RetainedWhisperRuntimeError.helperUnavailable)
            terminate()
        }
    }

    private func terminate() {
        let pid: pid_t? = stateLock.withLock {
            guard !isTerminated else { return nil }
            isTerminated = true
            try? input.close()
            guard process.isRunning else { return nil }
            process.terminate()
            return process.processIdentifier
        }
        registry.failAll(with: RetainedWhisperRuntimeError.helperUnavailable)
        guard let pid, pid > 0 else {
            closeHandles()
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            WhisperChildProcessEscalation.forceKillIfStillOwned(pid)
        }
    }

    private func closeHandles() {
        try? input.close()
        try? output.close()
    }
}

private struct FrameDataReader {
    let data: Data
    var offset = 0

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(2)
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = try readBytes(16)
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    var remainingByteCount: Int {
        data.count - offset
    }

    mutating func readData(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    mutating func readString(maximumByteCount: Int) throws -> String {
        let count = Int(try readUInt32())
        guard count <= maximumByteCount else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        let bytes = try readData(count)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        return value
    }

    private mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        let range = offset..<(offset + count)
        offset += count
        return Array(data[range])
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendUUID(_ value: UUID) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendBoundedString(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= 1_048_576 else {
            throw RetainedWhisperRuntimeError.unsupportedConfiguration
        }
        appendBigEndian(UInt32(bytes.count))
        append(bytes)
    }

    mutating func appendOptionalBoundedString(_ value: String?) throws {
        guard let value else {
            appendBigEndian(UInt32.max)
            return
        }
        try appendBoundedString(value)
    }
}

private extension FileHandle {
    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0 else {
            throw RetainedWhisperRuntimeError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk = try read(upToCount: count - data.count) ?? Data()
            guard !chunk.isEmpty else {
                throw RetainedWhisperRuntimeError.helperUnavailable
            }
            data.append(chunk)
        }
        return data
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#else
import Foundation

struct ProcessWhisperRuntimeSessionFactory: WhisperRuntimeSessionFactory {
    func makeSession(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> any WhisperRuntimeSession {
        _ = configuration
        throw RetainedWhisperRuntimeError.helperUnavailable
    }
}
#endif
