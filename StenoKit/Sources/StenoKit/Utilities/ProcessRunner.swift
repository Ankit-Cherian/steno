import Foundation

public struct ProcessExecutionResult: Sendable {
    public let terminationStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(terminationStatus: Int32, standardOutput: Data, standardError: Data) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        standardOutput: FileHandle? = nil,
        standardError: FileHandle? = nil
    ) async throws -> ProcessExecutionResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let outputPipe = standardOutput == nil ? Pipe() : nil
        let errorPipe = standardError == nil ? Pipe() : nil

        process.standardOutput = standardOutput ?? outputPipe
        process.standardError = standardError ?? errorPipe

        // Stream pipe data as it arrives to prevent the subprocess from blocking
        // on a full pipe buffer (64 KB on macOS). Without streaming, a verbose
        // subprocess can deadlock: it blocks on write(), we wait for it to exit.
        let outputBuffer = PipeAccumulator()
        let errorBuffer = PipeAccumulator()

        if let pipe = outputPipe {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { outputBuffer.append(chunk) }
            }
        }
        if let pipe = errorPipe {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { errorBuffer.append(chunk) }
            }
        }

        let state = ProcessRunState(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessExecutionResult, Error>) in
                process.terminationHandler = { _ in
                    // Disable streaming handlers first, then drain remaining bytes.
                    outputPipe?.fileHandleForReading.readabilityHandler = nil
                    errorPipe?.fileHandleForReading.readabilityHandler = nil

                    if let pipe = outputPipe {
                        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                        if !remaining.isEmpty { outputBuffer.append(remaining) }
                    }
                    if let pipe = errorPipe {
                        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                        if !remaining.isEmpty { errorBuffer.append(remaining) }
                    }

                    state.finish(
                        terminationStatus: process.terminationStatus,
                        standardOutput: outputBuffer.consume(),
                        standardError: errorBuffer.consume()
                    )
                }

                guard state.prepareToLaunch(continuation: continuation) else {
                    process.terminationHandler = nil
                    outputPipe?.fileHandleForReading.readabilityHandler = nil
                    errorPipe?.fileHandleForReading.readabilityHandler = nil
                    return
                }

                do {
                    try process.run()
                    state.didLaunch()
                } catch {
                    process.terminationHandler = nil
                    outputPipe?.fileHandleForReading.readabilityHandler = nil
                    errorPipe?.fileHandleForReading.readabilityHandler = nil
                    state.fail(error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Thread-safe accumulator for pipe data arriving via readabilityHandler.
private final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func consume() -> Data {
        lock.lock()
        let result = data
        lock.unlock()
        return result
    }
}

private final class ProcessRunState: @unchecked Sendable {
    private enum LaunchState: Equatable {
        case notStarted
        case launching
        case running
    }

    private let lock = NSLock()
    private let process: Process
    private var continuation: CheckedContinuation<ProcessExecutionResult, Error>?
    private var hasFinished = false
    private var wasCancelled = false
    private var launchState: LaunchState = .notStarted

    init(process: Process) {
        self.process = process
    }

    func prepareToLaunch(
        continuation: CheckedContinuation<ProcessExecutionResult, Error>
    ) -> Bool {
        lock.lock()
        guard !hasFinished, !wasCancelled else {
            hasFinished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        launchState = .launching
        lock.unlock()
        return true
    }

    func didLaunch() {
        lock.lock()
        launchState = .running
        let shouldTerminate = wasCancelled && !hasFinished
        lock.unlock()

        if shouldTerminate {
            terminateAndEscalate()
        }
    }

    func finish(terminationStatus: Int32, standardOutput: Data, standardError: Data) {
        lock.lock()
        guard !hasFinished, let continuation else {
            lock.unlock()
            return
        }
        hasFinished = true
        self.continuation = nil
        let cancelled = wasCancelled
        lock.unlock()

        // Never resume continuations while holding lock.
        // Cancellation handlers may execute concurrently and can otherwise deadlock.
        if cancelled {
            continuation.resume(throwing: CancellationError())
            return
        }

        continuation.resume(
            returning: ProcessExecutionResult(
                terminationStatus: terminationStatus,
                standardOutput: standardOutput,
                standardError: standardError
            )
        )
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !hasFinished, let continuation else {
            lock.unlock()
            return
        }
        hasFinished = true
        self.continuation = nil
        let cancelled = wasCancelled
        lock.unlock()
        // Resume outside lock. See withTaskCancellationHandler lock guidance.
        continuation.resume(throwing: cancelled ? CancellationError() : error)
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let shouldTerminate = !hasFinished && launchState == .running
        lock.unlock()

        if shouldTerminate {
            terminateAndEscalate()
        }
    }

    private func terminateAndEscalate() {
        guard process.isRunning else { return }
        process.terminate() // SIGTERM
        // Escalate to SIGKILL after 3 seconds if the subprocess ignores SIGTERM.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            guard pid > 0,
                  self.process.isRunning,
                  self.process.processIdentifier == pid else {
                return
            }
            kill(pid, SIGKILL)
        }
    }
}
