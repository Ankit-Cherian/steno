#if os(macOS)
import Darwin
import Foundation

private enum WhisperRuntimeProtocol {
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
        var flags: UInt32 = 0
        if request.suppressNonSpeechTokens { flags |= 1 << 0 }
        if request.vadModelPath != nil { flags |= 1 << 1 }
        payload.appendBigEndian(flags)
        try payload.appendBoundedString(request.audioURL.path)
        try payload.appendBoundedString(request.language)
        try payload.appendOptionalBoundedString(request.prompt)
        try payload.appendOptionalBoundedString(request.suppressRegex)
        try payload.appendOptionalBoundedString(request.vadModelPath?.path)
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
                    try await Task.detached(priority: .userInitiated) { [self] in
                        try blockingExchange(frame)
                    }.value
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
        await Task.detached(priority: .utility) { [process] in
            if process.isRunning {
                process.waitUntilExit()
            }
        }.value
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

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let shouldKill = self.stateLock.withLock {
                self.process.isRunning && self.process.processIdentifier == pid
            }
            if shouldKill {
                kill(pid, SIGKILL)
            }
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
