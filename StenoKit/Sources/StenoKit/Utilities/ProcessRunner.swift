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

        let state = ProcessRunState(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessExecutionResult, Error>) in
                state.prepare(continuation: continuation)
                process.terminationHandler = { _ in
                    let output = outputPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                    let error = errorPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                    state.finish(terminationStatus: process.terminationStatus, standardOutput: output, standardError: error)
                }

                do {
                    try process.run()
                } catch {
                    state.fail(error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var continuation: CheckedContinuation<ProcessExecutionResult, Error>?
    private var hasFinished = false
    private var wasCancelled = false

    init(process: Process) {
        self.process = process
    }

    func prepare(continuation: CheckedContinuation<ProcessExecutionResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
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
        lock.unlock()
        continuation.resume(throwing: error)
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let shouldResume = !hasFinished && !process.isRunning
        let continuation = shouldResume ? self.continuation : nil
        if shouldResume {
            hasFinished = true
            self.continuation = nil
        }
        lock.unlock()

        if process.isRunning {
            process.terminate()
        } else if let continuation {
            continuation.resume(throwing: CancellationError())
        }
    }
}
